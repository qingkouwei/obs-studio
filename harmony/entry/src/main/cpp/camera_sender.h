#pragma once

// ---------------------------------------------------------------------------
// camera_sender.h — the phone-role wireless-camera relay (W3-C1 sender side).
// Pure NAPI entry points registered in napi_init.cpp; the implementation is
// independent of libobs so the phone can run it without the OBS core.
// ---------------------------------------------------------------------------

#include <node_api.h>

namespace obs_bridge {

/** startCameraSender(host: string, port: number, bitrateKbps?: number): boolean
 *  Throws when the producer is unreachable or the camera pipeline fails. */
napi_value NativeStartCameraSender(napi_env env, napi_callback_info info);

/** stopCameraSender(): boolean */
napi_value NativeStopCameraSender(napi_env env, napi_callback_info info);

/** cameraSenderStatus(): { running: number, connected: number, failed: number, host: string } */
napi_value NativeCameraSenderStatus(napi_env env, napi_callback_info info);

} // namespace obs_bridge
