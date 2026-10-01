/******************************************************************************
    HarmonyOS EGL/GLES window-system backend for libobs-opengl.

    Replaces gl-nix.c + gl-x11-egl.c on HarmonyOS. The compositor hands us an
    OHNativeWindow from an ArkUI XComponent; we wrap it in an EGL window surface
    and drive it with the same gs_device the other backends use.

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 2 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
******************************************************************************/

#include "gl-harmony-egl.h"

#include <util/base.h>
#include <util/dstr.h>
#include <util/platform.h>

#include <glad/glad.h>
#include <glad/glad_egl.h>

#ifndef EGL_OPENGL_ES3_BIT
#define EGL_OPENGL_ES3_BIT 0x0040
#endif

struct gl_windowinfo {
	OHNativeWindow *window;
	EGLSurface surface;
};

struct gl_platform {
	EGLDisplay edisplay;
	EGLConfig config;
	EGLContext context;
	EGLSurface pbuffer;
};

static OHNativeWindow *g_default_window = NULL;

void gl_harmony_set_default_window(OHNativeWindow *window)
{
	if (g_default_window == window)
		return;

	if (g_default_window)
		OH_NativeWindow_NativeObjectUnreference(g_default_window);

	g_default_window = window;

	if (g_default_window)
		OH_NativeWindow_NativeObjectReference(g_default_window);
}

OHNativeWindow *gl_harmony_get_default_window(void)
{
	return g_default_window;
}

static const char *harmony_egl_error_to_string(EGLint error)
{
	switch (error) {
	case EGL_SUCCESS:
		return "EGL_SUCCESS";
	case EGL_NOT_INITIALIZED:
		return "EGL_NOT_INITIALIZED";
	case EGL_BAD_ACCESS:
		return "EGL_BAD_ACCESS";
	case EGL_BAD_ALLOC:
		return "EGL_BAD_ALLOC";
	case EGL_BAD_ATTRIBUTE:
		return "EGL_BAD_ATTRIBUTE";
	case EGL_BAD_CONFIG:
		return "EGL_BAD_CONFIG";
	case EGL_BAD_CONTEXT:
		return "EGL_BAD_CONTEXT";
	case EGL_BAD_CURRENT_SURFACE:
		return "EGL_BAD_CURRENT_SURFACE";
	case EGL_BAD_DISPLAY:
		return "EGL_BAD_DISPLAY";
	case EGL_BAD_MATCH:
		return "EGL_BAD_MATCH";
	case EGL_BAD_NATIVE_PIXMAP:
		return "EGL_BAD_NATIVE_PIXMAP";
	case EGL_BAD_NATIVE_WINDOW:
		return "EGL_BAD_NATIVE_WINDOW";
	case EGL_BAD_PARAMETER:
		return "EGL_BAD_PARAMETER";
	case EGL_BAD_SURFACE:
		return "EGL_BAD_SURFACE";
	case EGL_CONTEXT_LOST:
		return "EGL_CONTEXT_LOST";
	default:
		return "Unknown EGL error";
	}
}

static const char *get_egl_error_string(void)
{
	return harmony_egl_error_to_string(eglGetError());
}

struct gl_windowinfo *gl_windowinfo_create(const struct gs_init_data *info)
{
	struct gl_windowinfo *wi = bmalloc(sizeof(struct gl_windowinfo));
	OHNativeWindow *window = gs_window_native_window(&info->window);

	if (!window)
		window = g_default_window;

	if (!window) {
		blog(LOG_ERROR, "gl_windowinfo_create: no OHNativeWindow supplied. The ArkUI layer must set "
				"gs_init_data.window.display, or call gl_harmony_set_default_window() first.");
		bfree(wi);
		return NULL;
	}

	wi->window = window;
	wi->surface = EGL_NO_SURFACE;

	/* Hold a reference so the surface outlives the ArkUI component that
	 * created it if that component is torn down mid-frame.
	 */
	OH_NativeWindow_NativeObjectReference(wi->window);

	return wi;
}

void gl_windowinfo_destroy(struct gl_windowinfo *wi)
{
	if (!wi)
		return;

	if (wi->window)
		OH_NativeWindow_NativeObjectUnreference(wi->window);

	bfree(wi);
}

static bool harmony_choose_config(struct gl_platform *plat)
{
	const EGLint config_attribs[] = {
		EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_SURFACE_TYPE,	   EGL_WINDOW_BIT | EGL_PBUFFER_BIT,
		EGL_RED_SIZE,	   8,		      EGL_GREEN_SIZE,	   8,
		EGL_BLUE_SIZE,	   8,		      EGL_ALPHA_SIZE,	   8,
		EGL_DEPTH_SIZE,	   24,		      EGL_STENCIL_SIZE,	   8,
		EGL_NONE,
	};
	EGLint num_configs = 0;

	if (!eglChooseConfig(plat->edisplay, config_attribs, &plat->config, 1, &num_configs) || num_configs < 1) {
		blog(LOG_ERROR, "eglChooseConfig failed: %s", get_egl_error_string());
		return false;
	}

	return true;
}

static bool harmony_context_create(struct gl_platform *plat)
{
	const EGLint context_attribs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
	const EGLint pbuffer_attribs[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};

	plat->context = eglCreateContext(plat->edisplay, plat->config, EGL_NO_CONTEXT, context_attribs);
	if (plat->context == EGL_NO_CONTEXT) {
		blog(LOG_ERROR, "eglCreateContext failed: %s", get_egl_error_string());
		return false;
	}

	/* A 1x1 pbuffer lets the graphics thread own a current context even
	 * when no swapchain is bound, which is what device_enter_context()
	 * falls back to.
	 */
	plat->pbuffer = eglCreatePbufferSurface(plat->edisplay, plat->config, pbuffer_attribs);
	if (plat->pbuffer == EGL_NO_SURFACE) {
		blog(LOG_ERROR, "eglCreatePbufferSurface failed: %s", get_egl_error_string());
		return false;
	}

	return true;
}

static void harmony_context_destroy(struct gl_platform *plat)
{
	if (plat->pbuffer != EGL_NO_SURFACE) {
		eglDestroySurface(plat->edisplay, plat->pbuffer);
		plat->pbuffer = EGL_NO_SURFACE;
	}

	if (plat->context != EGL_NO_CONTEXT) {
		eglDestroyContext(plat->edisplay, plat->context);
		plat->context = EGL_NO_CONTEXT;
	}
}

struct gl_platform *gl_platform_create(gs_device_t *device, uint32_t adapter)
{
	struct gl_platform *plat = bzalloc(sizeof(struct gl_platform));

	UNUSED_PARAMETER(adapter);

	plat->edisplay = EGL_NO_DISPLAY;
	plat->context = EGL_NO_CONTEXT;
	plat->pbuffer = EGL_NO_SURFACE;

	plat->edisplay = eglGetDisplay(EGL_DEFAULT_DISPLAY);
	if (plat->edisplay == EGL_NO_DISPLAY) {
		blog(LOG_ERROR, "eglGetDisplay(EGL_DEFAULT_DISPLAY) failed: %s", get_egl_error_string());
		goto fail;
	}

	EGLint major = 0, minor = 0;
	if (!eglInitialize(plat->edisplay, &major, &minor)) {
		blog(LOG_ERROR, "eglInitialize failed: %s", get_egl_error_string());
		goto fail;
	}

	blog(LOG_INFO, "HarmonyOS EGL initialized, version %d.%d", major, minor);

	if (!eglBindAPI(EGL_OPENGL_ES_API)) {
		blog(LOG_ERROR, "eglBindAPI(EGL_OPENGL_ES_API) failed: %s", get_egl_error_string());
		goto fail;
	}

	if (!harmony_choose_config(plat))
		goto fail;

	if (!harmony_context_create(plat))
		goto fail;

	/* gl_init_extensions() and friends assume device->plat is already
	 * reachable before the first context enter.
	 */
	device->plat = plat;

	if (!eglMakeCurrent(plat->edisplay, plat->pbuffer, plat->pbuffer, plat->context)) {
		blog(LOG_ERROR, "eglMakeCurrent(pbuffer) failed: %s", get_egl_error_string());
		goto fail;
	}

	if (!gladLoadGL()) {
		blog(LOG_ERROR, "Failed to load OpenGL ES entry points.");
		goto fail;
	}

	blog(LOG_INFO, "HarmonyOS graphics: %s (%s), GLSL %s", glGetString(GL_RENDERER), glGetString(GL_VENDOR),
	     glGetString(GL_VERSION));

	return plat;

fail:
	harmony_context_destroy(plat);
	if (plat->edisplay != EGL_NO_DISPLAY)
		eglTerminate(plat->edisplay);
	bfree(plat);
	return NULL;
}

void gl_platform_destroy(struct gl_platform *plat)
{
	if (!plat)
		return;

	harmony_context_destroy(plat);

	if (plat->edisplay != EGL_NO_DISPLAY)
		eglTerminate(plat->edisplay);

	bfree(plat);
}

bool gl_platform_init_swapchain(struct gs_swap_chain *swap)
{
	const struct gl_platform *plat = swap->device->plat;
	struct gl_windowinfo *wi = swap->wi;

	if (!wi || !wi->window) {
		blog(LOG_ERROR, "gl_platform_init_swapchain: swapchain has no OHNativeWindow.");
		return false;
	}

	int32_t ret = OH_NativeWindow_NativeWindowHandleOpt(wi->window, SET_BUFFER_GEOMETRY, (int32_t)swap->info.cx,
							   (int32_t)swap->info.cy);
	if (ret != 0) {
		blog(LOG_WARNING, "SET_BUFFER_GEOMETRY(%u, %u) failed: %d", swap->info.cx, swap->info.cy, ret);
	}

	/* EGLNativeWindowType is an integer typedef on HarmonyOS, but the
	 * driver expects the OHNativeWindow pointer value itself.
	 */
	wi->surface =
		eglCreateWindowSurface(plat->edisplay, plat->config, (EGLNativeWindowType)wi->window, NULL);
	if (wi->surface == EGL_NO_SURFACE) {
		blog(LOG_ERROR, "eglCreateWindowSurface failed: %s", get_egl_error_string());
		return false;
	}

	return true;
}

void gl_platform_cleanup_swapchain(struct gs_swap_chain *swap)
{
	struct gl_windowinfo *wi = swap ? swap->wi : NULL;

	if (!wi)
		return;

	if (wi->surface != EGL_NO_SURFACE) {
		const struct gl_platform *plat = swap->device->plat;

		if (plat) {
			eglMakeCurrent(plat->edisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
			eglDestroySurface(plat->edisplay, wi->surface);
		}

		wi->surface = EGL_NO_SURFACE;
	}
}

void device_enter_context(gs_device_t *device)
{
	const struct gl_platform *plat = device->plat;
	const EGLSurface surface = (device->cur_swap && device->cur_swap->wi) ? device->cur_swap->wi->surface
									      : plat->pbuffer;

	if (!eglMakeCurrent(plat->edisplay, surface, surface, plat->context))
		blog(LOG_ERROR, "Failed to make context current: %s", get_egl_error_string());
}

void device_leave_context(gs_device_t *device)
{
	const struct gl_platform *plat = device->plat;

	if (!eglMakeCurrent(plat->edisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT))
		blog(LOG_ERROR, "Failed to release context: %s", get_egl_error_string());
}

void gl_clear_context(gs_device_t *device)
{
	device_leave_context(device);
}

void *device_get_device_obj(gs_device_t *device)
{
	return device->plat->context;
}

void gl_getclientsize(const struct gs_swap_chain *swap, uint32_t *width, uint32_t *height)
{
	const struct gl_windowinfo *wi = swap ? swap->wi : NULL;

	if (!wi) {
		*width = 0;
		*height = 0;
		return;
	}

	/* The EGL surface is the only authoritative source: the native
	 * window's buffer geometry can report the panel's natural (portrait)
	 * size while the compositor presents rotated, and querying it before
	 * the surface exists returns garbage. eglQuerySurface returns the
	 * dimensions glViewport works in. */
	if (wi->surface != EGL_NO_SURFACE && swap->device && swap->device->plat) {
		EGLint w = 0;
		EGLint h = 0;
		if (eglQuerySurface(swap->device->plat->edisplay, wi->surface, EGL_WIDTH, &w) &&
		    eglQuerySurface(swap->device->plat->edisplay, wi->surface, EGL_HEIGHT, &h) && w > 0 && h > 0) {
			*width = (uint32_t)w;
			*height = (uint32_t)h;
			return;
		}
	}

	*width = (uint32_t)swap->info.cx;
	*height = (uint32_t)swap->info.cy;
}

void gl_update(gs_device_t *device)
{
	struct gs_swap_chain *swap = device->cur_swap;

	if (!swap || !swap->wi || !swap->wi->window)
		return;

	int32_t ret = OH_NativeWindow_NativeWindowHandleOpt(swap->wi->window, SET_BUFFER_GEOMETRY,
							   (int32_t)swap->info.cx, (int32_t)swap->info.cy);
	if (ret != 0)
		blog(LOG_WARNING, "gl_update: SET_BUFFER_GEOMETRY failed: %d", ret);
}

void device_load_swapchain(gs_device_t *device, gs_swapchain_t *swap)
{
	if (device->cur_swap == swap)
		return;

	device->cur_swap = swap;
	device_enter_context(device);
}

bool device_is_present_ready(gs_device_t *device)
{
	UNUSED_PARAMETER(device);
	return true;
}

void device_present(gs_device_t *device)
{
	const struct gl_platform *plat = device->plat;
	struct gs_swap_chain *swap = device->cur_swap;

	if (!swap || !swap->wi || swap->wi->surface == EGL_NO_SURFACE) {
		blog(LOG_WARNING, "device_present called with no bound swapchain surface.");
		return;
	}

	eglSwapInterval(plat->edisplay, 0);

	if (!eglSwapBuffers(plat->edisplay, swap->wi->surface))
		blog(LOG_ERROR, "eglSwapBuffers failed: %s", get_egl_error_string());
}

bool device_is_monitor_hdr(gs_device_t *device, void *monitor)
{
	UNUSED_PARAMETER(device);
	UNUSED_PARAMETER(monitor);
	return false;
}

bool device_enum_adapters(gs_device_t *device, bool (*callback)(void *param, const char *name, uint32_t id),
			  void *param)
{
	UNUSED_PARAMETER(device);

	/* HarmonyOS exposes a single integrated GPU to the application. */
	return callback(param, "HarmonyOS GPU", 0);
}

uint32_t gs_get_adapter_count(void)
{
	return 1;
}

/* dmabuf import is how the Linux backends get zero-copy frames from PipeWire.
 * HarmonyOS has no dmabuf surface; the equivalent zero-copy path is
 * OH_NativeImage feeding a GL_TEXTURE_EXTERNAL_OES texture, which the
 * harmony-capture plugin owns. Report unsupported so libobs falls back to
 * regular texture upload rather than attempting an import that cannot work.
 */
struct gs_texture *device_texture_create_from_dmabuf(gs_device_t *device, unsigned int width, unsigned int height,
						     uint32_t drm_format, enum gs_color_format color_format,
						     uint32_t n_planes, const int *fds, const uint32_t *strides,
						     const uint32_t *offsets, const uint64_t *modifiers)
{
	UNUSED_PARAMETER(device);
	UNUSED_PARAMETER(width);
	UNUSED_PARAMETER(height);
	UNUSED_PARAMETER(drm_format);
	UNUSED_PARAMETER(color_format);
	UNUSED_PARAMETER(n_planes);
	UNUSED_PARAMETER(fds);
	UNUSED_PARAMETER(strides);
	UNUSED_PARAMETER(offsets);
	UNUSED_PARAMETER(modifiers);

	return NULL;
}

bool device_query_dmabuf_capabilities(gs_device_t *device, enum gs_dmabuf_flags *dmabuf_flags, uint32_t **drm_formats,
				      size_t *n_formats)
{
	UNUSED_PARAMETER(device);
	*dmabuf_flags = GS_DMABUF_FLAG_NONE;
	*drm_formats = NULL;
	*n_formats = 0;
	return false;
}

bool device_query_dmabuf_modifiers_for_format(gs_device_t *device, uint32_t drm_format, uint64_t **modifiers,
					      size_t *n_modifiers)
{
	UNUSED_PARAMETER(device);
	UNUSED_PARAMETER(drm_format);
	*modifiers = NULL;
	*n_modifiers = 0;
	return false;
}

struct gs_texture *device_texture_create_from_pixmap(gs_device_t *device, uint32_t width, uint32_t height,
						     enum gs_color_format color_format, uint32_t target, void *pixmap)
{
	UNUSED_PARAMETER(device);
	UNUSED_PARAMETER(width);
	UNUSED_PARAMETER(height);
	UNUSED_PARAMETER(color_format);
	UNUSED_PARAMETER(target);
	UNUSED_PARAMETER(pixmap);

	return NULL;
}

/* syncobj timeline fences are a Linux DRM construct with no HarmonyOS
 * equivalent. EGL fence sync is available and is what gs_sync_create() would
 * use if libobs's video pipeline required it on this platform.
 */
bool device_query_sync_capabilities(gs_device_t *device)
{
	UNUSED_PARAMETER(device);
	return false;
}

gs_sync_t *device_sync_create(gs_device_t *device)
{
	UNUSED_PARAMETER(device);
	return NULL;
}

gs_sync_t *device_sync_create_from_syncobj_timeline_point(gs_device_t *device, int syncobj_fd, uint64_t timeline_point)
{
	UNUSED_PARAMETER(device);
	UNUSED_PARAMETER(syncobj_fd);
	UNUSED_PARAMETER(timeline_point);
	return NULL;
}

void device_sync_destroy(gs_device_t *device, gs_sync_t *sync)
{
	UNUSED_PARAMETER(device);
	UNUSED_PARAMETER(sync);
}

bool device_sync_export_syncobj_timeline_point(gs_device_t *device, gs_sync_t *sync, int syncobj_fd,
					       uint64_t timeline_point)
{
	UNUSED_PARAMETER(device);
	UNUSED_PARAMETER(sync);
	UNUSED_PARAMETER(syncobj_fd);
	UNUSED_PARAMETER(timeline_point);
	return false;
}

bool device_sync_signal_syncobj_timeline_point(gs_device_t *device, int syncobj_fd, uint64_t timeline_point)
{
	UNUSED_PARAMETER(device);
	UNUSED_PARAMETER(syncobj_fd);
	UNUSED_PARAMETER(timeline_point);
	return false;
}

bool device_sync_wait(gs_device_t *device, gs_sync_t *sync)
{
	UNUSED_PARAMETER(device);
	UNUSED_PARAMETER(sync);
	return false;
}
