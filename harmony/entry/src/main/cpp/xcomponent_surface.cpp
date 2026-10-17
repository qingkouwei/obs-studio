// ---------------------------------------------------------------------------
// xcomponent_surface.cpp — XComponent NativeWindow registry + graphics seam.
// See xcomponent_surface.h for the overall flow.
// ---------------------------------------------------------------------------

#include "xcomponent_surface.h"

#include <cstring>
#include <memory>
#include <mutex>
#include <vector>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <hilog/log.h>

#ifdef HAVE_LIBOBS
// Rename libobs's LOG_* enumerators around the includes: they collide with
// hilog's LogLevel enum in this TU (see the same guard in obs_bridge.cpp).
#define LOG_ERROR OBS_LOG_ERROR
#define LOG_WARNING OBS_LOG_WARNING
#define LOG_INFO OBS_LOG_INFO
#define LOG_DEBUG OBS_LOG_DEBUG
#include <graphics/graphics.h>
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

namespace xcomp {
namespace {

struct SurfaceRecord {
    OH_NativeXComponent *component = nullptr;
    std::string id;
    NativeWindow *window = nullptr;
    uint64_t width = 0;
    uint64_t height = 0;
    bool isPreview = false;
    /* Studio mode: this record is the SECOND display, rendering the private
     * preview canvas (studioCanvas, an obs_canvas_t*) instead of the main
     * canvas. Independent of the isPreview singleton above. */
    bool isStudio = false;
    void *studioCanvas = nullptr;

    // Shell-mode EGL seam (used when HAVE_LIBOBS is undefined). When the core
    // is linked, libobs's graphics subsystem owns the EGL surface instead and
    // these stay unused.
    EGLDisplay eglDisplay = EGL_NO_DISPLAY;
    EGLContext eglContext = EGL_NO_CONTEXT;
    EGLSurface eglSurface = EGL_NO_SURFACE;

#ifdef HAVE_LIBOBS
    // libobs display object bound to this surface; rendered by libobs's
    // graphics thread (obs_render_main_texture via the draw callback below).
    obs_display_t *obsDisplay = nullptr;
#endif
};

std::mutex g_mutex;
std::vector<std::unique_ptr<SurfaceRecord>> g_records;
SurfaceRecord *g_preview = nullptr;
/* Studio-mode second display (preview canvas). Records live in g_records
 * for the process lifetime, so the draw-callback param stays valid. */
SurfaceRecord *g_studio = nullptr;

SurfaceRecord *FindByComponentLocked(OH_NativeXComponent *component)
{
    for (auto &rec : g_records) {
        if (rec->component == component) {
            return rec.get();
        }
    }
    return nullptr;
}

void QuerySize(SurfaceRecord *rec)
{
    uint64_t w = 0;
    uint64_t h = 0;
    if (OH_NativeXComponent_GetXComponentSize(rec->component, rec->window, &w, &h) ==
        OH_NATIVEXCOMPONENT_RESULT_SUCCESS) {
        rec->width = w;
        rec->height = h;
    }
}

#ifdef HAVE_LIBOBS

void ObsDisplayDrawCallback(void *param, uint32_t cx, uint32_t cy)
{
    // Called by libobs on its graphics thread with the display's GL context
    // current; compositing the program/preview output is one call. In studio
    // mode the second display draws the private preview canvas instead of
    // the main (program) canvas — obs_render_canvas_texture() takes the same
    // "blit the mix's render texture" path for any canvas.
    //
    /* Aspect-fit + centre the canvas into the surface, mirroring the desktop
     * preview. render_display_begin left the projection at gs_ortho(0,cx,0,cy)
     * and obs_render_main_texture blits the render_texture at its NATIVE base
     * size anchored at (0,0) — so without this the canvas is drawn 1:1-px in
     * the top-left corner, and whenever surface px ≠ base px the picture
     * neither fills nor centres (user report 10-14: selection box far bigger
     * than the camera picture). gs_draw_sprite maps ortho-space [0,base] to
     * the viewport, so a scaled/translated ortho that sends [0,base] to the
     * centred letterbox rect [x0,x0+w0]×[y0,y0+h0] is all that's needed —
     * same top-left orientation as the default, just scaled. The ArkUI
     * overlay reproduces this exact transform so the selection box always
     * tracks the pixels. */
    struct obs_video_info ovi;
    if (obs_get_video_info(&ovi) && ovi.base_width > 0 && ovi.base_height > 0 && cx > 0 && cy > 0) {
        const float bw = (float)ovi.base_width;
        const float bh = (float)ovi.base_height;
        const float s = fminf((float)cx / bw, (float)cy / bh);
        const float w0 = bw * s;
        const float h0 = bh * s;
        const float x0 = ((float)cx - w0) * 0.5f;
        const float y0 = ((float)cy - h0) * 0.5f;
        const float inv = 1.0f / s;
        gs_ortho(-x0 * inv, ((float)cx - x0) * inv, -y0 * inv, ((float)cy - y0) * inv, -100.0f, 100.0f);
    }

    SurfaceRecord *rec = static_cast<SurfaceRecord *>(param);
    if (rec != nullptr && rec->isStudio && rec->studioCanvas != nullptr) {
        obs_render_canvas_texture(static_cast<obs_canvas_t *>(rec->studioCanvas));
    } else {
        obs_render_main_texture();
    }

    (void)cx;
    (void)cy;
}

bool CreateObsDisplay(SurfaceRecord *rec)
{
    struct gs_init_data initData = {};
    // Contract with the in-repo HarmonyOS libobs-opengl backend
    // (libobs-opengl/gl-harmony-egl.{c,h}): gs_window carries no OHOS-specific
    // member, so the ArkUI layer hands the XComponent's OHNativeWindow* over
    // via gs_init_data.window.display. gl_windowinfo_create() reads it back
    // with gs_window_native_window() and creates the EGL window surface on it.
    // (NativeWindow* and OHNativeWindow* are the same type — external_window.h
    // does `typedef struct NativeWindow OHNativeWindow`.) num_backbuffers=2
    // gives libobs a swapchain on the XComponent producer surface.
    initData.window.display = rec->window;
    initData.cx = static_cast<uint32_t>(rec->width);
    initData.cy = static_cast<uint32_t>(rec->height);
    initData.num_backbuffers = 2;
    initData.format = GS_BGRA;
    initData.zsformat = GS_ZS_NONE;
    rec->obsDisplay = obs_display_create(&initData, 0xFF202020);
    if (rec->obsDisplay == nullptr) {
        OH_LOG_ERROR(LOG_APP, "obs_display_create failed for XComponent %{public}s", rec->id.c_str());
        return false;
    }
    obs_display_add_draw_callback(rec->obsDisplay, ObsDisplayDrawCallback, rec);
    return true;
}

void DestroyObsDisplay(SurfaceRecord *rec)
{
    if (rec->obsDisplay != nullptr) {
        obs_display_remove_draw_callback(rec->obsDisplay, ObsDisplayDrawCallback, rec);
        obs_display_destroy(rec->obsDisplay);
        rec->obsDisplay = nullptr;
    }
}

#else // shell-only EGL seam --------------------------------------------------

bool CreateShellEglSurface(SurfaceRecord *rec)
{
    rec->eglDisplay = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (rec->eglDisplay == EGL_NO_DISPLAY) {
        OH_LOG_ERROR(LOG_APP, "eglGetDisplay failed");
        return false;
    }
    EGLint major = 0;
    EGLint minor = 0;
    if (eglInitialize(rec->eglDisplay, &major, &minor) != EGL_TRUE) {
        OH_LOG_ERROR(LOG_APP, "eglInitialize failed: 0x%{public}x", eglGetError());
        rec->eglDisplay = EGL_NO_DISPLAY;
        return false;
    }

    const EGLint configAttribs[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_NONE
    };
    EGLConfig config = nullptr;
    EGLint numConfigs = 0;
    if (eglChooseConfig(rec->eglDisplay, configAttribs, &config, 1, &numConfigs) != EGL_TRUE ||
        numConfigs == 0) {
        OH_LOG_ERROR(LOG_APP, "eglChooseConfig failed: 0x%{public}x", eglGetError());
        return false;
    }

    const EGLint contextAttribs[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    rec->eglContext = eglCreateContext(rec->eglDisplay, config, EGL_NO_CONTEXT, contextAttribs);
    if (rec->eglContext == EGL_NO_CONTEXT) {
        OH_LOG_ERROR(LOG_APP, "eglCreateContext failed: 0x%{public}x", eglGetError());
        return false;
    }

    // On HarmonyOS the NativeWindow* is passed straight to EGL as the native
    // window handle.
    rec->eglSurface = eglCreateWindowSurface(
        rec->eglDisplay, config, reinterpret_cast<EGLNativeWindowType>(rec->window), nullptr);
    if (rec->eglSurface == EGL_NO_SURFACE) {
        OH_LOG_ERROR(LOG_APP, "eglCreateWindowSurface failed: 0x%{public}x", eglGetError());
        return false;
    }

    if (eglMakeCurrent(rec->eglDisplay, rec->eglSurface, rec->eglSurface, rec->eglContext) != EGL_TRUE) {
        OH_LOG_ERROR(LOG_APP, "eglMakeCurrent failed: 0x%{public}x", eglGetError());
        return false;
    }

    // Prove the whole path works before the core lands: clear the preview
    // canvas to the OBS background color once. libobs will own this surface
    // (and render every frame) once HAVE_LIBOBS is defined.
    glClearColor(0.08f, 0.09f, 0.11f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    eglSwapBuffers(rec->eglDisplay, rec->eglSurface);
    OH_LOG_INFO(LOG_APP,
                "shell EGL seam live on XComponent %{public}s (%{public}llu x %{public}llu)",
                rec->id.c_str(), static_cast<unsigned long long>(rec->width),
                static_cast<unsigned long long>(rec->height));
    return true;
}

void DestroyShellEglSurface(SurfaceRecord *rec)
{
    if (rec->eglDisplay != EGL_NO_DISPLAY) {
        eglMakeCurrent(rec->eglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (rec->eglSurface != EGL_NO_SURFACE) {
            eglDestroySurface(rec->eglDisplay, rec->eglSurface);
            rec->eglSurface = EGL_NO_SURFACE;
        }
        if (rec->eglContext != EGL_NO_CONTEXT) {
            eglDestroyContext(rec->eglDisplay, rec->eglContext);
            rec->eglContext = EGL_NO_CONTEXT;
        }
        eglTerminate(rec->eglDisplay);
        rec->eglDisplay = EGL_NO_DISPLAY;
    }
}

#endif // HAVE_LIBOBS

void OnSurfaceCreated(OH_NativeXComponent *component, void *window)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    SurfaceRecord *rec = FindByComponentLocked(component);
    if (rec == nullptr) {
        return;
    }
    /* The window pointer is borrowed from ArkUI: without taking a strong
     * reference it is released when this callback returns, and every
     * eglSwapBuffers on the surface created from it fails with
     * EGL_BAD_NATIVE_WINDOW. */
    if (OH_NativeWindow_NativeObjectReference(window) != 0)
        OH_LOG_ERROR(LOG_APP, "NativeObjectReference failed for %{public}s", rec->id.c_str());
    rec->window = static_cast<NativeWindow *>(window);
    QuerySize(rec);
    OH_LOG_INFO(LOG_APP, "XComponent surface created: id=%{public}s %{public}llu x %{public}llu",
                rec->id.c_str(), static_cast<unsigned long long>(rec->width),
                static_cast<unsigned long long>(rec->height));
}

void OnSurfaceChanged(OH_NativeXComponent *component, void *window)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    SurfaceRecord *rec = FindByComponentLocked(component);
    if (rec == nullptr) {
        return;
    }
    if (rec->window != static_cast<NativeWindow *>(window) && window != nullptr) {
        if (rec->window != nullptr)
            OH_NativeWindow_NativeObjectUnreference(rec->window);
        if (OH_NativeWindow_NativeObjectReference(window) != 0)
            OH_LOG_ERROR(LOG_APP, "NativeObjectReference failed (changed) for %{public}s", rec->id.c_str());
    }
    rec->window = static_cast<NativeWindow *>(window);
    QuerySize(rec);
    OH_LOG_INFO(LOG_APP, "XComponent surface changed: id=%{public}s -> %{public}llu x %{public}llu",
                rec->id.c_str(), static_cast<unsigned long long>(rec->width),
                static_cast<unsigned long long>(rec->height));
    if (rec->isPreview || rec->isStudio) {
        // Recreate the graphics surface at the new size. Under HAVE_LIBOBS
        // libobs's backend handles resize via obs_display; recreating the
        // display is always correct, just not the cheapest path.
#ifdef HAVE_LIBOBS
        DestroyObsDisplay(rec);
        CreateObsDisplay(rec);
#else
        DestroyShellEglSurface(rec);
        CreateShellEglSurface(rec);
#endif
    }
}

void OnSurfaceDestroyed(OH_NativeXComponent *component, void * /*window*/)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    SurfaceRecord *rec = FindByComponentLocked(component);
    if (rec == nullptr) {
        return;
    }
    OH_LOG_INFO(LOG_APP, "XComponent surface destroyed: id=%{public}s", rec->id.c_str());
    if (rec->isPreview) {
#ifdef HAVE_LIBOBS
        DestroyObsDisplay(rec);
#else
        DestroyShellEglSurface(rec);
#endif
        rec->isPreview = false;
        g_preview = nullptr;
    }
    if (rec->isStudio) {
#ifdef HAVE_LIBOBS
        DestroyObsDisplay(rec);
#else
        DestroyShellEglSurface(rec);
#endif
        rec->isStudio = false;
        rec->studioCanvas = nullptr;
        if (g_studio == rec) {
            g_studio = nullptr;
        }
    }
    if (rec->window != nullptr)
        OH_NativeWindow_NativeObjectUnreference(rec->window);
    rec->window = nullptr;
}

void DispatchTouchEvent(OH_NativeXComponent * /*component*/, void * /*window*/)
{
    // Preview-canvas interaction (source selection / move / resize handles)
    // is an ArkUI-level concern in this scaffold; touch is intentionally not
    // consumed natively.
}

OH_NativeXComponent_Callback g_surfaceCallbacks = {
    .OnSurfaceCreated = OnSurfaceCreated,
    .OnSurfaceChanged = OnSurfaceChanged,
    .OnSurfaceDestroyed = OnSurfaceDestroyed,
    .DispatchTouchEvent = DispatchTouchEvent,
};

} // namespace

void RegisterXComponent(OH_NativeXComponent *component)
{
    if (component == nullptr) {
        return;
    }
    char idBuf[OH_XCOMPONENT_ID_LEN_MAX + 1] = { '\0' };
    uint64_t idSize = OH_XCOMPONENT_ID_LEN_MAX;
    if (OH_NativeXComponent_GetXComponentId(component, idBuf, &idSize) !=
        OH_NATIVEXCOMPONENT_RESULT_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "OH_NativeXComponent_GetXComponentId failed");
        return;
    }

    std::lock_guard<std::mutex> lock(g_mutex);
    if (FindByComponentLocked(component) != nullptr) {
        return; // already registered (Init can run more than once per process)
    }
    auto rec = std::make_unique<SurfaceRecord>();
    rec->component = component;
    rec->id = std::string(idBuf);
    OH_LOG_INFO(LOG_APP, "registered XComponent '%{public}s'", rec->id.c_str());
    g_records.push_back(std::move(rec));

    if (OH_NativeXComponent_RegisterCallback(component, &g_surfaceCallbacks) !=
        OH_NATIVEXCOMPONENT_RESULT_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "OH_NativeXComponent_RegisterCallback failed");
    }
}

/* Pick the record for an XComponent id. Studio-mode toggles destroy and
 * recreate the canvas, and every recreation appends a NEW record under the
 * same id (the napi module Init runs again per component instance). The old
 * records survive in g_records with window == nullptr — matching one of
 * those is what left the preview permanently black after a studio
 * round-trip (user report 10-13 #6). Prefer the LAST record with a live
 * surface; fall back to the last id match so the "not created yet" error
 * still names the right component. */
SurfaceRecord *FindLiveByIdLocked(const std::string &xcomponentId)
{
    SurfaceRecord *lastMatch = nullptr;
    SurfaceRecord *lastLive = nullptr;
    for (auto &candidate : g_records) {
        if (candidate->id == xcomponentId) {
            lastMatch = candidate.get();
            if (candidate->window != nullptr) {
                lastLive = candidate.get();
            }
        }
    }
    return lastLive != nullptr ? lastLive : lastMatch;
}

bool AttachPreview(const std::string &xcomponentId)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    SurfaceRecord *rec = FindLiveByIdLocked(xcomponentId);
    if (rec == nullptr) {
        OH_LOG_ERROR(LOG_APP, "AttachPreview: unknown XComponent id '%{public}s'",
                     xcomponentId.c_str());
        return false;
    }
    if (rec->window == nullptr) {
        OH_LOG_ERROR(LOG_APP, "AttachPreview: surface for '%{public}s' not created yet",
                     xcomponentId.c_str());
        return false;
    }
    if (rec->isPreview) {
        return true; // already attached
    }

    if (g_preview != nullptr && g_preview != rec) {
        // Single-canvas product: detach the previous preview first.
#ifdef HAVE_LIBOBS
        DestroyObsDisplay(g_preview);
#else
        DestroyShellEglSurface(g_preview);
#endif
        g_preview->isPreview = false;
        g_preview = nullptr;
    }

    bool ok;
#ifdef HAVE_LIBOBS
    ok = CreateObsDisplay(rec);
#else
    ok = CreateShellEglSurface(rec);
#endif
    if (ok) {
        rec->isPreview = true;
        g_preview = rec;
    }
    return ok;
}

void DetachPreview()
{
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_preview == nullptr) {
        return;
    }
#ifdef HAVE_LIBOBS
    DestroyObsDisplay(g_preview);
#else
    DestroyShellEglSurface(g_preview);
#endif
    g_preview->isPreview = false;
    g_preview = nullptr;
    OH_LOG_INFO(LOG_APP, "preview surface detached");
}

bool PreviewAttached()
{
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_preview != nullptr;
}

bool AttachStudioPreview(const std::string &xcomponentId, void *canvas)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    SurfaceRecord *rec = FindLiveByIdLocked(xcomponentId);
    if (rec == nullptr) {
        OH_LOG_ERROR(LOG_APP, "AttachStudioPreview: unknown XComponent id '%{public}s'", xcomponentId.c_str());
        return false;
    }
    if (rec->window == nullptr) {
        OH_LOG_ERROR(LOG_APP, "AttachStudioPreview: surface for '%{public}s' not created yet", xcomponentId.c_str());
        return false;
    }
    if (g_studio == rec) {
        rec->studioCanvas = canvas; // re-point at a (new) canvas, keep display
        return true;
    }
    if (g_studio != nullptr) {
#ifdef HAVE_LIBOBS
        DestroyObsDisplay(g_studio);
#else
        DestroyShellEglSurface(g_studio);
#endif
        g_studio->isStudio = false;
        g_studio->studioCanvas = nullptr;
        g_studio = nullptr;
    }

    rec->studioCanvas = canvas;
    bool ok;
#ifdef HAVE_LIBOBS
    ok = CreateObsDisplay(rec);
#else
    ok = CreateShellEglSurface(rec);
#endif
    if (ok) {
        rec->isStudio = true;
        g_studio = rec;
        OH_LOG_INFO(LOG_APP, "studio preview surface attached: %{public}s", xcomponentId.c_str());
    }
    return ok;
}

void DetachStudioPreview()
{
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_studio == nullptr) {
        return;
    }
#ifdef HAVE_LIBOBS
    DestroyObsDisplay(g_studio);
#else
    DestroyShellEglSurface(g_studio);
#endif
    g_studio->isStudio = false;
    g_studio->studioCanvas = nullptr;
    g_studio = nullptr;
    OH_LOG_INFO(LOG_APP, "studio preview surface detached");
}

void ResetAll()
{
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_studio != nullptr) {
#ifdef HAVE_LIBOBS
        DestroyObsDisplay(g_studio);
#else
        DestroyShellEglSurface(g_studio);
#endif
        g_studio->isStudio = false;
        g_studio->studioCanvas = nullptr;
        g_studio = nullptr;
    }
    if (g_preview != nullptr) {
#ifdef HAVE_LIBOBS
        DestroyObsDisplay(g_preview);
#else
        DestroyShellEglSurface(g_preview);
#endif
        g_preview->isPreview = false;
        g_preview = nullptr;
    }
    g_records.clear();
}

} // namespace xcomp
