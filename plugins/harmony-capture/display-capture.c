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

    HarmonyOS display capture source, backed by the OH_AVScreenCapture NDK
    API in raw (OH_ORIGINAL_STREAM) buffer mode.

    Frames arrive through OH_AVScreenCapture_SetDataCallback as OH_NativeBuffer
    objects and are CPU-mapped (OH_NativeBuffer_Map*) into an obs_source_frame.
    A zero-copy path exists via OH_NativeImage + GL_TEXTURE_EXTERNAL_OES, but
    it requires "#extension GL_OES_EGL_image_external" in GLSL, which libobs's
    shader parser does not emit; it is intentionally left as a follow-up.
******************************************************************************/

#include "harmony-capture.h"

#include <inttypes.h>

#include <util/platform.h>

#include <multimedia/player_framework/native_avscreen_capture.h>
#include <multimedia/player_framework/native_avscreen_capture_base.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <native_buffer/native_buffer.h>

#define LOG_PREFIX "[harmony display capture] "

struct harmony_display_capture {
	obs_source_t *source;
	OH_AVScreenCapture *capture;

	uint64_t display_id;
	uint32_t width;
	uint32_t height;
	int frame_rate;
	bool capture_cursor;

	bool running;
};

static const char *display_capture_get_name(void *unused)
{
	UNUSED_PARAMETER(unused);
	return obs_module_text("HarmonyDisplayCapture");
}

static enum video_format nativebuffer_format_to_obs(int32_t format)
{
	switch (format) {
	case NATIVEBUFFER_PIXEL_FMT_RGBA_8888:
		/* The capture service leaves the alpha byte undefined;
		 * copy_packed_frame forces it to 0xFF (see there). */
		return VIDEO_FORMAT_RGBA;
	case NATIVEBUFFER_PIXEL_FMT_RGBX_8888:
		/* X padding is 0xFF in practice; libobs has no RGBX format. */
		return VIDEO_FORMAT_RGBA;
	case NATIVEBUFFER_PIXEL_FMT_BGRA_8888:
		return VIDEO_FORMAT_BGRA;
	case NATIVEBUFFER_PIXEL_FMT_BGRX_8888:
		return VIDEO_FORMAT_BGRX;
	case NATIVEBUFFER_PIXEL_FMT_YCBCR_420_SP:
		return VIDEO_FORMAT_NV12;
	default:
		return VIDEO_FORMAT_NONE;
	}
}

static bool copy_packed_frame(struct obs_source_frame *frame, const uint8_t *src, int32_t src_stride)
{
	const uint32_t src_row_bytes = (uint32_t)src_stride;

	if (src_row_bytes < frame->linesize[0]) {
		blog(LOG_ERROR, LOG_PREFIX "buffer stride %u smaller than frame linesize %u", src_row_bytes,
		     frame->linesize[0]);
		return false;
	}

	for (uint32_t row = 0; row < frame->height; row++)
		memcpy(frame->data[0] + (size_t)row * frame->linesize[0], src + (size_t)row * src_row_bytes,
		       frame->linesize[0]);

	/* The capture service leaves the alpha byte undefined; libobs blends
	 * with premultiplied alpha so a zero alpha makes the source fully
	 * transparent (black preview). Force opaque. */
	if (frame->format == VIDEO_FORMAT_RGBA || frame->format == VIDEO_FORMAT_BGRX ||
	    frame->format == VIDEO_FORMAT_BGRA) {
		for (uint32_t row = 0; row < frame->height; row++) {
			uint8_t *d = frame->data[0] + (size_t)row * frame->linesize[0];
			for (uint32_t col = 3; col < frame->width * 4; col += 4)
				d[col] = 0xFF;
		}
	}

	return true;
}

static bool copy_nv12_frame(struct obs_source_frame *frame, OH_NativeBuffer *buffer)
{
	OH_NativeBuffer_Planes planes = {0};
	void *addr = NULL;

	if (OH_NativeBuffer_MapPlanes(buffer, &addr, &planes) != 0) {
		blog(LOG_ERROR, LOG_PREFIX "failed to map NV12 planes");
		return false;
	}

	if (planes.planeCount < 2) {
		blog(LOG_ERROR, LOG_PREFIX "unexpected NV12 plane count %" PRIu32, planes.planeCount);
		OH_NativeBuffer_Unmap(buffer);
		return false;
	}

	const uint8_t *base = (const uint8_t *)addr;

	for (uint32_t plane = 0; plane < 2; plane++) {
		const uint8_t *src = base + planes.planes[plane].offset;
		const uint32_t src_row_bytes = planes.planes[plane].rowStride;
		const uint32_t plane_height = (plane == 0) ? frame->height : frame->height / 2;

		if (src_row_bytes < frame->linesize[plane]) {
			blog(LOG_ERROR, LOG_PREFIX "plane %" PRIu32 " stride %u smaller than linesize %u", plane,
			     src_row_bytes, frame->linesize[plane]);
			OH_NativeBuffer_Unmap(buffer);
			return false;
		}

		for (uint32_t row = 0; row < plane_height; row++)
			memcpy(frame->data[plane] + (size_t)row * frame->linesize[plane],
			       src + (size_t)row * src_row_bytes, frame->linesize[plane]);
	}

	OH_NativeBuffer_Unmap(buffer);
	return true;
}

static void display_capture_on_buffer_available(OH_AVScreenCapture *capture, OH_AVBuffer *buffer,
						OH_AVScreenCaptureBufferType buffer_type, int64_t timestamp,
						void *user_data)
{
	struct harmony_display_capture *cap = user_data;

	if (buffer_type != OH_SCREEN_CAPTURE_BUFFERTYPE_VIDEO || buffer == NULL)
		return;

	OH_NativeBuffer *native_buffer = OH_AVBuffer_GetNativeBuffer(buffer);
	if (native_buffer == NULL) {
		blog(LOG_ERROR, LOG_PREFIX "video buffer has no native buffer");
		return;
	}

	OH_NativeBuffer_Config config = {0};
	OH_NativeBuffer_GetConfig(native_buffer, &config);

	/* CPU address straight from the AVBuffer (official sample path).
	 * MapAndGetConfig on the NativeBuffer can yield an all-zero view for
	 * GPU-usage buffers. */
	const uint8_t *pixels = (const uint8_t *)OH_AVBuffer_GetAddr(buffer);

	const enum video_format format = nativebuffer_format_to_obs(config.format);
	if (format == VIDEO_FORMAT_NONE) {
		blog(LOG_WARNING, LOG_PREFIX "unsupported native buffer pixel format %d, dropping frame",
		     config.format);
		return;
	}

	struct obs_source_frame *frame = obs_source_frame_create(format, (uint32_t)config.width,
								 (uint32_t)config.height);
	if (frame == NULL)
		return;

	/* AVScreenCapture timestamps are CLOCK_MONOTONIC nanoseconds, the same
	 * clock os_gettime_ns() uses, so they can be passed through directly. */
	frame->timestamp = (timestamp > 0) ? (uint64_t)timestamp : os_gettime_ns();

	bool copied = false;
	if (format == VIDEO_FORMAT_NV12) {
		copied = copy_nv12_frame(frame, native_buffer);
	} else if (pixels != NULL) {
		copied = copy_packed_frame(frame, pixels, config.stride);
	}

	if (copied)
		obs_source_output_video(cap->source, frame);

	obs_source_frame_destroy(frame);

	UNUSED_PARAMETER(capture);
}

static void display_capture_on_error(OH_AVScreenCapture *capture, int32_t error_code, void *user_data)
{
	struct harmony_display_capture *cap = user_data;

	blog(LOG_ERROR, LOG_PREFIX "capture service reported error %d", error_code);
	cap->running = false;

	UNUSED_PARAMETER(capture);
}

static void display_capture_on_state_change(OH_AVScreenCapture *capture, OH_AVScreenCaptureStateCode state_code,
					    void *user_data)
{
	struct harmony_display_capture *cap = user_data;

	switch (state_code) {
	case OH_SCREEN_CAPTURE_STATE_STARTED:
		cap->running = true;
		blog(LOG_INFO, LOG_PREFIX "screen capture started by user");
		break;
	case OH_SCREEN_CAPTURE_STATE_CANCELED:
		cap->running = false;
		blog(LOG_WARNING, LOG_PREFIX "screen capture canceled by user");
		break;
	case OH_SCREEN_CAPTURE_STATE_STOPPED_BY_USER:
	case OH_SCREEN_CAPTURE_STATE_INTERRUPTED_BY_OTHER:
	case OH_SCREEN_CAPTURE_STATE_STOPPED_BY_CALL:
	case OH_SCREEN_CAPTURE_STATE_STOPPED_BY_USER_SWITCHES:
		cap->running = false;
		blog(LOG_WARNING, LOG_PREFIX "screen capture stopped externally (state %d)", (int)state_code);
		break;
	default:
		break;
	}

	UNUSED_PARAMETER(capture);
}

static void display_capture_stop(struct harmony_display_capture *cap)
{
	if (cap->capture == NULL)
		return;

	if (cap->running) {
		const OH_AVSCREEN_CAPTURE_ErrCode err = OH_AVScreenCapture_StopScreenCapture(cap->capture);
		if (err != AV_SCREEN_CAPTURE_ERR_OK)
			blog(LOG_WARNING, LOG_PREFIX "StopScreenCapture failed with %d", (int)err);
	}

	cap->running = false;
}

static bool display_capture_start(struct harmony_display_capture *cap)
{
	OH_AVScreenCaptureConfig config = {0};

	config.captureMode = OH_CAPTURE_SPECIFIED_SCREEN;
	config.dataType = OH_ORIGINAL_STREAM;

	/* Video-only capture. The NDK contract is explicit: an audio channel
	 * is ignored only when BOTH audioSampleRate and audioChannels are 0.
	 * A non-zero geometry with OH_SOURCE_INVALID is a contradictory
	 * request — the service tries to open a channel with no source and
	 * OH_AVScreenCapture_Init fails with OPERATE_NOT_PERMIT ("The
	 * configuration fails to be initialized"). */
	config.audioInfo.micCapInfo.audioSampleRate = 0;
	config.audioInfo.micCapInfo.audioChannels = 0;
	config.audioInfo.micCapInfo.audioSource = OH_SOURCE_INVALID;
	config.audioInfo.innerCapInfo.audioSampleRate = 0;
	config.audioInfo.innerCapInfo.audioChannels = 0;
	config.audioInfo.innerCapInfo.audioSource = OH_SOURCE_INVALID;
	config.audioInfo.audioEncInfo.audioBitrate = 0;
	config.audioInfo.audioEncInfo.audioCodecformat = OH_AUDIO_DEFAULT;

	config.videoInfo.videoCapInfo.displayId = cap->display_id;
	config.videoInfo.videoCapInfo.missionIDs = NULL;
	config.videoInfo.videoCapInfo.missionIDsLen = 0;
	config.videoInfo.videoCapInfo.videoFrameWidth = (int32_t)cap->width;
	config.videoInfo.videoCapInfo.videoFrameHeight = (int32_t)cap->height;
	config.videoInfo.videoCapInfo.videoSource = OH_VIDEO_SOURCE_SURFACE_RGBA;
	config.videoInfo.videoEncInfo.videoCodec = OH_VIDEO_DEFAULT;
	config.videoInfo.videoEncInfo.videoBitrate = 0;
	config.videoInfo.videoEncInfo.videoFrameRate = cap->frame_rate;

	OH_AVSCREEN_CAPTURE_ErrCode err = OH_AVScreenCapture_SetErrorCallback(cap->capture,
									      display_capture_on_error, cap);
	if (err != AV_SCREEN_CAPTURE_ERR_OK) {
		blog(LOG_ERROR, LOG_PREFIX "SetErrorCallback failed with %d", (int)err);
		return false;
	}

	err = OH_AVScreenCapture_SetStateCallback(cap->capture, display_capture_on_state_change, cap);
	if (err != AV_SCREEN_CAPTURE_ERR_OK) {
		blog(LOG_ERROR, LOG_PREFIX "SetStateCallback failed with %d", (int)err);
		return false;
	}

	err = OH_AVScreenCapture_SetDataCallback(cap->capture, display_capture_on_buffer_available, cap);
	if (err != AV_SCREEN_CAPTURE_ERR_OK) {
		blog(LOG_ERROR, LOG_PREFIX "SetDataCallback failed with %d", (int)err);
		return false;
	}

	err = OH_AVScreenCapture_Init(cap->capture, config);
	if (err != AV_SCREEN_CAPTURE_ERR_OK) {
		blog(LOG_ERROR, LOG_PREFIX "Init failed with %d", (int)err);
		return false;
	}

	OH_AVScreenCapture_ShowCursor(cap->capture, cap->capture_cursor);
	OH_AVScreenCapture_SetMaxVideoFrameRate(cap->capture, cap->frame_rate);

	err = OH_AVScreenCapture_StartScreenCapture(cap->capture);
	if (err != AV_SCREEN_CAPTURE_ERR_OK) {
		blog(LOG_ERROR, LOG_PREFIX "StartScreenCapture failed with %d", (int)err);
		return false;
	}

	blog(LOG_INFO, LOG_PREFIX "capture started (%ux%u @ %d fps, display %" PRIu64 ")", cap->width, cap->height,
	     cap->frame_rate, cap->display_id);
	return true;
}

static void display_capture_update_internal(struct harmony_display_capture *cap, obs_data_t *settings, bool restart)
{
	cap->display_id = (uint64_t)obs_data_get_int(settings, "display_id");
	cap->width = (uint32_t)obs_data_get_int(settings, "width");
	cap->height = (uint32_t)obs_data_get_int(settings, "height");
	cap->frame_rate = (int)obs_data_get_int(settings, "frame_rate");
	cap->capture_cursor = obs_data_get_bool(settings, "capture_cursor");

	if (cap->capture == NULL)
		return;

	/* Cursor visibility and frame rate can be changed on a live capture. */
	OH_AVScreenCapture_ShowCursor(cap->capture, cap->capture_cursor);
	OH_AVScreenCapture_SetMaxVideoFrameRate(cap->capture, cap->frame_rate);

	if (restart && cap->running) {
		display_capture_stop(cap);
		if (!display_capture_start(cap))
			blog(LOG_ERROR, LOG_PREFIX "failed to restart capture after settings change");
	} else if (restart && cap->width > 0 && cap->height > 0) {
		OH_AVScreenCapture_ResizeCanvas(cap->capture, (int32_t)cap->width, (int32_t)cap->height);
	}
}

static void *display_capture_create(obs_data_t *settings, obs_source_t *source)
{
	struct harmony_display_capture *cap = bzalloc(sizeof(*cap));

	cap->source = source;
	cap->capture = OH_AVScreenCapture_Create();

	if (cap->capture == NULL) {
		blog(LOG_ERROR, LOG_PREFIX "OH_AVScreenCapture_Create failed");
		bfree(cap);
		return NULL;
	}

	display_capture_update_internal(cap, settings, false);
	return cap;
}

static void display_capture_destroy(void *data)
{
	struct harmony_display_capture *cap = data;

	display_capture_stop(cap);

	if (cap->capture != NULL) {
		/* The NDK pairs OH_AVScreenCapture_Create with _Release; there
		 * is no OH_AVScreenCapture_Destroy. */
		OH_AVScreenCapture_Release(cap->capture);
		cap->capture = NULL;
	}

	bfree(cap);
}

static uint32_t display_capture_get_width(void *data)
{
	struct harmony_display_capture *cap = data;
	return cap->width;
}

static uint32_t display_capture_get_height(void *data)
{
	struct harmony_display_capture *cap = data;
	return cap->height;
}

static void display_capture_get_defaults(obs_data_t *settings)
{
	/* The NDK exposes no display-metrics API to query the physical screen
	 * resolution (no native_display_manager header exists in the sysroot),
	 * so the canvas size is a user setting that defaults to 1080p. */
	obs_data_set_default_int(settings, "display_id", 0);
	obs_data_set_default_int(settings, "width", 1920);
	obs_data_set_default_int(settings, "height", 1080);
	obs_data_set_default_int(settings, "frame_rate", 30);
	obs_data_set_default_bool(settings, "capture_cursor", true);
}

static obs_properties_t *display_capture_get_properties(void *data)
{
	UNUSED_PARAMETER(data);

	obs_properties_t *props = obs_properties_create();

	obs_properties_add_int(props, "display_id", obs_module_text("DisplayID"), 0, 15, 1);
	obs_properties_add_int(props, "width", obs_module_text("CaptureWidth"), 16, 8192, 1);
	obs_properties_add_int(props, "height", obs_module_text("CaptureHeight"), 16, 8192, 1);
	obs_properties_add_int(props, "frame_rate", obs_module_text("FrameRate"), 1, 120, 1);
	obs_properties_add_bool(props, "capture_cursor", obs_module_text("CaptureCursor"));

	/* Showing content of privacy-protected windows is not offered: the
	 * only NDK hook, OH_AVScreenCapture_SkipPrivacyMode, requires the IDs
	 * of windows owned by the calling application, which a generic capture
	 * source does not have. */

	return props;
}

static void display_capture_update(void *data, obs_data_t *settings)
{
	struct harmony_display_capture *cap = data;

	const uint64_t old_display_id = cap->display_id;
	const uint32_t old_width = cap->width;
	const uint32_t old_height = cap->height;

	const uint64_t new_display_id = (uint64_t)obs_data_get_int(settings, "display_id");
	const uint32_t new_width = (uint32_t)obs_data_get_int(settings, "width");
	const uint32_t new_height = (uint32_t)obs_data_get_int(settings, "height");

	const bool needs_restart = (new_display_id != old_display_id) ||
				   (new_width != old_width) || (new_height != old_height);

	display_capture_update_internal(cap, settings, needs_restart);
}

static void display_capture_activate(void *data)
{
	struct harmony_display_capture *cap = data;

	if (cap->running)
		return;

	if (!display_capture_start(cap))
		blog(LOG_ERROR, LOG_PREFIX "failed to start capture on activation");
}

static void display_capture_deactivate(void *data)
{
	struct harmony_display_capture *cap = data;

	display_capture_stop(cap);
}

struct obs_source_info harmony_display_capture_info = {
	.id = "harmony_display_capture",
	.type = OBS_SOURCE_TYPE_INPUT,
	.output_flags = OBS_SOURCE_ASYNC_VIDEO,
	.get_name = display_capture_get_name,
	.create = display_capture_create,
	.destroy = display_capture_destroy,
	.get_width = display_capture_get_width,
	.get_height = display_capture_get_height,
	.get_defaults = display_capture_get_defaults,
	.get_properties = display_capture_get_properties,
	.update = display_capture_update,
	.activate = display_capture_activate,
	.deactivate = display_capture_deactivate,
};
