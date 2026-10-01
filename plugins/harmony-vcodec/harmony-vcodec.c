/******************************************************************************
    Copyright (C) 2026 by OBS Studio contributors

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

    HarmonyOS hardware H.264/HEVC encoder, backed by the OH_VideoEncoder
    (AVCodec) NDK API in input-surface mode.

    Design: the encoder is created with OH_VideoEncoder_GetSurface, which
    hands out an OHNativeWindow fed straight to the hardware encoder. The
    source texture libobs composed is blitted into that window through an EGL
    window surface sharing libobs's GL context (encode_texture2 below), so no
    per-frame CPU copy happens; eglSwapBuffers queues the buffer for encoding.

    SEI injection is intentionally not implemented: native_avcodec_base.h
    (API 26) exposes no OH_MD_KEY_* for SEI or user-data injection on the
    encoder, and the surface input path offers no place to prepend NAL units.
******************************************************************************/

#include <obs-module.h>
#include <util/darray.h>
#include <util/platform.h>

#include <pthread.h>

#include <EGL/egl.h>
#include <GLES2/gl2.h>

#include <multimedia/player_framework/native_avcodec_videoencoder.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avbuffer_info.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_averrors.h>
#include <native_window/external_window.h>

#define LOG_PREFIX "[harmony vcodec] "

/* libobs's master EGL handles, captured on the graphics thread via a main
 * render callback. The GPU encode thread creates its own EGL context sharing
 * this one, which is what lets it sample libobs's composed textures — EGL
 * contexts do not implicitly share resources the way D3D devices do. */
static EGLDisplay g_master_display = EGL_NO_DISPLAY;
static EGLContext g_master_context = EGL_NO_CONTEXT;
static EGLConfig g_master_config = NULL;
static bool g_master_ready = false;

static void venc_capture_master_egl(void *param, uint32_t cx, uint32_t cy)
{
	UNUSED_PARAMETER(param);
	UNUSED_PARAMETER(cx);
	UNUSED_PARAMETER(cy);

	if (g_master_ready)
		return;

	const EGLDisplay dpy = eglGetCurrentDisplay();
	const EGLContext ctx = eglGetCurrentContext();
	if (dpy == EGL_NO_DISPLAY || ctx == EGL_NO_CONTEXT)
		return;

	EGLint config_id = 0;
	EGLConfig config = NULL;
	if (eglQueryContext(dpy, ctx, EGL_CONFIG_ID, &config_id) && config_id != 0) {
		const EGLint attribs[] = {EGL_CONFIG_ID, config_id, EGL_NONE};
		EGLint num = 0;
		if (!eglChooseConfig(dpy, attribs, &config, 1, &num) || num < 1)
			config = NULL;
	}
	if (config == NULL) {
		/* Fallback: a stock RGBA8888 ES2 config. */
		const EGLint attribs[] = {EGL_SURFACE_TYPE,    EGL_WINDOW_BIT, EGL_RENDERABLE_TYPE,
					  EGL_OPENGL_ES2_BIT, EGL_RED_SIZE,    1,                   EGL_GREEN_SIZE,
					  1,                  EGL_BLUE_SIZE,   1,                   EGL_ALPHA_SIZE,
					  1,                  EGL_NONE};
		EGLint num = 0;
		if (!eglChooseConfig(dpy, attribs, &config, 1, &num) || num < 1)
			return;
	}

	g_master_display = dpy;
	g_master_context = ctx;
	g_master_config = config;
	g_master_ready = true;
	blog(LOG_INFO, LOG_PREFIX "master EGL handles captured");
}

struct harmony_venc_packet {
	DARRAY(uint8_t) data;
	int64_t pts_ns;
	bool keyframe;
};

struct harmony_venc {
	obs_encoder_t *encoder;
	OH_AVCodec *codec;
	OHNativeWindow *window;

	bool hevc;
	uint32_t width;
	uint32_t height;
	uint32_t fps_num;
	uint32_t fps_den;

	int bitrate;      /* kbit/s, matches OBS's UI convention */
	int rate_control; /* enum OH_BitrateMode */
	int profile;
	int keyint_sec;

	/* GL/EGL objects; the encode surface is drawn on the GPU encode
	 * thread with enc->context (shared with libobs's master context). */
	EGLDisplay display;
	EGLSurface surface;
	EGLContext context;
	GLuint program;
	GLuint vertex_vbo;
	GLint position_location;
	GLint texture_location;
	GLint texture_uv_location;
	bool gl_ready;

	pthread_mutex_t mutex;
	DARRAY(struct harmony_venc_packet) packet_queue;
	DARRAY(uint8_t) extra_data;
	DARRAY(uint8_t) current_packet;
	int64_t last_dts;

	bool started;
	bool failed;
};

static const char *venc_vertex_shader_src =
	"attribute vec2 a_position;\n"
	"varying vec2 v_texcoord;\n"
	"void main()\n"
	"{\n"
	"	v_texcoord = vec2(a_position.x * 0.5 + 0.5, 0.5 - a_position.y * 0.5);\n"
	"	gl_Position = vec4(a_position, 0.0, 1.0);\n"
	"}\n";

/* OBS's GPU-encode path hands over NV12: tex[0] is the Y plane (R8, full
 * res), tex[1] the interleaved UV plane (R8G8, half res). Convert to RGB
 * with the Rec.709 limited-range matrix the video pipeline was configured
 * with; the encoder surface then re-encodes from RGB. */
static const char *venc_fragment_shader_src =
	"precision mediump float;\n"
	"varying vec2 v_texcoord;\n"
	"uniform sampler2D u_texture;\n"
	"uniform sampler2D u_texture_uv;\n"
	"void main()\n"
	"{\n"
	"	float y = texture2D(u_texture, v_texcoord).r;\n"
	"	vec2 uv = texture2D(u_texture_uv, v_texcoord).rg;\n"
	"	float yy = (y - 0.0625) * 1.16438356;\n"          /* (Y-16)/219 */
	"	float u = uv.r - 0.5;\n"                          /* (U-128)/255 */
	"	float v = uv.g - 0.5;\n"
	/* Rec.709 limited-range, scaled to the /224 / /219 normalisation: */
	"	float r = yy + 1.79274102 * v;\n"
	"	float g = yy - 0.21324862 * u - 0.53290930 * v;\n"
	"	float b = yy + 2.11240179 * u;\n"
	"	gl_FragColor = vec4(clamp(r,0.0,1.0), clamp(g,0.0,1.0), clamp(b,0.0,1.0), 1.0);\n"
	"}\n";

/* Full-screen triangle covering clip space. */
static const GLfloat venc_fullscreen_vertices[6] = {-1.0f, -1.0f, 3.0f, -1.0f, -1.0f, 3.0f};

static void venc_on_error(OH_AVCodec *codec, int32_t error_code, void *user_data)
{
	struct harmony_venc *enc = user_data;

	blog(LOG_ERROR, LOG_PREFIX "encoder reported error %d", error_code);
	enc->failed = true;

	UNUSED_PARAMETER(codec);
}

static void venc_on_stream_changed(OH_AVCodec *codec, OH_AVFormat *format, void *user_data)
{
	/* Surface-mode encoders can renegotiate geometry here; libobs drives
	 * the canvas size, so this is informational only. */
	UNUSED_PARAMETER(codec);
	UNUSED_PARAMETER(format);
	UNUSED_PARAMETER(user_data);
}

static void venc_on_new_output(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *user_data)
{
	struct harmony_venc *enc = user_data;
	OH_AVCodecBufferAttr attr = {0};

	if (buffer == NULL || OH_AVBuffer_GetBufferAttr(buffer, &attr) != AV_ERR_OK) {
		OH_VideoEncoder_FreeOutputBuffer(codec, index);
		return;
	}

	uint8_t *addr = OH_AVBuffer_GetAddr(buffer);

	if (addr != NULL && attr.size > 0) {
		pthread_mutex_lock(&enc->mutex);

		if ((attr.flags & AVCODEC_BUFFER_FLAGS_CODEC_DATA) != 0) {
			/* SPS/PPS (or VPS/SPS/PPS for HEVC) in Annex B form,
			 * kept for obs_encoder_info.get_extra_data. */
			enc->extra_data.num = 0;
			da_push_back_array(enc->extra_data, addr + attr.offset, (size_t)attr.size);
			blog(LOG_INFO, LOG_PREFIX "received codec config: %d bytes", attr.size);
		} else if ((attr.flags & AVCODEC_BUFFER_FLAGS_EOS) == 0) {
			struct harmony_venc_packet packet;

			da_init(packet.data);
			da_push_back_array(packet.data, addr + attr.offset, (size_t)attr.size);
			packet.pts_ns = attr.pts;
			packet.keyframe = (attr.flags & AVCODEC_BUFFER_FLAGS_SYNC_FRAME) != 0;

			da_push_back(enc->packet_queue, &packet);
		}

		pthread_mutex_unlock(&enc->mutex);
	}

	OH_VideoEncoder_FreeOutputBuffer(codec, index);
}

static bool venc_update_params(struct harmony_venc *enc, obs_data_t *settings)
{
	enc->bitrate = (int)obs_data_get_int(settings, "bitrate");
	enc->keyint_sec = (int)obs_data_get_int(settings, "keyint_sec");

	const char *rate_control = obs_data_get_string(settings, "rate_control");
	if (strcmp(rate_control, "VBR") == 0) {
		enc->rate_control = BITRATE_MODE_VBR;
	} else if (strcmp(rate_control, "CQ") == 0) {
		enc->rate_control = BITRATE_MODE_CQ;
	} else {
		enc->rate_control = BITRATE_MODE_CBR;
	}

	const char *profile = obs_data_get_string(settings, "profile");
	if (enc->hevc) {
		if (strcmp(profile, "main10") == 0)
			enc->profile = HEVC_PROFILE_MAIN_10;
		else
			enc->profile = HEVC_PROFILE_MAIN;
	} else {
		if (strcmp(profile, "baseline") == 0)
			enc->profile = AVC_PROFILE_BASELINE;
		else if (strcmp(profile, "main") == 0)
			enc->profile = AVC_PROFILE_MAIN;
		else
			enc->profile = AVC_PROFILE_HIGH;
	}

	if (enc->bitrate <= 0) {
		blog(LOG_ERROR, LOG_PREFIX "invalid bitrate %d", enc->bitrate);
		return false;
	}

	return true;
}

static GLuint venc_compile_shader(GLenum type, const char *source)
{
	GLuint shader = glCreateShader(type);
	if (shader == 0)
		return 0;

	glShaderSource(shader, 1, &source, NULL);
	glCompileShader(shader);

	GLint status = 0;
	glGetShaderiv(shader, GL_COMPILE_STATUS, &status);
	if (status == 0) {
		GLint log_length = 0;
		glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &log_length);
		if (log_length > 1) {
			char *log_text = bmalloc((size_t)log_length);
			glGetShaderInfoLog(shader, log_length, NULL, log_text);
			blog(LOG_ERROR, LOG_PREFIX "shader compile failed: %s", log_text);
			bfree(log_text);
		}
		glDeleteShader(shader);
		return 0;
	}

	return shader;
}

/* Lazily creates the EGL window surface over the encoder input OHNativeWindow
 * and the blit shader program. Must run on the libobs graphics thread with
 * libobs's GL context current. */
static bool venc_gl_init(struct harmony_venc *enc)
{
	if (!g_master_ready) {
		blog(LOG_ERROR, LOG_PREFIX "master EGL handles not captured yet");
		return false;
	}
	enc->display = g_master_display;

	/* A context private to the encode thread, sharing resources with
	 * libobs's master context (that is what makes the composed texture
	 * name valid here). One thread can only hold one current context,
	 * and the GPU encode thread never had libobs's. */
	const EGLint context_attribs[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
	enc->context = eglCreateContext(enc->display, g_master_config, g_master_context, context_attribs);
	if (enc->context == EGL_NO_CONTEXT) {
		blog(LOG_ERROR, LOG_PREFIX "eglCreateContext(shared) failed: 0x%x", eglGetError());
		return false;
	}

	enc->surface = eglCreateWindowSurface(enc->display, g_master_config, (EGLNativeWindowType)enc->window, NULL);
	if (enc->surface == EGL_NO_SURFACE) {
		blog(LOG_ERROR, LOG_PREFIX "eglCreateWindowSurface failed: 0x%x", eglGetError());
		eglDestroyContext(enc->display, enc->context);
		enc->context = EGL_NO_CONTEXT;
		enc->display = EGL_NO_DISPLAY;
		return false;
	}

	const EGLContext prev = eglGetCurrentContext();
	if (!eglMakeCurrent(enc->display, enc->surface, enc->surface, enc->context)) {
		blog(LOG_ERROR, LOG_PREFIX "eglMakeCurrent(shared ctx) failed: 0x%x", eglGetError());
		eglDestroySurface(enc->display, enc->surface);
		enc->surface = EGL_NO_SURFACE;
		eglDestroyContext(enc->display, enc->context);
		enc->context = EGL_NO_CONTEXT;
		enc->display = EGL_NO_DISPLAY;
		return false;
	}

	const GLuint vertex_shader = venc_compile_shader(GL_VERTEX_SHADER, venc_vertex_shader_src);
	const GLuint fragment_shader = venc_compile_shader(GL_FRAGMENT_SHADER, venc_fragment_shader_src);
	if (vertex_shader == 0 || fragment_shader == 0) {
		if (vertex_shader != 0)
			glDeleteShader(vertex_shader);
		if (fragment_shader != 0)
			glDeleteShader(fragment_shader);
		eglMakeCurrent(enc->display, EGL_NO_SURFACE, EGL_NO_SURFACE, prev);
		return false;
	}

	enc->program = glCreateProgram();
	glAttachShader(enc->program, vertex_shader);
	glAttachShader(enc->program, fragment_shader);
	glLinkProgram(enc->program);
	glDeleteShader(vertex_shader);
	glDeleteShader(fragment_shader);

	GLint status = 0;
	glGetProgramiv(enc->program, GL_LINK_STATUS, &status);
	if (status == 0) {
		blog(LOG_ERROR, LOG_PREFIX "program link failed");
		glDeleteProgram(enc->program);
		enc->program = 0;
		eglMakeCurrent(enc->display, EGL_NO_SURFACE, EGL_NO_SURFACE, prev);
		return false;
	}

	enc->position_location = glGetAttribLocation(enc->program, "a_position");
	enc->texture_location = glGetUniformLocation(enc->program, "u_texture");
	enc->texture_uv_location = glGetUniformLocation(enc->program, "u_texture_uv");

	/* GLES has no client-side vertex arrays: glVertexAttribPointer's
	 * pointer is a byte offset into the bound GL_ARRAY_BUFFER. Upload the
	 * fullscreen triangle once into a small VBO owned by this context. */
	glGenBuffers(1, &enc->vertex_vbo);
	glBindBuffer(GL_ARRAY_BUFFER, enc->vertex_vbo);
	glBufferData(GL_ARRAY_BUFFER, sizeof(venc_fullscreen_vertices), venc_fullscreen_vertices, GL_STATIC_DRAW);
	glBindBuffer(GL_ARRAY_BUFFER, 0);

	/* Leave the shared context unbound; encode_texture2 makes it current
	 * per frame. (On this thread prev is EGL_NO_CONTEXT anyway.) */
	eglMakeCurrent(enc->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);

	enc->gl_ready = true;
	blog(LOG_INFO, LOG_PREFIX "GL input surface ready (%ux%u, shared ctx %p)", enc->width, enc->height,
	     (void *)enc->context);
	return true;
}

/* Blits the libobs-composed texture into the encoder input surface. The whole
 * GL state we touch is saved and restored so libobs's own caches stay valid. */
static bool venc_blit_to_encoder(struct harmony_venc *enc, GLuint texture_id, GLuint uv_id, int64_t pts_ns)
{
	if (!eglMakeCurrent(enc->display, enc->surface, enc->surface, enc->context)) {
		blog(LOG_ERROR, LOG_PREFIX "eglMakeCurrent(encoder surface) failed: 0x%x", eglGetError());
		return false;
	}

	/* Timestamp the buffer so the encoder PTS matches the OBS timebase. */
	OH_NativeWindow_NativeWindowHandleOpt(enc->window, SET_UI_TIMESTAMP, (uint64_t)pts_ns);

	GLint prev_viewport[4] = {0};
	GLint prev_program = 0;
	GLint prev_active_texture = 0;
	GLint prev_texture_binding = 0;
	glGetIntegerv(GL_VIEWPORT, prev_viewport);
	glGetIntegerv(GL_CURRENT_PROGRAM, &prev_program);
	glGetIntegerv(GL_ACTIVE_TEXTURE, &prev_active_texture);
	glGetIntegerv(GL_TEXTURE_BINDING_2D, &prev_texture_binding);

	glViewport(0, 0, (GLsizei)enc->width, (GLsizei)enc->height);
	glUseProgram(enc->program);
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(GL_TEXTURE_2D, texture_id);
	glUniform1i(enc->texture_location, 0);
	if (enc->texture_uv_location >= 0) {
		glActiveTexture(GL_TEXTURE1);
		glBindTexture(GL_TEXTURE_2D, uv_id);
		glUniform1i(enc->texture_uv_location, 1);
	}
	glBindBuffer(GL_ARRAY_BUFFER, enc->vertex_vbo);
	glVertexAttribPointer((GLuint)enc->position_location, 2, GL_FLOAT, GL_FALSE, 0, 0);
	glEnableVertexAttribArray((GLuint)enc->position_location);
	glDrawArrays(GL_TRIANGLES, 0, 3);
	glDisableVertexAttribArray((GLuint)enc->position_location);
	glBindBuffer(GL_ARRAY_BUFFER, 0);
	if (enc->texture_uv_location >= 0) {
		glBindTexture(GL_TEXTURE_2D, 0);
		glActiveTexture(GL_TEXTURE0);
	}

	const bool swapped = eglSwapBuffers(enc->display, enc->surface) == EGL_TRUE;
	if (!swapped)
		blog(LOG_ERROR, LOG_PREFIX "eglSwapBuffers failed: 0x%x", eglGetError());

	glBindTexture(GL_TEXTURE_2D, (GLuint)prev_texture_binding);
	glActiveTexture((GLenum)prev_active_texture);
	glUseProgram((GLuint)prev_program);
	glViewport(prev_viewport[0], prev_viewport[1], (GLsizei)prev_viewport[2], (GLsizei)prev_viewport[3]);

	/* The encode thread had no context current before this frame; leave
	 * it unbound so nothing else can accidentally use it here. */
	if (!eglMakeCurrent(enc->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT))
		blog(LOG_WARNING, LOG_PREFIX "releasing encoder context failed: 0x%x", eglGetError());

	return swapped;
}

static int64_t venc_ns_to_timebase(const struct harmony_venc *enc, int64_t ns)
{
	if (ns <= 0)
		return 0;

	return (int64_t)((uint64_t)ns * enc->fps_num / (1000000000ULL * enc->fps_den));
}

static void venc_destroy(void *data);

static bool venc_encode_texture2(void *data, struct encoder_texture *texture, int64_t pts, uint64_t lock_key,
				 uint64_t *next_key, struct encoder_packet *packet, bool *received_packet)
{
	struct harmony_venc *enc = data;

	/* GL needs no inter-process locking. */
	*next_key = 0;
	*received_packet = false;

	if (enc->failed) {
		blog(LOG_ERROR, LOG_PREFIX "encoder is in a failed state, dropping frame");
		return false;
	}

	if (texture == NULL || texture->tex[0] == NULL) {
		blog(LOG_ERROR, LOG_PREFIX "encode_texture2 called without a source texture");
		return false;
	}

	if (!enc->gl_ready && !venc_gl_init(enc)) {
		enc->failed = true;
		return false;
	}

	const GLuint *tex_obj = (const GLuint *)gs_texture_get_obj(texture->tex[0]);
	if (tex_obj == NULL) {
		blog(LOG_ERROR, LOG_PREFIX "source texture has no GL object");
		return false;
	}
	const GLuint texture_id = *tex_obj;
	if (texture_id == 0) {
		blog(LOG_ERROR, LOG_PREFIX "gs_texture_get_obj returned no GL texture");
		return false;
	}
	GLuint uv_id = 0;
	if (texture->tex[1] != NULL) {
		const GLuint *uv_obj = (const GLuint *)gs_texture_get_obj(texture->tex[1]);
		if (uv_obj != NULL)
			uv_id = *uv_obj;
	}
	if (uv_id == 0) {
		blog(LOG_ERROR, LOG_PREFIX "NV12 UV plane missing (tex[1]=%p)", (void *)texture->tex[1]);
		return false;
	}

	const int64_t pts_ns = (int64_t)((uint64_t)pts * 1000000000ULL * enc->fps_den / enc->fps_num);
	if (!venc_blit_to_encoder(enc, texture_id, uv_id, pts_ns))
		return false;

	pthread_mutex_lock(&enc->mutex);

	if (enc->packet_queue.num == 0) {
		pthread_mutex_unlock(&enc->mutex);
		return true;
	}

	struct harmony_venc_packet queued = enc->packet_queue.array[0];
	da_erase(enc->packet_queue, 0);

	pthread_mutex_unlock(&enc->mutex);

	/* Hardware encoders with no B-frames emit PTS == DTS; clamp to keep
	 * the stream strictly monotonic regardless of clock jitter. */
	int64_t ts = venc_ns_to_timebase(enc, queued.pts_ns);
	if (ts <= enc->last_dts)
		ts = enc->last_dts + 1;
	enc->last_dts = ts;

	enc->current_packet.num = 0;
	da_push_back_array(enc->current_packet, queued.data.array, queued.data.num);
	da_free(queued.data);

	packet->type = OBS_ENCODER_VIDEO;
	packet->data = enc->current_packet.array;
	packet->size = enc->current_packet.num;
	packet->pts = ts;
	packet->dts = ts;
	packet->timebase_num = (int32_t)enc->fps_den;
	packet->timebase_den = (int32_t)enc->fps_num;
	packet->keyframe = queued.keyframe;

	*received_packet = true;

	UNUSED_PARAMETER(lock_key);
	return true;
}

static void *venc_create(obs_data_t *settings, obs_encoder_t *encoder)
{
	struct harmony_venc *enc = bzalloc(sizeof(*enc));

	enc->encoder = encoder;
	enc->display = EGL_NO_DISPLAY;
	enc->surface = EGL_NO_SURFACE;
	enc->hevc = strcmp(obs_encoder_get_codec(encoder), "hevc") == 0;
	pthread_mutex_init(&enc->mutex, NULL);
	da_init(enc->packet_queue);
	da_init(enc->extra_data);
	da_init(enc->current_packet);

	const video_t *video = obs_encoder_video(encoder);
	if (video == NULL) {
		blog(LOG_ERROR, LOG_PREFIX "encoder has no video context");
		goto fail;
	}

	const struct video_output_info *voi = video_output_get_info(video);
	enc->fps_num = voi->fps_num;
	enc->fps_den = voi->fps_den;
	enc->width = obs_encoder_get_width(encoder);
	enc->height = obs_encoder_get_height(encoder);

	if (enc->width == 0 || enc->height == 0 || enc->fps_num == 0 || enc->fps_den == 0) {
		blog(LOG_ERROR, LOG_PREFIX "invalid video geometry %ux%u @ %u/%u", enc->width, enc->height,
		     enc->fps_num, enc->fps_den);
		goto fail;
	}

	if (!venc_update_params(enc, settings))
		goto fail;

	const char *mime = enc->hevc ? OH_AVCODEC_MIMETYPE_VIDEO_HEVC : OH_AVCODEC_MIMETYPE_VIDEO_AVC;
	enc->codec = OH_VideoEncoder_CreateByMime(mime);
	if (enc->codec == NULL) {
		blog(LOG_ERROR, LOG_PREFIX "OH_VideoEncoder_CreateByMime(%s) failed: no hardware encoder?", mime);
		goto fail;
	}

	/* Surface input mode: the encoder pulls frames from its input surface,
	 * so onNeedInputBuffer is never used and stays NULL. */
	const OH_AVCodecCallback callbacks = {
		.onError = venc_on_error,
		.onStreamChanged = venc_on_stream_changed,
		.onNeedInputBuffer = NULL,
		.onNewOutputBuffer = venc_on_new_output,
	};

	if (OH_VideoEncoder_RegisterCallback(enc->codec, callbacks, enc) != AV_ERR_OK) {
		blog(LOG_ERROR, LOG_PREFIX "RegisterCallback failed");
		goto fail;
	}

	OH_AVFormat *format = OH_AVFormat_Create();
	if (format == NULL) {
		blog(LOG_ERROR, LOG_PREFIX "OH_AVFormat_Create failed");
		goto fail;
	}

	/* I-frame interval is milliseconds; clamp a zero/auto keyint to 2 s
	 * since an interval of 0 is rejected by some AVCodec implementations. */
	const int keyint_sec = (enc->keyint_sec > 0) ? enc->keyint_sec : 2;

	OH_AVFormat_SetIntValue(format, OH_MD_KEY_WIDTH, (int32_t)enc->width);
	OH_AVFormat_SetIntValue(format, OH_MD_KEY_HEIGHT, (int32_t)enc->height);
	OH_AVFormat_SetDoubleValue(format, OH_MD_KEY_FRAME_RATE, (double)enc->fps_num / (double)enc->fps_den);
	OH_AVFormat_SetIntValue(format, OH_MD_KEY_BITRATE, enc->bitrate * 1000);
	OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_ENCODE_BITRATE_MODE, enc->rate_control);
	OH_AVFormat_SetIntValue(format, OH_MD_KEY_I_FRAME_INTERVAL, keyint_sec * 1000);
	OH_AVFormat_SetIntValue(format, OH_MD_KEY_PROFILE, enc->profile);

	const OH_AVErrCode configure_result = OH_VideoEncoder_Configure(enc->codec, format);
	OH_AVFormat_Destroy(format);

	if (configure_result != AV_ERR_OK) {
		blog(LOG_ERROR, LOG_PREFIX "Configure failed with %d", (int)configure_result);
		goto fail;
	}

	if (OH_VideoEncoder_Prepare(enc->codec) != AV_ERR_OK) {
		blog(LOG_ERROR, LOG_PREFIX "Prepare failed");
		goto fail;
	}

	if (OH_VideoEncoder_GetSurface(enc->codec, &enc->window) != AV_ERR_OK || enc->window == NULL) {
		blog(LOG_ERROR, LOG_PREFIX "GetSurface failed");
		goto fail;
	}

	OH_NativeWindow_NativeWindowHandleOpt(enc->window, SET_BUFFER_GEOMETRY, (int32_t)enc->width,
					      (int32_t)enc->height);

	if (OH_VideoEncoder_Start(enc->codec) != AV_ERR_OK) {
		blog(LOG_ERROR, LOG_PREFIX "Start failed");
		goto fail;
	}
	enc->started = true;

	/* Capture libobs's master EGL handles on the graphics thread so the
	 * first encode_texture2 can build a sharing context. The callback
	 * runs every render_video, i.e. before any composed texture reaches
	 * the encode queue. */
	if (!g_master_ready)
		obs_add_main_render_callback(venc_capture_master_egl, NULL);

	blog(LOG_INFO, LOG_PREFIX "%s encoder started: %ux%u @ %u/%u fps, %d kbps, mode %d, profile %d, keyint %ds",
	     enc->hevc ? "HEVC" : "H.264", enc->width, enc->height, enc->fps_num, enc->fps_den, enc->bitrate,
	     enc->rate_control, enc->profile, enc->keyint_sec);
	return enc;

fail:
	venc_destroy(enc);
	return NULL;
}

static void venc_destroy(void *data)
{
	struct harmony_venc *enc = data;

	if (enc->codec != NULL) {
		if (enc->started)
			OH_VideoEncoder_Stop(enc->codec);
		OH_VideoEncoder_Destroy(enc->codec);
		enc->codec = NULL;
	}

	if (enc->window != NULL) {
		OH_NativeWindow_DestroyNativeWindow(enc->window);
		enc->window = NULL;
	}

	/* The EGL surface can be destroyed from any thread as long as it is
	 * not current (it never is after encode_texture2 restored libobs's
	 * surface). The GL program object cannot be deleted here because
	 * destroy may run off the graphics thread; it is a single small
	 * program released with the GL context when the app exits. */
	if (enc->display != EGL_NO_DISPLAY && enc->surface != EGL_NO_SURFACE) {
		eglDestroySurface(enc->display, enc->surface);
		enc->surface = EGL_NO_SURFACE;
	}
	if (enc->display != EGL_NO_DISPLAY && enc->context != EGL_NO_CONTEXT) {
		eglDestroyContext(enc->display, enc->context);
		enc->context = EGL_NO_CONTEXT;
	}
	enc->display = EGL_NO_DISPLAY;
	enc->gl_ready = false;

	pthread_mutex_lock(&enc->mutex);

	for (size_t i = 0; i < enc->packet_queue.num; i++)
		da_free(enc->packet_queue.array[i].data);
	da_free(enc->packet_queue);
	da_free(enc->extra_data);
	da_free(enc->current_packet);

	pthread_mutex_unlock(&enc->mutex);
	pthread_mutex_destroy(&enc->mutex);

	bfree(enc);
}

static bool venc_update(void *data, obs_data_t *settings)
{
	struct harmony_venc *enc = data;

	const int new_bitrate = (int)obs_data_get_int(settings, "bitrate");
	if (new_bitrate == enc->bitrate)
		return true;

	enc->bitrate = new_bitrate;
	if (enc->codec == NULL || !enc->started)
		return true;

	OH_AVFormat *format = OH_AVFormat_Create();
	if (format == NULL)
		return false;

	OH_AVFormat_SetIntValue(format, OH_MD_KEY_BITRATE, new_bitrate * 1000);
	const OH_AVErrCode result = OH_VideoEncoder_SetParameter(enc->codec, format);
	OH_AVFormat_Destroy(format);

	if (result != AV_ERR_OK) {
		blog(LOG_WARNING, LOG_PREFIX "dynamic bitrate update to %d kbps failed with %d", new_bitrate,
		     (int)result);
		return false;
	}

	blog(LOG_INFO, LOG_PREFIX "bitrate updated to %d kbps", new_bitrate);
	return true;
}

static bool venc_extra_data(void *data, uint8_t **extra_data, size_t *size)
{
	struct harmony_venc *enc = data;
	bool available = false;

	pthread_mutex_lock(&enc->mutex);

	if (enc->extra_data.num > 0) {
		*extra_data = enc->extra_data.array;
		*size = enc->extra_data.num;
		available = true;
	}

	pthread_mutex_unlock(&enc->mutex);
	return available;
}

static void venc_defaults_h264(obs_data_t *settings)
{
	obs_data_set_default_int(settings, "bitrate", 2500);
	obs_data_set_default_string(settings, "rate_control", "CBR");
	obs_data_set_default_int(settings, "keyint_sec", 2);
	obs_data_set_default_string(settings, "profile", "high");
}

#ifdef ENABLE_HEVC
static void venc_defaults_hevc(obs_data_t *settings)
{
	obs_data_set_default_int(settings, "bitrate", 2500);
	obs_data_set_default_string(settings, "rate_control", "CBR");
	obs_data_set_default_int(settings, "keyint_sec", 2);
	obs_data_set_default_string(settings, "profile", "main");
}
#endif /* ENABLE_HEVC */

static obs_properties_t *venc_properties(bool hevc)
{
	obs_properties_t *props = obs_properties_create();

	obs_properties_add_int(props, "bitrate", obs_module_text("Bitrate"), 100, 1000000, 100);

	obs_property_t *rate_control = obs_properties_add_list(props, "rate_control", obs_module_text("RateControl"),
							       OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_STRING);
	obs_property_list_add_string(rate_control, obs_module_text("RateControl.CBR"), "CBR");
	obs_property_list_add_string(rate_control, obs_module_text("RateControl.VBR"), "VBR");
	obs_property_list_add_string(rate_control, obs_module_text("RateControl.CQ"), "CQ");

	obs_properties_add_int(props, "keyint_sec", obs_module_text("KeyframeIntervalSec"), 0, 20, 1);

	obs_property_t *profile = obs_properties_add_list(props, "profile", obs_module_text("Profile"),
							  OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_STRING);
	if (hevc) {
		obs_property_list_add_string(profile, "main", "main");
		obs_property_list_add_string(profile, "main10", "main10");
	} else {
		obs_property_list_add_string(profile, "high", "high");
		obs_property_list_add_string(profile, "main", "main");
		obs_property_list_add_string(profile, "baseline", "baseline");
	}

	return props;
}

static obs_properties_t *venc_properties_h264(void *data)
{
	UNUSED_PARAMETER(data);
	return venc_properties(false);
}

#ifdef ENABLE_HEVC
static obs_properties_t *venc_properties_hevc(void *data)
{
	UNUSED_PARAMETER(data);
	return venc_properties(true);
}
#endif /* ENABLE_HEVC */

static const char *venc_name_h264(void *unused)
{
	UNUSED_PARAMETER(unused);
	return obs_module_text("HarmonyH264Encoder");
}

#ifdef ENABLE_HEVC
static const char *venc_name_hevc(void *unused)
{
	UNUSED_PARAMETER(unused);
	return obs_module_text("HarmonyHEVCEncoder");
}
#endif /* ENABLE_HEVC */

OBS_DECLARE_MODULE()
OBS_MODULE_USE_DEFAULT_LOCALE("harmony-vcodec", "en-US")

bool obs_module_load(void)
{
	struct obs_encoder_info h264_info = {
		.id = "harmony_h264",
		.type = OBS_ENCODER_VIDEO,
		.codec = "h264",
		.get_name = venc_name_h264,
		.create = venc_create,
		.destroy = venc_destroy,
		.encode_texture2 = venc_encode_texture2,
		.update = venc_update,
		.get_defaults = venc_defaults_h264,
		.get_properties = venc_properties_h264,
		.get_extra_data = venc_extra_data,
		.caps = OBS_ENCODER_CAP_PASS_TEXTURE | OBS_ENCODER_CAP_DYN_BITRATE,
	};
	obs_register_encoder(&h264_info);

#ifdef ENABLE_HEVC
	struct obs_encoder_info hevc_info = h264_info;
	hevc_info.id = "harmony_hevc";
	hevc_info.codec = "hevc";
	hevc_info.get_name = venc_name_hevc;
	hevc_info.get_defaults = venc_defaults_hevc;
	hevc_info.get_properties = venc_properties_hevc;
	obs_register_encoder(&hevc_info);
#endif

	blog(LOG_INFO, "[harmony-vcodec] AVCodec hardware encoders registered");
	return true;
}
