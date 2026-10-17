#pragma once

// ---------------------------------------------------------------------------
// obs_bridge.h — C++ side of the ArkTS <-> libobs NAPI bridge.
//
// Every function below is a napi callback with the standard
// (napi_env, napi_callback_info) signature and is registered on the module
// exports in napi_init.cpp. Implementations live in obs_bridge.cpp.
//
// Build modes (see CMakeLists.txt):
//   * HAVE_LIBOBS undefined — the bridge is a shell: libobs-dependent calls
//     throw a napi error ("libobs core not linked yet") and the ArkTS wrapper
//     degrades to a logged error instead of taking down the UI.
//   * HAVE_LIBOBS defined   — the genuine libobs API is called.
// ---------------------------------------------------------------------------

#include <node_api.h>

#define DECLARE_NAPI_FUNCTION(name, func)                                     \
    { (name), nullptr, (func), nullptr, nullptr, nullptr, napi_default, nullptr }

namespace obs_bridge {

// Core lifecycle --------------------------------------------------------------
napi_value NativeInit(napi_env env, napi_callback_info info);
napi_value NativeShutdown(napi_env env, napi_callback_info info);

// Preview surface (XComponent seam) -------------------------------------------
napi_value NativeAttachPreviewSurface(napi_env env, napi_callback_info info);
napi_value NativeDetachPreviewSurface(napi_env env, napi_callback_info info);
/* Studio mode: bind a scene to the private preview canvas, read which scene
 * is on it, and attach/detach the second (preview) display. */
napi_value NativeSetPreviewScene(napi_env env, napi_callback_info info);
napi_value NativeGetPreviewSceneId(napi_env env, napi_callback_info info);
napi_value NativeAttachStudioPreviewSurface(napi_env env, napi_callback_info info);
napi_value NativeDetachStudioPreviewSurface(napi_env env, napi_callback_info info);

// Scenes / sources --------------------------------------------------------------
napi_value NativeGetScenes(napi_env env, napi_callback_info info);
napi_value NativeCreateScene(napi_env env, napi_callback_info info);
napi_value NativeRemoveScene(napi_env env, napi_callback_info info);
napi_value NativeRenameScene(napi_env env, napi_callback_info info);
napi_value NativeGetSources(napi_env env, napi_callback_info info);
napi_value NativeAddSource(napi_env env, napi_callback_info info);
napi_value NativeRemoveSource(napi_env env, napi_callback_info info);
napi_value NativeSetSourceVisible(napi_env env, napi_callback_info info);
napi_value NativeGetSourceBounds(napi_env env, napi_callback_info info);
napi_value NativeSetSourcePosition(napi_env env, napi_callback_info info);
napi_value NativeSetSourceRect(napi_env env, napi_callback_info info);
napi_value NativeScaleSourceBy(napi_env env, napi_callback_info info);
napi_value NativeSetSourceTransform(napi_env env, napi_callback_info info);
napi_value NativeGetSourceTransform(napi_env env, napi_callback_info info);
napi_value NativeSetSourceBoundsFit(napi_env env, napi_callback_info info);
napi_value NativeSetSourceSize(napi_env env, napi_callback_info info);
napi_value NativeSetSourceLocked(napi_env env, napi_callback_info info);
napi_value NativeSetSourceOrder(napi_env env, napi_callback_info info);
napi_value NativeDuplicateSource(napi_env env, napi_callback_info info);
napi_value NativeRenameSource(napi_env env, napi_callback_info info);
napi_value NativeSelectScene(napi_env env, napi_callback_info info);
napi_value NativeGetTransitionTypes(napi_env env, napi_callback_info info);
napi_value NativeSetTransitionType(napi_env env, napi_callback_info info);
napi_value NativeGetVideoInfo(napi_env env, napi_callback_info info);
napi_value NativeResetVideo(napi_env env, napi_callback_info info);

// Filters ---------------------------------------------------------------------
napi_value NativeGetFilterTypes(napi_env env, napi_callback_info info);
napi_value NativeGetFilters(napi_env env, napi_callback_info info);
napi_value NativeAddFilter(napi_env env, napi_callback_info info);
napi_value NativeRemoveFilter(napi_env env, napi_callback_info info);
napi_value NativeSetFilterEnabled(napi_env env, napi_callback_info info);

// Audio -------------------------------------------------------------------------
napi_value NativeGetAudioTracks(napi_env env, napi_callback_info info);
napi_value NativeSetMute(napi_env env, napi_callback_info info);
napi_value NativeSetVolume(napi_env env, napi_callback_info info);
napi_value NativeGetOutputLevels(napi_env env, napi_callback_info info);
napi_value NativeCanCaptureSystemAudio(napi_env env, napi_callback_info info);
// Lazy desktop-loopback starter: NativeInit no longer requests playback
// capture (its privacy dialog re-appears on every cold start — session
// consent); the ArkTS side calls this when the user adds the desktop audio
// source. Idempotent.
napi_value NativeEnsureDesktopAudio(napi_env env, napi_callback_info info);

// Outputs ------------------------------------------------------------------------
napi_value NativeStartStreaming(napi_env env, napi_callback_info info);
napi_value NativeStopStreaming(napi_env env, napi_callback_info info);
napi_value NativeStartRecording(napi_env env, napi_callback_info info);
napi_value NativeStopRecording(napi_env env, napi_callback_info info);
napi_value NativeGetStats(napi_env env, napi_callback_info info);
napi_value NativeSetStatsCallback(napi_env env, napi_callback_info info);

/**
 * ArkWeb browser source (harmony-web) frame feed.
 * nativeWebSourceFeed(itemId, width, height, rgbaArrayBuffer, timestampNs) -> bool
 *
 * The harmony-web plugin registers a plain async-video source type; ArkWeb is
 * ArkTS-only, so pixels are pushed in from the ets side (WebFeed.ets runs an
 * off-screen Web component + componentSnapshot loop and hands RGBA buffers
 * here). Resolves itemId -> obs_source_t and calls obs_source_output_video(),
 * the same non-graphics-thread async path harmony-remotecam proved safe.
 * Returns false (never throws) when the item is gone or the buffer is short.
 */
napi_value NativeWebSourceFeed(napi_env env, napi_callback_info info);

/**
 * nativeGetSourceSettings(itemId) -> JSON string of the source's stored
 * settings ('' when the item is gone). Lets the ArkTS WebFeed registry
 * rebuild from libobs state after a scene reload instead of duplicating
 * url/viewport bookkeeping in the UI layer.
 */
napi_value NativeGetSourceSettings(napi_env env, napi_callback_info info);

/**
 * nativeSetSourceSettings(itemId, settingsJson) -> bool
 *
 * Merges a settings patch over the source's current settings (obs_data_apply
 * — keys absent from the patch keep their value) and pushes the result
 * through obs_source_update, so the plugin's update() owns any restart
 * decision. Write-back channel of the per-source settings sheets.
 */
napi_value NativeSetSourceSettings(napi_env env, napi_callback_info info);
napi_value NativeMediaControl(napi_env env, napi_callback_info info);
napi_value NativeGetMediaState(napi_env env, napi_callback_info info);
napi_value NativeMediaSeek(napi_env env, napi_callback_info info);
napi_value NativeGetSourceAudioProps(napi_env env, napi_callback_info info);
napi_value NativeSetSourceAudioProps(napi_env env, napi_callback_info info);
napi_value NativeGetPropertySchema(napi_env env, napi_callback_info info);
napi_value NativeSetFilterSettings(napi_env env, napi_callback_info info);

// Shared helpers (also used by napi_init.cpp) ---------------------------------------

/** Throws a JS Error with the given message and returns nullptr. */
napi_value ThrowError(napi_env env, const char *message);

/**
 * Throws the canonical "core not linked" error used by every entry point that
 * needs libobs when the bridge was built shell-only. Returns nullptr.
 */
napi_value ThrowCoreNotLinked(napi_env env);

/**
 * Full shutdown path shared by NativeShutdown and the ability teardown:
 * stops outputs, stops audio capture tracks, releases the preview surface
 * and calls obs_shutdown() when the core is linked. Safe to call twice.
 */
void ShutdownCore();

} // namespace obs_bridge
