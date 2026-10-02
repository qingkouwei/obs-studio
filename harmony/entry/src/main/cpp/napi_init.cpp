// ---------------------------------------------------------------------------
// napi_init.cpp — module registration for libobs_bridge.so.
//
// Two things happen in Init():
//   1. If the module was loaded through an XComponent's `libraryname`
//      (PreviewCanvas.ets does exactly that), the ArkUI runtime injects the
//      OH_NativeXComponent object into `exports` under
//      OH_NATIVE_XCOMPONENT_OBJ. We unwrap it and register the surface
//      lifecycle callbacks so the NativeWindow lands in the xcomp registry.
//   2. The full NAPI surface declared in types/libobs_bridge/index.d.ts is
//      attached to `exports`.
// ---------------------------------------------------------------------------

#include <cstdlib>

#include <ace/xcomponent/native_interface_xcomponent.h>
#include <hilog/log.h>
#include <node_api.h>

#include "obs_bridge.h"
#include "xcomponent_surface.h"

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0B50
#define LOG_TAG "obs_bridge"

using namespace obs_bridge;

namespace {

void MaybeRegisterXComponent(napi_env env, napi_value exports)
{
    napi_value xcomponentValue = nullptr;
    napi_status status =
        napi_get_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ, &xcomponentValue);
    if (status != napi_ok) {
        return; // loaded as a plain napi module (e.g. by the ets import)
    }
    napi_valuetype type = napi_undefined;
    napi_typeof(env, xcomponentValue, &type);
    if (type != napi_object) {
        return;
    }
    OH_NativeXComponent *component = nullptr;
    if (napi_unwrap(env, xcomponentValue, reinterpret_cast<void **>(&component)) == napi_ok &&
        component != nullptr) {
        xcomp::RegisterXComponent(component);
    }
}

napi_value Init(napi_env env, napi_value exports)
{
    MaybeRegisterXComponent(env, exports);

    napi_property_descriptor desc[] = {
        // Core lifecycle
        DECLARE_NAPI_FUNCTION("nativeInit", NativeInit),
        DECLARE_NAPI_FUNCTION("nativeShutdown", NativeShutdown),
        // Preview surface
        DECLARE_NAPI_FUNCTION("nativeAttachPreviewSurface", NativeAttachPreviewSurface),
        DECLARE_NAPI_FUNCTION("nativeDetachPreviewSurface", NativeDetachPreviewSurface),
        // Scenes / sources
        DECLARE_NAPI_FUNCTION("nativeGetScenes", NativeGetScenes),
        DECLARE_NAPI_FUNCTION("nativeCreateScene", NativeCreateScene),
        DECLARE_NAPI_FUNCTION("nativeRemoveScene", NativeRemoveScene),
        DECLARE_NAPI_FUNCTION("nativeGetSources", NativeGetSources),
        DECLARE_NAPI_FUNCTION("nativeAddSource", NativeAddSource),
        DECLARE_NAPI_FUNCTION("nativeRemoveSource", NativeRemoveSource),
        DECLARE_NAPI_FUNCTION("nativeSetSourceVisible", NativeSetSourceVisible),
        DECLARE_NAPI_FUNCTION("nativeSelectScene", NativeSelectScene),
        // Video settings
        DECLARE_NAPI_FUNCTION("nativeGetVideoInfo", NativeGetVideoInfo),
        DECLARE_NAPI_FUNCTION("nativeResetVideo", NativeResetVideo),
        // Filters
        DECLARE_NAPI_FUNCTION("nativeGetFilterTypes", NativeGetFilterTypes),
        DECLARE_NAPI_FUNCTION("nativeGetFilters", NativeGetFilters),
        DECLARE_NAPI_FUNCTION("nativeAddFilter", NativeAddFilter),
        DECLARE_NAPI_FUNCTION("nativeRemoveFilter", NativeRemoveFilter),
        DECLARE_NAPI_FUNCTION("nativeSetFilterEnabled", NativeSetFilterEnabled),
        // Audio
        DECLARE_NAPI_FUNCTION("nativeGetAudioTracks", NativeGetAudioTracks),
        DECLARE_NAPI_FUNCTION("nativeSetMute", NativeSetMute),
        DECLARE_NAPI_FUNCTION("nativeSetVolume", NativeSetVolume),
        DECLARE_NAPI_FUNCTION("nativeGetOutputLevels", NativeGetOutputLevels),
        DECLARE_NAPI_FUNCTION("nativeCanCaptureSystemAudio", NativeCanCaptureSystemAudio),
        // Outputs / stats
        DECLARE_NAPI_FUNCTION("nativeStartStreaming", NativeStartStreaming),
        DECLARE_NAPI_FUNCTION("nativeStopStreaming", NativeStopStreaming),
        DECLARE_NAPI_FUNCTION("nativeStartRecording", NativeStartRecording),
        DECLARE_NAPI_FUNCTION("nativeStopRecording", NativeStopRecording),
        DECLARE_NAPI_FUNCTION("nativeGetStats", NativeGetStats),
        DECLARE_NAPI_FUNCTION("nativeSetStatsCallback", NativeSetStatsCallback),
    };

    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    OH_LOG_INFO(LOG_APP, "libobs_bridge napi module initialized");
    return exports;
}

} // namespace

static napi_module g_obsBridgeModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    // Must match the ArkTS import specifier 'libobs_bridge.so' and the
    // XComponent `libraryname: "obs_bridge"` in PreviewCanvas.ets.
    .nm_modname = "obs_bridge",
    .nm_priv = nullptr,
    .reserved = {nullptr},
};

extern "C" __attribute__((constructor)) void RegisterObsBridgeModule(void)
{
    napi_module_register(&g_obsBridgeModule);
}
