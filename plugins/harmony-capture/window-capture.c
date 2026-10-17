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

    HarmonyOS window capture source, backed by OH_AVScreenCapture in
    OH_CAPTURE_SPECIFIED_WINDOW mode.

    LIMITATION: the window is identified by its mission ID. The NDK does not
    expose any window-enumeration API (verified against
    native_avscreen_capture.h and native_avscreen_capture_base.h in API 26:
    there is no OH_AVScreenCapture_WindowInfo, no GetWindowList, and the
    PresentPicker/OnUserSelected flow only reports the capture *type* and
    display IDs, never the selected window's mission ID). The "window"
    dropdown is therefore populated with the mission ID currently configured
    in settings, and the list is editable so any mission ID can be typed in.
******************************************************************************/

#include "harmony-capture.h"

#include <inttypes.h>

#include <util/dstr.h>
#include <util/platform.h>

#include <multimedia/player_framework/native_avscreen_capture.h>
#include <multimedia/player_framework/native_avscreen_capture_base.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <native_buffer/native_buffer.h>
#include <window_manager/oh_display_manager.h>

#define LOG_PREFIX "[harmony window capture] "

/* Native display resolution via the NDK display manager (window_manager/
 * oh_display_manager.h, API 12+, libnative_display_manager.so). The capture
 * canvas declares this size so the service never scales the window: a
 * window can't exceed the screen, so window->canvas is always identity or
 * downscale-by-the-window-being-small, never a stretch. Desktop OBS gets
 * this for free (its frames ARE the window's pixels); declaring the display
 * size is the closest OHOS equivalent. */
static void harmony_native_display_size(uint32_t *width, uint32_t *height)
{
	int32_t w = 0, h = 0;
	NativeDisplayManager_ErrorCode rw = OH_NativeDisplayManager_GetDefaultDisplayWidth(&w);
	NativeDisplayManager_ErrorCode rh = OH_NativeDisplayManager_GetDefaultDisplayHeight(&h);

	if (rw == DISPLAY_MANAGER_OK && rh == DISPLAY_MANAGER_OK && w > 0 && h > 0) {
		*width = (uint32_t)w;
		*height = (uint32_t)h;
	} else {
		/* Query failed: fall back to the old fixed default. */
		*width = 1920;
		*height = 1080;
	}
	blog(LOG_INFO, LOG_PREFIX "display query: rw=%d rh=%d -> %dx%d (used %ux%u)", (int)rw, (int)rh, w, h,
	     *width, *height);
}

struct harmony_window_capture {
	obs_source_t *source;
	OH_AVScreenCapture *capture;

	int32_t mission_id;
	uint32_t width;  /* current capture canvas: what the service is
			  * producing frames at right now. Owned by create()/
			  * start() (seed) and the content-changed follow; when
			  * follow_window_size is off it mirrors the pinned
			  * settings width/height. */
	uint32_t height;
	int frame_rate;
	bool capture_cursor;

	bool running;
	int32_t selected_type; /* from the picker's user-selection callback */

	/* Desktop-aligned sizing: the capture canvas follows the selected
	 * window's real rect (from the content-changed callback's OH_Rect), so
	 * a frame is the window's own pixels — never a stretched fixed 1080p
	 * and never letterboxed. The callback only records a pending size; the
	 * resize is applied from get_width on OBS's graphics thread.
	 * pin_size (settings bool, default false = follow) gates the follow;
	 * when true, the pinned width/height is the canvas. Named pin_* (not
	 * follow_*) so a source saved before this key existed reads false and
	 * keeps the desktop-aligned follow — obs_data_get_bool defaults missing
	 * keys to false, which is exactly the behaviour we want as the default. */
	uint32_t pending_w;
	uint32_t pending_h;
	bool pending_resize;
	bool pin_size;
};

static const char *window_capture_get_name(void *unused)
{
	UNUSED_PARAMETER(unused);
	return obs_module_text("HarmonyWindowCapture");
}

static enum video_format nativebuffer_format_to_obs(int32_t format)
{
	switch (format) {
	case NATIVEBUFFER_PIXEL_FMT_RGBA_8888:
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

static void window_capture_on_buffer_available(OH_AVScreenCapture *capture, OH_AVBuffer *buffer,
					       OH_AVScreenCaptureBufferType buffer_type, int64_t timestamp,
					       void *user_data)
{
	struct harmony_window_capture *cap = user_data;

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
	 * GPU-usage buffers — same trap as display capture (journey §3.9). */
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

static void window_capture_on_error(OH_AVScreenCapture *capture, int32_t error_code, void *user_data)
{
	struct harmony_window_capture *cap = user_data;

	blog(LOG_ERROR, LOG_PREFIX "capture service reported error %d", error_code);
	cap->running = false;

	UNUSED_PARAMETER(capture);
}

/* Selection callback (API 20): informational only. The capture service
 * applies the user's picker choice to the running instance itself — the C
 * API deliberately exposes no windowId (only type + displayId), and the
 * PresentPicker docs state capture continues "with the newly selected
 * source" after the picker closes. */
static void window_capture_on_user_selected(OH_AVScreenCapture *capture, OH_AVScreenCapture_UserSelectionInfo *selections,
					    void *user_data)
{
	struct harmony_window_capture *cap = user_data;
	int32_t type = -1;
	OH_AVScreenCapture_GetCaptureTypeSelected(selections, &type);
	cap->selected_type = type;
	blog(LOG_INFO, LOG_PREFIX "user selected capture type %d (0=screen 1=window 2=app)", type);

	UNUSED_PARAMETER(capture);
}

/* Content-changed callback (API 20): the event-driven equivalent of desktop
 * OBS's GetClientRect resize poll. `area` is the captured window's real rect
 * in px. We only STASH it here — this runs on the capture service's callback
 * thread, and calling ResizeCanvas back into the service from there is an
 * unverified re-entrancy risk. The actual resize is applied from
 * window_capture_get_width below, which OBS calls on its own graphics thread
 * (the desktop pattern: react to the size event on the consumer's thread). */
static void window_capture_on_content_changed(OH_AVScreenCapture *capture,
					      OH_AVScreenCaptureContentChangedEvent event, OH_Rect *area,
					      void *user_data)
{
	struct harmony_window_capture *cap = user_data;

	if (event == OH_SCREEN_CAPTURE_CONTENT_VISIBLE && area != NULL && !cap->pin_size) {
		const uint32_t w = (uint32_t)(area->width > 0 ? area->width : 0);
		const uint32_t h = (uint32_t)(area->height > 0 ? area->height : 0);
		if (w && h && (w != cap->width || h != cap->height)) {
			cap->pending_w = w;
			cap->pending_h = h;
			cap->pending_resize = true;
		}
	}

	UNUSED_PARAMETER(capture);
}

static void window_capture_on_state_change(OH_AVScreenCapture *capture, OH_AVScreenCaptureStateCode state_code,
					   void *user_data)
{
	struct harmony_window_capture *cap = user_data;

	switch (state_code) {
	case OH_SCREEN_CAPTURE_STATE_STARTED:
		cap->running = true;
		blog(LOG_INFO, LOG_PREFIX "window capture started by user");
		break;
	case OH_SCREEN_CAPTURE_STATE_CANCELED:
		cap->running = false;
		blog(LOG_WARNING, LOG_PREFIX "window capture canceled by user");
		break;
	case OH_SCREEN_CAPTURE_STATE_STOPPED_BY_USER:
	case OH_SCREEN_CAPTURE_STATE_INTERRUPTED_BY_OTHER:
	case OH_SCREEN_CAPTURE_STATE_STOPPED_BY_CALL:
	case OH_SCREEN_CAPTURE_STATE_STOPPED_BY_USER_SWITCHES:
		cap->running = false;
		blog(LOG_WARNING, LOG_PREFIX "window capture stopped externally (state %d)", (int)state_code);
		break;
	default:
		break;
	}

	UNUSED_PARAMETER(capture);
}

static void window_capture_stop(struct harmony_window_capture *cap)
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

static bool window_capture_start(struct harmony_window_capture *cap)
{
	/* mission_id == 0 is a first-class mode, not an error: the official
	 * C flow (avscreencapture-c-basic-process) documents that an empty
	 * missionIDs list makes the system show its own window-selection
	 * Picker — the user picks the window there and capture starts after
	 * confirmation (state callback OH_SCREEN_CAPTURE_STATE_STARTED).
	 * A configured mission ID merely pre-selects that window in the
	 * Picker. Either way the user always confirms; there is no silent
	 * window capture. */

	OH_AVScreenCaptureConfig config = {0};
	int32_t mission_ids[1] = {cap->mission_id};

	config.captureMode = OH_CAPTURE_SPECIFIED_WINDOW;
	config.dataType = OH_ORIGINAL_STREAM;

	/* Video-only capture: mark both audio sources invalid so the service
	 * never opens a microphone or inner-capture channel for this source. */
	/* Video-only: the channel is ignored only when BOTH sample rate and
	 * channels are 0; non-zero geometry with OH_SOURCE_INVALID makes Init
	 * fail with OPERATE_NOT_PERMIT. See display-capture.c. */
	config.audioInfo.micCapInfo.audioSampleRate = 0;
	config.audioInfo.micCapInfo.audioChannels = 0;
	config.audioInfo.micCapInfo.audioSource = OH_SOURCE_INVALID;
	config.audioInfo.innerCapInfo.audioSampleRate = 0;
	config.audioInfo.innerCapInfo.audioChannels = 0;
	config.audioInfo.innerCapInfo.audioSource = OH_SOURCE_INVALID;
	config.audioInfo.audioEncInfo.audioBitrate = 0;
	config.audioInfo.audioEncInfo.audioCodecformat = OH_AUDIO_DEFAULT;

	config.videoInfo.videoCapInfo.displayId = 0;
	if (cap->mission_id > 0) {
		config.videoInfo.videoCapInfo.missionIDs = mission_ids;
		config.videoInfo.videoCapInfo.missionIDsLen = 1;
	} else {
		/* empty list -> system window Picker */
		config.videoInfo.videoCapInfo.missionIDs = NULL;
		config.videoInfo.videoCapInfo.missionIDsLen = 0;
	}
	config.videoInfo.videoCapInfo.videoFrameWidth = (int32_t)cap->width;
	config.videoInfo.videoCapInfo.videoFrameHeight = (int32_t)cap->height;
	config.videoInfo.videoCapInfo.videoSource = OH_VIDEO_SOURCE_SURFACE_RGBA;
	config.videoInfo.videoEncInfo.videoCodec = OH_VIDEO_DEFAULT;
	config.videoInfo.videoEncInfo.videoBitrate = 0;
	config.videoInfo.videoEncInfo.videoFrameRate = cap->frame_rate;

	OH_AVSCREEN_CAPTURE_ErrCode err = OH_AVScreenCapture_SetErrorCallback(cap->capture, window_capture_on_error,
									      cap);
	if (err != AV_SCREEN_CAPTURE_ERR_OK) {
		blog(LOG_ERROR, LOG_PREFIX "SetErrorCallback failed with %d", (int)err);
		return false;
	}

	err = OH_AVScreenCapture_SetStateCallback(cap->capture, window_capture_on_state_change, cap);
	if (err != AV_SCREEN_CAPTURE_ERR_OK) {
		blog(LOG_ERROR, LOG_PREFIX "SetStateCallback failed with %d", (int)err);
		return false;
	}

	err = OH_AVScreenCapture_SetDataCallback(cap->capture, window_capture_on_buffer_available, cap);
	if (err != AV_SCREEN_CAPTURE_ERR_OK) {
		blog(LOG_ERROR, LOG_PREFIX "SetDataCallback failed with %d", (int)err);
		return false;
	}

	/* Content-changed drives the desktop-style "canvas = window size"
	 * follow. Must be registered before Start (API 20). */
	err = OH_AVScreenCapture_SetCaptureContentChangedCallback(cap->capture, window_capture_on_content_changed, cap);
	if (err != AV_SCREEN_CAPTURE_ERR_OK)
		blog(LOG_WARNING, LOG_PREFIX "SetCaptureContentChangedCallback failed with %d (canvas stays fixed)",
		     (int)err);

	/* Must be registered before the authorization flow starts (header
	 * docs, API 20). */
	err = OH_AVScreenCapture_SetSelectionCallback(cap->capture, window_capture_on_user_selected, cap);
	if (err != AV_SCREEN_CAPTURE_ERR_OK)
		blog(LOG_WARNING, LOG_PREFIX "SetSelectionCallback failed with %d (continuing)", (int)err);

	/* mission 0 = "let the user choose a window". The official mechanism
	 * is the capture strategy's PickerPopUp switch (API 20): "If set to
	 * True, the Picker will pop up uniformly after screen capture
	 * starts". Must be set before Start. (PresentPicker is only for
	 * re-showing the picker DURING an active capture and returns
	 * OPERATE_NOT_PERMIT outside that state — verified on device.) */
	if (cap->mission_id <= 0) {
		OH_AVScreenCapture_CaptureStrategy *strategy = OH_AVScreenCapture_CreateCaptureStrategy();
		if (strategy != NULL) {
			OH_AVScreenCapture_StrategyForPickerPopUp(strategy, true);
			err = OH_AVScreenCapture_SetCaptureStrategy(cap->capture, strategy);
			if (err != AV_SCREEN_CAPTURE_ERR_OK)
				blog(LOG_WARNING, LOG_PREFIX "SetCaptureStrategy failed with %d", (int)err);
			OH_AVScreenCapture_ReleaseCaptureStrategy(strategy);
		} else {
			blog(LOG_WARNING, LOG_PREFIX "CreateCaptureStrategy returned NULL");
		}
	}

	err = OH_AVScreenCapture_Init(cap->capture, config);
	if (err != AV_SCREEN_CAPTURE_ERR_OK) {
		blog(LOG_ERROR, LOG_PREFIX "Init failed with %d (is mission %d still alive?)", (int)err,
		     cap->mission_id);
		return false;
	}

	OH_AVScreenCapture_ShowCursor(cap->capture, cap->capture_cursor);
	OH_AVScreenCapture_SetMaxVideoFrameRate(cap->capture, cap->frame_rate);

	err = OH_AVScreenCapture_StartScreenCapture(cap->capture);
	if (err != AV_SCREEN_CAPTURE_ERR_OK) {
		blog(LOG_ERROR, LOG_PREFIX "StartScreenCapture failed with %d", (int)err);
		return false;
	}

	/* Safety net: if the PickerPopUp strategy did not surface a picker
	 * (selection callback never fired), try the dynamic-update entry
	 * point once. */
	if (cap->mission_id <= 0) {
		err = OH_AVScreenCapture_PresentPicker(cap->capture);
		if (err != AV_SCREEN_CAPTURE_ERR_OK)
			blog(LOG_WARNING, LOG_PREFIX "PresentPicker fallback failed with %d", (int)err);
	}

	blog(LOG_INFO, LOG_PREFIX "capture started (mission %d, %ux%u @ %d fps)", cap->mission_id, cap->width,
	     cap->height, cap->frame_rate);
	return true;
}

static int32_t parse_mission_id(const char *window)
{
	if (window == NULL || *window == '\0')
		return 0;

	return (int32_t)strtol(window, NULL, 10);
}

static void window_capture_update_internal(struct harmony_window_capture *cap, obs_data_t *settings, bool restart)
{
	cap->mission_id = parse_mission_id(obs_data_get_string(settings, "window"));
	cap->pin_size = obs_data_get_bool(settings, "pin_size");

	const uint32_t pin_w = (uint32_t)obs_data_get_int(settings, "width");
	const uint32_t pin_h = (uint32_t)obs_data_get_int(settings, "height");
	if (cap->pin_size && pin_w > 0 && pin_h > 0) {
		cap->width = pin_w;
		cap->height = pin_h;
	} else {
		/* follow mode (or an incomplete pin): seed the canvas at the
		 * native display so the very first frames are never a
		 * stretched 1080p; the content-changed callback then narrows
		 * it to the window's real rect. */
		cap->pin_size = false;
		harmony_native_display_size(&cap->width, &cap->height);
	}
	cap->frame_rate = (int)obs_data_get_int(settings, "frame_rate");
	cap->capture_cursor = obs_data_get_bool(settings, "capture_cursor");

	if (cap->capture == NULL)
		return;

	OH_AVScreenCapture_ShowCursor(cap->capture, cap->capture_cursor);
	OH_AVScreenCapture_SetMaxVideoFrameRate(cap->capture, cap->frame_rate);

	if (restart && cap->running) {
		window_capture_stop(cap);
		if (!window_capture_start(cap))
			blog(LOG_ERROR, LOG_PREFIX "failed to restart capture after settings change");
	} else if (restart && cap->width > 0 && cap->height > 0) {
		OH_AVScreenCapture_ResizeCanvas(cap->capture, (int32_t)cap->width, (int32_t)cap->height);
	}
}

static void *window_capture_create(obs_data_t *settings, obs_source_t *source)
{
	struct harmony_window_capture *cap = bzalloc(sizeof(*cap));

	cap->source = source;
	cap->selected_type = -1; /* 0 is a valid picker result (screen) */
	cap->capture = OH_AVScreenCapture_Create();

	if (cap->capture == NULL) {
		blog(LOG_ERROR, LOG_PREFIX "OH_AVScreenCapture_Create failed");
		bfree(cap);
		return NULL;
	}

	window_capture_update_internal(cap, settings, false);
	return cap;
}

static void window_capture_destroy(void *data)
{
	struct harmony_window_capture *cap = data;

	window_capture_stop(cap);

	if (cap->capture != NULL) {
		/* The NDK pairs OH_AVScreenCapture_Create with _Release; there
		 * is no OH_AVScreenCapture_Destroy. */
		OH_AVScreenCapture_Release(cap->capture);
		cap->capture = NULL;
	}

	bfree(cap);
}

/* Apply a window-rect change the content-changed callback stashed. Runs on
 * OBS's graphics thread (get_* path) rather than the capture service's event
 * thread, so we never re-enter the service from its own callback. ResizeCanvas
 * is a lightweight dimension-set, not the heavy synchronous teardown that made
 * the audio-start IPC an ANR risk, so one call here is acceptable; it is also
 * guarded to fire at most once per observed change. */
static void window_capture_apply_pending_resize(struct harmony_window_capture *cap)
{
	if (!cap->pending_resize)
		return;

	const uint32_t w = cap->pending_w;
	const uint32_t h = cap->pending_h;
	cap->pending_resize = false;

	if (w == 0 || h == 0 || (w == cap->width && h == cap->height))
		return;

	const OH_AVSCREEN_CAPTURE_ErrCode err = OH_AVScreenCapture_ResizeCanvas(cap->capture, (int32_t)w, (int32_t)h);
	if (err == AV_SCREEN_CAPTURE_ERR_OK) {
		cap->width = w;
		cap->height = h;
		blog(LOG_INFO, LOG_PREFIX "canvas followed window rect -> %ux%u", w, h);
	} else {
		blog(LOG_WARNING, LOG_PREFIX "ResizeCanvas to %ux%u failed with %d (canvas stays %ux%u)", w, h,
		     (int)err, cap->width, cap->height);
	}
}

static uint32_t window_capture_get_width(void *data)
{
	struct harmony_window_capture *cap = data;
	window_capture_apply_pending_resize(cap);
	return cap->width;
}

static uint32_t window_capture_get_height(void *data)
{
	struct harmony_window_capture *cap = data;
	return cap->height;
}

static void window_capture_get_defaults(obs_data_t *settings)
{
	obs_data_set_default_string(settings, "window", "");
	/* Default is follow mode: pin_size false, width/height 0. The canvas
	 * seeds at the native display and then tracks the window's real rect
	 * (content-changed callback) — the desktop-aligned behaviour. Pinning
	 * a fixed size is opt-in via the properties checkbox. */
	obs_data_set_default_int(settings, "width", 0);
	obs_data_set_default_int(settings, "height", 0);
	obs_data_set_default_bool(settings, "pin_size", false);
	obs_data_set_default_int(settings, "frame_rate", 30);
	obs_data_set_default_bool(settings, "capture_cursor", false);
}

static obs_properties_t *window_capture_get_properties(void *data)
{
	struct harmony_window_capture *cap = data;

	obs_properties_t *props = obs_properties_create();

	/* See the LIMITATION note at the top of this file: the NDK has no
	 * window enumeration, so the dropdown can only offer mission IDs that
	 * are already known (i.e. the one currently configured). The list is
	 * editable so the user can type any mission ID. */
	obs_property_t *window_list =
		obs_properties_add_list(props, "window", obs_module_text("WindowCapture.Window"),
					OBS_COMBO_TYPE_EDITABLE, OBS_COMBO_FORMAT_STRING);

	if (cap != NULL && cap->mission_id > 0) {
		struct dstr label = {0};
		struct dstr value = {0};

		dstr_printf(&label, "Mission %d", cap->mission_id);
		dstr_printf(&value, "%d", cap->mission_id);
		obs_property_list_add_string(window_list, label.array, value.array);

		dstr_free(&label);
		dstr_free(&value);
	}

	obs_properties_add_bool(props, "pin_size", obs_module_text("PinCaptureSize"));
	obs_properties_add_int(props, "width", obs_module_text("CaptureWidth"), 16, 8192, 1);
	obs_properties_add_int(props, "height", obs_module_text("CaptureHeight"), 16, 8192, 1);
	obs_properties_add_int(props, "frame_rate", obs_module_text("FrameRate"), 1, 120, 1);
	obs_properties_add_bool(props, "capture_cursor", obs_module_text("CaptureCursor"));

	return props;
}

static void window_capture_update(void *data, obs_data_t *settings)
{
	struct harmony_window_capture *cap = data;

	const int32_t old_mission_id = cap->mission_id;
	const bool old_pin = cap->pin_size;
	const uint32_t old_width = cap->width;
	const uint32_t old_height = cap->height;

	const int32_t new_mission_id = parse_mission_id(obs_data_get_string(settings, "window"));
	const bool new_pin = obs_data_get_bool(settings, "pin_size");
	uint32_t new_width = (uint32_t)obs_data_get_int(settings, "width");
	uint32_t new_height = (uint32_t)obs_data_get_int(settings, "height");
	if (!new_pin || new_width == 0 || new_height == 0)
		harmony_native_display_size(&new_width, &new_height);

	/* Restart only on a genuine source change. In follow mode the canvas
	 * moves on its own via the callback, so a width/height delta there is
	 * not a user edit and must not re-prompt the picker; only a mission
	 * change or a pin<->follow / pinned-size change warrants a restart. */
	const bool size_changed = (new_pin != old_pin) || (new_pin && (new_width != old_width || new_height != old_height));
	const bool needs_restart = (new_mission_id != old_mission_id) || size_changed;

	window_capture_update_internal(cap, settings, needs_restart);
}

static void window_capture_activate(void *data)
{
	struct harmony_window_capture *cap = data;

	if (cap->running)
		return;

	if (!window_capture_start(cap))
		blog(LOG_ERROR, LOG_PREFIX "failed to start capture on activation");
}

static void window_capture_deactivate(void *data)
{
	struct harmony_window_capture *cap = data;

	window_capture_stop(cap);
}

struct obs_source_info harmony_window_capture_info = {
	.id = "harmony_window_capture",
	.type = OBS_SOURCE_TYPE_INPUT,
	.output_flags = OBS_SOURCE_ASYNC_VIDEO,
	.get_name = window_capture_get_name,
	.create = window_capture_create,
	.destroy = window_capture_destroy,
	.get_width = window_capture_get_width,
	.get_height = window_capture_get_height,
	.get_defaults = window_capture_get_defaults,
	.get_properties = window_capture_get_properties,
	.update = window_capture_update,
	.activate = window_capture_activate,
	.deactivate = window_capture_deactivate,
};
