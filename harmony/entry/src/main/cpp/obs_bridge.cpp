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
#include <util/base.h>
#include <media-io/audio-io.h>
#include <media-io/video-io.h>
#include <obs-data.h>
#include <obs-module.h>
#include <obs-harmony-api.h>  // public surface only; obs-harmony.h drags in obs-internal.h
#include <obs.h>
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
// Audio capture tracks (desktop loopback + microphone)
//
// Desktop audio is HarmonyOS playback capture ("内录"): API 23+/26 provides
// OH_AudioCapturer_RequestPlaybackCaptureStart with mode
// MEDIA|EXCLUDING_SELF. IMPORTANT: that request is ASYNC — a successful
// return only means "submitted"; the actual result (including whether the
// user approved the system privacy dialog) arrives in
// OnPlaybackCaptureStartResult as SUCCESS / NOT_AUTHORIZED / FAILED. The
// track state machine below models exactly that, and nativeGetAudioTracks()
// reports it honestly to the UI.
// ===========================================================================

constexpr const char *TRACK_DESKTOP_ID = "desktop-audio";
constexpr const char *TRACK_MIC_ID = "mic-audio";

// Mirrored 1:1 in ArkTS — see types/libobs_bridge/index.d.ts (NativeAudioTrack.state).
enum class CaptureState : int32_t {
    Unsupported = 0,
    Idle = 1,
    Requesting = 2,   // async loopback authorization pending
    Running = 3,
    NotAuthorized = 4, // user denied the system privacy dialog
    Failed = 5,
};

struct AudioTrack {
    const char *id;
    const char *name;
    bool loopback; // true = desktop playback capture, false = microphone
    std::atomic<CaptureState> state{CaptureState::Idle};
    std::atomic<bool> muted{false};
    std::atomic<float> volume{1.0f}; // linear 0..1
    std::atomic<float> peak{0.0f};   // linear 0..1, latest buffer
    std::atomic<float> rms{0.0f};    // linear 0..1, latest buffer
    // builder/capturer are guarded by g_audioMutex.
    OH_AudioStreamBuilder *builder = nullptr;
    OH_AudioCapturer *capturer = nullptr;
};

std::mutex g_audioMutex;
AudioTrack g_desktopTrack{TRACK_DESKTOP_ID, "Desktop Audio", true};
AudioTrack g_micTrack{TRACK_MIC_ID, "Microphone", false};

void OnAudioReadData(OH_AudioCapturer * /*capturer*/, void *userData, void *audioData,
                     int32_t audioDataSize)
{
    // Runs on the audio service's capture thread. Configured format is
    // 48 kHz stereo S16LE (see StartTrack). Keep this cheap: meters only.
    // Under HAVE_LIBOBS this is also the point where the PCM buffer will be
    // handed to libobs's audio pipeline (obs_source_output_audio via a
    // dedicated capture source) once the audio feed plumbing lands.
    AudioTrack *track = static_cast<AudioTrack *>(userData);
    if (track == nullptr || audioData == nullptr || audioDataSize <= 0) {
        return;
    }
    const float gain = track->muted.load(std::memory_order_relaxed)
                           ? 0.0f
                           : track->volume.load(std::memory_order_relaxed);
    const int16_t *samples = static_cast<const int16_t *>(audioData);
    const size_t count = static_cast<size_t>(audioDataSize) / sizeof(int16_t);
    float peak = 0.0f;
    double sumSquares = 0.0;
    for (size_t i = 0; i < count; ++i) {
        const float s = (static_cast<float>(samples[i]) / 32768.0f) * gain;
        const float a = std::fabs(s);
        if (a > peak) {
            peak = a;
        }
        sumSquares += static_cast<double>(s) * static_cast<double>(s);
    }
    const float rms = count > 0 ? static_cast<float>(std::sqrt(sumSquares / static_cast<double>(count))) : 0.0f;
    track->peak.store(peak, std::memory_order_relaxed);
    track->rms.store(rms, std::memory_order_relaxed);
}

void OnPlaybackCaptureStartResult(OH_AudioCapturer * /*capturer*/, void *userData,
                                  OH_AudioStream_PlaybackCaptureStartState state)
{
    AudioTrack *track = static_cast<AudioTrack *>(userData);
    if (track == nullptr) {
        return;
    }
    switch (state) {
        case AUDIOSTREAM_PLAYBACKCAPTURE_START_STATE_SUCCESS:
            track->state.store(CaptureState::Running);
            OH_LOG_INFO(LOG_APP, "desktop loopback authorized + running");
            break;
        case AUDIOSTREAM_PLAYBACKCAPTURE_START_STATE_NOT_AUTHORIZED:
            track->state.store(CaptureState::NotAuthorized);
            OH_LOG_WARN(LOG_APP, "desktop loopback NOT authorized (privacy dialog denied)");
            break;
        default:
            track->state.store(CaptureState::Failed);
            OH_LOG_ERROR(LOG_APP, "desktop loopback start failed, state=%{public}d",
                         static_cast<int>(state));
            break;
    }
}

bool StartTrack(AudioTrack &track)
{
    std::lock_guard<std::mutex> lock(g_audioMutex);
    if (track.capturer != nullptr) {
        return true; // already built/running
    }
    track.peak.store(0.0f);
    track.rms.store(0.0f);

    OH_AudioStream_Result r = OH_AudioStreamBuilder_Create(&track.builder, AUDIOSTREAM_TYPE_CAPTURER);
    if (r != AUDIOSTREAM_SUCCESS || track.builder == nullptr) {
        OH_LOG_ERROR(LOG_APP, "builder create failed for %{public}s: %{public}d", track.id, r);
        track.state.store(CaptureState::Failed);
        return false;
    }
    OH_AudioStreamBuilder_SetCapturerInfo(track.builder, AUDIOSTREAM_SOURCE_TYPE_MIC);
    OH_AudioStreamBuilder_SetSamplingRate(track.builder, 48000);
    OH_AudioStreamBuilder_SetChannelCount(track.builder, 2);
    OH_AudioStreamBuilder_SetSampleFormat(track.builder, AUDIOSTREAM_SAMPLE_S16LE);
    OH_AudioStreamBuilder_SetCapturerReadDataCallback(track.builder, &OnAudioReadData, &track);

    if (track.loopback) {
        // Desktop loopback: capture media playback, excluding our own output.
        // PC/2in1 support of SystemCapability.Multimedia.Audio.PlaybackCapture is
        // UNVERIFIED (official docs list Phone/Tablet/TV), so failure here —
        // or NOT_AUTHORIZED in the async callback — is a normal, surfaced
        // outcome, not a bug. The UI reports it as such.
        OH_AudioStreamBuilder_SetPlaybackCaptureMode(
            track.builder, AUDIOSTREAM_PLAYBACKCAPTURE_MODE_MEDIA |
                               AUDIOSTREAM_PLAYBACKCAPTURE_MODE_EXCLUDING_SELF);
    }

    r = OH_AudioStreamBuilder_GenerateCapturer(track.builder, &track.capturer);
    OH_AudioStreamBuilder_Destroy(track.builder);
    track.builder = nullptr;
    if (r != AUDIOSTREAM_SUCCESS || track.capturer == nullptr) {
        OH_LOG_ERROR(LOG_APP, "generate capturer failed for %{public}s: %{public}d", track.id, r);
        track.state.store(CaptureState::Failed);
        return false;
    }

    if (track.loopback) {
        track.state.store(CaptureState::Requesting);
        r = OH_AudioCapturer_RequestPlaybackCaptureStart(track.capturer,
                                                         &OnPlaybackCaptureStartResult, &track);
        if (r != AUDIOSTREAM_SUCCESS) {
            OH_LOG_ERROR(LOG_APP, "RequestPlaybackCaptureStart submit failed: %{public}d", r);
            track.state.store(CaptureState::Failed);
            return false;
        }
        // ASYNC by design: the request is submitted; the outcome (success or
        // privacy-dialog denial) lands in OnPlaybackCaptureStartResult. Do NOT
        // report Running here.
        OH_LOG_INFO(LOG_APP, "desktop loopback start requested (async authorization pending)");
        return true;
    }

    // Microphone: plain capturer, requires ohos.permission.MICROPHONE to have
    // been granted (requested in EntryAbility). Without it Start() fails and
    // the track reports Failed; the UI can re-trigger after granting.
    r = OH_AudioCapturer_Start(track.capturer);
    track.state.store(r == AUDIOSTREAM_SUCCESS ? CaptureState::Running : CaptureState::Failed);
    OH_LOG_INFO(LOG_APP, "mic capturer start result: %{public}d", r);
    return r == AUDIOSTREAM_SUCCESS;
}

void StopTrack(AudioTrack &track)
{
    std::lock_guard<std::mutex> lock(g_audioMutex);
    if (track.capturer != nullptr) {
        OH_AudioCapturer_Stop(track.capturer);
        OH_AudioCapturer_Release(track.capturer);
        track.capturer = nullptr;
    }
    track.state.store(CaptureState::Idle);
    track.peak.store(0.0f);
    track.rms.store(0.0f);
}

napi_value BuildTrackObject(napi_env env, const AudioTrack &track)
{
    napi_value obj = nullptr;
    napi_create_object(env, &obj);
    SetProperty(env, obj, "id", CreateString(env, track.id));
    SetProperty(env, obj, "name", CreateString(env, track.name));
    SetProperty(env, obj, "muted", CreateBool(env, track.muted.load()));
    SetProperty(env, obj, "volume", CreateDouble(env, track.volume.load()));
    SetProperty(env, obj, "state", CreateInt32(env, static_cast<int32_t>(track.state.load())));
    const bool supported =
        track.loopback ? (track.state.load() != CaptureState::Unsupported) : true;
    SetProperty(env, obj, "supported", CreateBool(env, supported));
    return obj;
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
                "obs-ffmpeg",      "obs-filters",   "obs-outputs",    "obs-transitions",
                "obs-x264",        "rtmp-services", "image-source",   "text-freetype2",
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

    // Audio capture tracks are HarmonyOS-native and live in BOTH modes, so
    // the mixer meters show real signal even before the core port lands.
    StartTrack(g_desktopTrack);
    StartTrack(g_micTrack);
    return CreateBool(env, coreOk);
}

void ShutdownCore()
{
#ifdef HAVE_LIBOBS
    StopStatsThread();
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
    StopTrack(g_desktopTrack);
    StopTrack(g_micTrack);
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
    obs_source_remove(obs_scene_get_source(it->second));
    obs_scene_release(it->second);
    g_scenes.erase(it);
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
        return CreateBool(env, false);
    }
    obs_sceneitem_remove(item);
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
        g_programTransition = obs_source_create_private("fade_transition", "harmony_scene_transition", nullptr);
        if (g_programTransition == nullptr) {
            OH_LOG_WARN(LOG_APP, "fade_transition source unavailable, falling back to cut");
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
    obs_source_filter_add(source, filter);
    obs_source_release(filter); // source holds the ref now
    return CreateBool(env, true);
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
    napi_set_element(env, array, 0, BuildTrackObject(env, g_desktopTrack));
    napi_set_element(env, array, 1, BuildTrackObject(env, g_micTrack));
    return array;
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
    AudioTrack *track = nullptr;
    if (trackId == TRACK_DESKTOP_ID) {
        track = &g_desktopTrack;
    } else if (trackId == TRACK_MIC_ID) {
        track = &g_micTrack;
    } else {
        return ThrowError(env, "nativeSetMute: unknown track id");
    }
    track->muted.store(muted);
#ifdef HAVE_LIBOBS
    // Under the linked core the mixer also drives the channel-0 program audio
    // via libobs (obs_source_set_muted on the capture source feeding the
    // mix). The gain/mute above already silences what the meters show and
    // what will be fed to the audio pipeline from OnAudioReadData.
#endif
    return CreateBool(env, true);
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
    AudioTrack *track = nullptr;
    if (trackId == TRACK_DESKTOP_ID) {
        track = &g_desktopTrack;
    } else if (trackId == TRACK_MIC_ID) {
        track = &g_micTrack;
    } else {
        return ThrowError(env, "nativeSetVolume: unknown track id");
    }
    track->volume.store(static_cast<float>(volume));
    return CreateBool(env, true);
}

napi_value NativeGetOutputLevels(napi_env env, napi_callback_info /*info*/)
{
    napi_value array = nullptr;
    napi_create_array(env, &array);
    // Non-const: reading the meters consumes (resets) the accumulated values.
    AudioTrack *tracks[2] = {&g_desktopTrack, &g_micTrack};
    for (uint32_t i = 0; i < 2; ++i) {
        napi_value obj = nullptr;
        napi_create_object(env, &obj);
        SetProperty(env, obj, "id", CreateString(env, tracks[i]->id));
        SetProperty(env, obj, "peak", CreateDouble(env, tracks[i]->peak.exchange(0.0f)));
        SetProperty(env, obj, "rms", CreateDouble(env, tracks[i]->rms.exchange(0.0f)));
        napi_set_element(env, array, i, obj);
    }
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

} // namespace obs_bridge
