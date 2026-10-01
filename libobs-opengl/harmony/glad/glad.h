/* Minimal glad-compatible shim for HarmonyOS, which exposes OpenGL ES 3.2
 * rather than desktop OpenGL.
 *
 * Every other libobs-opengl translation unit does `#include <glad/glad.h>` and
 * then calls plain `glFoo()`. On desktop those names are glad function-pointer
 * macros resolved at runtime. On HarmonyOS the GLES entry points are exported
 * directly by libGLESv3.so, so no loader indirection is needed and these names
 * resolve as real symbols at link time.
 *
 * This header is placed ahead of deps/glad/include on the include path for
 * HarmonyOS builds only, so no other platform is affected.
 */

#pragma once

#include <GLES3/gl32.h>
#include <GLES2/gl2ext.h>

/* ------------------------------------------------------------------------- */
/* Desktop GL enum -> GLES extension equivalents                             */
/* ------------------------------------------------------------------------- */
/*
 * libobs-opengl was written against desktop GL 3.3. Of the 177 GL_* tokens it
 * uses, 11 are absent from the GLES headers. Most have a directly equivalent
 * EXT entry point on GLES, so alias to the vendor-provided name rather than
 * hardcoding a value and risking drift.
 */

/* GL_EXT_texture_format_BGRA8888 */
#ifndef GL_BGRA
#define GL_BGRA GL_BGRA_EXT
#endif

/* Core ES 3.0 (Table 3.2) type for BGRA byte order without the BGRA_EXT
 * format token: RGBA + UNSIGNED_INT_8_8_8_8_REV stores memory as B,G,R,A.
 * The Maleoon driver rejects GL_BGRA_EXT as a texImage2D format even though
 * GL_EXT_texture_format_BGRA8888 is advertised, so the BGRA path below uses
 * this spelling instead. */
#ifndef GL_UNSIGNED_INT_8_8_8_8_REV
#define GL_UNSIGNED_INT_8_8_8_8_REV 0x8035
#endif

/* GL_EXT_texture_norm16 — normalised 16-bit formats are not GLES core */
#ifndef GL_R16
#define GL_R16 GL_R16_EXT
#endif
#ifndef GL_RG16
#define GL_RG16 GL_RG16_EXT
#endif
#ifndef GL_RGBA16
#define GL_RGBA16 GL_RGBA16_EXT
#endif

/* GL_MIRROR_CLAMP_EXT is desktop-only; GLES spells it clamp-to-edge. */
#ifndef GL_MIRROR_CLAMP_EXT
#define GL_MIRROR_CLAMP_EXT GL_MIRROR_CLAMP_TO_EDGE_EXT
#endif

#ifndef GL_MAX_TEXTURE_MAX_ANISOTROPY_EXT
#define GL_MAX_TEXTURE_MAX_ANISOTROPY_EXT 0x84FF
#endif
#ifndef GL_TEXTURE_SRGB_DECODE_EXT
#define GL_TEXTURE_SRGB_DECODE_EXT 0x8A48
#endif

/* ------------------------------------------------------------------------- */
/* Desktop GL enums with no GLES equivalent                                  */
/* ------------------------------------------------------------------------- */

/* Desktop rectangle-texture enum. GLES has no rectangle textures, so this
 * value is never assigned to gl_target and gs_texture_is_rect() correctly
 * returns false. NOTE: must NOT be 0x0DE1 — that is GL_TEXTURE_2D itself,
 * which would make every 2D texture look like a rectangle texture. */
#ifndef GL_TEXTURE_RECTANGLE
#define GL_TEXTURE_RECTANGLE 0x84F5
#endif

/* Desktop-only seamless cube sampling; GLES 3.x is always seamless. The
 * glEnable call is compiled out under __OHOS__ in gl-subsystem.c.
 */
#ifndef GL_TEXTURE_CUBE_MAP_SEAMLESS
#define GL_TEXTURE_CUBE_MAP_SEAMLESS 0x884F
#endif

/* sRGB framebuffer enable does not exist on GLES; the encoding is fixed by the
 * EGLConfig. Call sites are compiled out under __OHOS__.
 */
#ifndef GL_FRAMEBUFFER_SRGB
#define GL_FRAMEBUFFER_SRGB 0x0DB9
#endif

/* NVX GPU memory queries are NVIDIA desktop-only. Defined so the code compiles;
 * glGetIntegerv leaves the out-param untouched and sets GL_INVALID_ENUM, so
 * gpu_get_dmem()/gpu_get_smem() report 0 on HarmonyOS.
 */
#ifndef GL_GPU_MEMORY_INFO_DEDICATED_VIDMEM_NVX
#define GL_GPU_MEMORY_INFO_DEDICATED_VIDMEM_NVX 0x9047
#endif
#ifndef GL_GPU_MEMORY_INFO_TOTAL_AVAILABLE_MEMORY_NVX
#define GL_GPU_MEMORY_INFO_TOTAL_AVAILABLE_MEMORY_NVX 0x9048
#endif

/* ARB_timer_query. GLES exposes it only via GL_EXT_disjoint_timer_query, which
 * HarmonyOS GPUs do not reliably implement, so gs_timer_* is stubbed below.
 * GL_TIMESTAMP still has to be a nameable token because the call sites pass it
 * as an argument.
 */
#ifndef GL_TIMESTAMP
#define GL_TIMESTAMP 0x8E28
#endif

/* ------------------------------------------------------------------------- */
/* Capability flags                                                          */
/* ------------------------------------------------------------------------- */
/*
 * GLES 3.2 covers the OpenGL 3.3 feature set OBS actually uses, so report 3.3
 * as satisfied and 4.3 as absent so the code takes its non-4.3 paths.
 */
#define GLAD_GL_VERSION_3_3 1
#define GLAD_GL_VERSION_4_3 0
#define GLAD_GL_ARB_debug_output 0
#define GLAD_GL_ARB_copy_image 0
#define GLAD_GL_NV_copy_image 0
#define GLAD_GL_EXT_texture_sRGB_decode 1
#define GLAD_GL_EXT_texture_filter_anisotropic 1

/* glQueryCounter is desktop GL 3.3 / ARB_timer_query. gs_timer_* degrades to a
 * no-op rather than faulting on an entry point the driver may not provide.
 */
static inline void glad_glQueryCounter_noop(GLuint id, GLenum target)
{
	(void)id;
	(void)target;
}
#define glQueryCounter glad_glQueryCounter_noop

/* glGetQueryObjectiv/ui64v are ARB_timer_query companions to glQueryCounter and
 * are likewise absent, so the timer readback is stubbed to match.
 */
static inline void glad_glGetQueryObjectiv_noop(GLuint id, GLenum pname, GLint *params)
{
	(void)id;
	(void)pname;
	*params = 0;
}
#define glGetQueryObjectiv glad_glGetQueryObjectiv_noop

/* ------------------------------------------------------------------------- */
/* Entry point remapping                                                     */
/* ------------------------------------------------------------------------- */

/* GLES 3.x dropped glMapBuffer in favour of glMapBufferRange, which requires an
 * explicit byte range. Query the bound buffer's allocation and map all of it to
 * reproduce glMapBuffer's semantics; libobs always maps whole PBOs.
 */
static inline void *glad_glMapBuffer(GLenum target, GLenum access)
{
	GLint size = 0;
	GLbitfield flags;

	glGetBufferParameteriv(target, GL_BUFFER_SIZE, &size);
	if (size <= 0)
		return NULL;

	switch (access) {
	case GL_READ_ONLY:
		flags = GL_MAP_READ_BIT;
		break;
	case GL_WRITE_ONLY:
		flags = GL_MAP_WRITE_BIT;
		break;
	default:
		flags = GL_MAP_READ_BIT | GL_MAP_WRITE_BIT;
		break;
	}

	return glMapBufferRange(target, 0, (GLsizeiptr)size, flags);
}
#define glMapBuffer glad_glMapBuffer

/* GLES spells the depth clear entry point glClearDepthf and takes a GLfloat.
 * All libobs call sites pass a literal that narrows without loss.
 */
#define glClearDepth glClearDepthf

/* GLES 3.2 promotes both of these to core under their unprefixed names. */
#define glPushDebugGroupKHR glPushDebugGroup
#define glPopDebugGroupKHR glPopDebugGroup

/* glCopyImageSubData is GLES 3.2 core. The NV_copy_image path is disabled via
 * GLAD_GL_NV_copy_image above, but the symbol still has to resolve at link
 * time. */
#define glCopyImageSubDataNV glCopyImageSubData

static inline void glad_glGetQueryObjectui64v_noop(GLuint id, GLenum pname, GLuint64 *params)
{
	(void)id;
	(void)pname;
	*params = 0;
}
#define glGetQueryObjectui64v glad_glGetQueryObjectui64v_noop

#ifdef __cplusplus
extern "C" {
#endif

/* glad's runtime loaders. GLES entry points are linked directly, so these
 * succeed unconditionally; they exist so the existing call sites in
 * gl-subsystem.c and the winsys files compile unchanged.
 */
static inline int gladLoadGL(void)
{
	return 1;
}

typedef void *(*GLADloadproc)(const char *name);

static inline void gladLoadGLLoader(GLADloadproc loader)
{
	(void)loader;
}

#ifdef __cplusplus
}
#endif
