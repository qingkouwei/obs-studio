// ---------------------------------------------------------------------------
// camera_sender.cpp — the phone-role ("wireless camera") outbound relay for
// W3-C1. It is deliberately independent of libobs: the phone never runs the
// OBS core. The whole sender is pure HarmonyOS NDK:
//
//   Camera Kit  ->  renders straight into the H.264 encoder's INPUT SURFACE
//                   (zero-copy: no NV12 readback on the phone),
//   OH_VideoEncoder  ->  emits Annex-B buffers via onNewOutputBuffer,
//   a socket writer thread  ->  frames each buffer with the RCTM wire
//                   header and pushes it over TCP to the producer device.
//
// The encoder output callback must never block on TCP backpressure, so the
// callback only copies the bitstream into a queue and the dedicated sender
// thread drains it. Live semantics: if the queue overruns (producer stalled /
// network hiccup) the OLDEST items drop, not the newest.
//
// RCTM header constants live in remotecam_wire.h (mirror of
// plugins/harmony-remotecam/remotecam-protocol.h).
// ---------------------------------------------------------------------------

#include "camera_sender.h"
#include "obs_bridge.h" // ThrowError

#include <arpa/inet.h>
#include <atomic>
#include <chrono>
#include <cinttypes>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <errno.h>
#include <fcntl.h>
#include <mutex>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <string>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
#include <vector>

#include <hilog/log.h>

#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avcodec_videoencoder.h>
#include <multimedia/player_framework/native_avcodec_audioencoder.h>
#include <multimedia/player_framework/native_averrors.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avmemory.h>
#include <native_window/external_window.h>

#include <ohaudio/native_audiocapturer.h>
#include <ohaudio/native_audiostreambuilder.h>
#include <ohaudio/native_audiostream_base.h>

#include <ohcamera/camera.h>
#include <ohcamera/camera_input.h>
#include <ohcamera/camera_manager.h>
#include <ohcamera/capture_session.h>
#include <ohcamera/video_output.h>

#include "remotecam_wire.h"

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0B50
#define LOG_TAG "camera_sender"

#define CSLOGI(...) OH_LOG_INFO(LOG_APP, __VA_ARGS__)
#define CSLOGW(...) OH_LOG_WARN(LOG_APP, __VA_ARGS__)
#define CSLOGE(...) OH_LOG_ERROR(LOG_APP, __VA_ARGS__)

namespace obs_bridge {
namespace {

struct OutItem {
    std::vector<uint8_t> payload;
    int64_t pts;
    uint32_t flags;
};

// ---------------------------------------------------------------------------
// Mic audio side (task #36): OH_AudioCapturer (48k stereo S16) -> AAC-LC
// encoder (async-buffer mode) -> RCTM frames with kRctmFlagAudio. PCM goes
// in through the OH_AVMemory* the onNeedInputData callback hands us; the
// encoder only owns the buffer until PushInputData, so the read callback
// copies into an upload queue and drains it from the need-input callback.
// ---------------------------------------------------------------------------
namespace audio {

constexpr int32_t kRate = 48000;
constexpr int32_t kChannels = 2;
constexpr int32_t kBitrateBps = 96000;
// AAC frames are 1024 samples — the encoder expects whole AU-sized inputs.
// (20 ms / 960-sample chunks fed misaligned PCM: the encoder emitted 13-byte
// "silence" AUs while the mic clearly had signal, 10-05 device probe.)
constexpr int kPcmChunkBytes = 1024 * kChannels * 2; // 4096 B = 21.33 ms
constexpr int64_t kPcmBytesPerSec = (int64_t)kRate * kChannels * 2; // 192000
constexpr int kMaxUpload = 8;                             // ~170 ms backlog

struct PcmChunk {
    std::vector<uint8_t> pcm;
    int64_t pts;
};

struct Slicer {
    // read callbacks deliver arbitrary sizes; the encoder input buffers are
    // fixed-size. Slice the stream into whole kPcmChunkBytes pieces first.
    std::vector<uint8_t> buf;
    // Stream->time mapping: pts = anchor_pts + bytes_sliced * 1e9 / 192000.
    // anchor_pts is taken (once) from the monotonic clock at the first slice;
    // from then on it is pure arithmetic, which keeps the chunk grid exactly
    // 20 ms apart and monotonic by construction.
    int64_t anchor_pts = 0;
    int64_t sliced_bytes = 0;
    bool anchored = false;
};

} // namespace audio

class CameraSender {
public:
    std::atomic<bool> running{false};
    std::atomic<bool> connected{false};
    std::atomic<bool> failed{false};
    // Production semantics (10-04 review): once the first connection is up,
    // a peer drop / send error must NOT end the feed — the thread retries
    // with exponential backoff until the user stops it. UI reads these to
    // render "重连中（第 N 次）".
    std::atomic<bool> ever_connected{false};
    std::atomic<bool> reconnecting{false};
    std::atomic<int> retry_count{0};
    std::atomic<uint64_t> dropped{0};

    // config
    std::string host;
    uint16_t port = kRemoteCamDefaultPort;
    int32_t bitrate_kbps = 3000;
    int32_t fps = 30;

    // encoder
    OH_AVCodec *encoder = nullptr;
    OHNativeWindow *window = nullptr;

    // camera
    Camera_Manager *manager = nullptr;
    Camera_Input *input = nullptr;
    Camera_CaptureSession *session = nullptr;
    Camera_VideoOutput *vout = nullptr;
    Camera_VideoProfile profile{};
    char device_id_buf[64]; // owned copy; dev.cameraId points here
    uint32_t width = 0;
    uint32_t height = 0;

    // socket + queue
    int sock_fd = -1;
    pthread_t send_thread{};
    bool thread_started = false;

    std::mutex qmutex;
    std::condition_variable qcond;
    std::deque<OutItem> queue;
    // Cached config AU (SPS/PPS): the encoder emits it once at start, but a
    // reconnecting peer needs it again before the next keyframe.
    std::vector<uint8_t> config_au;

    // mic audio side (task #36): capturer -> AAC encoder -> shared RCTM queue
    OH_AudioCapturer *capturer = nullptr;
    OH_AVCodec *aenc = nullptr;
    std::mutex amutex;
    std::condition_variable apcm_cond;      // wakes parked encoder-input cbs
    std::deque<audio::PcmChunk> apcm;       // PCM backlog, cap kMaxUpload
    audio::Slicer aslicer;                  // read-cb stream -> fixed chunks
    std::vector<uint8_t> audio_config;      // cached CSD/ADTS config, resend on reconnect
    bool audio_live = false;                // encoder + capturer up
    // Stage diagnostics (task #36): log one line per N events per stage.
    std::atomic<int> a_cap_cnt{0}, a_cap_peak{0}, a_enc_out_cnt{0};
    std::atomic<int> a_enc_in_cnt{0}, a_enc_starve{0};

    void enqueue(OutItem &&item) {
        {
            std::lock_guard<std::mutex> lk(qmutex);
            if (item.flags & kRctmFlagConfig) {
                config_au = item.payload; // cache for reconnects
            }
            // Depth cap for live semantics: ~1 s of AUs at 30 fps.
            constexpr size_t kMaxQueue = 30;
            while (queue.size() >= kMaxQueue) {
                queue.pop_front();
            }
            queue.push_back(std::move(item));
        }
        qcond.notify_one();
    }

    void shutdownSocket();
    void stop();
};

CameraSender g_sender;

// ---------------------------------------------------------------------------
// Camera callbacks (error surface only; frames flow through the surface).
// Declared before CameraSender's out-of-line stop() uses their addresses.
// ---------------------------------------------------------------------------

void OnCameraInputError(const Camera_Input *input, Camera_ErrorCode code) {
    (void)input;
    CSLOGW("camera input error %{public}d", (int)code);
}
CameraInput_Callbacks g_input_cbs{.onError = OnCameraInputError};

void OnSessionError(Camera_CaptureSession *session, Camera_ErrorCode code) {
    (void)session;
    CSLOGW("capture session error %{public}d", (int)code);
}
CaptureSession_Callbacks g_session_cbs{.onError = OnSessionError};

void OnVideoOutputError(Camera_VideoOutput *vout, Camera_ErrorCode code) {
    (void)vout;
    CSLOGW("video output error %{public}d", (int)code);
}
VideoOutput_Callbacks g_vout_cbs{.onError = OnVideoOutputError};

// ---------------------------------------------------------------------------
// Mic audio pipeline (task #36)
// ---------------------------------------------------------------------------

namespace {

int64_t NowNs() {
    struct timespec ts{};
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

// Capturer read callback: arbitrary-size S16LE stereo stream -> slice into
// fixed 20 ms chunks for the encoder's input buffers.
//
// pts model: anchor the stream to the monotonic clock ONCE (first slice),
// then pts = anchor + stream_position, because for a constant-bitrate PCM
// stream the position IS time: 48000 Hz x 2 ch x 2 bytes = 192000 B/s, one
// 3840-byte chunk = exactly 20 ms. No per-callback guessing, monotonic by
// construction, same CLOCK_MONOTONIC domain as the video path.
void OnAudioCaptured(OH_AudioCapturer *cap, void *user, void *data, int32_t size) {
    (void)cap;
    (void)user;
    CameraSender &s = g_sender;
    if (!s.running.load() || size <= 0) return;
    {
        // Peak-energy probe: distinguishes "mic captured silence" from a
        // downstream codec/format fault. S16LE signed peak over the callback.
        const int16_t *pcm = static_cast<const int16_t *>(data);
        int n = size / 2;
        int32_t peak = 0;
        for (int i = 0; i < n; i++) {
            int32_t v = pcm[i] < 0 ? -pcm[i] : pcm[i];
            if (v > peak) peak = v;
        }
        int c = ++s.a_cap_cnt;
        if (peak > s.a_cap_peak) s.a_cap_peak = peak;
        if (c == 1 || c % 1500 == 0)
            CSLOGI("audio stage1 capture: %{public}d cbs peak=%{public}d size=%{public}d", c, (int)s.a_cap_peak.load(),
                   size);
    }
    std::lock_guard<std::mutex> lk(s.amutex);
    audio::Slicer &sl = s.aslicer;
    const uint8_t *p = static_cast<const uint8_t *>(data);
    sl.buf.insert(sl.buf.end(), p, p + size);
    while ((int)sl.buf.size() >= audio::kPcmChunkBytes) {
        if (!sl.anchored) {
            sl.anchor_pts = NowNs();
            sl.anchored = true;
        }
        audio::PcmChunk chunk;
        chunk.pcm.assign(sl.buf.begin(), sl.buf.begin() + audio::kPcmChunkBytes);
        chunk.pts = sl.anchor_pts + sl.sliced_bytes * 1000000000LL / audio::kPcmBytesPerSec;
        sl.sliced_bytes += audio::kPcmChunkBytes;
        sl.buf.erase(sl.buf.begin(), sl.buf.begin() + audio::kPcmChunkBytes);
        if ((int)s.apcm.size() >= audio::kMaxUpload) {
            s.apcm.pop_front(); // live semantics: drop oldest PCM
        }
        s.apcm.push_back(std::move(chunk));
        s.apcm_cond.notify_one(); // wake a parked encoder-input callback
    }
}

void OnAudioEncError(OH_AVCodec *codec, int32_t err, void *user) {
    (void)codec; (void)user;
    CSLOGW("audio encoder error %{public}d — audio disabled, video continues", err);
    g_sender.audio_live = false;
    g_sender.apcm_cond.notify_all(); // release parked input callbacks
}

void OnAudioEncStreamChanged(OH_AVCodec *codec, OH_AVFormat *format, void *user) {
    (void)codec; (void)user;
    // AAC CSD arrives here (OH_MD_KEY_CODEC_CONFIG). Cache it for reconnect
    // re-priming; also forward it as a config frame so the peer decoder can
    // be configured even without a separate GetOutputDescription call.
    uint8_t *addr = nullptr;
    size_t size = 0;
    if (format && OH_AVFormat_GetBuffer(format, OH_MD_KEY_CODEC_CONFIG, &addr, &size) && addr && size) {
        CameraSender &s = g_sender;
        std::lock_guard<std::mutex> lk(s.amutex);
        s.audio_config.assign(addr, addr + size);
        CSLOGI("audio config cached, %{public}zu bytes", size);
    }
}

void OnAudioNeedInput(OH_AVCodec *codec, uint32_t index, OH_AVMemory *mem, void *user) {
    (void)user;
    CameraSender &s = g_sender;
    OH_AVCodecBufferAttr attr{};
    {
        std::unique_lock<std::mutex> lk(s.amutex);
        if (s.running.load() && s.audio_live) {
            // Block until real PCM exists — never push an empty buffer back.
            // A timed wait that expires still feeds size=0 and the codec
            // hot-loops (device probe 10-05: ~7800 need_input/s vs 47 real
            // chunks/s → every AU the encoder emitted was 13-byte silence).
            // Releasing amutex here lets the capture callback keep running;
            // running=false from stop()/OnAudioEncError breaks us out.
            s.apcm_cond.wait(lk, [&] { return !s.apcm.empty() || !s.running.load() || !s.audio_live; });
        }
        if (!s.apcm.empty()) {
            audio::PcmChunk chunk = std::move(s.apcm.front());
            s.apcm.pop_front();
            uint8_t *dst = OH_AVMemory_GetAddr(mem);
            int32_t cap = OH_AVMemory_GetSize(mem);
            size_t n = chunk.pcm.size();
            if ((int32_t)n > cap) n = (size_t)cap;
            if (dst && n > 0) memcpy(dst, chunk.pcm.data(), n);
            int c = ++s.a_enc_in_cnt;
            if (c == 1 || c % 1500 == 0)
                CSLOGI("audio stage2 encoder-in: %{public}d pushes maxN=%{public}zu cap=%{public}d starve=%{public}d",
                       c, (size_t)n, cap, (int)s.a_enc_starve.load());
            attr.pts = chunk.pts;
            attr.size = (int32_t)n;
            attr.flags = AVCODEC_BUFFER_FLAGS_NONE;
        } else {
            s.a_enc_starve++;
        }
    }
    OH_AudioEncoder_PushInputData(codec, index, attr);
}

void OnAudioNewOutput(OH_AVCodec *codec, uint32_t index, OH_AVMemory *mem,
                      OH_AVCodecBufferAttr *attr, void *user) {
    (void)user;
    CameraSender &s = g_sender;
    if (attr && attr->size > 0 && s.running.load() && s.audio_live) {
        uint8_t *addr = OH_AVMemory_GetAddr(mem);
        if (addr) {
            // One-shot format probe: ADTS starts 0xFF 0xFx; raw AAC does not.
            if (s.a_enc_out_cnt.fetch_add(1) == 0) {
                uint32_t head = 0;
                for (int i = 0; i < 4 && i < attr->size; i++) head = head << 8 | addr[i];
                CSLOGI("first audio AU: head=0x%{public}08x size=%{public}d flags=0x%{public}x (FFFx=ADTS)", head,
                       attr->size, attr->flags);
            }
            OutItem item;
            item.payload.assign(addr + attr->offset, addr + attr->offset + attr->size);
            item.pts = attr->pts;
            item.flags = kRctmFlagAudio;
            if (attr->flags & AVCODEC_BUFFER_FLAGS_CODEC_DATA) {
                item.flags |= kRctmFlagConfig;
                std::lock_guard<std::mutex> lk(s.amutex);
                if (s.audio_config.empty()) s.audio_config = item.payload;
            }
            s.enqueue(std::move(item));
        }
    }
    OH_AudioEncoder_FreeOutputData(codec, index);
}

} // namespace

// Bring up the mic side AFTER the video pipeline is streaming; a failure
// here must NOT kill the video feed — audio is opportunistic.
void StartAudio(CameraSender &s) {
    s.audio_live = false;
    OH_AVCodec *enc = OH_AudioEncoder_CreateByMime(OH_AVCODEC_MIMETYPE_AUDIO_AAC);
    if (!enc) {
        CSLOGW("no AAC encoder — feed stays video-only");
        return;
    }
    OH_AVFormat *fmt = OH_AVFormat_Create();
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_AUD_SAMPLE_RATE, audio::kRate);
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_AUD_CHANNEL_COUNT, audio::kChannels);
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, SAMPLE_S16LE);
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_BITRATE, audio::kBitrateBps);
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_MAX_BITRATE, audio::kBitrateBps);
    if (OH_AudioEncoder_SetCallback(enc, OH_AVCodecAsyncCallback{
            .onError = OnAudioEncError,
            .onStreamChanged = OnAudioEncStreamChanged,
            .onNeedInputData = OnAudioNeedInput,
            .onNeedOutputData = OnAudioNewOutput,
                                             },
                                    &s) != AV_ERR_OK ||
        OH_AudioEncoder_Configure(enc, fmt) != AV_ERR_OK) {
        OH_AVFormat_Destroy(fmt);
        OH_AudioEncoder_Destroy(enc);
        CSLOGW("audio encoder configure failed — video-only");
        return;
    }
    OH_AVFormat_Destroy(fmt);
    if (OH_AudioEncoder_Prepare(enc) != AV_ERR_OK || OH_AudioEncoder_Start(enc) != AV_ERR_OK) {
        OH_AudioEncoder_Destroy(enc);
        CSLOGW("audio encoder start failed — video-only");
        return;
    }
    s.aenc = enc;

    OH_AudioStreamBuilder *builder = nullptr;
    if (OH_AudioStreamBuilder_Create(&builder, AUDIOSTREAM_TYPE_CAPTURER) != AUDIOSTREAM_SUCCESS || !builder) {
        OH_AudioEncoder_Stop(enc);
        OH_AudioEncoder_Destroy(enc);
        s.aenc = nullptr;
        CSLOGW("audio builder create failed — video-only");
        return;
    }
    OH_AudioStreamBuilder_SetSamplingRate(builder, audio::kRate);
    OH_AudioStreamBuilder_SetChannelCount(builder, audio::kChannels);
    OH_AudioStreamBuilder_SetSampleFormat(builder, AUDIOSTREAM_SAMPLE_S16LE);
    OH_AudioStreamBuilder_SetEncodingType(builder, AUDIOSTREAM_ENCODING_TYPE_RAW);
    OH_AudioStreamBuilder_SetCapturerInfo(builder, AUDIOSTREAM_SOURCE_TYPE_MIC);
    OH_AudioStreamBuilder_SetCapturerReadDataCallback(builder, OnAudioCaptured, nullptr);
    OH_AudioCapturer *cap = nullptr;
    OH_AudioStream_Result rc = OH_AudioStreamBuilder_GenerateCapturer(builder, &cap);
    OH_AudioStreamBuilder_Destroy(builder);
    if (rc != AUDIOSTREAM_SUCCESS || !cap) {
        OH_AudioEncoder_Stop(enc);
        OH_AudioEncoder_Destroy(enc);
        s.aenc = nullptr;
        CSLOGW("GenerateCapturer failed (%{public}d) — video-only", (int)rc);
        return;
    }
    if (OH_AudioCapturer_Start(cap) != AUDIOSTREAM_SUCCESS) {
        OH_AudioCapturer_Release(cap);
        OH_AudioEncoder_Stop(enc);
        OH_AudioEncoder_Destroy(enc);
        s.aenc = nullptr;
        CSLOGW("capturer start failed (MIC permission?) — video-only");
        return;
    }
    s.capturer = cap;
    {
        std::lock_guard<std::mutex> lk(s.amutex);
        s.apcm.clear();
        s.aslicer.buf.clear();
    }
    s.audio_live = true;

    // Raw AAC (unlike Annex-B H.264) carries NO in-band config: the peer's
    // decoder cannot start without the AudioSpecificConfig. The OHOS encoder
    // does not reliably emit a separate CODEC_DATA buffer, so export the CSD
    // here and push it as a config frame BEFORE any audio AU — otherwise the
    // receiver's decoder sits starved and produces nothing (the -91 dB silence
    // we saw on 10-05: the aac track in the file was the tablet's own desktop
    // audio, not this feed).
    OH_AVFormat *od = OH_AudioEncoder_GetOutputDescription(enc);
    if (od) {
        uint8_t *caddr = nullptr;
        size_t csize = 0;
        if (OH_AVFormat_GetBuffer(od, OH_MD_KEY_CODEC_CONFIG, &caddr, &csize) && caddr && csize > 0) {
            OutItem ci;
            ci.payload.assign(caddr, caddr + csize);
            ci.pts = 0;
            ci.flags = kRctmFlagAudio | kRctmFlagConfig;
            {
                std::lock_guard<std::mutex> lk(s.amutex);
                if (s.audio_config.empty()) s.audio_config = ci.payload;
            }
            s.enqueue(std::move(ci));
            CSLOGI("audio CSD exported: %{public}zu bytes", csize);
        } else {
            // Normal on this device: the encoder emits ADTS-framed AUs, which
            // are self-describing — no out-of-band CSD exists or is needed.
            CSLOGI("no separate audio CSD (ADTS stream is self-configuring)");
        }
    }
    CSLOGI("mic audio live: AAC %{public}d bps %{public}d Hz stereo", audio::kBitrateBps, audio::kRate);
}

void StopAudio(CameraSender &s) {
    // Wake parked input callbacks BEFORE touching the codec — encoder Stop
    // would otherwise block on a waiter that can no longer receive data.
    // Flip audio_live under amutex so the predicate check and the notify
    // can never race (missed wakeup = deadlock against OH_AudioEncoder_Stop).
    {
        std::lock_guard<std::mutex> lk(s.amutex);
        s.audio_live = false;
    }
    s.apcm_cond.notify_all();
    if (s.capturer) {
        OH_AudioCapturer_Stop(s.capturer);
        OH_AudioCapturer_Release(s.capturer);
        s.capturer = nullptr;
    }
    if (s.aenc) {
        OH_AudioEncoder_Stop(s.aenc);
        OH_AudioEncoder_Destroy(s.aenc);
        s.aenc = nullptr;
    }
    std::lock_guard<std::mutex> lk(s.amutex);
    s.apcm.clear();
    s.aslicer.buf.clear();
    s.audio_config.clear();
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

void CameraSender::shutdownSocket() {
    connected = false;
    if (sock_fd >= 0) {
        ::shutdown(sock_fd, SHUT_RDWR);
        ::close(sock_fd);
        sock_fd = -1;
    }
}

void CameraSender::stop() {
    running = false;
    qcond.notify_all();
    StopAudio(*this);

    // Camera teardown first so the encoder surface stops receiving frames.
    if (vout) {
        OH_VideoOutput_Stop(vout);
        OH_VideoOutput_UnregisterCallback(vout, &g_vout_cbs);
        OH_VideoOutput_Release(vout);
        vout = nullptr;
    }
    if (session) {
        OH_CaptureSession_Stop(session);
        OH_CaptureSession_UnregisterCallback(session, &g_session_cbs);
        OH_CaptureSession_Release(session);
        session = nullptr;
    }
    if (input) {
        OH_CameraInput_UnregisterCallback(input, &g_input_cbs);
        OH_CameraInput_Close(input);
        OH_CameraInput_Release(input);
        input = nullptr;
    }
    if (manager) {
        OH_Camera_DeleteCameraManager(manager);
        manager = nullptr;
    }

    if (encoder) {
        OH_VideoEncoder_Stop(encoder);
        OH_VideoEncoder_Destroy(encoder);
        encoder = nullptr;
    }
    if (window) {
        OH_NativeWindow_DestroyNativeWindow(window);
        window = nullptr;
    }

    shutdownSocket();

    if (thread_started) {
        pthread_join(send_thread, nullptr);
        thread_started = false;
    }
    {
        std::lock_guard<std::mutex> lk(qmutex);
        queue.clear();
    }
}

// ---------------------------------------------------------------------------
// Encoder output callback -> queue (never touches the socket)
// ---------------------------------------------------------------------------

void OnEncoderError(OH_AVCodec *codec, int32_t error_code, void *user_data) {
    (void)codec;
    (void)user_data;
    CSLOGE("encoder error %{public}d", error_code);
    g_sender.failed = true;
    g_sender.running = false;
    g_sender.qcond.notify_all();
}

void OnEncoderStreamChanged(OH_AVCodec *codec, OH_AVFormat *format, void *user_data) {
    (void)codec;
    (void)format;
    (void)user_data;
    // Surface-mode geometry is fixed at Configure; informational only.
}

void OnEncoderNewOutput(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *user_data) {
    (void)user_data;
    if (buffer == nullptr) {
        OH_VideoEncoder_FreeOutputBuffer(codec, index);
        return;
    }

    OH_AVCodecBufferAttr attr{};
    if (OH_AVBuffer_GetBufferAttr(buffer, &attr) == AV_ERR_OK && attr.size > 0 && g_sender.running) {
        uint8_t *addr = OH_AVBuffer_GetAddr(buffer);
        if (addr != nullptr) {
            OutItem item;
            item.payload.assign(addr + attr.offset, addr + attr.offset + attr.size);
            item.pts = attr.pts;
            uint32_t flags = 0;
            if (attr.flags & AVCODEC_BUFFER_FLAGS_CODEC_DATA) flags |= kRctmFlagConfig;
            if (attr.flags & AVCODEC_BUFFER_FLAGS_SYNC_FRAME) flags |= kRctmFlagKey;
            item.flags = flags;
            g_sender.enqueue(std::move(item));
        }
    }
    OH_VideoEncoder_FreeOutputBuffer(codec, index);
}

// ---------------------------------------------------------------------------
// Socket writer thread: connect (retrying with backoff once the feed has
// lived once), then drain the queue as RCTM frames. A mid-feed drop clears
// the stale backlog, re-sends the cached config AU and waits for the next
// 1 s-GOP keyframe — the producer-side decoder rejoins without a restart.
// ---------------------------------------------------------------------------

namespace {

bool InterruptibleSleep(CameraSender &s, uint64_t ms) {
    // wait_for(lock, dur, pred) returns the PREDICATE value, not "timed out":
    // pred == !running. Return true when the sender is still running (i.e.
    // the sleep completed naturally or was never interrupted by stop()).
    std::unique_lock<std::mutex> lk(s.qmutex);
    return !s.qcond.wait_for(lk, std::chrono::milliseconds(ms), [&] { return !s.running.load(); });
}

bool OpenProducer(CameraSender &s) {
    int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        CSLOGE("socket() failed: %{public}s", strerror(errno));
        return false;
    }
    int one = 1;
    ::setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(s.port);
    if (inet_pton(AF_INET, s.host.c_str(), &addr.sin_addr) != 1) {
        CSLOGE("bad host %{public}s", s.host.c_str());
        ::close(fd);
        return false;
    }
    // Non-blocking connect + poll, so a dead-but-not-refused peer (screen-off
    // tablet) fails in ~3 s instead of hanging on the 75 s SYN retry.
    ::fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    if (::connect(fd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) < 0) {
        if (errno != EINPROGRESS) {
            CSLOGE("connect to %{public}s:%{public}u failed: %{public}s", s.host.c_str(), (unsigned)s.port,
                   strerror(errno));
            ::close(fd);
            return false;
        }
        pollfd pfd{fd, POLLOUT, 0};
        int pr = ::poll(&pfd, 1, 3000);
        int soerr = 0;
        socklen_t sl = sizeof(soerr);
        if (pr != 1 || ::getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &sl) != 0 || soerr != 0) {
            CSLOGE("connect timeout/refused %{public}s:%{public}u (%{public}s)", s.host.c_str(), (unsigned)s.port,
                   soerr ? strerror(soerr) : "timeout");
            ::close(fd);
            return false;
        }
    }
    ::fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) & ~O_NONBLOCK);
    s.sock_fd = fd;
    return true;
}

} // namespace

void *SendThread(void *arg) {
    (void)arg;
    CameraSender &s = g_sender;

    auto sendall = [&](const uint8_t *p, size_t n) {
        int fd = s.sock_fd;
        while (n > 0) {
            ssize_t w = ::send(fd, p, n, MSG_NOSIGNAL);
            if (w <= 0) {
                if (w < 0 && errno == EINTR) continue;
                return false;
            }
            p += w;
            n -= (size_t)w;
        }
        return true;
    };

    auto send_frame = [&](OutItem &item) {
        uint8_t hdr[20];
        auto put32 = [&](int off, uint32_t v) {
            hdr[off] = (uint8_t)(v >> 24);
            hdr[off + 1] = (uint8_t)(v >> 16);
            hdr[off + 2] = (uint8_t)(v >> 8);
            hdr[off + 3] = (uint8_t)v;
        };
        put32(0, kRctmMagic);
        put32(4, item.flags);
        int64_t pts = item.pts;
        for (int i = 0; i < 8; i++) hdr[8 + i] = (uint8_t)(((uint64_t)pts >> (56 - 8 * i)) & 0xFF);
        put32(16, (uint32_t)item.payload.size());
        return sendall(hdr, sizeof(hdr)) && sendall(item.payload.data(), item.payload.size());
    };

    uint64_t backoff_ms = 1000;
    while (s.running.load()) {
        s.connected = false;
        if (!OpenProducer(s)) {
            if (!s.ever_connected.load()) {
                // First-ever connect failed: surface to the caller (the UI
                // wants an immediate "check IP/port" error, not a silent
                // retry loop).
                s.failed = true;
                s.running = false;
                break;
            }
            s.reconnecting = true;
            s.retry_count++;
            CSLOGW("reconnect attempt %{public}d in %{public}" PRIu64 " ms", s.retry_count.load(), backoff_ms);
            if (!InterruptibleSleep(s, backoff_ms)) break;
            backoff_ms = backoff_ms < 30000 ? backoff_ms * 2 : 30000;
            continue;
        }
        s.connected = true;
        s.reconnecting = false;
        if (!s.ever_connected.load()) {
            s.ever_connected = true;
            CSLOGI("connected to producer %{public}s:%{public}u", s.host.c_str(), (unsigned)s.port);
        } else {
            // Join a live encoder stream: drop stale backlog, prime the new
            // peer with the cached config AU; the 1 s GOP guarantees a fresh
            // keyframe shortly.
            std::vector<uint8_t> cfg;
            {
                std::lock_guard<std::mutex> lk(s.qmutex);
                s.dropped += s.queue.size();
                s.queue.clear();
                cfg = s.config_au;
            }
            if (!cfg.empty()) {
                OutItem ci;
                ci.payload = std::move(cfg);
                ci.pts = 0;
                ci.flags = kRctmFlagConfig;
                if (!send_frame(ci)) {
                    continue; // will loop back into reconnect
                }
            }
            // Re-prime the peer's audio decoder too (cached AAC CSD).
            std::vector<uint8_t> acfg;
            {
                std::lock_guard<std::mutex> lk(s.amutex);
                acfg = s.audio_config;
            }
            if (!acfg.empty()) {
                OutItem ai;
                ai.payload = std::move(acfg);
                ai.pts = 0;
                ai.flags = kRctmFlagAudio | kRctmFlagConfig;
                if (!send_frame(ai)) {
                    continue;
                }
            }
            CSLOGI("reconnected to producer (retry=%{public}d, dropped stale=%" PRIu64 ")", s.retry_count.load(),
                   s.dropped.load());
            s.retry_count = 0;
        }
        backoff_ms = 1000;

        while (s.running.load()) {
            OutItem item;
            {
                std::unique_lock<std::mutex> lk(s.qmutex);
                s.qcond.wait(lk, [&] { return !s.queue.empty() || !s.running.load(); });
                if (!s.running.load()) break;
                if (s.queue.empty()) continue;
                item = std::move(s.queue.front());
                s.queue.pop_front();
            }
            if (!send_frame(item)) {
                CSLOGW("peer closed / send error: %{public}s", strerror(errno));
                s.shutdownSocket();
                if (s.running.load()) {
                    s.reconnecting = true; // camera+encoder keep running
                    s.retry_count++;
                    if (!InterruptibleSleep(s, backoff_ms)) break;
                    backoff_ms = backoff_ms < 30000 ? backoff_ms * 2 : 30000;
                }
                break; // inner loop -> outer reconnect
            }
        }
        if (!s.running.load()) break;
    }

    s.shutdownSocket();
    CSLOGI("send thread exit (running=%{public}d failed=%{public}d)", (int)s.running.load(), (int)s.failed.load());
    return nullptr;
}

// ---------------------------------------------------------------------------
// Pipeline bring-up
// ---------------------------------------------------------------------------

bool FindBackCamera(Camera_Manager *mgr, Camera_Device *out, char *id_buf, size_t id_buf_size) {
    Camera_Device *cameras = nullptr;
    uint32_t n = 0;
    if (OH_CameraManager_GetSupportedCameras(mgr, &cameras, &n) != CAMERA_OK || n == 0) return false;
    const Camera_Device *chosen = nullptr;
    for (uint32_t i = 0; i < n; i++) {
        if (cameras[i].cameraPosition == CAMERA_POSITION_BACK) {
            chosen = &cameras[i];
            break;
        }
    }
    if (!chosen) chosen = &cameras[0];
    /* Deep-copy the id: DeleteSupportedCameras frees the strings the list
     * entries point into, and CreateCameraInput dereferences cameraId on
     * the copy — a shallow struct copy here is a dangling pointer
     * (camera-capture.c keeps an id_buf for the same reason; 10-04 device
     * repro: GetOutputCapability failed right after the list was freed). */
    snprintf(id_buf, id_buf_size, "%s", chosen->cameraId ? chosen->cameraId : "");
    out->cameraId = id_buf;
    out->cameraPosition = chosen->cameraPosition;
    out->cameraType = chosen->cameraType;
    out->connectionType = chosen->connectionType;
    OH_CameraManager_DeleteSupportedCameras(mgr, cameras, n);
    return true;
}

// Configure the encoder on a surface input; the camera then renders straight
// into it. Mirrors plugins/harmony-vcodec surface-mode wiring.
bool StartEncoder(CameraSender &s) {
    s.encoder = OH_VideoEncoder_CreateByMime(OH_AVCODEC_MIMETYPE_VIDEO_AVC);
    if (!s.encoder) {
        CSLOGE("no H.264 hardware encoder");
        return false;
    }

    OH_AVCodecCallback cbs{};
    cbs.onError = OnEncoderError;
    cbs.onStreamChanged = OnEncoderStreamChanged;
    cbs.onNeedInputBuffer = nullptr; // surface mode: no CPU input
    cbs.onNewOutputBuffer = OnEncoderNewOutput;
    if (OH_VideoEncoder_RegisterCallback(s.encoder, cbs, &s) != AV_ERR_OK) {
        CSLOGE("RegisterCallback failed");
        return false;
    }

    OH_AVFormat *fmt = OH_AVFormat_Create();
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_WIDTH, (int32_t)s.width);
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_HEIGHT, (int32_t)s.height);
    OH_AVFormat_SetDoubleValue(fmt, OH_MD_KEY_FRAME_RATE, (double)s.fps);
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_BITRATE, s.bitrate_kbps * 1000);
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_VIDEO_ENCODE_BITRATE_MODE, BITRATE_MODE_CBR);
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_I_FRAME_INTERVAL, 1000); // 1 s GOP: peers join mid-stream
    OH_AVErrCode cret = OH_VideoEncoder_Configure(s.encoder, fmt);
    OH_AVFormat_Destroy(fmt);
    if (cret != AV_ERR_OK) {
        CSLOGE("encoder Configure failed %{public}d", (int)cret);
        return false;
    }

    if (OH_VideoEncoder_Prepare(s.encoder) != AV_ERR_OK) {
        CSLOGE("Prepare failed");
        return false;
    }
    if (OH_VideoEncoder_GetSurface(s.encoder, &s.window) != AV_ERR_OK || !s.window) {
        CSLOGE("GetSurface failed");
        return false;
    }
    OH_NativeWindow_NativeWindowHandleOpt(s.window, SET_BUFFER_GEOMETRY, (int32_t)s.width, (int32_t)s.height);
    if (OH_VideoEncoder_Start(s.encoder) != AV_ERR_OK) {
        CSLOGE("encoder Start failed");
        return false;
    }
    return true;
}

std::string WindowSurfaceId(OHNativeWindow *w) {
    uint64_t id = 0;
    if (OH_NativeWindow_GetSurfaceId(w, &id) != 0) return {};
    char buf[24];
    snprintf(buf, sizeof(buf), "%" PRIu64, id);
    return buf;
}

bool StartCamera(CameraSender &s) {
    if (OH_Camera_GetCameraManager(&s.manager) != CAMERA_OK || !s.manager) {
        CSLOGE("GetCameraManager failed");
        return false;
    }

    Camera_Device dev{};
    memset(s.device_id_buf, 0, sizeof(s.device_id_buf));
    if (!FindBackCamera(s.manager, &dev, s.device_id_buf, sizeof(s.device_id_buf))) {
        CSLOGE("no camera device");
        return false;
    }

    Camera_OutputCapability *cap = nullptr;
    if (OH_CameraManager_GetSupportedCameraOutputCapability(s.manager, &dev, &cap) != CAMERA_OK || !cap) {
        CSLOGE("GetOutputCapability failed");
        return false;
    }
    // Prefer 720p, else the first usable profile. The struct is copied by
    // value before the capability array is freed (same discipline as
    // camera-capture.c).
    const Camera_VideoProfile *chosen = nullptr;
    for (uint32_t i = 0; i < cap->videoProfilesSize && !chosen; i++) {
        const Camera_VideoProfile *p = cap->videoProfiles[i];
        if (p && p->size.width == 1280 && p->size.height == 720) chosen = p;
    }
    if (!chosen) {
        for (uint32_t i = 0; i < cap->videoProfilesSize; i++) {
            if (cap->videoProfiles[i]) {
                chosen = cap->videoProfiles[i];
                break;
            }
        }
    }
    if (!chosen) {
        OH_CameraManager_DeleteSupportedCameraOutputCapability(s.manager, cap);
        CSLOGE("no video profile");
        return false;
    }
    s.profile = *chosen;
    s.width = chosen->size.width;
    s.height = chosen->size.height;
    OH_CameraManager_DeleteSupportedCameraOutputCapability(s.manager, cap);

    if (!StartEncoder(s)) return false;
    std::string surface_id = WindowSurfaceId(s.window);
    if (surface_id.empty()) {
        CSLOGE("no surface id from encoder window");
        return false;
    }

    if (OH_CameraManager_CreateCameraInput(s.manager, &dev, &s.input) != CAMERA_OK || !s.input) {
        CSLOGE("CreateCameraInput failed");
        return false;
    }
    OH_CameraInput_RegisterCallback(s.input, &g_input_cbs);
    if (OH_CameraInput_Open(s.input) != CAMERA_OK) {
        CSLOGE("CameraInput_Open failed (CAMERA permission?)");
        return false;
    }

    if (OH_CameraManager_CreateVideoOutput(s.manager, &s.profile, surface_id.c_str(), &s.vout) != CAMERA_OK || !s.vout) {
        CSLOGE("CreateVideoOutput failed");
        return false;
    }
    OH_VideoOutput_RegisterCallback(s.vout, &g_vout_cbs);

    if (OH_CameraManager_CreateCaptureSession(s.manager, &s.session) != CAMERA_OK || !s.session) {
        CSLOGE("CreateCaptureSession failed");
        return false;
    }
    OH_CaptureSession_SetSessionMode(s.session, NORMAL_VIDEO);
    OH_CaptureSession_RegisterCallback(s.session, &g_session_cbs);
    if (OH_CaptureSession_BeginConfig(s.session) != CAMERA_OK) {
        CSLOGE("BeginConfig failed");
        return false;
    }
    OH_CaptureSession_AddInput(s.session, s.input);
    OH_CaptureSession_AddVideoOutput(s.session, s.vout);
    if (OH_CaptureSession_CommitConfig(s.session) != CAMERA_OK) {
        CSLOGE("CommitConfig failed");
        return false;
    }

    int32_t fps = s.fps;
    if (s.profile.range.min > 0 && fps < (int32_t)s.profile.range.min) fps = (int32_t)s.profile.range.min;
    if (s.profile.range.max > 0 && fps > (int32_t)s.profile.range.max) fps = (int32_t)s.profile.range.max;
    OH_VideoOutput_SetFrameRate(s.vout, fps, fps);

    if (OH_VideoOutput_Start(s.vout) != CAMERA_OK) {
        CSLOGE("VideoOutput_Start failed");
        return false;
    }
    if (OH_CaptureSession_Start(s.session) != CAMERA_OK) {
        CSLOGE("CaptureSession_Start failed");
        return false;
    }

    CSLOGI("wireless camera streaming %{public}ux%{public}u @%{public}d to %{public}s:%{public}u", (unsigned)s.width,
           (unsigned)s.height, (int)fps, s.host.c_str(), (unsigned)s.port);
    return true;
}

std::string ArgString(napi_env env, napi_value v) {
    size_t len = 0;
    napi_get_value_string_utf8(env, v, nullptr, 0, &len);
    std::string s(len, '\0');
    napi_get_value_string_utf8(env, v, s.data(), len + 1, &len);
    return s;
}

} // namespace

napi_value NativeStartCameraSender(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 2) return ThrowError(env, "startCameraSender(host, port[, bitrateKbps])");
    if (g_sender.running.load()) {
        napi_value jbool;
        napi_get_boolean(env, true, &jbool);
        return jbool;
    }

    g_sender.host = ArgString(env, args[0]);
    int32_t port = 0;
    napi_get_value_int32(env, args[1], &port);
    if (port <= 0 || port >= 65536) return ThrowError(env, "invalid port");
    g_sender.port = (uint16_t)port;
    if (argc >= 3) {
        int32_t br = 0;
        napi_get_value_int32(env, args[2], &br);
        if (br > 0) g_sender.bitrate_kbps = br;
    }
    g_sender.fps = 30;
    g_sender.failed = false;
    g_sender.connected = false;
    g_sender.running = true;

    // Writer thread first: it connects and waits for encoder output.
    if (pthread_create(&g_sender.send_thread, nullptr, SendThread, nullptr) != 0) {
        g_sender.running = false;
        return ThrowError(env, "pthread_create failed");
    }
    g_sender.thread_started = true;

    // Give the connect a bounded moment (OpenProducer itself caps at ~3 s
    // via non-blocking connect + poll): if it already failed (bad host /
    // producer down), tear down synchronously and report to the UI.
    for (int i = 0; i < 70 && !g_sender.connected.load() && !g_sender.failed.load(); i++) {
        struct timespec ts{0, 50 * 1000 * 1000}; // 50 ms
        nanosleep(&ts, nullptr);
    }
    if (g_sender.failed.load() || !g_sender.connected.load()) {
        g_sender.stop();
        return ThrowError(env, "connect to producer failed (check IP/port; add a 无线机位 source on it first)");
    }

    if (!StartCamera(g_sender)) {
        g_sender.stop();
        return ThrowError(env, "camera/encoder pipeline start failed");
    }

    // Mic audio is opportunistic: failure here keeps the video-only feed
    // alive (the producer side simply never sees AUDIO-flagged frames).
    StartAudio(g_sender);

    napi_value jbool;
    napi_get_boolean(env, true, &jbool);
    return jbool;
}

napi_value NativeStopCameraSender(napi_env env, napi_callback_info info) {
    (void)info;
    g_sender.stop();
    napi_value jbool;
    napi_get_boolean(env, true, &jbool);
    return jbool;
}

napi_value NativeCameraSenderStatus(napi_env env, napi_callback_info info) {
    (void)info;
    napi_value obj;
    napi_create_object(env, &obj);
    napi_value running, connected, failed, host, reconnecting, retry;
    napi_create_int64(env, g_sender.running.load() ? 1 : 0, &running);
    napi_create_int64(env, g_sender.connected.load() ? 1 : 0, &connected);
    napi_create_int64(env, g_sender.failed.load() ? 1 : 0, &failed);
    napi_create_int64(env, g_sender.reconnecting.load() ? 1 : 0, &reconnecting);
    napi_create_int64(env, g_sender.retry_count.load(), &retry);
    napi_create_string_utf8(env, g_sender.host.c_str(), NAPI_AUTO_LENGTH, &host);
    napi_set_named_property(env, obj, "running", running);
    napi_set_named_property(env, obj, "connected", connected);
    napi_set_named_property(env, obj, "failed", failed);
    napi_set_named_property(env, obj, "reconnecting", reconnecting);
    napi_set_named_property(env, obj, "retry", retry);
    napi_set_named_property(env, obj, "host", host);
    return obj;
}

} // namespace obs_bridge
