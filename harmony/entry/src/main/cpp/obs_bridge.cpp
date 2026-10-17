// ---------------------------------------------------------------------------
// obs_bridge.cpp — the NAPI bridge implementation.
//
// Two build modes (see CMakeLists.txt):
//   * HAVE_LIBOBS undefined (shell-only): every libobs-dependent entry point
//     throws a descriptive napi error; the ArkTS wrapper logs it and degrades.
//     The HarmonyOS-native parts (XComponent/EGL seam, OHAudio loopback +
//     microphone capture, live level metering) are REAL and fully functional
//     in this mode.
//   * HAVE_LIBOBS defined: genuine libobs calls (obs_startup, obs_scene_create,
//     obs_source_create, obs_output_start, obs_get_video, ...).
// ---------------------------------------------------------------------------

#include "obs_bridge.h"
#include "xcomponent_surface.h"

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <dlfcn.h>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <deviceinfo.h>
#include <hilog/log.h>

// HarmonyOS native multimedia APIs (always available — part of the NDK).
#include <ohaudio/native_audiocapturer.h>
#include <ohaudio/native_audiostream_base.h>
#include <ohaudio/native_audiostreambuilder.h>

#ifdef HAVE_LIBOBS
// libobs's util/base.h declares an unscoped enum { LOG_ERROR, LOG_WARNING,
// LOG_INFO, LOG_DEBUG } that collides with hilog's LogLevel enumerators in
// this translation unit. Rename the libobs ones across the includes; the
// values are compile-time constants so the prebuilt libobs.so is unaffected,
// and after the #undefs our OH_LOG_* calls bind to hilog's enum again.
#define LOG_ERROR OBS_LOG_ERROR
#define LOG_WARNING OBS_LOG_WARNING
#define LOG_INFO OBS_LOG_INFO
#define LOG_DEBUG OBS_LOG_DEBUG
#include <graphics/graphics.h>
#include <graphics/matrix4.h> // struct matrix4 full definition (box transform AABB)
#include <util/base.h>
#include <media-io/audio-io.h>
#include <media-io/video-io.h>
#include <obs-data.h>
#include <obs-module.h>
#include <obs-harmony-api.h>  // public surface only; obs-harmony.h drags in obs-internal.h
#include <obs.h>
#include <util/platform.h> // os_gettime_ns (web source feed timestamps)
#undef LOG_ERROR
#undef LOG_WARNING
#undef LOG_INFO
#undef LOG_DEBUG
#endif

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0B50
#define LOG_TAG "obs_bridge"

namespace obs_bridge {
namespace {

// ===========================================================================
// Small napi helpers
// ===========================================================================

napi_value CreateBool(napi_env env, bool value)
{
    napi_value result = nullptr;
    napi_get_boolean(env, value, &result);
    return result;
}

napi_value CreateInt32(napi_env env, int32_t value)
{
    napi_value result = nullptr;
    napi_create_int32(env, value, &result);
    return result;
}

napi_value CreateInt64(napi_env env, int64_t value)
{
    napi_value result = nullptr;
    napi_create_int64(env, value, &result);
    return result;
}

napi_value CreateDouble(napi_env env, double value)
{
    napi_value result = nullptr;
    napi_create_double(env, value, &result);
    return result;
}

napi_value CreateString(napi_env env, const std::string &value)
{
    napi_value result = nullptr;
    napi_create_string_utf8(env, value.c_str(), value.size(), &result);
    return result;
}

void SetProperty(napi_env env, napi_value object, const char *name, napi_value value)
{
    if (value != nullptr) {
        napi_set_named_property(env, object, name, value);
    }
}

bool GetStringArg(napi_env env, napi_value value, std::string &out)
{
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) {
        return false;
    }
    std::vector<char> buffer(length + 1, '\0');
    size_t copied = 0;
    if (napi_get_value_string_utf8(env, value, buffer.data(), length + 1, &copied) != napi_ok) {
        return false;
    }
    out.assign(buffer.data(), copied);
    return true;
}

napi_value GetUndefined(napi_env env)
{
    napi_value value = nullptr;
    napi_get_undefined(env, &value);
    return value;
}

// ===========================================================================
// Audio mixer tracks — REAL OBS sources, not shadow capturers.
//
// The mixer used to run its own two OH_AudioCapturers purely to paint the
// meters, while the actual recorded/streamed audio was produced by the
// harmony_mic_capture / harmony_desktop_audio OBS sources. That was a
// "phantom mixer": the faders and mute changed meters that fed nothing, and
// what you heard in the recording was out of the mixer's control (user
// report 10-17). Now one track per live audio SOURCE: we enumerate every
// input source that carries OBS_SOURCE_AUDIO, attach an obs_volmeter to it
// for the level meter, and route mute/volume straight to the source
// (obs_source_set_muted / set_volume) so the mixer is the single knob for
// program audio — exactly like the desktop OBS mixer.
//
// The old async loopback authorization lives in the desktop-audio plugin
// now; the bridge just reads whether the source is active.
// ===========================================================================

// Mirrored 1:1 in ArkTS — see types/libobs_bridge/index.d.ts (NativeAudioTrack.state).
enum class CaptureState : int32_t {
    Unsupported = 0,
    Idle = 1,
    Requesting = 2,   // async loopback authorization pending
    Running = 3,
    NotAuthorized = 4, // user denied the system privacy dialog
    Failed = 5,
};

#ifdef HAVE_LIBOBS

// One mixer track == one live audio obs_source_t. We hold only a WEAK
// reference: a strong ref here would keep a source alive forever after the
// user deletes it from the scene (it would linger as an un-removable mixer
// row — the orphan bug of 10-17). obs_weak_source_get_source() upgrades to a
// temporary strong ref exactly where we touch the source; the attached
// volmeter auto-detaches via the source's destroy signal.
struct SourceTrack {
    std::string uuid;
    obs_weak_source_t *weak = nullptr; // owned weak ref
    obs_volmeter_t *meter = nullptr;
    std::atomic<float> peak{0.0f};    // linear 0..1, latest meter frame
    std::atomic<float> rms{0.0f};     // linear 0..1, latest meter frame
    std::atomic<int64_t> lastNs{0};   // last meter callback; drives decay
    bool seen = false;                // reconciler scratch (per GetAudioTracks)
};

std::mutex g_audioMutex;
static std::map<std::string, SourceTrack *> g_audioTracks; // keyed by source uuid

// Upgrade a track's weak ref to a temporary strong ref (nullptr if the
// source is already gone). Caller must obs_source_release() the result.
static obs_source_t *LockTrackSource(SourceTrack *track)
{
    if (track->weak == nullptr) {
        return nullptr;
    }
    return obs_weak_source_get_source(track->weak);
}

// Runs on the libobs audio thread. magnitude/peak are dBFS; fold to a linear
// 0..1 multiplier for the existing meter UI and stamp the update time.
static float clamp01f(float v)
{
    return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
}

void OnMeterUpdated(void *param, const float magnitude[MAX_AUDIO_CHANNELS],
                    const float peak[MAX_AUDIO_CHANNELS],
                    const float input_peak[MAX_AUDIO_CHANNELS])
{
    SourceTrack *track = static_cast<SourceTrack *>(param);
    if (track == nullptr) {
        return;
    }
    float maxMagDb = magnitude[0];
    float maxPeakDb = peak[0];
    for (int i = 1; i < MAX_AUDIO_CHANNELS; ++i) {
        if (magnitude[i] > maxMagDb) {
            maxMagDb = magnitude[i];
        }
        if (peak[i] > maxPeakDb) {
            maxPeakDb = peak[i];
        }
    }
    if (maxMagDb < -90.0f) {
        maxMagDb = -90.0f;
    }
    if (maxPeakDb < -90.0f) {
        maxPeakDb = -90.0f;
    }
    track->rms.store(clamp01f(obs_db_to_mul(maxMagDb)), std::memory_order_relaxed);
    track->peak.store(clamp01f(obs_db_to_mul(maxPeakDb)), std::memory_order_relaxed);
    track->lastNs.store(os_gettime_ns(), std::memory_order_relaxed);
    (void)input_peak;
}

// Register/update a mixer track for one audio source. Scope is decided by
// the caller: NativeGetAudioTracks snapshots the items of every registered
// scene, so a source that is in NO scene (an orphan left behind by a buggy
// remove path) never gets a row — and a track whose source vanished from all
// scenes is pruned below.
static void RegisterAudioSource(obs_source_t *source)
{
    if (obs_source_get_type(source) != OBS_SOURCE_TYPE_INPUT) {
        return;
    }
    if ((obs_source_get_output_flags(source) & OBS_SOURCE_AUDIO) == 0) {
        return;
    }
    const char *uuidRaw = obs_source_get_uuid(source);
    const std::string uuid = uuidRaw != nullptr ? uuidRaw : "";
    if (uuid.empty()) {
        return;
    }
    auto it = g_audioTracks.find(uuid);
    if (it == g_audioTracks.end()) {
        obs_weak_source_t *weak = obs_source_get_weak_source(source);
        if (weak == nullptr) {
            return;
        }
        SourceTrack *track = new SourceTrack();
        track->uuid = uuid;
        track->weak = weak;
        track->seen = true;
        track->meter = obs_volmeter_create(OBS_FADER_LOG);
        if (track->meter != nullptr) {
            obs_volmeter_set_peak_meter_type(track->meter, SAMPLE_PEAK_METER);
            obs_volmeter_attach_source(track->meter, source);
            obs_volmeter_add_callback(track->meter, &OnMeterUpdated, track);
        }
        g_audioTracks[uuid] = track;
    } else {
        it->second->seen = true;
    }
}

// Walk one scene's items, collecting strong refs to each audio source into
// the snapshot vector (caller releases them after registration).
static bool CollectSceneAudioRef(obs_scene_t * /*scene*/, obs_sceneitem_t *item, void *param)
{
    auto *out = static_cast<std::vector<obs_source_t *> *>(param);
    obs_source_t *src = obs_sceneitem_get_source(item);
    if (src != nullptr) {
        obs_source_t *ref = obs_source_get_ref(src);
        if (ref != nullptr) {
            out->push_back(ref);
        }
    }
    return true;
}

// Destroy + erase every track the last enum pass did not see (source removed).
void PruneAudioTracksLocked()
{
    for (auto it = g_audioTracks.begin(); it != g_audioTracks.end();) {
        if (it->second->seen) {
            ++it;
            continue;
        }
        SourceTrack *track = it->second;
        if (track->meter != nullptr) {
            obs_volmeter_remove_callback(track->meter, &OnMeterUpdated, track);
            obs_volmeter_detach_source(track->meter);
            obs_volmeter_destroy(track->meter);
        }
        if (track->weak != nullptr) {
            obs_weak_source_release(track->weak);
        }
        delete track;
        it = g_audioTracks.erase(it);
    }
}

napi_value BuildTrackObject(napi_env env, SourceTrack *track)
{
    napi_value obj = nullptr;
    napi_create_object(env, &obj);
    SetProperty(env, obj, "id", CreateString(env, track->uuid));
    // Temporary strong ref for the reads below; the source cannot die while
    // we hold it.
    obs_source_t *source = LockTrackSource(track);
    const char *nameRaw = source != nullptr ? obs_source_get_name(source) : nullptr;
    SetProperty(env, obj, "name", CreateString(env, nameRaw != nullptr ? nameRaw : ""));
    SetProperty(env, obj, "muted", CreateBool(env, source != nullptr && obs_source_muted(source)));
    SetProperty(env, obj, "volume",
                CreateDouble(env, source != nullptr ? obs_source_get_volume(source) : 0.0));
    // The capture plugins mirror their real state (incl. the async loopback
    // authorization: Requesting / NotAuthorized / Failed) into the source's
    // private settings; prefer that over the bare active flag. A source that
    // never published (older plugin, non-harmony audio source) falls back
    // to active ? Running : Idle.
    int32_t state = (source != nullptr && obs_source_active(source))
                        ? static_cast<int32_t>(CaptureState::Running)
                        : static_cast<int32_t>(CaptureState::Idle);
    if (source != nullptr) {
        obs_data_t *ps = obs_source_get_private_settings(source);
        if (ps != nullptr) {
            const long long published = obs_data_get_int(ps, "harmony_capture_state");
            obs_data_release(ps);
            if (published >= 1 && published <= 5) {
                state = static_cast<int32_t>(published);
            }
        }
        obs_source_release(source);
    }
    SetProperty(env, obj, "state", CreateInt32(env, state));
    SetProperty(env, obj, "supported", CreateBool(env, true));
    return obj;
}

#endif // HAVE_LIBOBS

// Free the track registry (used by ShutdownCore; safe in both build modes).
void ReleaseAllAudioTracks()
{
#ifdef HAVE_LIBOBS
    std::lock_guard<std::mutex> lock(g_audioMutex);
    for (auto &entry : g_audioTracks) {
        SourceTrack *track = entry.second;
        if (track->meter != nullptr) {
            obs_volmeter_remove_callback(track->meter, &OnMeterUpdated, track);
            obs_volmeter_detach_source(track->meter);
            obs_volmeter_destroy(track->meter);
        }
        if (track->weak != nullptr) {
            obs_weak_source_release(track->weak);
        }
        delete track;
    }
    g_audioTracks.clear();
#endif
}

// ===========================================================================
// Stats push channel (napi threadsafe function) + output runtime
// ===========================================================================

struct StatsPayload {
    bool streaming = false;
    bool recording = false;
    double bitrateKbps = 0.0;
    int64_t droppedFrames = 0;
    int64_t totalFrames = 0;
    int64_t uptimeSeconds = 0;
};

std::mutex g_statsMutex;
napi_threadsafe_function g_statsTsf = nullptr;

void CallJsStats(napi_env env, napi_value jsCallback, void * /*context*/, void *data)
{
    std::unique_ptr<StatsPayload> payload(static_cast<StatsPayload *>(data));
    if (env == nullptr || jsCallback == nullptr || payload == nullptr) {
        return; // env is being torn down; drop the payload
    }
    napi_value obj = nullptr;
    napi_create_object(env, &obj);
    SetProperty(env, obj, "streaming", CreateBool(env, payload->streaming));
    SetProperty(env, obj, "recording", CreateBool(env, payload->recording));
    SetProperty(env, obj, "bitrateKbps", CreateDouble(env, payload->bitrateKbps));
    SetProperty(env, obj, "droppedFrames", CreateInt64(env, payload->droppedFrames));
    SetProperty(env, obj, "totalFrames", CreateInt64(env, payload->totalFrames));
    SetProperty(env, obj, "uptimeSeconds", CreateInt64(env, payload->uptimeSeconds));

    napi_value global = nullptr;
    napi_get_global(env, &global);
    napi_value ignored = nullptr;
    napi_call_function(env, global, jsCallback, 1, &obj, &ignored);
}

void PushStats(const StatsPayload &stats)
{
    std::lock_guard<std::mutex> lock(g_statsMutex);
    if (g_statsTsf == nullptr) {
        return;
    }
    if (napi_acquire_threadsafe_function(g_statsTsf) != napi_ok) {
        return;
    }
    StatsPayload *copy = new StatsPayload(stats);
    if (napi_call_threadsafe_function(g_statsTsf, copy, napi_tsfn_nonblocking) != napi_ok) {
        delete copy;
    }
    napi_release_threadsafe_function(g_statsTsf, napi_tsfn_release);
}

#ifdef HAVE_LIBOBS

std::mutex g_outputMutex;
obs_output_t *g_streamOutput = nullptr;
obs_service_t *g_streamService = nullptr;
obs_output_t *g_recordOutput = nullptr;
std::chrono::steady_clock::time_point g_streamStartTime;
std::chrono::steady_clock::time_point g_recordStartTime;

std::atomic<bool> g_statsThreadRun{false};
std::thread g_statsThread;

StatsPayload ComputeStatsLocked()
{
    StatsPayload stats;
    const bool streaming = g_streamOutput != nullptr && obs_output_active(g_streamOutput);
    const bool recording = g_recordOutput != nullptr && obs_output_active(g_recordOutput);
    stats.streaming = streaming;
    stats.recording = recording;
    obs_output_t *primary = streaming ? g_streamOutput : (recording ? g_recordOutput : nullptr);
    if (primary != nullptr) {
        const auto startTime = streaming ? g_streamStartTime : g_recordStartTime;
        const auto elapsed = std::chrono::steady_clock::now() - startTime;
        const double seconds =
            std::chrono::duration_cast<std::chrono::milliseconds>(elapsed).count() / 1000.0;
        const uint64_t totalBytes = obs_output_get_total_bytes(primary);
        stats.droppedFrames = obs_output_get_frames_dropped(primary);
        stats.totalFrames = obs_output_get_total_frames(primary);
        stats.uptimeSeconds = static_cast<int64_t>(seconds);
        stats.bitrateKbps = seconds > 0.5
                                ? (static_cast<double>(totalBytes) * 8.0 / 1000.0) / seconds
                                : 0.0;
    }
    return stats;
}

void StatsThreadMain()
{
    while (g_statsThreadRun.load()) {
        // Sleep in small slices so shutdown stays responsive.
        for (int i = 0; i < 10 && g_statsThreadRun.load(); ++i) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
        if (!g_statsThreadRun.load()) {
            break;
        }
        StatsPayload stats;
        {
            std::lock_guard<std::mutex> lock(g_outputMutex);
            stats = ComputeStatsLocked();
        }
        PushStats(stats);
        if (!stats.streaming && !stats.recording) {
            // Outputs finished (e.g. network drop ended the stream): push the
            // final state once and let the thread exit; it is restarted by
            // the next Start call.
            break;
        }
    }
}

void StartStatsThread()
{
    if (g_statsThreadRun.exchange(true)) {
        return; // already running
    }
    if (g_statsThread.joinable()) {
        g_statsThread.join();
    }
    g_statsThread = std::thread(StatsThreadMain);
}

void StopStatsThread()
{
    if (!g_statsThreadRun.exchange(false)) {
        if (g_statsThread.joinable()) {
            g_statsThread.join();
        }
        return;
    }
    if (g_statsThread.joinable()) {
        g_statsThread.join();
    }
}

// Shared encoder factory for both outputs. Prefer the OH_VideoEncoder
// hardware path (plugins/harmony-vcodec, ids "harmony_h264"/"harmony_hevc").
// When the settings panel asks for HEVC, harmony_hevc leads the chain and
// falls back to H.264 hardware (some devices' HEVC encoder rejects a
// resolution or profile); H.264 requests never silently upgrade. Software
// x264 on a phone/PC SoC cannot sustain 1080p60 and would burn the battery,
// so it is only the last resort when no hardware encoder is available.
// Whichever wins is logged, because the two behave very differently under
// load and that distinction matters when debugging drops.
obs_encoder_t *CreateVideoEncoder(int64_t bitrateKbps, const char *codec, const char **failureOut)
{
    const bool wantHevc = codec != nullptr && strcmp(codec, "hevc") == 0;
    static const char *kHevcIds[] = {"harmony_hevc", "harmony_h264", "obs_x264"};
    static const char *kH264Ids[] = {"harmony_h264", "obs_x264"};
    const char *const *ids = wantHevc ? kHevcIds : kH264Ids;
    const size_t idCount = wantHevc ? sizeof(kHevcIds) / sizeof(kHevcIds[0])
                                    : sizeof(kH264Ids) / sizeof(kH264Ids[0]);

    obs_data_t *settings = obs_data_create();
    obs_data_set_int(settings, "bitrate", bitrateKbps);

    obs_encoder_t *encoder = nullptr;
    for (size_t i = 0; i < idCount; i++) {
        encoder = obs_video_encoder_create(ids[i], "harmony_video_encoder", settings, nullptr);
        if (encoder != nullptr) {
            OH_LOG_INFO(LOG_APP, "video encoder: %{public}s (bitrate=%{public}lld kbps)", ids[i],
                        static_cast<long long>(bitrateKbps));
            break;
        }
        OH_LOG_WARN(LOG_APP, "video encoder '%{public}s' unavailable, trying next", ids[i]);
    }

    obs_data_release(settings);

    if (encoder == nullptr && failureOut != nullptr) {
        *failureOut = wantHevc ? "harmony_hevc/harmony_h264/obs_x264" : "harmony_h264/obs_x264";
    }
    return encoder;
}

obs_encoder_t *CreateAudioEncoder(int64_t bitrateKbps, const char **failureOut)
{
    obs_data_t *settings = obs_data_create();
    obs_data_set_int(settings, "bitrate", bitrateKbps);
    obs_encoder_t *encoder = obs_audio_encoder_create("ffmpeg_aac", "harmony_audio_encoder",
                                                      settings, 0, nullptr);
    obs_data_release(settings);
    if (encoder == nullptr && failureOut != nullptr) {
        *failureOut = "ffmpeg_aac";
    }
    return encoder;
}

bool WireOutputEncoders(obs_output_t *output, int64_t videoKbps, int64_t audioKbps,
                        const char *videoCodec, std::string &errorOut)
{
    const char *failedId = nullptr;
    obs_encoder_t *video = CreateVideoEncoder(videoKbps, videoCodec, &failedId);
    if (video == nullptr) {
        errorOut = std::string("video encoder unavailable (plugin id not loaded: ") +
                   (failedId != nullptr ? failedId : "?") +
                   "). Stage obs-x264 or the OH_VideoEncoder-based plugin in OBS_HARMONY_PREFIX.";
        return false;
    }
    obs_encoder_t *audio = CreateAudioEncoder(audioKbps, &failedId);
    if (audio == nullptr) {
        errorOut = std::string("audio encoder unavailable (plugin id not loaded: ") +
                   (failedId != nullptr ? failedId : "?") + ")";
        obs_encoder_release(video);
        return false;
    }
    obs_encoder_set_video(video, obs_get_video());
    obs_encoder_set_audio(audio, obs_get_audio());
    obs_output_set_video_encoder(output, video);
    obs_output_set_audio_encoder(output, audio, 0);
    obs_encoder_release(video);
    obs_encoder_release(audio);
    return true;
}

// ---------------------------------------------------------------------------
// Scene registry (HAVE_LIBOBS)
// ---------------------------------------------------------------------------

std::mutex g_sceneMutex;
std::map<std::string, obs_scene_t *> g_scenes; // scene source UUID -> scene
/* Private fade wrapper that owns the program channel during scene
 * transitions (created lazily in NativeSelectScene; guarded by
 * g_sceneMutex). */
obs_source_t *g_programTransition = nullptr;
/* Type id the program transition shell was created with (fade_transition by
 * default). A type change rebuilds the shell around the currently visible
 * source — see NativeSetTransitionType. */
std::string g_programTransitionId = "fade_transition";

/* Studio mode (opt-in). The program/preview split mirrors the desktop
 * frontend: the main canvas (channel 0) is PROGRAM — what records and
 * streams; a private PREVIEW canvas holds the scene the operator has
 * selected but not yet taken. A second XComponent display renders the
 * preview canvas (see xcomp::AttachStudioPreview). All guarded by
 * g_sceneMutex; created lazily the first time studio mode is entered and
 * left alive for the process (tearing a canvas down mid-frame races the
 * video thread). */
obs_canvas_t *g_previewCanvas = nullptr;
std::string g_previewSceneId; // scene uuid bound to the preview canvas, if any

struct SceneItemEnumCtx {
    int64_t wantedId = -1;
    obs_sceneitem_t *found = nullptr;
    bool stop = false;
};

bool SceneItemFindCallback(obs_scene_t * /*scene*/, obs_sceneitem_t *item, void *param)
{
    SceneItemEnumCtx *ctx = static_cast<SceneItemEnumCtx *>(param);
    if (obs_sceneitem_get_id(item) == ctx->wantedId) {
        ctx->found = item;
        return false; // stop enumeration
    }
    return true;
}

obs_sceneitem_t *FindSceneItemById(int64_t itemId)
{
    // Caller holds g_sceneMutex. Scene item ids are unique per scene, so walk
    // every registered scene. Items are owned by the scene; we do not hold
    // references and must use them synchronously.
    for (auto &entry : g_scenes) {
        SceneItemEnumCtx ctx;
        ctx.wantedId = itemId;
        obs_scene_enum_items(entry.second, SceneItemFindCallback, &ctx);
        if (ctx.found != nullptr) {
            return ctx.found;
        }
    }
    return nullptr;
}

/* Shared obs_video_info construction for NativeInit and
 * NativeResetVideo (settings panel). Zero width/height/fps keeps the
 * factory defaults (1080p60). Output dimensions track base dimensions —
 * the port never used the downscale path. */
void BuildVideoInfo(struct obs_video_info *ovi, int width, int height, int fps)
{
    // The graphics module is the ported libobs OpenGL/EGL backend for
    // HarmonyOS; its EGL surfaces are created on XComponent NativeWindows
    // (see xcomponent_surface.cpp).
    ovi->graphics_module = "libobs-opengl";
    ovi->fps_num = fps > 0 ? fps : 60;
    ovi->fps_den = 1;
    ovi->base_width = width > 0 ? width : 1920;
    ovi->base_height = height > 0 ? height : 1080;
    ovi->output_width = ovi->base_width;
    ovi->output_height = ovi->base_height;
    ovi->output_format = VIDEO_FORMAT_NV12;
    ovi->adapter = 0;
    ovi->gpu_conversion = true;
    ovi->colorspace = VIDEO_CS_709;
    ovi->range = VIDEO_RANGE_DEFAULT;
    ovi->scale_type = OBS_SCALE_BILINEAR;
}

#endif // HAVE_LIBOBS

} // namespace (anonymous helpers above; entry points below are obs_bridge::)

// ===========================================================================
// Exported napi entry points (declared in obs_bridge.h, referenced by
// napi_init.cpp). These live directly in namespace obs_bridge — NOT in the
// anonymous namespace — so their linkage matches the header declarations.
// ===========================================================================

#ifdef HAVE_LIBOBS
/* libobs' default blog() sink is stderr, which never reaches hilog on
 * HarmonyOS. Forward every blog() line into hilog so failures inside
 * gs_create()/obs_reset_video() (module load errors, EGL diagnostics)
 * are visible in `hdc shell hilog`. */
static void ObsLogToHilog(int lvl, const char *msg, va_list args, void *param)
{
    (void)param;
    char buf[2048];
    vsnprintf(buf, sizeof(buf), msg, args);

    /* libobs levels: 100=error 200=warning 300=info 400=debug.
     * The libobs/hilog LOG_* name collision is handled at the includes
     * above (rename + #undef), so after that block these names bind to
     * hilog's LogLevel again. */
    LogLevel out = lvl <= 100 ? LOG_ERROR : lvl <= 200 ? LOG_WARN : LOG_INFO;
    OH_LOG_Print(LOG_APP, out, LOG_DOMAIN, LOG_TAG, "[obs] %{public}s", buf);
}
#endif

napi_value NativeInit(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string configDir;
    std::string codeDir;
    std::string dataDir;
    if (argc < 3) {
        return ThrowError(env, "nativeInit(configDir, codeDir, dataDir): expected 3 string arguments");
    }
    if (!GetStringArg(env, args[0], configDir)) {
        return ThrowError(env, "nativeInit: configDir must be a string");
    }
    if (!GetStringArg(env, args[1], codeDir)) {
        return ThrowError(env, "nativeInit: codeDir must be a string");
    }
    if (!GetStringArg(env, args[2], dataDir)) {
        return ThrowError(env, "nativeInit: dataDir must be a string");
    }

    bool coreOk = false;
#ifdef HAVE_LIBOBS
    if (!obs_initialized()) {
        // Must precede obs_startup(): obs_startup runs
        // add_default_module_paths(), and the graphics subsystem loads libobs's
        // .effect shaders through find_libobs_data_file() during
        // obs_reset_video(). Both resolve against the roots set here, so
        // injecting them afterwards would be too late.
        obs_harmony_set_paths(codeDir.c_str(), dataDir.c_str());
        /* HarmonyOS ships no CA bundle readable from the app sandbox and our
         * static libcurl was built without a CURL_CA_BUNDLE default, so every
         * HTTPS request fails "not correctly signed by the trusted CA". The
         * curl.org bundle is shipped in rawfile and extracted to
         * <dataDir>/certs/cacert.pem by RawFileExtractor; file-updater picks
         * this variable up for its easy handles. */
        {
            std::string caBundle = dataDir + "/certs/cacert.pem";
            setenv("CURL_CA_BUNDLE", caBundle.c_str(), 1);
            OH_LOG_INFO(LOG_APP, "CURL_CA_BUNDLE=%{public}s", caBundle.c_str());
        }
        base_set_log_handler(ObsLogToHilog, nullptr);
        OH_LOG_INFO(LOG_APP, "obs paths: code=%{public}s data=%{public}s config=%{public}s",
                    codeDir.c_str(), dataDir.c_str(), configDir.c_str());

        if (!obs_startup("en-US", configDir.c_str(), nullptr)) {
            return ThrowError(env, "obs_startup() failed");
        }
        // obs_startup already registered <codeDir> for plugin binaries and
        // <dataDir>/obs-plugins/%module% for their data, so nothing extra is
        // needed here. obs_load_all_modules() dlopens every .so it finds; the
        // bundle directory also holds FFmpeg and libc++_shared, which are not
        // plugins. libobs rejects those at LOG_DEBUG (missing obs_module_load)
        // and moves on, so the noise in a debug log is expected, not a fault.
        /* SELinux denies opendir() on the extracted bundle libs directory,
         * so libobs' obs_find_modules2() directory scan silently finds
         * nothing. Load the known plugin set explicitly by absolute path
         * instead (obs_open_module + obs_init_module are public API). */
        {
            static const char *const kPlugins[] = {
                "harmony-capture", "harmony-audio", "harmony-camera", "harmony-vcodec",
                "harmony-remotecam", "harmony-web",  "obs-ffmpeg",   "obs-filters",    "obs-outputs",
                "obs-transitions", "obs-x264",      "rtmp-services",  "image-source",
                "text-freetype2",
            };
            for (const char *name : kPlugins) {
                char bin[512], data[512];
                /* Bare soname, not an absolute path: HarmonyOS' linker
                 * namespaces reject dlopen() of bundle-lib paths that were
                 * not declared as NAPI modules ("check ns accessible
                 * failed"), but resolve plain sonames against the app's
                 * native lib search path. */
                snprintf(bin, sizeof(bin), "%s.so", name);
                snprintf(data, sizeof(data), "%s/obs-plugins/%s", dataDir.c_str(), name);
                obs_module_t *mod = nullptr;
                int ret = obs_open_module(&mod, bin, data);
                if (ret != MODULE_SUCCESS) {
                    OH_LOG_ERROR(LOG_APP, "plugin %{public}s: obs_open_module ret=%{public}d", name, ret);
                    continue;
                }
                if (!obs_init_module(mod))
                    OH_LOG_ERROR(LOG_APP, "plugin %{public}s: obs_init_module failed", name);
                else
                    OH_LOG_INFO(LOG_APP, "plugin %{public}s loaded", name);
            }
        }
        obs_post_load_modules();
        obs_log_loaded_modules();

        struct obs_video_info ovi = {};
        BuildVideoInfo(&ovi, 0, 0, 0);
        const int videoRc = obs_reset_video(&ovi);
        if (videoRc != OBS_VIDEO_SUCCESS) {
            OH_LOG_ERROR(LOG_APP, "obs_reset_video failed: %{public}d "
                                  "(graphics backend module staged and ported?)", videoRc);
        }

        struct obs_audio_info oai = {};
        oai.samples_per_sec = 48000;
        oai.speakers = SPEAKERS_STEREO;
        if (!obs_reset_audio(&oai)) {
            OH_LOG_ERROR(LOG_APP, "obs_reset_audio failed");
        }
        coreOk = videoRc == OBS_VIDEO_SUCCESS;
        OH_LOG_INFO(LOG_APP, "libobs %{public}s started (video rc=%{public}d)",
                    obs_get_version_string(), videoRc);
    } else {
        coreOk = true;
    }
#else
    OH_LOG_WARN(LOG_APP,
                "nativeInit: bridge built shell-only (HAVE_LIBOBS undefined); "
                "libobs calls will report 'core not linked'");
    (void)configDir;
#endif

    // The mixer is source-driven (see the audio tracks block above): no
    // shadow capturers start here anymore. The mic/desktop SOURCES capture
    // audio themselves when a scene holds them; the mixer discovers them
    // via obs_enum_sources on its poll.
    return CreateBool(env, coreOk);
}

/* Kept as a no-op for ABI compatibility with the ArkTS wrapper. The
 * desktop-audio SOURCE now requests its own loopback authorization when it
 * activates (see plugins/harmony-audio/desktop-audio.c on_start_state), so
 * there is nothing for the bridge to pre-start. */
napi_value NativeEnsureDesktopAudio(napi_env env, napi_callback_info /*info*/)
{
    return CreateBool(env, true);
}

void ShutdownCore()
{
#ifdef HAVE_LIBOBS
    StopStatsThread();
    // Release mixer tracks (volmeters + source refs) while the core is
    // still alive, before the scene teardown and obs_shutdown below.
    ReleaseAllAudioTracks();
    {
        std::lock_guard<std::mutex> lock(g_outputMutex);
        if (g_streamOutput != nullptr) {
            if (obs_output_active(g_streamOutput)) {
                obs_output_stop(g_streamOutput);
            }
            obs_output_release(g_streamOutput);
            g_streamOutput = nullptr;
            if (g_streamService != nullptr) {
                obs_service_release(g_streamService);
                g_streamService = nullptr;
            }
        }
        if (g_recordOutput != nullptr) {
            if (obs_output_active(g_recordOutput)) {
                obs_output_stop(g_recordOutput);
            }
            obs_output_release(g_recordOutput);
            g_recordOutput = nullptr;
        }
    }
    {
        std::lock_guard<std::mutex> lock(g_sceneMutex);
        if (g_programTransition != nullptr) {
            obs_transition_clear(g_programTransition);
            obs_source_release(g_programTransition);
            g_programTransition = nullptr;
        }
        for (auto &entry : g_scenes) {
            obs_source_remove(obs_scene_get_source(entry.second));
            obs_scene_release(entry.second);
        }
        g_scenes.clear();
    }
    if (obs_initialized()) {
        obs_shutdown();
    }
#endif
    xcomp::ResetAll();
    std::lock_guard<std::mutex> lock(g_statsMutex);
    if (g_statsTsf != nullptr) {
        napi_release_threadsafe_function(g_statsTsf, napi_tsfn_release);
        g_statsTsf = nullptr;
    }
}

napi_value NativeShutdown(napi_env env, napi_callback_info /*info*/)
{
    ShutdownCore();
    return GetUndefined(env);
}

napi_value NativeAttachPreviewSurface(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string xcomponentId;
    if (argc < 1 || !GetStringArg(env, args[0], xcomponentId)) {
        return ThrowError(env, "nativeAttachPreviewSurface(xcomponentId): argument must be a string");
    }
    return CreateBool(env, xcomp::AttachPreview(xcomponentId));
}

napi_value NativeDetachPreviewSurface(napi_env env, napi_callback_info /*info*/)
{
    xcomp::DetachPreview();
    return GetUndefined(env);
}

/* ---- Studio mode (opt-in) ------------------------------------------------
 * The program/preview split. The preview canvas is created with ACTIVATE |
 * EPHEMERAL (the DEVICE preset), NOT the PREVIEW preset: our capture sources
 * only start on obs_source_activate(MAIN_VIEW) (obs-source.c: activate_refs
 * is bumped for MAIN_VIEW only), and a canvas's view is MAIN_VIEW iff it has
 * the ACTIVATE flag (obs-canvas.c:159). A PREVIEW-preset (AUX) canvas would
 * never activate the camera/display and the preview would stay black.
 * EPHEMERAL keeps it out of the saved profile. */

/* nativeSetPreviewScene(id) -> bool. Binds a registered scene to the private
 * preview canvas (creating the canvas on first call). This is the studio-mode
 * "preview" selection; the program canvas is untouched until Take/Cut. */
napi_value NativeSetPreviewScene(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string id;
    if (argc < 1 || !GetStringArg(env, args[0], id)) {
        return ThrowError(env, "nativeSetPreviewScene(id): argument must be a string");
    }
#ifndef HAVE_LIBOBS
    (void)id;
    return ThrowCoreNotLinked(env);
#else
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    auto it = g_scenes.find(id);
    if (it == g_scenes.end()) {
        return CreateBool(env, false);
    }
    if (g_previewCanvas == nullptr) {
        struct obs_video_info ovi;
        if (!obs_get_video_info(&ovi)) {
            return CreateBool(env, false);
        }
        g_previewCanvas = obs_canvas_create_private("harmony_preview", &ovi, ACTIVATE | EPHEMERAL);
        if (g_previewCanvas == nullptr) {
            OH_LOG_ERROR(LOG_APP, "studio: obs_canvas_create_private failed");
            return CreateBool(env, false);
        }
    }
    obs_canvas_set_channel(g_previewCanvas, 0, obs_scene_get_source(it->second));
    g_previewSceneId = id;
    return CreateBool(env, true);
#endif
}

/* nativeGetPreviewSceneId() -> the scene uuid currently on the preview
 * canvas ('' when studio mode has not bound one) — lets the scene list
 * highlight the preview row separately from the program row. */
napi_value NativeGetPreviewSceneId(napi_env env, napi_callback_info /*info*/)
{
#ifndef HAVE_LIBOBS
    return CreateString(env, "");
#else
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    return CreateString(env, g_previewSceneId);
#endif
}

/* nativeAttachStudioPreviewSurface(xcomponentId) -> bool. Points the second
 * display at the preview canvas. Requires nativeSetPreviewScene to have run
 * first (creates the canvas). */
napi_value NativeAttachStudioPreviewSurface(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string xcomponentId;
    if (argc < 1 || !GetStringArg(env, args[0], xcomponentId)) {
        return ThrowError(env, "nativeAttachStudioPreviewSurface(id): argument must be a string");
    }
#ifndef HAVE_LIBOBS
    (void)xcomponentId;
    return ThrowCoreNotLinked(env);
#else
    void *canvas;
    {
        std::lock_guard<std::mutex> lock(g_sceneMutex);
        canvas = g_previewCanvas;
    }
    if (canvas == nullptr) {
        OH_LOG_ERROR(LOG_APP, "studio: attach preview display before a preview scene is set");
        return CreateBool(env, false);
    }
    return CreateBool(env, xcomp::AttachStudioPreview(xcomponentId, canvas));
#endif
}

napi_value NativeDetachStudioPreviewSurface(napi_env env, napi_callback_info /*info*/)
{
    xcomp::DetachStudioPreview();
    return GetUndefined(env);
}

napi_value NativeGetScenes(napi_env env, napi_callback_info /*info*/)
{
    napi_value array = nullptr;
    napi_create_array(env, &array);
#ifdef HAVE_LIBOBS
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    uint32_t index = 0;
    for (auto &entry : g_scenes) {
        obs_source_t *source = obs_scene_get_source(entry.second);
        napi_value obj = nullptr;
        napi_create_object(env, &obj);
        SetProperty(env, obj, "id", CreateString(env, entry.first));
        SetProperty(env, obj, "name",
                    CreateString(env, source != nullptr ? obs_source_get_name(source) : ""));
        napi_set_element(env, array, index++, obj);
    }
#else
    OH_LOG_DEBUG(LOG_APP, "nativeGetScenes: shell-only, returning empty list");
#endif
    return array;
}

napi_value NativeCreateScene(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string name;
    if (argc < 1 || !GetStringArg(env, args[0], name)) {
        return ThrowError(env, "nativeCreateScene(name): argument must be a string");
    }
#ifndef HAVE_LIBOBS
    return ThrowCoreNotLinked(env);
#else
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    obs_scene_t *scene = obs_scene_create(name.c_str());
    if (scene == nullptr) {
        return ThrowError(env, "obs_scene_create() failed");
    }
    obs_source_t *source = obs_scene_get_source(scene);
    const char *uuid = obs_source_get_uuid(source);
    const std::string id = uuid != nullptr ? uuid : name;
    g_scenes[id] = scene;
    /* Bind to the program channel so the graphics thread actually renders
     * this scene: obs_render_main_texture() draws channel 0, and sources
     * only activate once they are in the render tree. Without this the
     * canvas stays empty and capture plugins never start. Once the
     * transition wrapper owns channel 0 it keeps ownership (invariant:
     * after g_programTransition exists, channel 0 is always the wrapper),
     * so route through obs_transition_set instead of displacing it. */
    if (g_programTransition != nullptr) {
        obs_transition_set(g_programTransition, source);
    } else {
        obs_set_output_source(0, source);
    }
    return CreateString(env, id);
#endif
}

napi_value NativeRemoveScene(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string id;
    if (argc < 1 || !GetStringArg(env, args[0], id)) {
        return ThrowError(env, "nativeRemoveScene(id): argument must be a string");
    }
#ifndef HAVE_LIBOBS
    return ThrowCoreNotLinked(env);
#else
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    auto it = g_scenes.find(id);
    if (it == g_scenes.end()) {
        return CreateBool(env, false);
    }
    /* Studio mode: if the preview canvas was staging this scene, drop the
     * binding so the second display does not keep rendering a removed
     * source (the canvas channel holds its own reference otherwise). */
    if (g_previewCanvas != nullptr && g_previewSceneId == id) {
        obs_canvas_set_channel(g_previewCanvas, 0, nullptr);
        g_previewSceneId.clear();
    }
    obs_source_remove(obs_scene_get_source(it->second));
    obs_scene_release(it->second);
    g_scenes.erase(it);
    return CreateBool(env, true);
#endif
}

/* nativeRenameScene(id, name): rename the scene's source (the scene list
 * reads names from obs_source_get_name, so the UI follows automatically). */
napi_value NativeRenameScene(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string id, name;
    if (argc < 2 || !GetStringArg(env, args[0], id) || !GetStringArg(env, args[1], name)) {
        return ThrowError(env, "nativeRenameScene(id, name): bad arguments");
    }
#ifndef HAVE_LIBOBS
    (void)id; (void)name;
    return ThrowCoreNotLinked(env);
#else
    if (name.empty()) {
        return CreateBool(env, false);
    }
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    auto it = g_scenes.find(id);
    if (it == g_scenes.end()) {
        return CreateBool(env, false);
    }
    obs_source_set_name(obs_scene_get_source(it->second), name.c_str());
    return CreateBool(env, true);
#endif
}

#ifdef HAVE_LIBOBS
struct SourceEnumCtx {
    napi_env env;
    napi_value array;
    uint32_t index = 0;
};

bool SourceCollectCallback(obs_scene_t * /*scene*/, obs_sceneitem_t *item, void *param)
{
    SourceEnumCtx *ctx = static_cast<SourceEnumCtx *>(param);
    obs_source_t *source = obs_sceneitem_get_source(item);
    napi_value obj = nullptr;
    napi_create_object(ctx->env, &obj);
    SetProperty(ctx->env, obj, "id",
                CreateString(ctx->env, std::to_string(obs_sceneitem_get_id(item))));
    const char *uuid = source != nullptr ? obs_source_get_uuid(source) : nullptr;
    SetProperty(ctx->env, obj, "sourceUuid", CreateString(ctx->env, uuid != nullptr ? uuid : ""));
    SetProperty(ctx->env, obj, "name",
                CreateString(ctx->env, source != nullptr ? obs_source_get_name(source) : ""));
    SetProperty(ctx->env, obj, "typeId",
                CreateString(ctx->env,
                             source != nullptr ? obs_source_get_unversioned_id(source) : ""));
    SetProperty(ctx->env, obj, "visible", CreateBool(ctx->env, obs_sceneitem_visible(item)));
    SetProperty(ctx->env, obj, "locked", CreateBool(ctx->env, obs_sceneitem_locked(item)));
    napi_set_element(ctx->env, ctx->array, ctx->index++, obj);
    return true; // continue enumeration
}
#endif

napi_value NativeGetSources(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string sceneId;
    if (argc < 1 || !GetStringArg(env, args[0], sceneId)) {
        return ThrowError(env, "nativeGetSources(sceneId): argument must be a string");
    }
    napi_value array = nullptr;
    napi_create_array(env, &array);
#ifndef HAVE_LIBOBS
    (void)sceneId;
    OH_LOG_DEBUG(LOG_APP, "nativeGetSources: shell-only, returning empty list");
#else
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    auto it = g_scenes.find(sceneId);
    if (it != g_scenes.end()) {
        SourceEnumCtx ctx{env, array, 0};
        obs_scene_enum_items(it->second, SourceCollectCallback, &ctx);
    }
#endif
    return array;
}

napi_value NativeAddSource(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value args[4] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string sceneId;
    std::string typeId;
    std::string name;
    std::string settingsJson;
    if (argc < 4 || !GetStringArg(env, args[0], sceneId) || !GetStringArg(env, args[1], typeId) ||
        !GetStringArg(env, args[2], name) || !GetStringArg(env, args[3], settingsJson)) {
        return ThrowError(env,
                          "nativeAddSource(sceneId, typeId, name, settingsJson): "
                          "all four arguments must be strings");
    }
#ifndef HAVE_LIBOBS
    (void)sceneId; (void)typeId; (void)name; (void)settingsJson;
    return ThrowCoreNotLinked(env);
#else
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    auto it = g_scenes.find(sceneId);
    if (it == g_scenes.end()) {
        return ThrowError(env, "nativeAddSource: unknown scene id");
    }
    obs_data_t *settings = settingsJson.empty() ? obs_data_create()
                                                : obs_data_create_from_json(settingsJson.c_str());
    if (settings == nullptr) {
        return ThrowError(env, "obs_data_create_from_json() failed on settingsJson");
    }
    // Real libobs source creation. The type ids understood here are whatever
    // the staged plugins register — on HarmonyOS the flagship one will be the
    // OH_AVScreenCapture-backed display source; today "image_source" &co come
    // from the staged plugin set.
    obs_source_t *source = obs_source_create(typeId.c_str(), name.c_str(), settings, nullptr);
    obs_data_release(settings);
    if (source == nullptr) {
        return ThrowError(env, "obs_source_create() failed (source type id not registered?)");
    }
    obs_sceneitem_t *item = obs_scene_add(it->second, source);
    const int64_t itemId = obs_sceneitem_get_id(item);
    // Fit-to-canvas on add for oversized sources (a raw 4000x3000 knock-in
    // photo or a 3120x2080 display capture must not spill across the
    // preview). Implemented as an EXPLICIT SCALE bake, not a bounds clamp:
    // OBS_BOUNDS_SCALE_INNER normalises the item scale away, which silently
    // breaks pinch-zoom (set_scale changes nothing on screen — user report
    // 10-14: "捏合能缩放摄像头，但缩放捕获屏幕不太行") and makes the
    // selection box report the letterboxed bounds rather than the content.
    // A baked scale keeps the item in free-transform mode, so pinch/drag and
    // the box all behave like the camera source does. SHRINK-ONLY gate: a
    // small source stays at natural size (desktop parity).
    {
        struct obs_video_info ovi;
        const uint32_t sw = obs_source_get_width(source);
        const uint32_t sh = obs_source_get_height(source);
        if (obs_get_video_info(&ovi) && sw > 0 && sh > 0 &&
            (sw > ovi.base_width || sh > ovi.base_height)) {
            const float fit = fminf((float)ovi.base_width / (float)sw,
                                    (float)ovi.base_height / (float)sh);
            struct vec2 scale;
            vec2_set(&scale, fit, fit);
            obs_sceneitem_set_scale(item, &scale);
            /* Centre the shrunk item on the canvas (was the bounds
             * alignment default). pos is the top-left in absolute px. */
            const float w = (float)sw * fit;
            const float h = (float)sh * fit;
            struct vec2 pos;
            vec2_set(&pos, ((float)ovi.base_width - w) * 0.5f,
                     ((float)ovi.base_height - h) * 0.5f);
            obs_sceneitem_set_pos(item, &pos);
        }
    }
    obs_source_release(source);
    return CreateString(env, std::to_string(itemId));
#endif
}

napi_value NativeRemoveSource(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string id;
    if (argc < 1 || !GetStringArg(env, args[0], id)) {
        return ThrowError(env, "nativeRemoveSource(id): argument must be a string");
    }
#ifndef HAVE_LIBOBS
    (void)id;
    return ThrowCoreNotLinked(env);
#else
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    obs_sceneitem_t *item = FindSceneItemById(std::strtoll(id.c_str(), nullptr, 10));
    if (item == nullptr) {
        OH_LOG_WARN(LOG_APP, "nativeRemoveSource: no scene item for id '%{public}s'", id.c_str());
        return CreateBool(env, false);
    }
    obs_sceneitem_remove(item);
    OH_LOG_INFO(LOG_APP, "nativeRemoveSource: removed scene item '%{public}s'", id.c_str());
    return CreateBool(env, true);
#endif
}

napi_value NativeSetSourceVisible(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string id;
    bool visible = true;
    napi_get_value_bool(env, args[1], &visible);
    if (argc < 2 || !GetStringArg(env, args[0], id)) {
        return ThrowError(env, "nativeSetSourceVisible(id, visible): bad arguments");
    }
#ifndef HAVE_LIBOBS
    (void)id; (void)visible;
    return ThrowCoreNotLinked(env);
#else
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    obs_sceneitem_t *item = FindSceneItemById(std::strtoll(id.c_str(), nullptr, 10));
    if (item == nullptr) {
        return CreateBool(env, false);
    }
    return CreateBool(env, obs_sceneitem_set_visible(item, visible));
#endif
}

/* ---- Canvas interaction (W4: source select / move / scale) ------------
 * The ArkUI gesture layer above the preview XComponent needs the item's
 * bounding box in canvas coordinates to (a) hit-test taps and (b) draw the
 * selection outline; move/scale map drag and pinch deltas onto the item.
 * All coordinates are canvas px (base_width x base_height), top-left
 * origin — the ArkUI layer owns the canvas→view transform. */

/* nativeGetSourceBounds(id) -> JSON '{"x":..,"y":..,"w":..,"h":..}' of the
 * item's axis-aligned bounding box, or '' when the item is gone.
 * Uses obs_sceneitem_get_box_transform — the same box transform the desktop
 * selection outline consumes — so fit-to-canvas sources (OBS_BOUNDS_SCALE_
 * INNER, where the rendered size is the BOUNDS not source×scale, and the
 * bounds alignment shifts the box off pos) report the true rendered rect
 * (user report 10-14: "红框有时大小也和画面不一致"). */
napi_value NativeGetSourceBounds(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string id;
    if (argc < 1 || !GetStringArg(env, args[0], id)) {
        return ThrowError(env, "nativeGetSourceBounds(id): argument must be a string");
    }
#ifndef HAVE_LIBOBS
    (void)id;
    return ThrowCoreNotLinked(env);
#else
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    obs_sceneitem_t *item = FindSceneItemById(std::strtoll(id.c_str(), nullptr, 10));
    if (item == nullptr) {
        return CreateString(env, "");
    }
    struct matrix4 m;
    obs_sceneitem_get_box_transform(item, &m);
    /* box_transform maps a UNIT box (corners (0,0),(1,0),(0,1),(1,1)) to the
     * item's rendered rect in canvas space — the box scale is ALREADY baked
     * into the matrix (this is exactly how the desktop selection outline uses
     * it). The earlier version multiplied the corners by obs_sceneitem_get_
     * box_scale as well, squaring the extent (a full-canvas source reported
     * 1920×1920 → 3686400 px, so the outline blew up to fill the whole panel
     * while the picture rendered at true size — user report 10-14 "红框和摄
     * 像头不在一起"). matrix4 is row-vector: p' = p.x*m.x + p.y*m.y + m.t. */
    double minX = 1e30, minY = 1e30, maxX = -1e30, maxY = -1e30;
    const float px[4] = {0.0f, 1.0f, 0.0f, 1.0f};
    const float py[4] = {0.0f, 0.0f, 1.0f, 1.0f};
    for (int i = 0; i < 4; i++) {
        const double ox = (double)px[i] * m.x.x + (double)py[i] * m.y.x + m.t.x;
        const double oy = (double)px[i] * m.x.y + (double)py[i] * m.y.y + m.t.y;
        if (ox < minX) minX = ox;
        if (ox > maxX) maxX = ox;
        if (oy < minY) minY = oy;
        if (oy > maxY) maxY = oy;
    }
    char buf[128];
    snprintf(buf, sizeof(buf), "{\"x\":%.2f,\"y\":%.2f,\"w\":%.2f,\"h\":%.2f}",
             minX, minY, maxX - minX, maxY - minY);
    return CreateString(env, buf);
#endif
}

/* nativeSetSourcePosition(id, x, y): canvas-px top-left position. */
napi_value NativeSetSourcePosition(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string id;
    double x = 0, y = 0;
    if (argc < 3 || !GetStringArg(env, args[0], id) || napi_get_value_double(env, args[1], &x) != napi_ok ||
        napi_get_value_double(env, args[2], &y) != napi_ok) {
        return ThrowError(env, "nativeSetSourcePosition(id, x, y): bad arguments");
    }
#ifndef HAVE_LIBOBS
    (void)id; (void)x; (void)y;
    return ThrowCoreNotLinked(env);
#else
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    obs_sceneitem_t *item = FindSceneItemById(std::strtoll(id.c_str(), nullptr, 10));
    if (item == nullptr) {
        return CreateBool(env, false);
    }
    struct vec2 pos;
    vec2_set(&pos, x, y);
    obs_sceneitem_set_pos(item, &pos);
    return CreateBool(env, true);
#endif
}

/* nativeSetSourceRect(id, x, y, w, h): set the item's rendered rect in
 * canvas px (top-left + size). Backs the corner-handle resize gesture —
 * ArkTS owns the anchor math, this just commits an absolute box. Bounds are
 * cleared (a bounded item ignores scale), and the scale is derived from the
 * source's natural size so the picture fills exactly w×h. All coordinates
 * are absolute canvas px, matching get_source_bounds. */
napi_value NativeSetSourceRect(napi_env env, napi_callback_info info)
{
    size_t argc = 5;
    napi_value args[5] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string id;
    double x = 0, y = 0, w = 0, h = 0;
    if (argc < 5 || !GetStringArg(env, args[0], id) || napi_get_value_double(env, args[1], &x) != napi_ok ||
        napi_get_value_double(env, args[2], &y) != napi_ok || napi_get_value_double(env, args[3], &w) != napi_ok ||
        napi_get_value_double(env, args[4], &h) != napi_ok) {
        return ThrowError(env, "nativeSetSourceRect(id, x, y, w, h): bad arguments");
    }
#ifndef HAVE_LIBOBS
    (void)x; (void)y; (void)w; (void)h;
    return ThrowCoreNotLinked(env);
#else
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    obs_sceneitem_t *item = FindSceneItemById(std::strtoll(id.c_str(), nullptr, 10));
    if (item == nullptr) {
        return CreateBool(env, false);
    }
    obs_source_t *src = obs_sceneitem_get_source(item);
    const float sw = (float)obs_source_get_width(src);
    const float sh = (float)obs_source_get_height(src);
    if (sw <= 0.0f || sh <= 0.0f || w <= 1.0 || h <= 1.0) {
        return CreateBool(env, false);
    }
    if (obs_sceneitem_get_bounds_type(item) != OBS_BOUNDS_NONE) {
        obs_sceneitem_set_bounds_type(item, OBS_BOUNDS_NONE);
    }
    struct vec2 scale;
    vec2_set(&scale, (float)w / sw, (float)h / sh); // API expects absolute
    obs_sceneitem_set_scale(item, &scale);
    struct vec2 pos;
    vec2_set(&pos, x, y);
    obs_sceneitem_set_pos(item, &pos);
    return CreateBool(env, true);
#endif
}

/* nativeScaleSourceBy(id, factor): uniform scale about the item origin. */
napi_value NativeScaleSourceBy(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string id;
    double factor = 1.0;
    if (argc < 2 || !GetStringArg(env, args[0], id) || napi_get_value_double(env, args[1], &factor) != napi_ok) {
        return ThrowError(env, "nativeScaleSourceBy(id, factor): bad arguments");
    }
#ifndef HAVE_LIBOBS
    (void)id; (void)factor;
    return ThrowCoreNotLinked(env);
#else
    if (factor <= 0.0) {
        return CreateBool(env, false);
    }
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    obs_sceneitem_t *item = FindSceneItemById(std::strtoll(id.c_str(), nullptr, 10));
    if (item == nullptr) {
        return CreateBool(env, false);
    }
    /* Bounds mode (the 缩放至全屏/拉伸 presets) NORMALISES the item scale
     * away — calculate_bounds_data derives the effective scale purely from
     * bounds/source, so set_scale under SCALE_INNER changes nothing on
     * screen (user report 10-14: pinch works on the camera but not on
     * 捕获屏幕). Bake the current RENDERED size into the scale and drop the
     * bounds on the first pinch — the desktop "No scaling" transition. The
     * content rect comes from the DRAW transform (box_transform reports the
     * bounds box, wider than the letterboxed content). */
    if (obs_sceneitem_get_bounds_type(item) != OBS_BOUNDS_NONE) {
        obs_source_t *src = obs_sceneitem_get_source(item);
        const float sw = (float)obs_source_get_width(src);
        const float sh = (float)obs_source_get_height(src);
        struct matrix4 dm;
        obs_sceneitem_get_draw_transform(item, &dm);
        float minX = 1e30f, minY = 1e30f, maxX = -1e30f, maxY = -1e30f;
        const float px[4] = {0.0f, sw, 0.0f, sw};
        const float py[4] = {0.0f, 0.0f, sh, sh};
        for (int i = 0; i < 4; i++) {
            const float ox = px[i] * dm.x.x + py[i] * dm.y.x + dm.t.x;
            const float oy = px[i] * dm.x.y + py[i] * dm.y.y + dm.t.y;
            if (ox < minX) minX = ox;
            if (ox > maxX) maxX = ox;
            if (oy < minY) minY = oy;
            if (oy > maxY) maxY = oy;
        }
        if (sw > 0.0f && sh > 0.0f && maxX > minX && maxY > minY) {
            struct vec2 baked;
            vec2_set(&baked, (maxX - minX) * factor / sw, (maxY - minY) * factor / sh);
            struct vec2 pos;
            vec2_set(&pos, minX, minY); // keep the on-screen corner
            obs_sceneitem_set_bounds_type(item, OBS_BOUNDS_NONE);
            obs_sceneitem_set_scale(item, &baked); // API expects absolute
            obs_sceneitem_set_pos(item, &pos);
            return CreateBool(env, true);
        }
    }
    struct vec2 cur;
    obs_sceneitem_get_scale(item, &cur);
    struct vec2 next;
    vec2_set(&next, cur.x * factor, cur.y * factor);
    obs_sceneitem_set_scale(item, &next);
    return CreateBool(env, true);
#endif
}

/* ---- Transform / duplicate / rename (source context menu, #49) -------- */

/* nativeSetSourceTransform(id, rotDeg, flipX, flipY): rotate about the item
 * origin and mirror either axis, matching the desktop right-click entries
 * "Transform > Rotate 90° / Flip horizontal / Flip vertical". flipX/flipY
 * are absolute (not toggles) so the ArkTS layer owns the current state. */
napi_value NativeSetSourceTransform(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value args[4] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string id;
    double rotDeg = 0.0;
    bool flipX = false, flipY = false;
    if (argc < 4 || !GetStringArg(env, args[0], id) ||
        napi_get_value_double(env, args[1], &rotDeg) != napi_ok ||
        napi_get_value_bool(env, args[2], &flipX) != napi_ok ||
        napi_get_value_bool(env, args[3], &flipY) != napi_ok) {
        return ThrowError(env, "nativeSetSourceTransform(id, rot, flipX, flipY): bad arguments");
    }
#ifndef HAVE_LIBOBS
    (void)id; (void)rotDeg; (void)flipX; (void)flipY;
    return ThrowCoreNotLinked(env);
#else
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    obs_sceneitem_t *item = FindSceneItemById(std::strtoll(id.c_str(), nullptr, 10));
    if (item == nullptr) {
        return CreateBool(env, false);
    }
    obs_sceneitem_set_rot(item, (float)rotDeg);
    struct vec2 scale;
    obs_sceneitem_get_scale(item, &scale);
    scale.x = flipX ? -fabsf(scale.x) : fabsf(scale.x);
    scale.y = flipY ? -fabsf(scale.y) : fabsf(scale.y);
    obs_sceneitem_set_scale(item, &scale);
    return CreateBool(env, true);
#endif
}

/* nativeSetSourceBoundsFit(id, mode): 'fit'/'stretch'/'none' — the
 * "Scale to fit window / Stretch to window / No scaling" bounds presets.
 * fit uses SCALE_INNER against the full canvas, centred. */
napi_value NativeSetSourceBoundsFit(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string id, mode;
    if (argc < 2 || !GetStringArg(env, args[0], id) || !GetStringArg(env, args[1], mode)) {
        return ThrowError(env, "nativeSetSourceBoundsFit(id, mode): bad arguments");
    }
#ifndef HAVE_LIBOBS
    (void)id; (void)mode;
    return ThrowCoreNotLinked(env);
#else
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    obs_sceneitem_t *item = FindSceneItemById(std::strtoll(id.c_str(), nullptr, 10));
    if (item == nullptr) {
        return CreateBool(env, false);
    }
    enum obs_bounds_type type;
    if (mode == "stretch") {
        type = OBS_BOUNDS_STRETCH;
    } else if (mode == "none") {
        type = OBS_BOUNDS_NONE;
    } else {
        type = OBS_BOUNDS_SCALE_INNER;
    }
    struct obs_video_info ovi;
    if (!obs_get_video_info(&ovi)) {
        return CreateBool(env, false);
    }
    struct vec2 bounds;
    vec2_set(&bounds, (float)ovi.base_width, (float)ovi.base_height);
    obs_sceneitem_set_bounds_type(item, type);
    obs_sceneitem_set_bounds_alignment(item, OBS_ALIGN_CENTER);
    obs_sceneitem_set_bounds(item, &bounds);
    return CreateBool(env, true);
#endif
}

/* nativeDuplicateSource(id) -> new item id ('' on failure). Adds a second
 * scene item referencing the SAME source — the desktop frontend's
 * "Copy (reference)" behaviour (obs_sceneitem_duplicate does not exist in
 * this libobs; obs_scene_add with the shared source is its reference form). */
napi_value NativeDuplicateSource(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string id;
    if (argc < 1 || !GetStringArg(env, args[0], id)) {
        return ThrowError(env, "nativeDuplicateSource(id): argument must be a string");
    }
#ifndef HAVE_LIBOBS
    (void)id;
    return ThrowCoreNotLinked(env);
#else
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    obs_sceneitem_t *item = FindSceneItemById(std::strtoll(id.c_str(), nullptr, 10));
    if (item == nullptr) {
        return CreateString(env, "");
    }
    obs_scene_t *parent = obs_sceneitem_get_scene(item);
    obs_source_t *source = obs_sceneitem_get_source(item);
    obs_sceneitem_t *copy = obs_scene_add(parent, source);
    if (copy == nullptr) {
        return CreateString(env, "");
    }
    /* Carry geometry over so the duplicate lands on top of the original
     * (visibly "the same thing twice") instead of the scene default. */
    struct vec2 pos, scale;
    obs_sceneitem_get_pos(item, &pos);
    obs_sceneitem_get_scale(item, &scale);
    obs_sceneitem_set_pos(copy, &pos);
    obs_sceneitem_set_scale(copy, &scale);
    obs_sceneitem_set_rot(copy, obs_sceneitem_get_rot(item));
    return CreateString(env, std::to_string(obs_sceneitem_get_id(copy)));
#endif
}

/* nativeRenameSource(id, name): rename the underlying source; the scene
 * list refreshes from obs_source_get_name so the UI follows automatically. */
napi_value NativeRenameSource(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string id, name;
    if (argc < 2 || !GetStringArg(env, args[0], id) || !GetStringArg(env, args[1], name)) {
        return ThrowError(env, "nativeRenameSource(id, name): bad arguments");
    }
#ifndef HAVE_LIBOBS
    (void)id; (void)name;
    return ThrowCoreNotLinked(env);
#else
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    obs_sceneitem_t *item = FindSceneItemById(std::strtoll(id.c_str(), nullptr, 10));
    obs_source_t *src = item != nullptr ? obs_sceneitem_get_source(item) : nullptr;
    if (src == nullptr || name.empty()) {
        return CreateBool(env, false);
    }
    obs_source_set_name(src, name.c_str());
    return CreateBool(env, true);
#endif
}

/* nativeGetSourceTransform(id) -> JSON '{"rot":deg,"flipX":bool,"flipY":bool}'
 * (rot normalised to 0..360). The menu's flip/rotate entries are toggles,
 * so the ArkTS layer needs the current absolute state to compute the next
 * one — bounds' w/h sign cannot carry rotation, and a fresh restore from
 * scene.json would otherwise desync the local mirror. */
napi_value NativeGetSourceTransform(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string id;
    if (argc < 1 || !GetStringArg(env, args[0], id)) {
        return ThrowError(env, "nativeGetSourceTransform(id): argument must be a string");
    }
#ifndef HAVE_LIBOBS
    (void)id;
    return ThrowCoreNotLinked(env);
#else
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    obs_sceneitem_t *item = FindSceneItemById(std::strtoll(id.c_str(), nullptr, 10));
    if (item == nullptr) {
        return CreateString(env, "");
    }
    float rot = obs_sceneitem_get_rot(item);
    while (rot < 0.0f) {
        rot += 360.0f;
    }
    while (rot >= 360.0f) {
        rot -= 360.0f;
    }
    struct vec2 scale;
    obs_sceneitem_get_scale(item, &scale);
    char buf[96];
    snprintf(buf, sizeof(buf), "{\"rot\":%.1f,\"flipX\":%s,\"flipY\":%s}", rot, scale.x < 0.0f ? "true" : "false",
             scale.y < 0.0f ? "true" : "false");
    return CreateString(env, buf);
#endif
}

/* nativeSetSourceSize(id, w, h): absolute size in canvas px. Computes the
 * item scale from the source's base dimensions (scale = target / base),
 * preserving the sign of the current scale so a mirrored item stays
 * mirrored. w or h <= 0 keeps that axis unchanged. */
napi_value NativeSetSourceSize(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string id;
    double w = 0, h = 0;
    if (argc < 3 || !GetStringArg(env, args[0], id) || napi_get_value_double(env, args[1], &w) != napi_ok ||
        napi_get_value_double(env, args[2], &h) != napi_ok) {
        return ThrowError(env, "nativeSetSourceSize(id, w, h): bad arguments");
    }
#ifndef HAVE_LIBOBS
    (void)id; (void)w; (void)h;
    return ThrowCoreNotLinked(env);
#else
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    obs_sceneitem_t *item = FindSceneItemById(std::strtoll(id.c_str(), nullptr, 10));
    if (item == nullptr) {
        return CreateBool(env, false);
    }
    obs_source_t *src = obs_sceneitem_get_source(item);
    const uint32_t baseW = obs_source_get_width(src);
    const uint32_t baseH = obs_source_get_height(src);
    if (baseW == 0 || baseH == 0) {
        return CreateBool(env, false);
    }
    struct vec2 cur;
    obs_sceneitem_get_scale(item, &cur);
    struct vec2 next = cur;
    if (w > 0) {
        const float sign = cur.x < 0.0f ? -1.0f : 1.0f;
        next.x = sign * (float)(w / (double)baseW);
    }
    if (h > 0) {
        const float sign = cur.y < 0.0f ? -1.0f : 1.0f;
        next.y = sign * (float)(h / (double)baseH);
    }
    obs_sceneitem_set_scale(item, &next);
    return CreateBool(env, true);
#endif
}

/* ---- Source lock + z-order (desktop source-row icons parity) --------- */

/* nativeSetSourceLocked(id, locked) -> bool. A locked item ignores canvas
 * drag/pinch in the ArkUI gesture layer (PreviewInteractor checks the flag). */
napi_value NativeSetSourceLocked(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string id;
    bool locked = false;
    if (argc < 2 || !GetStringArg(env, args[0], id) || napi_get_value_bool(env, args[1], &locked) != napi_ok) {
        return ThrowError(env, "nativeSetSourceLocked(id, locked): bad arguments");
    }
#ifndef HAVE_LIBOBS
    (void)id; (void)locked;
    return ThrowCoreNotLinked(env);
#else
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    obs_sceneitem_t *item = FindSceneItemById(std::strtoll(id.c_str(), nullptr, 10));
    if (item == nullptr) {
        return CreateBool(env, false);
    }
    return CreateBool(env, obs_sceneitem_set_locked(item, locked));
#endif
}

/* nativeSetSourceOrder(id, dir): dir is 'up' | 'down' | 'top' | 'bottom'.
 * Moves the item in the scene's draw order (later = drawn on top). */
napi_value NativeSetSourceOrder(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string id, dir;
    if (argc < 2 || !GetStringArg(env, args[0], id) || !GetStringArg(env, args[1], dir)) {
        return ThrowError(env, "nativeSetSourceOrder(id, dir): bad arguments");
    }
#ifndef HAVE_LIBOBS
    (void)id; (void)dir;
    return ThrowCoreNotLinked(env);
#else
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    obs_sceneitem_t *item = FindSceneItemById(std::strtoll(id.c_str(), nullptr, 10));
    if (item == nullptr) {
        return CreateBool(env, false);
    }
    enum obs_order_movement movement;
    if (dir == "up") {
        movement = OBS_ORDER_MOVE_UP;
    } else if (dir == "down") {
        movement = OBS_ORDER_MOVE_DOWN;
    } else if (dir == "top") {
        movement = OBS_ORDER_MOVE_TOP;
    } else if (dir == "bottom") {
        movement = OBS_ORDER_MOVE_BOTTOM;
    } else {
        return CreateBool(env, false);
    }
    obs_sceneitem_set_order(item, movement);
    return CreateBool(env, true);
#endif
}

/* ---- Advanced audio props (desktop 高级音频属性 parity) -------------- */

/* nativeGetSourceAudioProps(id) -> JSON '{"sync":ms,"monitor":0|1|2}'
 * ('' when the item is gone). monitor maps the obs_monitoring_type enum:
 * 0=none, 1=monitor-only, 2=monitor-and-output. */
napi_value NativeGetSourceAudioProps(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string id;
    if (argc < 1 || !GetStringArg(env, args[0], id)) {
        return ThrowError(env, "nativeGetSourceAudioProps(id): argument must be a string");
    }
#ifndef HAVE_LIBOBS
    (void)id;
    return ThrowCoreNotLinked(env);
#else
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    obs_sceneitem_t *item = FindSceneItemById(std::strtoll(id.c_str(), nullptr, 10));
    obs_source_t *src = item != nullptr ? obs_sceneitem_get_source(item) : nullptr;
    if (src == nullptr) {
        return CreateString(env, "");
    }
    char buf[96];
    snprintf(buf, sizeof(buf), "{\"sync\":%lld,\"monitor\":%d}", (long long)obs_source_get_sync_offset(src),
             (int)obs_source_get_monitoring_type(src));
    return CreateString(env, buf);
#endif
}

/* nativeSetSourceAudioProps(id, syncOffsetMs, monitoringType) -> bool. */
napi_value NativeSetSourceAudioProps(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string id;
    double syncMs = 0;
    int32_t monitor = 0;
    if (argc < 3 || !GetStringArg(env, args[0], id) || napi_get_value_double(env, args[1], &syncMs) != napi_ok ||
        napi_get_value_int32(env, args[2], &monitor) != napi_ok) {
        return ThrowError(env, "nativeSetSourceAudioProps(id, syncMs, monitor): bad arguments");
    }
#ifndef HAVE_LIBOBS
    (void)id; (void)syncMs; (void)monitor;
    return ThrowCoreNotLinked(env);
#else
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    obs_sceneitem_t *item = FindSceneItemById(std::strtoll(id.c_str(), nullptr, 10));
    obs_source_t *src = item != nullptr ? obs_sceneitem_get_source(item) : nullptr;
    if (src == nullptr) {
        return CreateBool(env, false);
    }
    obs_source_set_sync_offset(src, (int64_t)syncMs);
    if (monitor >= OBS_MONITORING_TYPE_NONE && monitor <= OBS_MONITORING_TYPE_MONITOR_AND_OUTPUT) {
        obs_source_set_monitoring_type(src, (enum obs_monitoring_type)monitor);
    }
    return CreateBool(env, true);
#endif
}

/* ---- Media source transport (ffmpeg_source playback controls) -------- */

/* nativeMediaControl(id, action) -> bool. action is one of
 * "play" | "pause" | "restart" | "stop". Only sources whose output flags
 * carry OBS_SOURCE_CONTROLLABLE_MEDIA respond; everything else is a no-op
 * that still returns true (the panel hides itself for non-media sources). */
napi_value NativeMediaControl(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string id, action;
    if (argc < 2 || !GetStringArg(env, args[0], id) || !GetStringArg(env, args[1], action)) {
        return ThrowError(env, "nativeMediaControl(id, action): bad arguments");
    }
#ifndef HAVE_LIBOBS
    (void)id; (void)action;
    return ThrowCoreNotLinked(env);
#else
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    obs_sceneitem_t *item = FindSceneItemById(std::strtoll(id.c_str(), nullptr, 10));
    obs_source_t *src = item != nullptr ? obs_sceneitem_get_source(item) : nullptr;
    if (src == nullptr) {
        return CreateBool(env, false);
    }
    if (action == "play") {
        obs_source_media_play_pause(src, false);
    } else if (action == "pause") {
        obs_source_media_play_pause(src, true);
    } else if (action == "restart") {
        obs_source_media_restart(src);
    } else if (action == "stop") {
        obs_source_media_stop(src);
    } else {
        return CreateBool(env, false);
    }
    return CreateBool(env, true);
#endif
}

/* nativeGetMediaState(id) -> JSON
 * '{"time":ms,"duration":ms,"state":"playing|paused|stopped|ended|error|none"}'
 * ('' when the item is gone). The panel polls this on its own timer to move
 * the seek slider; duration 0 means "not a media source / not loaded yet". */
napi_value NativeGetMediaState(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string id;
    if (argc < 1 || !GetStringArg(env, args[0], id)) {
        return ThrowError(env, "nativeGetMediaState(id): argument must be a string");
    }
#ifndef HAVE_LIBOBS
    (void)id;
    return ThrowCoreNotLinked(env);
#else
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    obs_sceneitem_t *item = FindSceneItemById(std::strtoll(id.c_str(), nullptr, 10));
    obs_source_t *src = item != nullptr ? obs_sceneitem_get_source(item) : nullptr;
    if (src == nullptr) {
        return CreateString(env, "");
    }
    const int64_t duration = obs_source_media_get_duration(src);
    const int64_t time = obs_source_media_get_time(src);
    const char *state = "none";
    switch (obs_source_media_get_state(src)) {
    case OBS_MEDIA_STATE_PLAYING:
        state = "playing";
        break;
    case OBS_MEDIA_STATE_PAUSED:
        state = "paused";
        break;
    case OBS_MEDIA_STATE_STOPPED:
        state = "stopped";
        break;
    case OBS_MEDIA_STATE_ENDED:
        state = "ended";
        break;
    case OBS_MEDIA_STATE_ERROR:
        state = "error";
        break;
    default:
        state = "none";
        break;
    }
    char buf[160];
    snprintf(buf, sizeof(buf), "{\"time\":%lld,\"duration\":%lld,\"state\":\"%s\"}", (long long)time,
             (long long)duration, state);
    return CreateString(env, buf);
#endif
}

/* nativeMediaSeek(id, ms) -> bool. Absolute seek; the slider commits on
 * release so a drag does not spam seeks. */
napi_value NativeMediaSeek(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string id;
    double ms = 0;
    if (argc < 2 || !GetStringArg(env, args[0], id) || napi_get_value_double(env, args[1], &ms) != napi_ok) {
        return ThrowError(env, "nativeMediaSeek(id, ms): bad arguments");
    }
#ifndef HAVE_LIBOBS
    (void)id; (void)ms;
    return ThrowCoreNotLinked(env);
#else
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    obs_sceneitem_t *item = FindSceneItemById(std::strtoll(id.c_str(), nullptr, 10));
    obs_source_t *src = item != nullptr ? obs_sceneitem_get_source(item) : nullptr;
    if (src == nullptr) {
        return CreateBool(env, false);
    }
    obs_source_media_set_time(src, (int64_t)ms);
    return CreateBool(env, true);
#endif
}

/* ---- Generic property schema (desktop OBS property renderer parity) --- */

#ifdef HAVE_LIBOBS
/* Append s as a JSON string literal (with quotes). */
static void AppendJsonString(std::string &out, const char *s)
{
    out += '"';
    for (; s != nullptr && *s != '\0'; s++) {
        const unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') {
            out += '\\';
            out += (char)c;
        } else if (c == '\n') {
            out += "\\n";
        } else if (c == '\r') {
            out += "\\r";
        } else if (c == '\t') {
            out += "\\t";
        } else if (c < 0x20) {
            char buf[8];
            snprintf(buf, sizeof(buf), "\\u%04x", c);
            out += buf;
        } else {
            out += (char)c;
        }
    }
    out += '"';
}

static void AppendComma(std::string &out)
{
    if (out.size() > 1) {
        out += ',';
    }
}

/* Walk one obs_properties_t, emitting a JSON descriptor per supported
 * property. obs_property_name() is the SETTINGS KEY; the human label is
 * obs_property_description() (verified against obs-properties.c new_prop).
 * GROUPs are flattened recursively; BUTTON/FONT/EDITABLE_LIST/FRAME_RATE
 * are skipped (no meaningful touch representation yet). */
static void CollectPropertySchema(obs_properties_t *props, obs_data_t *settings, std::string &out)
{
    for (obs_property_t *p = obs_properties_first(props); p != nullptr; obs_property_next(&p)) {
        if (!obs_property_visible(p)) {
            continue;
        }
        const char *key = obs_property_name(p);
        if (key == nullptr || key[0] == '\0') {
            continue;
        }
        const enum obs_property_type type = obs_property_get_type(p);
        if (type == OBS_PROPERTY_GROUP) {
            obs_properties_t *sub = obs_property_group_content(p);
            if (sub != nullptr) {
                CollectPropertySchema(sub, settings, out);
            }
            continue;
        }
        if (type == OBS_PROPERTY_INVALID || type == OBS_PROPERTY_BUTTON || type == OBS_PROPERTY_FONT ||
            type == OBS_PROPERTY_EDITABLE_LIST || type == OBS_PROPERTY_FRAME_RATE) {
            continue;
        }

        AppendComma(out);
        out += "{\"key\":";
        AppendJsonString(out, key);
        out += ",\"label\":";
        const char *label = obs_property_description(p);
        AppendJsonString(out, label != nullptr && label[0] != '\0' ? label : key);
        char buf[256];
        switch (type) {
        case OBS_PROPERTY_BOOL:
            out += ",\"type\":\"bool\",\"value\":";
            out += obs_data_get_bool(settings, key) ? "true" : "false";
            break;
        case OBS_PROPERTY_INT:
            out += ",\"type\":\"int\"";
            snprintf(buf, sizeof(buf), ",\"min\":%d,\"max\":%d,\"step\":%d,\"value\":%lld", obs_property_int_min(p),
                     obs_property_int_max(p), obs_property_int_step(p), obs_data_get_int(settings, key));
            out += buf;
            break;
        case OBS_PROPERTY_FLOAT:
            out += ",\"type\":\"float\"";
            snprintf(buf, sizeof(buf), ",\"min\":%g,\"max\":%g,\"step\":%g,\"value\":%g", obs_property_float_min(p),
                     obs_property_float_max(p), obs_property_float_step(p), obs_data_get_double(settings, key));
            out += buf;
            break;
        case OBS_PROPERTY_TEXT:
        case OBS_PROPERTY_PATH:
            out += ",\"type\":\"text\",\"value\":";
            AppendJsonString(out, obs_data_get_string(settings, key));
            break;
        case OBS_PROPERTY_COLOR:
        case OBS_PROPERTY_COLOR_ALPHA:
            out += ",\"type\":\"color\"";
            snprintf(buf, sizeof(buf), ",\"value\":%u", (unsigned)obs_data_get_int(settings, key));
            out += buf;
            break;
        case OBS_PROPERTY_LIST: {
            const enum obs_combo_format fmt = obs_property_list_format(p);
            out += ",\"type\":\"list\",\"format\":";
            AppendJsonString(out, fmt == OBS_COMBO_FORMAT_INT ? "int" : (fmt == OBS_COMBO_FORMAT_FLOAT ? "float" :
                                                                                                                                       "string"));
            out += ",\"options\":[";
            const size_t count = obs_property_list_item_count(p);
            for (size_t i = 0; i < count; i++) {
                if (i > 0) {
                    out += ',';
                }
                out += "{\"name\":";
                AppendJsonString(out, obs_property_list_item_name(p, i));
                out += ",\"value\":";
                if (fmt == OBS_COMBO_FORMAT_INT) {
                    snprintf(buf, sizeof(buf), "%lld", obs_property_list_item_int(p, i));
                    out += buf;
                } else if (fmt == OBS_COMBO_FORMAT_FLOAT) {
                    snprintf(buf, sizeof(buf), "%g", obs_property_list_item_float(p, i));
                    out += buf;
                } else {
                    AppendJsonString(out, obs_property_list_item_string(p, i));
                }
                out += '}';
            }
            out += "],\"value\":";
            if (fmt == OBS_COMBO_FORMAT_INT) {
                snprintf(buf, sizeof(buf), "%lld", obs_data_get_int(settings, key));
                out += buf;
            } else if (fmt == OBS_COMBO_FORMAT_FLOAT) {
                snprintf(buf, sizeof(buf), "%g", obs_data_get_double(settings, key));
                out += buf;
            } else {
                AppendJsonString(out, obs_data_get_string(settings, key));
            }
            break;
        }
        default:
            break;
        }
        const char *suffix = type == OBS_PROPERTY_INT ? obs_property_int_suffix(p) :
                         (type == OBS_PROPERTY_FLOAT ? obs_property_float_suffix(p) : nullptr);
        if (suffix != nullptr && suffix[0] != '\0') {
            out += ",\"suffix\":";
            AppendJsonString(out, suffix);
        }
        out += '}';
    }
}
#endif

/* nativeGetPropertySchema(itemId, filterName) -> JSON array of property
 * descriptors ('[]' unavailable / not controllable). filterName '' renders
 * the source's own properties; otherwise the named filter's. The ArkTS
 * generic renderer turns this into switches/sliders/fields live. */
napi_value NativeGetPropertySchema(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string id, filterName;
    if (argc < 1 || !GetStringArg(env, args[0], id)) {
        return ThrowError(env, "nativeGetPropertySchema(itemId, filterName?): bad arguments");
    }
    if (argc >= 2) {
        GetStringArg(env, args[1], filterName);
    }
#ifndef HAVE_LIBOBS
    (void)id; (void)filterName;
    return CreateString(env, "[]");
#else
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    obs_sceneitem_t *item = FindSceneItemById(std::strtoll(id.c_str(), nullptr, 10));
    obs_source_t *source = item != nullptr ? obs_sceneitem_get_source(item) : nullptr;
    if (source == nullptr) {
        return CreateString(env, "[]");
    }
    obs_source_t *filter = nullptr;
    if (!filterName.empty()) {
        filter = obs_source_get_filter_by_name(source, filterName.c_str());
        if (filter == nullptr) {
            return CreateString(env, "[]");
        }
        source = filter;
    }
    obs_properties_t *props = obs_source_properties(source);
    obs_data_t *settings = obs_source_get_settings(source);
    std::string out = "[";
    if (props != nullptr) {
        CollectPropertySchema(props, settings, out);
    }
    out += ']';
    if (props != nullptr) {
        obs_properties_destroy(props);
    }
    obs_data_release(settings);
    if (filter != nullptr) {
        obs_source_release(filter);
    }
    return CreateString(env, out);
#endif
}

/* nativeSetFilterSettings(itemId, filterName, settingsJson) -> bool. Same
 * merge-and-update semantics as nativeSetSourceSettings, for filters. */
napi_value NativeSetFilterSettings(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string id, filterName, patchJson;
    if (argc < 3 || !GetStringArg(env, args[0], id) || !GetStringArg(env, args[1], filterName) ||
        !GetStringArg(env, args[2], patchJson)) {
        return ThrowError(env, "nativeSetFilterSettings(itemId, filterName, settingsJson): bad arguments");
    }
#ifndef HAVE_LIBOBS
    (void)id; (void)filterName; (void)patchJson;
    return ThrowCoreNotLinked(env);
#else
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    obs_sceneitem_t *item = FindSceneItemById(std::strtoll(id.c_str(), nullptr, 10));
    obs_source_t *source = item != nullptr ? obs_sceneitem_get_source(item) : nullptr;
    if (source == nullptr) {
        return CreateBool(env, false);
    }
    obs_source_t *filter = obs_source_get_filter_by_name(source, filterName.c_str());
    if (filter == nullptr) {
        return CreateBool(env, false);
    }
    obs_data_t *patch = obs_data_create_from_json(patchJson.c_str());
    if (patch == nullptr) {
        obs_source_release(filter);
        return ThrowError(env, "nativeSetFilterSettings: settingsJson is not valid JSON");
    }
    obs_data_t *current = obs_source_get_settings(filter);
    obs_data_apply(current, patch);
    obs_source_update(filter, current);
    obs_data_release(patch);
    obs_data_release(current);
    obs_source_release(filter);
    return CreateBool(env, true);
#endif
}

/* ---- Transition type (studio-mode 转场动画面板) ---------------------- */

/* Candidate transition ids from obs-transitions, in the desktop panel's
 * display order. Probed against the registered source types so a build that
 * ships fewer transition plugins simply offers fewer rows (and an unknown id
 * is rejected by setTransitionType). cut_transition is excluded: "cut" is
 * duration 0 in this frontend's model, not a transition source. */
static const char *const kTransitionCandidates[] = {
    "fade_transition", "slide_transition", "swipe_transition", "fade_to_color_transition", "wipe_transition",
};

/* nativeGetTransitionTypes() -> JSON array [{"id","name"}...] of the
 * transition types actually registered, plus the current one first if it is
 * somehow outside the candidate list. */
napi_value NativeGetTransitionTypes(napi_env env, napi_callback_info /*info*/)
{
#ifndef HAVE_LIBOBS
    return CreateString(env, "[]");
#else
    std::string out = "[";
    for (size_t i = 0; i < sizeof(kTransitionCandidates) / sizeof(kTransitionCandidates[0]); i++) {
        const char *tid = kTransitionCandidates[i];
        const char *display = obs_source_get_display_name(tid);
        if (display == nullptr) {
            continue; /* plugin not loaded in this build */
        }
        if (out.size() > 1) {
            out += ',';
        }
        out += "{\"id\":\"";
        out += tid;
        out += "\",\"name\":\"";
        /* Display names are plain ASCII locale strings; escape double
         * quotes defensively. */
        for (const char *p = display; *p != '\0'; p++) {
            if (*p == '"' || *p == '\\') {
                out += '\\';
            }
            out += *p;
        }
        out += "\"}";
    }
    out += ']';
    return CreateString(env, out);
#endif
}

/* nativeSetTransitionType(id) -> bool. Swaps the program-channel transition
 * shell to another transition type. The channel-0 ownership invariant (after
 * the shell exists, channel 0 always owns it) is preserved by rebuilding
 * around the currently visible source: seed the new shell with the source
 * the old shell shows, bind it to channel 0, then drop the old shell. */
napi_value NativeSetTransitionType(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string id;
    if (argc < 1 || !GetStringArg(env, args[0], id)) {
        return ThrowError(env, "nativeSetTransitionType(id): argument must be a string");
    }
#ifndef HAVE_LIBOBS
    (void)id;
    return ThrowCoreNotLinked(env);
#else
    if (id.empty() || obs_source_get_display_name(id.c_str()) == nullptr) {
        return CreateBool(env, false);
    }
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    if (g_programTransitionId == id) {
        return CreateBool(env, true);
    }

    if (g_programTransition != nullptr) {
        /* Rebuild the live shell: hand the visible source to a fresh shell
         * of the new type before releasing the old one, so channel 0 never
         * goes ownerless mid-swap. */
        obs_source_t *visible = obs_transition_get_active_source(g_programTransition);
        if (visible == nullptr || visible == g_programTransition) {
            if (visible != nullptr) {
                obs_source_release(visible); /* never re-parent the shell */
            }
            visible = obs_transition_get_source(g_programTransition, OBS_TRANSITION_SOURCE_A);
        }
        obs_source_t *fresh = obs_source_create_private(id.c_str(), "harmony_scene_transition", nullptr);
        if (fresh == nullptr) {
            obs_source_release(visible);
            return CreateBool(env, false);
        }
        obs_transition_set(fresh, visible);
        obs_source_release(visible);
        obs_set_output_source(0, fresh);
        obs_transition_clear(g_programTransition);
        obs_source_release(g_programTransition);
        g_programTransition = fresh;
    }
    g_programTransitionId = id;
    return CreateBool(env, true);
#endif
}

/* Switch the program channel (channel 0) to another registered scene.
 * Without a transition this is the "cut" the desktop frontend performs when
 * you click a scene in the scene list. With a duration > 0 it runs through
 * libobs's transition machinery: the program channel is taken over (once,
 * lazily) by a private fade_transition wrapper source — obs_transition_*
 * refuses any source whose type is not OBS_SOURCE_TYPE_TRANSITION, so the
 * scene sources themselves cannot host the transition. Seed the wrapper
 * with the current channel source, bind the wrapper to channel 0, then
 * obs_transition_start AUTO to the target; the video thread ticks it and
 * swaps A/B internally. duration <= 0 keeps the plain cut path. */
napi_value NativeSelectScene(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string id;
    if (argc < 1 || !GetStringArg(env, args[0], id)) {
        return ThrowError(env, "nativeSelectScene(id, durationMs?): id must be a string");
    }
    int64_t durationMs = 0;
    if (argc >= 2) {
        napi_get_value_int64(env, args[1], &durationMs);
    }
#ifndef HAVE_LIBOBS
    (void)id; (void)durationMs;
    return ThrowCoreNotLinked(env);
#else
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    auto it = g_scenes.find(id);
    if (it == g_scenes.end()) {
        return CreateBool(env, false);
    }
    obs_source_t *target = obs_scene_get_source(it->second);

    if (durationMs <= 0) {
        obs_set_output_source(0, target);
        return CreateBool(env, true);
    }

    if (g_programTransition == nullptr) {
        /* One persistent wrapper owned by us; the channel holds its own
         * reference once bound, so this create-ref stays for our lifetime
         * (released in ShutdownCore). */
        g_programTransition = obs_source_create_private(g_programTransitionId.c_str(), "harmony_scene_transition",
                                                        nullptr);
        if (g_programTransition == nullptr) {
            OH_LOG_WARN(LOG_APP, "%{public}s source unavailable, falling back to cut",
                        g_programTransitionId.c_str());
            obs_set_output_source(0, target);
            return CreateBool(env, true);
        }
        /* Seed with whatever owns channel 0 right now so the fade has a
         * real "from" picture (obs_get_output_source addrefs). */
        obs_source_t *current = obs_get_output_source(0);
        obs_transition_set(g_programTransition, current);
        obs_source_release(current);
        obs_set_output_source(0, g_programTransition);
    }

    const bool started = obs_transition_start(g_programTransition, OBS_TRANSITION_MODE_AUTO,
                                              (uint32_t)durationMs, target);
    OH_LOG_INFO(LOG_APP, "scene transition to '%{public}s': %{public}s (%{public}lld ms)", id.c_str(),
                started ? "started" : "noop/same", (long long)durationMs);
    return CreateBool(env, true);
#endif
}

// ---------------------------------------------------------------------------
// Video settings (settings panel): reset the canvas at a new resolution/fps.
// obs_reset_video re-creates the shared context and every XComponent EGL
// surface is rebuilt against it by the surface callbacks, so calling it while
// outputs are live is the same operation the desktop frontend performs from
// Settings → Video. Refuse while recording/streaming (libobs would drop the
// encoder surfaces mid-file; the desktop UI blocks the same way).
// ---------------------------------------------------------------------------

napi_value NativeGetVideoInfo(napi_env env, napi_callback_info /*info*/)
{
    napi_value obj = nullptr;
    napi_create_object(env, &obj);
#ifndef HAVE_LIBOBS
    SetProperty(env, obj, "width", CreateInt32(env, 1920));
    SetProperty(env, obj, "height", CreateInt32(env, 1080));
    SetProperty(env, obj, "fps", CreateInt32(env, 60));
#else
    struct obs_video_info ovi;
    if (obs_get_video_info(&ovi)) {
        SetProperty(env, obj, "width", CreateInt32(env, (int32_t)ovi.base_width));
        SetProperty(env, obj, "height", CreateInt32(env, (int32_t)ovi.base_height));
        SetProperty(env, obj, "fps",
                    CreateInt32(env, ovi.fps_den > 0 ? (int32_t)(ovi.fps_num / ovi.fps_den) : 0));
    }
#endif
    return obj;
}

napi_value NativeResetVideo(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t width = 0, height = 0, fps = 0;
    if (argc < 3 || napi_get_value_int32(env, args[0], &width) != napi_ok ||
        napi_get_value_int32(env, args[1], &height) != napi_ok ||
        napi_get_value_int32(env, args[2], &fps) != napi_ok) {
        return ThrowError(env, "nativeResetVideo(width, height, fps): three integers required");
    }
#ifndef HAVE_LIBOBS
    (void)width; (void)height; (void)fps;
    return ThrowCoreNotLinked(env);
#else
    if (width < 320 || height < 240 || width > 7680 || height > 4320 || (width % 2) || (height % 2)) {
        return CreateBool(env, false);
    }
    if (fps < 10 || fps > 120) {
        return CreateBool(env, false);
    }
    struct obs_video_info ovi = {};
    BuildVideoInfo(&ovi, width, height, fps);
    const int rc = obs_reset_video(&ovi);
    OH_LOG_INFO(LOG_APP, "nativeResetVideo %{public}dx%{public}d@%{public}d rc=%{public}d", width, height, fps, rc);
    return CreateBool(env, rc == OBS_VIDEO_SUCCESS);
#endif
}

// ---------------------------------------------------------------------------
// Filters (HAVE_LIBOBS) — thin wrappers over obs_source_create for filter
// types registered by obs-filters, attached with obs_source_filter_add.
// The ArkTS panel exposes add/remove/enable/list; settings stay at defaults.
// ---------------------------------------------------------------------------

napi_value NativeGetFilterTypes(napi_env env, napi_callback_info /*info*/)
{
    napi_value array = nullptr;
    napi_create_array(env, &array);
#ifndef HAVE_LIBOBS
    OH_LOG_DEBUG(LOG_APP, "nativeGetFilterTypes: shell-only, empty");
#else
    /* The subset of obs-filters types that are meaningful and GPU-cheap on
     * mobile GLES. Ids are the exact obs_source_info.id strings registered by
     * obs-filters (note: colour correction registers as "color_filter", not
     * "color_correction_filter"). Filters are private sources — libobs rejects
     * a public obs_source_create for OBS_SOURCE_TYPE_FILTER, so probing and
     * creation both go through obs_source_create_private. */
    static const char *const kCandidateFilters[] = {
        "color_filter", "scale_filter", "crop_filter", "sharpness_filter",
        /* audio: obs-filters registers these unconditionally at module load;
         * the create_private probe below still guards against a partial load.
         * libobs lets any source carry an audio filter — on a video-only
         * source it simply never processes audio, so no runtime guard needed
         * here (the desktop UI hides them instead; tracked as a polish item). */
        "gain_filter", "noise_gate_filter", "noise_suppress_filter", "late_delay_filter",
    };
    uint32_t index = 0;
    for (const char *fid : kCandidateFilters) {
        /* Cheap existence probe: create_private returns nullptr when the type
         * id was never registered (plugin missing / failed to load), so the
         * panel's candidate list degrades gracefully. */
        obs_source_t *probe = obs_source_create_private(fid, "__probe__", nullptr);
        if (probe != nullptr) {
            obs_source_release(probe);
            napi_value item = nullptr;
            napi_create_string_utf8(env, fid, NAPI_AUTO_LENGTH, &item);
            napi_set_element(env, array, index++, item);
        }
    }
#endif
    return array;
}

napi_value NativeAddFilter(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string sourceId; // scene item id (stringified int64)
    std::string filterTypeId;
    if (argc < 2 || !GetStringArg(env, args[0], sourceId) || !GetStringArg(env, args[1], filterTypeId)) {
        return ThrowError(env, "nativeAddFilter(sourceId, filterTypeId): bad arguments");
    }
#ifndef HAVE_LIBOBS
    (void)sourceId; (void)filterTypeId;
    return CreateBool(env, false);
#else
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    obs_sceneitem_t *item = FindSceneItemById(std::strtoll(sourceId.c_str(), nullptr, 10));
    if (item == nullptr) {
        return CreateBool(env, false);
    }
    obs_source_t *source = obs_sceneitem_get_source(item);
    if (source == nullptr) {
        return CreateBool(env, false);
    }
    // Filters are private sources; a public obs_source_create rejects
    // OBS_SOURCE_TYPE_FILTER with "can't be created publically".
    // Pass the type's DEFAULT settings, not nullptr: color_filter's
    // opacity comes from obs_data_get_int(SETTING_OPACITY) and a missing
    // key reads as 0 — a zero row in the matrix multiplies every pixel to
    // black. obs_get_source_defaults runs the plugin's get_defaults hook
    // (opacity=100 → 1.0), exactly what the Qt frontend does.
    obs_data_t *defaults = obs_get_source_defaults(filterTypeId.c_str());
    obs_source_t *filter = obs_source_create_private(filterTypeId.c_str(), filterTypeId.c_str(), defaults);
    if (defaults) {
        obs_data_release(defaults);
    }
    if (filter == nullptr) {
        return CreateBool(env, false); // type not registered
    }
    /* obs_source_filter_add is void and silently rejects incompatible
     * capability pairs (filter_compatible in obs-source.c): an audio-only
     * filter on a video-only source is created, refused, and destroyed —
     * yet our old code still returned true, so the panel showed a phantom
     * filter. Mirror the check (audio-only filter ⇒ source must carry
     * OBS_SOURCE_AUDIO) and report the truth. */
    const uint32_t f_caps = obs_source_get_output_flags(filter);
    const uint32_t s_caps = obs_source_get_output_flags(source);
    if ((f_caps & OBS_SOURCE_AUDIO) != 0 && (f_caps & OBS_SOURCE_VIDEO) == 0
        && (s_caps & OBS_SOURCE_AUDIO) == 0) {
        obs_source_release(filter);
        OH_LOG_WARN(LOG_APP, "addFilter: '%{public}s' is audio-only, source '%{public}s' has no audio, refused",
                    filterTypeId.c_str(), obs_source_get_name(source));
        return CreateBool(env, false);
    }
    obs_source_filter_add(source, filter);
    const bool added = obs_source_get_filter_by_name(source, filterTypeId.c_str()) != nullptr;
    obs_source_release(filter); // source holds the ref now
    return CreateBool(env, added);
#endif
}

napi_value NativeRemoveFilter(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string sourceId, filterName;
    if (argc < 2 || !GetStringArg(env, args[0], sourceId) || !GetStringArg(env, args[1], filterName)) {
        return ThrowError(env, "nativeRemoveFilter(sourceId, filterName): bad arguments");
    }
#ifndef HAVE_LIBOBS
    (void)sourceId; (void)filterName;
    return CreateBool(env, false);
#else
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    obs_sceneitem_t *item = FindSceneItemById(std::strtoll(sourceId.c_str(), nullptr, 10));
    if (item == nullptr) {
        return CreateBool(env, false);
    }
    obs_source_t *source = obs_sceneitem_get_source(item);
    obs_source_t *filter = obs_source_get_filter_by_name(source, filterName.c_str());
    if (filter == nullptr) {
        return CreateBool(env, false);
    }
    obs_source_filter_remove(source, filter);
    obs_source_release(filter);
    return CreateBool(env, true);
#endif
}

napi_value NativeSetFilterEnabled(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string sourceId, filterName;
    bool enabled = true;
    napi_get_value_bool(env, args[2], &enabled);
    if (argc < 3 || !GetStringArg(env, args[0], sourceId) || !GetStringArg(env, args[1], filterName)) {
        return ThrowError(env, "nativeSetFilterEnabled(sourceId, filterName, enabled): bad arguments");
    }
#ifndef HAVE_LIBOBS
    (void)sourceId; (void)filterName; (void)enabled;
    return CreateBool(env, false);
#else
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    obs_sceneitem_t *item = FindSceneItemById(std::strtoll(sourceId.c_str(), nullptr, 10));
    if (item == nullptr) {
        return CreateBool(env, false);
    }
    obs_source_t *source = obs_sceneitem_get_source(item);
    obs_source_t *filter = obs_source_get_filter_by_name(source, filterName.c_str());
    if (filter == nullptr) {
        return CreateBool(env, false);
    }
    obs_source_set_enabled(filter, enabled);
    obs_source_release(filter);
    return CreateBool(env, true);
#endif
}

struct FilterEnumCtx {
    napi_env env;
    napi_value array;
    uint32_t index = 0;
};

void FilterCollectCallback(obs_source_t * /*parent*/, obs_source_t *filter, void *param)
{
    FilterEnumCtx *ctx = static_cast<FilterEnumCtx *>(param);
    napi_value obj = nullptr;
    napi_create_object(ctx->env, &obj);
    SetProperty(ctx->env, obj, "name", CreateString(ctx->env, obs_source_get_name(filter)));
    SetProperty(ctx->env, obj, "typeId",
                CreateString(ctx->env, obs_source_get_unversioned_id(filter)));
    SetProperty(ctx->env, obj, "enabled", CreateBool(ctx->env, obs_source_enabled(filter)));
    napi_set_element(ctx->env, ctx->array, ctx->index++, obj);
}

napi_value NativeGetFilters(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string sourceId;
    if (argc < 1 || !GetStringArg(env, args[0], sourceId)) {
        return ThrowError(env, "nativeGetFilters(sourceId): argument must be a string");
    }
    napi_value array = nullptr;
    napi_create_array(env, &array);
#ifndef HAVE_LIBOBS
    (void)sourceId;
#else
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    obs_sceneitem_t *item = FindSceneItemById(std::strtoll(sourceId.c_str(), nullptr, 10));
    if (item != nullptr) {
        obs_source_t *source = obs_sceneitem_get_source(item);
        FilterEnumCtx ctx{env, array, 0};
        obs_source_enum_filters(source, FilterCollectCallback, &ctx);
    }
#endif
    return array;
}

napi_value NativeGetAudioTracks(napi_env env, napi_callback_info /*info*/)
{
    napi_value array = nullptr;
    napi_create_array(env, &array);
#ifdef HAVE_LIBOBS
    // Snapshot the registered scenes' audio sources OUTSIDE g_audioMutex
    // (scene enumeration takes g_sceneMutex; never nest the two), then
    // reconcile the track registry under the audio lock.
    std::vector<obs_source_t *> snapshot;
    {
        std::lock_guard<std::mutex> lock(g_sceneMutex);
        for (auto &entry : g_scenes) {
            obs_scene_enum_items(entry.second, CollectSceneAudioRef, &snapshot);
        }
    }
    {
        std::lock_guard<std::mutex> lock(g_audioMutex);
        for (auto &entry : g_audioTracks) {
            entry.second->seen = false;
        }
        for (obs_source_t *src : snapshot) {
            RegisterAudioSource(src);
        }
        PruneAudioTracksLocked();
        uint32_t i = 0;
        for (auto &entry : g_audioTracks) {
            napi_set_element(env, array, i++, BuildTrackObject(env, entry.second));
        }
    }
    for (obs_source_t *src : snapshot) {
        obs_source_release(src);
    }
#endif
    return array;
}

// Resolve a mixer track id (source uuid) to a TEMPORARY strong ref. The
// caller owns the returned reference and must obs_source_release() it.
static obs_source_t *LookupTrackSource(const std::string &uuid)
{
#ifdef HAVE_LIBOBS
    std::lock_guard<std::mutex> lock(g_audioMutex);
    auto it = g_audioTracks.find(uuid);
    if (it != g_audioTracks.end()) {
        return LockTrackSource(it->second);
    }
#else
    (void)uuid;
#endif
    return nullptr;
}

napi_value NativeSetMute(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string trackId;
    bool muted = false;
    if (argc < 2 || !GetStringArg(env, args[0], trackId) ||
        napi_get_value_bool(env, args[1], &muted) != napi_ok) {
        return ThrowError(env, "nativeSetMute(trackId, muted): bad arguments");
    }
#ifdef HAVE_LIBOBS
    obs_source_t *source = LookupTrackSource(trackId);
    if (source == nullptr) {
        return ThrowError(env, "nativeSetMute: unknown track id");
    }
    // The mixer IS the program-audio control now: muting the source mutes it
    // in preview, recording and streaming alike — desktop OBS semantics.
    obs_source_set_muted(source, muted);
    obs_source_release(source); // LookupTrackSource hands us a temp ref
    return CreateBool(env, true);
#else
    return ThrowCoreNotLinked(env);
#endif
}

napi_value NativeSetVolume(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string trackId;
    double volume = 1.0;
    if (argc < 2 || !GetStringArg(env, args[0], trackId) ||
        napi_get_value_double(env, args[1], &volume) != napi_ok) {
        return ThrowError(env, "nativeSetVolume(trackId, volume): bad arguments");
    }
    if (volume < 0.0) {
        volume = 0.0;
    } else if (volume > 1.0) {
        volume = 1.0;
    }
#ifdef HAVE_LIBOBS
    obs_source_t *source = LookupTrackSource(trackId);
    if (source == nullptr) {
        return ThrowError(env, "nativeSetVolume: unknown track id");
    }
    obs_source_set_volume(source, static_cast<float>(volume));
    obs_source_release(source); // LookupTrackSource hands us a temp ref
    return CreateBool(env, true);
#else
    return ThrowCoreNotLinked(env);
#endif
}

napi_value NativeGetOutputLevels(napi_env env, napi_callback_info /*info*/)
{
    napi_value array = nullptr;
    napi_create_array(env, &array);
#ifdef HAVE_LIBOBS
    // Levels are last-published obs_volmeter values, linear 0..1. When the
    // audio thread has gone quiet (meter callbacks stop arriving), decay
    // toward zero manually — the volmeter only fires on actual frames, so a
    // silent source must NOT freeze its bar at the old peak.
    static constexpr int64_t DECAY_WINDOW_NS = 300 * 1000 * 1000; // 300 ms
    std::lock_guard<std::mutex> lock(g_audioMutex);
    const int64_t now = os_gettime_ns();
    uint32_t i = 0;
    for (auto &entry : g_audioTracks) {
        SourceTrack *track = entry.second;
        napi_value obj = nullptr;
        napi_create_object(env, &obj);
        SetProperty(env, obj, "id", CreateString(env, track->uuid));
        const bool stale = (now - track->lastNs.load()) > DECAY_WINDOW_NS;
        if (stale) {
            track->peak.store(0.0f);
            track->rms.store(0.0f);
        }
        SetProperty(env, obj, "peak", CreateDouble(env, track->peak.load()));
        SetProperty(env, obj, "rms", CreateDouble(env, track->rms.load()));
        napi_set_element(env, array, i++, obj);
    }
#endif
    return array;
}

napi_value NativeCanCaptureSystemAudio(napi_env env, napi_callback_info /*info*/)
{
    // Honest runtime probe — do NOT assume PC/2in1 support. Official docs list
    // Phone/Tablet/TV for SystemCapability.Multimedia.Audio.PlaybackCapture;
    // the ArkTS wrapper ANDs this native probe with
    // canIUse('SystemCapability.Multimedia.Audio.PlaybackCapture').
    //
    // Probe 1: the device's actually-loaded libohaudio.so must export the
    //          API 23 async loopback entry point.
    const bool symbolPresent =
        dlsym(RTLD_DEFAULT, "OH_AudioCapturer_RequestPlaybackCaptureStart") != nullptr;
    // Probe 2: the runtime API level must be >= 23 (RequestPlaybackCaptureStart).
    const int32_t apiLevel = OH_GetSdkApiVersion();
    // Probe 3: the screen-capture stack the desktop-audio UX pairs with must
    //          be present (OH_AVScreenCapture, API 10+).
    const bool capturePresent = dlsym(RTLD_DEFAULT, "OH_AVScreenCapture_Create") != nullptr;
    const bool ok = symbolPresent && capturePresent && apiLevel >= 23;
    OH_LOG_INFO(LOG_APP,
                "system audio probe: loopback symbol=%{public}d avcapture=%{public}d "
                "api=%{public}d -> %{public}s",
                symbolPresent, capturePresent, apiLevel, ok ? "supported" : "unsupported");
    return CreateBool(env, ok);
}

napi_value NativeStartStreaming(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string configJson;
    if (argc < 1 || !GetStringArg(env, args[0], configJson)) {
        return ThrowError(env, "nativeStartStreaming(configJson): argument must be a string");
    }
#ifndef HAVE_LIBOBS
    (void)configJson;
    return ThrowCoreNotLinked(env);
#else
    std::lock_guard<std::mutex> lock(g_outputMutex);
    if (g_streamOutput != nullptr && obs_output_active(g_streamOutput)) {
        return CreateBool(env, true); // already live
    }
    obs_data_t *config = obs_data_create_from_json(configJson.c_str());
    if (config == nullptr) {
        config = obs_data_create();
    }
    const char *server = obs_data_get_string(config, "server");
    const char *key = obs_data_get_string(config, "key");
    const int64_t videoKbps = obs_data_get_int(config, "videoBitrateKbps");
    const int64_t audioKbps = obs_data_get_int(config, "audioBitrateKbps");
    if (server == nullptr || server[0] == '\0') {
        obs_data_release(config);
        return ThrowError(env, "nativeStartStreaming: configJson.server (rtmp url) is required");
    }

    // RTMP service (the librtmp stack ships in plugins/obs-outputs/librtmp).
    obs_data_t *serviceSettings = obs_data_create();
    obs_data_set_string(serviceSettings, "server", server);
    obs_data_set_string(serviceSettings, "key", key != nullptr ? key : "");
    obs_service_t *service =
        obs_service_create("rtmp_custom", "harmony_service", serviceSettings, nullptr);
    obs_data_release(serviceSettings);
    if (service == nullptr) {
        obs_data_release(config);
        return ThrowError(env, "obs_service_create('rtmp_custom') failed (obs-outputs not staged?)");
    }

    obs_output_t *output = obs_output_create("rtmp_output", "harmony_stream", nullptr, nullptr);
    /* Copy the server string out of config before releasing it — the log
     * line below (and the service settings above) must not dangle. */
    const std::string serverCopy = server != nullptr ? server : "";
    obs_data_release(config);
    if (output == nullptr) {
        obs_service_release(service);
        return ThrowError(env, "obs_output_create('rtmp_output') failed (obs-outputs not staged?)");
    }
    obs_output_set_service(output, service);
    /* obs_output_set_service does NOT addref — the output holds a bare
     * pointer. Our create reference must outlive the output or the service
     * is destroyed under it (start then sees a NULL service). Released in
     * NativeStopStreaming / on failed start. */

    std::string encoderError;
    /* Streaming stays on the H.264 chain: legacy RTMP/FLV has no standard
     * HEVC tag (desktop OBS needs SIST for HEVC), so the settings-panel
     * codec switch only governs recording. */
    if (!WireOutputEncoders(output, videoKbps > 0 ? videoKbps : 2500,
                            audioKbps > 0 ? audioKbps : 160, nullptr, encoderError)) {
        obs_service_release(service);
        obs_output_release(output);
        return ThrowError(env, encoderError.c_str());
    }

    if (!obs_output_start(output)) {
        obs_service_release(service);
        obs_output_release(output);
        return ThrowError(env, "obs_output_start() failed for the rtmp output");
    }
    if (g_streamOutput != nullptr) {
        obs_output_stop(g_streamOutput);
        obs_output_release(g_streamOutput);
        if (g_streamService) {
            obs_service_release(g_streamService);
            g_streamService = nullptr;
        }
    }
    g_streamService = service;
    g_streamOutput = output;
    g_streamStartTime = std::chrono::steady_clock::now();
    StartStatsThread();
    OH_LOG_INFO(LOG_APP, "streaming started to %{public}s", serverCopy.c_str());
    return CreateBool(env, true);
#endif
}

napi_value NativeStopStreaming(napi_env env, napi_callback_info /*info*/)
{
#ifndef HAVE_LIBOBS
    return ThrowCoreNotLinked(env);
#else
    std::lock_guard<std::mutex> lock(g_outputMutex);
    if (g_streamOutput == nullptr) {
        return CreateBool(env, true);
    }
    // obs_output_stop() is asynchronous; libobs keeps its own references
    // while the output winds down, so releasing ours here is safe.
    obs_output_stop(g_streamOutput);
    obs_output_release(g_streamOutput);
    g_streamOutput = nullptr;
    if (g_streamService != nullptr) {
        obs_service_release(g_streamService);
        g_streamService = nullptr;
    }
    if (g_recordOutput == nullptr) {
        StopStatsThread();
    }
    return CreateBool(env, true);
#endif
}

napi_value NativeStartRecording(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string configJson;
    if (argc < 1 || !GetStringArg(env, args[0], configJson)) {
        return ThrowError(env, "nativeStartRecording(configJson): argument must be a string");
    }
#ifndef HAVE_LIBOBS
    (void)configJson;
    return ThrowCoreNotLinked(env);
#else
    std::lock_guard<std::mutex> lock(g_outputMutex);
    if (g_recordOutput != nullptr && obs_output_active(g_recordOutput)) {
        return CreateBool(env, true);
    }
    // configJson carries the muxer settings straight through, e.g.
    // {"path": "/data/storage/.../rec.mp4"}.
    // HarmonyOS's app sandbox forbids fork/exec of a bundled ELF, so the
    // ffmpeg_muxer output (which spawns the obs-ffmpeg-mux helper) is not
    // usable here. obs-outputs' mp4_output is a fully in-process encoded
    // muxer (h264/aac) writing straight to the sandbox path — the right fit.
    obs_data_t *config = obs_data_create_from_json(configJson.c_str());
    if (config == nullptr) {
        return ThrowError(env, "obs_data_create_from_json() failed on configJson");
    }
    const char *path = obs_data_get_string(config, "path");
    if (path == nullptr || path[0] == '\0') {
        obs_data_release(config);
        return ThrowError(env, "nativeStartRecording: configJson.path is required");
    }
    const int64_t videoKbps = obs_data_get_int(config, "videoBitrateKbps");
    const int64_t audioKbps = obs_data_get_int(config, "audioBitrateKbps");
    const std::string videoCodecCopy = obs_data_get_string(config, "videoCodec");

    obs_output_t *output = obs_output_create("mp4_output", "harmony_recording", config, nullptr);
    obs_data_release(config);
    if (output == nullptr) {
        return ThrowError(env, "obs_output_create('mp4_output') failed (obs-outputs not staged?)");
    }
    std::string encoderError;
    if (!WireOutputEncoders(output, videoKbps > 0 ? videoKbps : 10000,
                            audioKbps > 0 ? audioKbps : 192, videoCodecCopy.c_str(), encoderError)) {
        obs_output_release(output);
        return ThrowError(env, encoderError.c_str());
    }
    if (!obs_output_start(output)) {
        obs_output_release(output);
        return ThrowError(env, "obs_output_start() failed for the recording output");
    }
    if (g_recordOutput != nullptr) {
        obs_output_release(g_recordOutput);
    }
    g_recordOutput = output;
    g_recordStartTime = std::chrono::steady_clock::now();
    StartStatsThread();
    OH_LOG_INFO(LOG_APP, "recording started to %{public}s", path);
    return CreateBool(env, true);
#endif
}

napi_value NativeStopRecording(napi_env env, napi_callback_info /*info*/)
{
#ifndef HAVE_LIBOBS
    return ThrowCoreNotLinked(env);
#else
    std::lock_guard<std::mutex> lock(g_outputMutex);
    if (g_recordOutput == nullptr) {
        return CreateBool(env, true);
    }
    obs_output_stop(g_recordOutput);
    obs_output_release(g_recordOutput);
    g_recordOutput = nullptr;
    if (g_streamOutput == nullptr) {
        StopStatsThread();
    }
    return CreateBool(env, true);
#endif
}

napi_value NativeGetStats(napi_env env, napi_callback_info /*info*/)
{
    napi_value obj = nullptr;
    napi_create_object(env, &obj);
#ifndef HAVE_LIBOBS
    SetProperty(env, obj, "streaming", CreateBool(env, false));
    SetProperty(env, obj, "recording", CreateBool(env, false));
    SetProperty(env, obj, "bitrateKbps", CreateDouble(env, 0.0));
    SetProperty(env, obj, "droppedFrames", CreateInt64(env, 0));
    SetProperty(env, obj, "totalFrames", CreateInt64(env, 0));
    SetProperty(env, obj, "uptimeSeconds", CreateInt64(env, 0));
#else
    StatsPayload stats;
    {
        std::lock_guard<std::mutex> lock(g_outputMutex);
        stats = ComputeStatsLocked();
    }
    SetProperty(env, obj, "streaming", CreateBool(env, stats.streaming));
    SetProperty(env, obj, "recording", CreateBool(env, stats.recording));
    SetProperty(env, obj, "bitrateKbps", CreateDouble(env, stats.bitrateKbps));
    SetProperty(env, obj, "droppedFrames", CreateInt64(env, stats.droppedFrames));
    SetProperty(env, obj, "totalFrames", CreateInt64(env, stats.totalFrames));
    SetProperty(env, obj, "uptimeSeconds", CreateInt64(env, stats.uptimeSeconds));
#endif
    return obj;
}

napi_value NativeSetStatsCallback(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::lock_guard<std::mutex> lock(g_statsMutex);
    if (g_statsTsf != nullptr) {
        napi_release_threadsafe_function(g_statsTsf, napi_tsfn_release);
        g_statsTsf = nullptr;
    }

    napi_valuetype type = napi_undefined;
    if (argc < 1 || napi_typeof(env, args[0], &type) != napi_ok ||
        type == napi_null || type == napi_undefined) {
        return CreateBool(env, true); // unregistered
    }
    if (type != napi_function) {
        return ThrowError(env, "nativeSetStatsCallback(cb): argument must be a function or null");
    }

    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "obs_stats_push", NAPI_AUTO_LENGTH, &resourceName);
    if (napi_create_threadsafe_function(env, args[0], nullptr, resourceName,
                                        0 /*unlimited queue*/, 1 /*one native thread*/,
                                        nullptr, nullptr, nullptr, CallJsStats,
                                        &g_statsTsf) != napi_ok) {
        g_statsTsf = nullptr;
        return ThrowError(env, "napi_create_threadsafe_function failed");
    }
    return CreateBool(env, true);
}

// ===========================================================================
// Shared helpers declared in obs_bridge.h
// ===========================================================================

napi_value ThrowError(napi_env env, const char *message)
{
    napi_value error = nullptr;
    napi_value messageValue = nullptr;
    napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &messageValue);
    napi_create_error(env, nullptr, messageValue, &error);
    napi_throw(env, error);
    OH_LOG_ERROR(LOG_APP, "%{public}s", message);
    return nullptr;
}

napi_value ThrowCoreNotLinked(napi_env env)
{
    return ThrowError(env,
                      "libobs core is not linked in this build (HAVE_LIBOBS undefined). "
                      "Cross-compile libobs for HarmonyOS arm64, stage it into a prefix with "
                      "include/ + lib/libobs.so, and rebuild with "
                      "-DOBS_HARMONY_PREFIX=<prefix>.");
}

/**
 * nativeGetSourceSettings(itemId) -> JSON string of the source's settings
 * (or '' when the item is gone). The WebFeed registry rebuilds itself from
 * this after a scene reload: ArkTS learns each harmony_web_source item's url
 * and viewport straight from libobs, which is their single source of truth.
 */
napi_value NativeGetSourceSettings(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string id;
    if (argc < 1 || !GetStringArg(env, args[0], id)) {
        return ThrowError(env, "nativeGetSourceSettings(id): argument must be a string");
    }
#ifndef HAVE_LIBOBS
    return ThrowCoreNotLinked(env);
#else
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    obs_sceneitem_t *item = FindSceneItemById(std::strtoll(id.c_str(), nullptr, 10));
    obs_source_t *src = item != nullptr ? obs_sceneitem_get_source(item) : nullptr;
    if (src == nullptr) {
        return CreateString(env, "");
    }
    obs_data_t *settings = obs_source_get_settings(src);
    const char *json = settings != nullptr ? obs_data_get_json(settings) : nullptr;
    std::string out = json != nullptr ? json : "";
    if (settings != nullptr) {
        obs_data_release(settings);
    }
    return CreateString(env, out);
#endif
}

/**
 * nativeSetSourceSettings(itemId, settingsJson) -> bool
 *
 * Applies a settings PATCH to an existing source: the current settings are
 * read, the patch's keys are merged over them (obs_data_apply, key by key —
 * keys the patch omits keep their current value), and obs_source_update
 * pushes the result through the plugin's update() callback, which owns all
 * restart decisions (camera device switch, window canvas pin, ...). This is
 * the write-back channel of the per-source ArkTS settings panel.
 */
napi_value NativeSetSourceSettings(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string id;
    std::string patch_json;
    if (argc < 2 || !GetStringArg(env, args[0], id) || !GetStringArg(env, args[1], patch_json)) {
        return ThrowError(env, "nativeSetSourceSettings(id, settingsJson): both arguments must be strings");
    }
#ifndef HAVE_LIBOBS
    return ThrowCoreNotLinked(env);
#else
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    obs_sceneitem_t *item = FindSceneItemById(std::strtoll(id.c_str(), nullptr, 10));
    obs_source_t *src = item != nullptr ? obs_sceneitem_get_source(item) : nullptr;
    if (src == nullptr) {
        napi_value failed;
        napi_get_boolean(env, false, &failed);
        return failed;
    }

    obs_data_t *patch = obs_data_create_from_json(patch_json.c_str());
    if (patch == nullptr) {
        return ThrowError(env, "nativeSetSourceSettings: settingsJson is not valid JSON");
    }

    obs_data_t *current = obs_source_get_settings(src);
    obs_data_apply(current, patch);
    obs_source_update(src, current);
    obs_data_release(patch);
    obs_data_release(current);

    napi_value ok;
    napi_get_boolean(env, true, &ok);
    return ok;
#endif
}

// ---------------------------------------------------------------------------
// ArkWeb browser source feed (harmony-web)
// ---------------------------------------------------------------------------
//
// The Web page lives in an ArkTS componentSnapshot loop (WebFeed.ets):
// rasterise off-screen -> RGBA ArrayBuffer -> nativeWebSourceFeed(itemId, ...).
// The harmony-web plugin only registered the source TYPE (no capture of its
// own — ArkWeb is not a native API), so pixels enter libobs right here. This
// is the same async-frame path harmony-remotecam proved safe to drive from a
// non-graphics thread (there the codec callback, here the ArkTS napi thread);
// obs_source_output_video() copies into libobs' own async buffer.
//
// Geometry: the plugin's get_width/get_height report the viewport stored in
// settings (800x600 defaults, editable); the ArkTS host renders its off-screen
// Web component at exactly that viewport and snapshots at that size, so frame
// w/h and the stored size agree. width/height args here are validated against
// the buffer length and used to build the frame — mismatched feeds drop.

napi_value NativeWebSourceFeed(napi_env env, napi_callback_info info)
{
    // nativeWebSourceFeed(itemId, width, height, rgba, timestampNs) -> bool
    size_t argc = 5;
    napi_value args[5] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string id;
    int64_t width = 0, height = 0;
    if (argc < 5 || !GetStringArg(env, args[0], id) || napi_get_value_int64(env, args[1], &width) != napi_ok ||
        napi_get_value_int64(env, args[2], &height) != napi_ok || width <= 0 || height <= 0 ||
        width > 8192 || height > 8192) {
        return CreateBool(env, false);
    }
    void *data = nullptr;
    size_t len = 0;
    if (napi_get_arraybuffer_info(env, args[3], &data, &len) != napi_ok || data == nullptr) {
        return CreateBool(env, false);
    }
    const uint64_t wantBytes = (uint64_t)width * (uint64_t)height * 4;
    if (len < wantBytes) {
        return CreateBool(env, false); // short buffer: drop, never read OOB
    }
    uint64_t ts = 0;
    if (napi_get_value_int64(env, args[4], (int64_t *)&ts) != napi_ok || ts == 0) {
        ts = (uint64_t)os_gettime_ns();
    }

#ifndef HAVE_LIBOBS
    return ThrowCoreNotLinked(env);
#else
    std::lock_guard<std::mutex> lock(g_sceneMutex);
    obs_sceneitem_t *item = FindSceneItemById(std::strtoll(id.c_str(), nullptr, 10));
    if (item == nullptr) {
        return CreateBool(env, false); // source gone (item id may be stale after scene reload)
    }
    obs_source_t *src = obs_sceneitem_get_source(item);
    if (src == nullptr) {
        return CreateBool(env, false);
    }

    // PixelMap snapshots are BGRA_8888 on OHOS; libobs' VIDEO_FORMAT_BGRA is
    // the matching byte order (B,G,R,A), so the buffer goes through untouched
    // — a per-pixel R/B swap in ArkTS at snapshot rate would only burn the UI
    // thread.
    struct obs_source_frame *frame = obs_source_frame_create(VIDEO_FORMAT_BGRA, (uint32_t)width, (uint32_t)height);
    if (frame == nullptr) {
        return CreateBool(env, false);
    }
    // linesize may be 64-byte aligned while the ArkTS buffer is tight w*4 —
    // copy row by row, never assume they match.
    const uint8_t *rows = static_cast<const uint8_t *>(data);
    for (int64_t y = 0; y < height; y++)
        memcpy(frame->data[0] + (size_t)y * frame->linesize[0], rows + (size_t)y * (size_t)(width * 4),
               (size_t)(width * 4));
    frame->timestamp = ts;
    obs_source_output_video(src, frame);
    obs_source_frame_destroy(frame);
    return CreateBool(env, true);
#endif
}

} // namespace obs_bridge
