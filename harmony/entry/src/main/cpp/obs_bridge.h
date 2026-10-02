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

// Scenes / sources --------------------------------------------------------------
napi_value NativeGetScenes(napi_env env, napi_callback_info info);
napi_value NativeCreateScene(napi_env env, napi_callback_info info);
napi_value NativeRemoveScene(napi_env env, napi_callback_info info);
napi_value NativeGetSources(napi_env env, napi_callback_info info);
napi_value NativeAddSource(napi_env env, napi_callback_info info);
napi_value NativeRemoveSource(napi_env env, napi_callback_info info);
napi_value NativeSetSourceVisible(napi_env env, napi_callback_info info);
napi_value NativeSelectScene(napi_env env, napi_callback_info info);
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

// Outputs ------------------------------------------------------------------------
napi_value NativeStartStreaming(napi_env env, napi_callback_info info);
napi_value NativeStopStreaming(napi_env env, napi_callback_info info);
napi_value NativeStartRecording(napi_env env, napi_callback_info info);
napi_value NativeStopRecording(napi_env env, napi_callback_info info);
napi_value NativeGetStats(napi_env env, napi_callback_info info);
napi_value NativeSetStatsCallback(napi_env env, napi_callback_info info);

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
