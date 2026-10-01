#pragma once

// ---------------------------------------------------------------------------
// xcomponent_surface.h — the seam between ArkUI's XComponent(SURFACE) and the
// graphics backend.
//
// Flow:
//   1. The XComponent in PreviewCanvas.ets declares libraryname "obs_bridge",
//      so when the component is created the ArkUI runtime loads this napi
//      module and injects the OH_NativeXComponent object into the module
//      exports under OH_NATIVE_XCOMPONENT_OBJ. napi_init.cpp unwraps it and
//      calls RegisterXComponent(), which installs the surface lifecycle
//      callbacks (OnSurfaceCreated / OnSurfaceChanged / OnSurfaceDestroyed).
//   2. OnSurfaceCreated stores the NativeWindow* keyed by XComponent id.
//   3. ArkTS calls nativeAttachPreviewSurface(id). AttachPreview() then
//      either (HAVE_LIBOBS) hands the window to libobs's graphics subsystem
//      via obs_display_create() — this is where libobs's EGL surface gets
//      created on the ported OpenGL backend — or (shell-only mode) creates a
//      plain EGL window surface itself so the seam is exercised end-to-end
//      even before the core lands.
// ---------------------------------------------------------------------------

#include <cstdint>
#include <string>

#include <ace/xcomponent/native_interface_xcomponent.h>
#include <native_window/external_window.h>

namespace xcomp {

/**
 * Install the surface lifecycle callbacks for an XComponent instance and
 * record it in the registry. Called once per XComponent from module Init.
 */
void RegisterXComponent(OH_NativeXComponent *component);

/**
 * Mark the XComponent with the given id as the libobs preview/program canvas
 * and create the graphics surface on its NativeWindow. Returns false if the
 * id is unknown or the surface has not been created yet.
 */
bool AttachPreview(const std::string &xcomponentId);

/** Tear down the preview surface/EGL resources. Safe to call when detached. */
void DetachPreview();

/** True while a preview surface is attached and live. */
bool PreviewAttached();

/** Called from ShutdownCore(); detaches and forgets all registered surfaces. */
void ResetAll();

} // namespace xcomp
