/* glad EGL shim for HarmonyOS.
 *
 * libobs-opengl's EGL winsys files include <glad/glad_egl.h> and call
 * gladLoadEGL(). On HarmonyOS EGL is provided by libEGL.so as real exported
 * symbols, so the loader is a formality.
 */

#pragma once

#include <EGL/egl.h>
#include <EGL/eglext.h>

#ifdef __cplusplus
extern "C" {
#endif

static inline int gladLoadEGL(void)
{
	return 1;
}

typedef void *(*GLADeglLoadproc)(const char *name);

static inline void gladLoadEGLLoader(GLADeglLoadproc loader)
{
	(void)loader;
}

#ifdef __cplusplus
}
#endif
