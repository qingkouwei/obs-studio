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

    HarmonyOS camera capture source, backed by the Camera Kit NDK API
    (libohcamera.so, verified against the API 26 sysroot headers in
    ohcamera/).

    Pipeline: Camera_Manager -> Camera_Input (open) -> CaptureSession in
    NORMAL_VIDEO mode with a single VideoOutput whose surface is produced by
    an OH_ImageReceiverNative (Image Kit, libimage_receiver.so). Frames arrive
    through OH_ImageReceiverNative_OnImageArrive, are read back to the CPU via
    OH_ImageNative_GetByteBuffer + OH_NativeBuffer_MapPlanes and pushed with
    obs_source_output_video(), the same readback approach
    plugins/harmony-capture/display-capture.c uses for OH_NativeBuffer.

    Requires ohos.permission.CAMERA (user_grant). Without it
    OH_CameraInput_Open fails with CAMERA_OPERATION_NOT_ALLOWED, which is
    logged clearly and leaves the source inactive instead of crashing.

    LIMITATION: the Camera Kit NDK error callbacks (OH_CameraInput_OnError,
    OH_CaptureSession_OnError, OH_VideoOutput_OnError) take no user-data
    pointer, so errors are attributed through a file-static pointer to the
    most recently started capture instance. Only the error *logging* is
    affected; frame delivery uses OH_ImageReceiverNative_OnImageArrive, which
    does carry user data.
******************************************************************************/

#include "harmony-camera.h"

#include <inttypes.h>
#include <pthread.h>
#include <stdio.h>

#include <util/dstr.h>
#include <util/platform.h>

#include <ohcamera/camera.h>
#include <ohcamera/camera_input.h>
#include <ohcamera/camera_manager.h>
#include <ohcamera/capture_session.h>
#include <ohcamera/video_output.h>
#include <multimedia/image_framework/image/image_receiver_native.h>
#include <native_buffer/native_buffer.h>

#define LOG_PREFIX "[harmony camera capture] "

/* Number of frames the image receiver may buffer before dropping. */
#define RECEIVER_CAPACITY 8

struct harmony_camera_capture {
	obs_source_t *source;
	pthread_mutex_t frame_mutex;

	Camera_Manager *manager;
	Camera_Input *input;
	Camera_CaptureSession *session;
	Camera_VideoOutput *video_output;
	OH_ImageReceiverOptions *receiver_options;
	OH_ImageReceiverNative *receiver;

	/* Settings. */
	char device_id[64];
	char resolution[32];
	int frame_rate;
	int32_t camera_format; /* Camera_Format */

	/* Negotiated from the device's video profiles when starting. */
	Camera_VideoProfile profile;
	uint32_t width;
	uint32_t height;

	bool running;
};

/* See LIMITATION note in the file header. */
static struct harmony_camera_capture *volatile g_active_capture = NULL;

static const char *camera_capture_get_name(void *unused)
{
	UNUSED_PARAMETER(unused);
	return obs_module_text("HarmonyCameraCapture");
}

static const char *camera_position_to_string(Camera_Position position)
{
	switch (position) {
	case CAMERA_POSITION_BACK:
		return "Back";
	case CAMERA_POSITION_FRONT:
		return "Front";
	default:
		return "Unspecified";
	}
}

static const char *camera_type_to_string(Camera_Type type)
{
	switch (type) {
	case CAMERA_TYPE_WIDE_ANGLE:
		return "wide angle";
	case CAMERA_TYPE_ULTRA_WIDE:
		return "ultra wide";
	case CAMERA_TYPE_TELEPHOTO:
		return "telephoto";
	case CAMERA_TYPE_TRUE_DEPTH:
		return "true depth";
	default:
		return "default";
	}
}

static const char *camera_format_to_string(Camera_Format format)
{
	switch (format) {
	case CAMERA_FORMAT_YUV_420_SP:
		return "YUV 420 SP (NV12)";
	case CAMERA_FORMAT_RGBA_8888:
		return "RGBA 8888";
	case CAMERA_FORMAT_YCBCR_P010:
		return "YCbCr P010";
	case CAMERA_FORMAT_YCRCB_P010:
		return "YCrCb P010";
	default:
		return "Unknown";
	}
}

/* ------------------------------------------------------------------------ */
/* Device and capability discovery                                          */
/* ------------------------------------------------------------------------ */

static bool camera_capture_ensure_manager(struct harmony_camera_capture *cap)
{
	if (cap->manager != NULL)
		return true;

	Camera_ErrorCode err = OH_Camera_GetCameraManager(&cap->manager);
	if (err != CAMERA_OK || cap->manager == NULL) {
		blog(LOG_ERROR, LOG_PREFIX "OH_Camera_GetCameraManager failed with %d", (int)err);
		cap->manager = NULL;
		return false;
	}

	return true;
}

/* Finds a camera device by its ID string, falling back to the first camera
 * when device_id is empty or unknown. *out is filled with a copy whose
 * cameraId points into id_buf, so the caller stays valid after the device
 * list is released. */
static bool camera_capture_find_device(Camera_Manager *manager, const char *device_id, Camera_Device *out,
				       char *id_buf, size_t id_buf_size)
{
	Camera_Device *cameras = NULL;
	uint32_t size = 0;

	Camera_ErrorCode err = OH_CameraManager_GetSupportedCameras(manager, &cameras, &size);
	if (err != CAMERA_OK || cameras == NULL || size == 0) {
		blog(LOG_ERROR, LOG_PREFIX "GetSupportedCameras failed with %d (%" PRIu32 " cameras)", (int)err, size);
		return false;
	}

	const Camera_Device *found = NULL;
	/* "@remote" is a sentinel, not an id: the Service Collaboration
	 * cross-device camera (the phone camera mounted into this device's
	 * Camera Kit under the same account) shows up as a regular entry
	 * with CAMERA_CONNECTION_REMOTE. Pick it preferentially; a plain
	 * first-camera fallback keeps the knock-from-future flow working
	 * even when the remote mount is not up (yet). */
	const bool want_remote = device_id != NULL && strcmp(device_id, "@remote") == 0;
	const Camera_Device *remote = NULL;
	for (uint32_t i = 0; i < size; i++) {
		const Camera_Device *camera = &cameras[i];
		if (camera->cameraId == NULL)
			continue;
		if (device_id != NULL && device_id[0] != '\0' && !want_remote &&
		    strcmp(camera->cameraId, device_id) == 0) {
			found = camera;
			break;
		}
		if (want_remote && camera->connectionType == CAMERA_CONNECTION_REMOTE) {
			remote = camera;
			break;
		}
		if (found == NULL)
			found = camera;
	}
	if (want_remote && remote != NULL) {
		blog(LOG_INFO, LOG_PREFIX "selected remote (cross-device) camera '%s'", remote->cameraId);
		found = remote;
	} else if (want_remote) {
		blog(LOG_WARNING, LOG_PREFIX "no CAMERA_CONNECTION_REMOTE device present, falling back to first camera");
	}

	if (found == NULL) {
		blog(LOG_ERROR, LOG_PREFIX "no usable camera in list of %" PRIu32, size);
		OH_CameraManager_DeleteSupportedCameras(manager, cameras, size);
		return false;
	}

	snprintf(id_buf, id_buf_size, "%s", found->cameraId);
	out->cameraId = id_buf;
	out->cameraPosition = found->cameraPosition;
	out->cameraType = found->cameraType;
	out->connectionType = found->connectionType;

	if (!want_remote && device_id != NULL && device_id[0] != '\0' && strcmp(device_id, id_buf) != 0)
		blog(LOG_WARNING, LOG_PREFIX "camera '%s' not found, falling back to '%s'", device_id, id_buf);

	OH_CameraManager_DeleteSupportedCameras(manager, cameras, size);
	return true;
}

/* Queries the video output capability of a device. Prefers the NORMAL_VIDEO
 * scene mode (the session runs in that mode) and falls back to the plain
 * capability query. On success *capability must be released with
 * OH_CameraManager_DeleteSupportedCameraOutputCapability(). */
static bool camera_capture_get_capability(Camera_Manager *manager, const Camera_Device *device,
					  Camera_OutputCapability **capability)
{
	Camera_ErrorCode err =
		OH_CameraManager_GetSupportedCameraOutputCapabilityWithSceneMode(manager, device, NORMAL_VIDEO,
										 capability);
	if (err != CAMERA_OK || *capability == NULL) {
		err = OH_CameraManager_GetSupportedCameraOutputCapability(manager, device, capability);
		if (err != CAMERA_OK || *capability == NULL) {
			blog(LOG_ERROR, LOG_PREFIX "GetSupportedCameraOutputCapability failed with %d", (int)err);
			return false;
		}
	}

	return true;
}

/* Picks the video profile that best matches the requested format and size:
 * exact match wins, then size match, then format match, then first profile. */
static bool camera_capture_select_profile(Camera_OutputCapability *capability, int32_t want_format, uint32_t want_width,
					  uint32_t want_height, Camera_VideoProfile *out)
{
	const Camera_VideoProfile *exact = NULL;
	const Camera_VideoProfile *size_match = NULL;
	const Camera_VideoProfile *format_match = NULL;
	const Camera_VideoProfile *first = NULL;

	for (uint32_t i = 0; i < capability->videoProfilesSize; i++) {
		const Camera_VideoProfile *profile = capability->videoProfiles[i];
		if (profile == NULL)
			continue;

		const bool size_ok = (profile->size.width == want_width) && (profile->size.height == want_height);
		const bool format_ok = (want_format == 0) || ((int32_t)profile->format == want_format);

		if (first == NULL)
			first = profile;
		if (size_ok && format_ok && exact == NULL)
			exact = profile;
		if (size_ok && size_match == NULL)
			size_match = profile;
		if (format_ok && format_match == NULL)
			format_match = profile;
	}

	const Camera_VideoProfile *chosen = exact ? exact : (size_match ? size_match : (format_match ? format_match
													       : first));
	if (chosen == NULL) {
		blog(LOG_ERROR, LOG_PREFIX "camera exposes %" PRIu32 " video profiles, none usable",
		     capability->videoProfilesSize);
		return false;
	}

	if (!exact)
		blog(LOG_WARNING, LOG_PREFIX "no video profile for %ux%u format %d, using %ux%u format %d instead",
		     want_width, want_height, want_format, chosen->size.width, chosen->size.height,
		     (int)chosen->format);

	*out = *chosen;
	return true;
}

/* ------------------------------------------------------------------------ */
/* Frame readback and delivery                                              */
/* ------------------------------------------------------------------------ */

static enum video_format nativebuffer_format_to_obs(int32_t format, bool *swap_chroma)
{
	*swap_chroma = false;

	switch (format) {
	case NATIVEBUFFER_PIXEL_FMT_YCBCR_420_SP:
		return VIDEO_FORMAT_NV12;
	case NATIVEBUFFER_PIXEL_FMT_YCRCB_420_SP:
		/* NV21-style semi-planar with Cr first; libobs has no NV21
		 * format, so the interleaved chroma bytes are swapped into
		 * NV12 order while copying. */
		*swap_chroma = true;
		return VIDEO_FORMAT_NV12;
	case NATIVEBUFFER_PIXEL_FMT_RGBA_8888:
		return VIDEO_FORMAT_RGBA;
	case NATIVEBUFFER_PIXEL_FMT_RGBX_8888:
		/* X padding is 0xFF in practice; libobs has no RGBX format. */
		return VIDEO_FORMAT_RGBA;
	case NATIVEBUFFER_PIXEL_FMT_BGRA_8888:
		return VIDEO_FORMAT_BGRA;
	case NATIVEBUFFER_PIXEL_FMT_BGRX_8888:
		return VIDEO_FORMAT_BGRX;
	default:
		return VIDEO_FORMAT_NONE;
	}
}

static int32_t camera_format_to_nativebuffer(Camera_Format format)
{
	switch (format) {
	case CAMERA_FORMAT_YUV_420_SP:
		return NATIVEBUFFER_PIXEL_FMT_YCBCR_420_SP;
	case CAMERA_FORMAT_RGBA_8888:
		return NATIVEBUFFER_PIXEL_FMT_RGBA_8888;
	default:
		return NATIVEBUFFER_PIXEL_FMT_BUTT;
	}
}

/* Row stride for one component of the image, as reported by the Image Kit
 * itself. OH_NativeBuffer_MapPlanes() fills rowStride for AVScreenCapture
 * buffers but returns garbage (stride 1) for ImageReceiver/camera buffers —
 * the journey §3.9 class of "buffer metadata lies". OH_ImageNative_GetRowStride
 * is the authoritative source for these frames; fall back to the buffer
 * config stride, then to the untightened width, if the query fails. */
static uint32_t image_row_stride(OH_ImageNative *image, OH_NativeBuffer *buffer, uint32_t component_type,
				 uint32_t fallback)
{
	int32_t stride = 0;
	if (OH_ImageNative_GetRowStride(image, component_type, &stride) == IMAGE_SUCCESS &&
	    (uint32_t)stride >= fallback)
		return (uint32_t)stride;

	OH_NativeBuffer_Config cfg = {0};
	OH_NativeBuffer_GetConfig(buffer, &cfg);
	if (cfg.stride >= (int32_t)fallback)
		return (uint32_t)cfg.stride;

	return fallback;
}

/* NV12 -> RGBA on the CPU. libobs' async multi-plane path uploads NV12 as
 * GL_R8 + GL_RG16 textures, which the Maleoon GLES driver rejects during the
 * colour-conversion draw (GL_INVALID_FRAMEBUFFER_OPERATION per frame -> the
 * source renders black). The packed RGBA upload path is the one proven on
 * this device by display-capture, so convert here and hand libobs a
 * VIDEO_FORMAT_RGBA frame. BT.709 limited-range coefficients scaled x256;
 * the output is flagged full-range because we expand by hand. */
static bool copy_nv12_to_rgba(struct obs_source_frame *frame, OH_ImageNative *image, uint32_t component_type,
			      bool swap_chroma)
{
	OH_NativeBuffer *buffer = NULL;
	if (OH_ImageNative_GetByteBuffer(image, component_type, &buffer) != IMAGE_SUCCESS || buffer == NULL) {
		blog(LOG_ERROR, LOG_PREFIX "GetByteBuffer failed for NV12 component");
		return false;
	}

	void *addr = NULL;
	if (OH_NativeBuffer_Map(buffer, &addr) != 0 || addr == NULL) {
		blog(LOG_ERROR, LOG_PREFIX "failed to map NV12 buffer");
		return false;
	}

	const uint8_t *base = (const uint8_t *)addr;
	const uint32_t stride_y = image_row_stride(image, buffer, component_type, frame->width);
	const uint8_t *chroma = base + (size_t)stride_y * frame->height;

	for (uint32_t row = 0; row + 1 < frame->height; row += 2) {
		const uint8_t *y0 = base + (size_t)row * stride_y;
		const uint8_t *y1 = base + (size_t)(row + 1) * stride_y;
		const uint8_t *cv = chroma + (size_t)(row / 2) * stride_y;
		uint8_t *o0 = frame->data[0] + (size_t)row * frame->linesize[0];
		uint8_t *o1 = frame->data[0] + (size_t)(row + 1) * frame->linesize[0];

		for (uint32_t col = 0; col + 1 < frame->width; col += 2) {
			int32_t cb = (int32_t)(swap_chroma ? cv[col + 1] : cv[col]) - 128;
			int32_t cr = (int32_t)(swap_chroma ? cv[col] : cv[col + 1]) - 128;

			for (int sub = 0; sub < 4; sub++) {
				const uint32_t sx = col + (sub & 1);
				const uint8_t *ys = (sub & 2) ? y1 : y0;
				int32_t yy = (int32_t)ys[sx];
				int32_t yc = 298 * (yy - 16);
				int32_t r = (yc + 459 * cr) >> 8;
				int32_t g = (yc - 55 * cb - 137 * cr) >> 8;
				int32_t b = (yc + 541 * cb) >> 8;
				uint8_t *px = ((sub & 2) ? o1 : o0) + (size_t)sx * 4;
				px[0] = (uint8_t)(r < 0 ? 0 : r > 255 ? 255 : r);
				px[1] = (uint8_t)(g < 0 ? 0 : g > 255 ? 255 : g);
				px[2] = (uint8_t)(b < 0 ? 0 : b > 255 ? 255 : b);
				px[3] = 0xFF;
			}
		}
	}

	/* Odd bottom row (height not divisible by 2): duplicate last line. */
	if (frame->height & 1) {
		const uint8_t *src = frame->data[0] + (size_t)(frame->height - 2) * frame->linesize[0];
		memcpy(frame->data[0] + (size_t)(frame->height - 1) * frame->linesize[0], src, frame->linesize[0]);
	}

	frame->full_range = true;
	OH_NativeBuffer_Unmap(buffer);
	return true;
}

static bool copy_packed_frame(struct obs_source_frame *frame, OH_ImageNative *image, uint32_t component_type)
{
	OH_NativeBuffer *buffer = NULL;
	if (OH_ImageNative_GetByteBuffer(image, component_type, &buffer) != IMAGE_SUCCESS || buffer == NULL) {
		blog(LOG_ERROR, LOG_PREFIX "GetByteBuffer failed for packed component");
		return false;
	}

	void *addr = NULL;
	if (OH_NativeBuffer_Map(buffer, &addr) != 0 || addr == NULL) {
		blog(LOG_ERROR, LOG_PREFIX "failed to map packed buffer");
		return false;
	}

	const uint8_t *src = (const uint8_t *)addr;
	const uint32_t src_row_bytes = image_row_stride(image, buffer, component_type, frame->linesize[0]);

	bool ok = true;
	if (src_row_bytes < frame->linesize[0]) {
		blog(LOG_ERROR, LOG_PREFIX "buffer stride %u smaller than frame linesize %u", src_row_bytes,
		     frame->linesize[0]);
		ok = false;
	} else {
		for (uint32_t row = 0; row < frame->height; row++)
			memcpy(frame->data[0] + (size_t)row * frame->linesize[0], src + (size_t)row * src_row_bytes,
			       frame->linesize[0]);
		/* Force opaque alpha (premultiplied-blend fix, journey §3.10)
		 * for formats that carry an alpha byte. */
		if (frame->format == VIDEO_FORMAT_RGBA || frame->format == VIDEO_FORMAT_BGRA) {
			for (uint32_t row = 0; row < frame->height; row++) {
				uint8_t *px = frame->data[0] + (size_t)row * frame->linesize[0];
				for (uint32_t col = 3; col < frame->width * 4; col += 4)
					px[col] = 0xFF;
			}
		}
	}

	OH_NativeBuffer_Unmap(buffer);
	return ok;
}

static void camera_capture_on_image_arrive(OH_ImageReceiverNative *receiver, void *user_data)
{
	struct harmony_camera_capture *cap = user_data;

	pthread_mutex_lock(&cap->frame_mutex);

	if (!cap->running) {
		pthread_mutex_unlock(&cap->frame_mutex);
		return;
	}

	OH_ImageNative *image = NULL;
	if (OH_ImageReceiverNative_ReadLatestImage(receiver, &image) != IMAGE_SUCCESS || image == NULL) {
		blog(LOG_WARNING, LOG_PREFIX "ReadLatestImage failed");
		pthread_mutex_unlock(&cap->frame_mutex);
		return;
	}

	Image_Size size = {0};
	if (OH_ImageNative_GetImageSize(image, &size) != IMAGE_SUCCESS || size.width == 0 || size.height == 0) {
		size.width = cap->width;
		size.height = cap->height;
	}

	int64_t timestamp = 0;
	OH_ImageNative_GetTimestamp(image, &timestamp);

	uint32_t *component_types = NULL;
	size_t type_size = 0;

	if (OH_ImageNative_GetComponentTypes(image, NULL, &type_size) != IMAGE_SUCCESS || type_size == 0) {
		blog(LOG_WARNING, LOG_PREFIX "GetComponentTypes failed");
		goto image_done;
	}

	component_types = bmalloc(type_size * sizeof(uint32_t));
	if (OH_ImageNative_GetComponentTypes(image, &component_types, &type_size) != IMAGE_SUCCESS) {
		blog(LOG_WARNING, LOG_PREFIX "GetComponentTypes (fill) failed");
		goto image_done;
	}

	/* Prefer the buffer's own format; OH_ImageNative_GetFormat is API 23+,
	 * so fall back to the negotiated profile format if it is unavailable
	 * or fails. */
	int32_t buffer_format = camera_format_to_nativebuffer(cap->profile.format);
	OH_NativeBuffer_Format image_format = NATIVEBUFFER_PIXEL_FMT_BUTT;
	if (OH_ImageNative_GetFormat(image, &image_format) == IMAGE_SUCCESS)
		buffer_format = (int32_t)image_format;

	bool swap_chroma = false;
	const enum video_format format = nativebuffer_format_to_obs(buffer_format, &swap_chroma);
	if (format == VIDEO_FORMAT_NONE) {
		blog(LOG_WARNING, LOG_PREFIX "unsupported camera buffer format %d, dropping frame", buffer_format);
		goto image_done;
	}

	/* NV12 is converted to RGBA on the CPU (see copy_nv12_to_rgba), so the
	 * frame handed to libobs is always a packed format. */
	const enum video_format out_format = (format == VIDEO_FORMAT_NV12) ? VIDEO_FORMAT_RGBA : format;
	struct obs_source_frame *frame = obs_source_frame_create(out_format, size.width, size.height);
	if (frame == NULL)
		goto image_done;

	const bool copied = (format == VIDEO_FORMAT_NV12) ? copy_nv12_to_rgba(frame, image, component_types[0], swap_chroma)
							  : copy_packed_frame(frame, image, component_types[0]);

	/* Image receiver timestamps are CLOCK_MONOTONIC nanoseconds, the same
	 * clock os_gettime_ns() uses, so they can be passed through directly. */
	frame->timestamp = (timestamp > 0) ? (uint64_t)timestamp : os_gettime_ns();

	if (copied)
		obs_source_output_video(cap->source, frame);

	obs_source_frame_destroy(frame);

image_done:
	bfree(component_types);
	OH_ImageNative_Release(image);
	pthread_mutex_unlock(&cap->frame_mutex);
}

/* ------------------------------------------------------------------------ */
/* Error callbacks (no user-data pointer in the NDK signatures; see the      */
/* LIMITATION note in the file header)                                       */
/* ------------------------------------------------------------------------ */

static void camera_capture_on_input_error(const Camera_Input *input, Camera_ErrorCode error_code)
{
	struct harmony_camera_capture *cap = g_active_capture;

	if (error_code == CAMERA_DEVICE_PREEMPTED)
		blog(LOG_WARNING, LOG_PREFIX "camera input preempted by a higher-priority app (%d)", (int)error_code);
	else
		blog(LOG_ERROR, LOG_PREFIX "camera input error %d", (int)error_code);

	if (cap != NULL)
		cap->running = false;

	UNUSED_PARAMETER(input);
}

static void camera_capture_on_session_error(Camera_CaptureSession *session, Camera_ErrorCode error_code)
{
	struct harmony_camera_capture *cap = g_active_capture;

	blog(LOG_ERROR, LOG_PREFIX "capture session error %d", (int)error_code);

	if (cap != NULL)
		cap->running = false;

	UNUSED_PARAMETER(session);
}

static void camera_capture_on_session_focus_state(Camera_CaptureSession *session, Camera_FocusState focus_state)
{
	blog(LOG_DEBUG, LOG_PREFIX "focus state changed to %d", (int)focus_state);
	UNUSED_PARAMETER(session);
}

static void camera_capture_on_video_error(Camera_VideoOutput *video_output, Camera_ErrorCode error_code)
{
	struct harmony_camera_capture *cap = g_active_capture;

	blog(LOG_ERROR, LOG_PREFIX "video output error %d", (int)error_code);

	if (cap != NULL)
		cap->running = false;

	UNUSED_PARAMETER(video_output);
}

static void camera_capture_on_frame_start(Camera_VideoOutput *video_output)
{
	blog(LOG_DEBUG, LOG_PREFIX "video output frame start");
	UNUSED_PARAMETER(video_output);
}

static void camera_capture_on_frame_end(Camera_VideoOutput *video_output, int32_t frame_count)
{
	blog(LOG_DEBUG, LOG_PREFIX "video output frame end (count %d)", frame_count);
	UNUSED_PARAMETER(video_output);
}

static CameraInput_Callbacks camera_input_callbacks = {
	.onError = camera_capture_on_input_error,
};

static CaptureSession_Callbacks capture_session_callbacks = {
	.onFocusStateChange = camera_capture_on_session_focus_state,
	.onError = camera_capture_on_session_error,
};

static VideoOutput_Callbacks video_output_callbacks = {
	.onFrameStart = camera_capture_on_frame_start,
	.onFrameEnd = camera_capture_on_frame_end,
	.onError = camera_capture_on_video_error,
};

/* ------------------------------------------------------------------------ */
/* Start / stop                                                             */
/* ------------------------------------------------------------------------ */

/* Tears the whole pipeline down in reverse creation order. Must be called
 * with frame_mutex held. */
static void camera_capture_teardown(struct harmony_camera_capture *cap)
{
	if (g_active_capture == cap)
		g_active_capture = NULL;

	if (cap->running) {
		if (cap->video_output != NULL) {
			Camera_ErrorCode err = OH_VideoOutput_Stop(cap->video_output);
			if (err != CAMERA_OK)
				blog(LOG_WARNING, LOG_PREFIX "OH_VideoOutput_Stop failed with %d", (int)err);
		}
		if (cap->session != NULL) {
			Camera_ErrorCode err = OH_CaptureSession_Stop(cap->session);
			if (err != CAMERA_OK)
				blog(LOG_WARNING, LOG_PREFIX "OH_CaptureSession_Stop failed with %d", (int)err);
		}
		cap->running = false;
	}

	if (cap->receiver != NULL)
		OH_ImageReceiverNative_OffImageArrive(cap->receiver, camera_capture_on_image_arrive);

	if (cap->session != NULL) {
		OH_CaptureSession_UnregisterCallback(cap->session, &capture_session_callbacks);
		OH_CaptureSession_Release(cap->session);
		cap->session = NULL;
	}

	if (cap->video_output != NULL) {
		OH_VideoOutput_UnregisterCallback(cap->video_output, &video_output_callbacks);
		OH_VideoOutput_Release(cap->video_output);
		cap->video_output = NULL;
	}

	if (cap->input != NULL) {
		OH_CameraInput_UnregisterCallback(cap->input, &camera_input_callbacks);
		OH_CameraInput_Close(cap->input);
		OH_CameraInput_Release(cap->input);
		cap->input = NULL;
	}

	if (cap->receiver != NULL) {
		OH_ImageReceiverNative_Release(cap->receiver);
		cap->receiver = NULL;
	}

	if (cap->receiver_options != NULL) {
		OH_ImageReceiverOptions_Release(cap->receiver_options);
		cap->receiver_options = NULL;
	}

	obs_source_output_video(cap->source, NULL);
}

static bool camera_capture_start(struct harmony_camera_capture *cap)
{
	pthread_mutex_lock(&cap->frame_mutex);

	if (cap->running) {
		pthread_mutex_unlock(&cap->frame_mutex);
		return true;
	}

	camera_capture_teardown(cap);

	if (!camera_capture_ensure_manager(cap))
		goto fail;

	Camera_Device device = {0};
	char device_id_buf[64];
	if (!camera_capture_find_device(cap->manager, cap->device_id, &device, device_id_buf, sizeof(device_id_buf)))
		goto fail;

	uint32_t want_width = 0;
	uint32_t want_height = 0;
	if (sscanf(cap->resolution, "%ux%u", &want_width, &want_height) != 2) {
		blog(LOG_WARNING, LOG_PREFIX "invalid resolution '%s', using device default", cap->resolution);
		want_width = 0;
		want_height = 0;
	}

	Camera_OutputCapability *capability = NULL;
	if (!camera_capture_get_capability(cap->manager, &device, &capability))
		goto fail;

	const bool have_profile =
		camera_capture_select_profile(capability, cap->camera_format, want_width, want_height, &cap->profile);
	OH_CameraManager_DeleteSupportedCameraOutputCapability(cap->manager, capability);
	if (!have_profile)
		goto fail;

	cap->width = cap->profile.size.width;
	cap->height = cap->profile.size.height;

	Camera_ErrorCode err = OH_CameraManager_CreateCameraInput(cap->manager, &device, &cap->input);
	if (err != CAMERA_OK || cap->input == NULL) {
		blog(LOG_ERROR, LOG_PREFIX "CreateCameraInput failed with %d", (int)err);
		goto fail;
	}

	OH_CameraInput_RegisterCallback(cap->input, &camera_input_callbacks);

	err = OH_CameraInput_Open(cap->input);
	if (err != CAMERA_OK) {
		if (err == CAMERA_OPERATION_NOT_ALLOWED)
			blog(LOG_ERROR,
			     LOG_PREFIX "OH_CameraInput_Open denied: ohos.permission.CAMERA has not been granted");
		else if (err == CAMERA_CONFLICT_CAMERA)
			blog(LOG_ERROR, LOG_PREFIX "OH_CameraInput_Open failed: camera is in use by another app");
		else
			blog(LOG_ERROR, LOG_PREFIX "OH_CameraInput_Open failed with %d", (int)err);
		goto fail;
	}

	Image_ErrorCode img_err = OH_ImageReceiverOptions_Create(&cap->receiver_options);
	if (img_err != IMAGE_SUCCESS || cap->receiver_options == NULL) {
		blog(LOG_ERROR, LOG_PREFIX "OH_ImageReceiverOptions_Create failed with %d", (int)img_err);
		goto fail;
	}

	const Image_Size receiver_size = {.width = cap->width, .height = cap->height};
	OH_ImageReceiverOptions_SetSize(cap->receiver_options, receiver_size);
	OH_ImageReceiverOptions_SetCapacity(cap->receiver_options, RECEIVER_CAPACITY);

	img_err = OH_ImageReceiverNative_Create(cap->receiver_options, &cap->receiver);
	if (img_err != IMAGE_SUCCESS || cap->receiver == NULL) {
		blog(LOG_ERROR, LOG_PREFIX "OH_ImageReceiverNative_Create failed with %d", (int)img_err);
		goto fail;
	}

	uint64_t surface_id = 0;
	img_err = OH_ImageReceiverNative_GetReceivingSurfaceId(cap->receiver, &surface_id);
	if (img_err != IMAGE_SUCCESS) {
		blog(LOG_ERROR, LOG_PREFIX "GetReceivingSurfaceId failed with %d", (int)img_err);
		goto fail;
	}

	char surface_id_str[21];
	snprintf(surface_id_str, sizeof(surface_id_str), "%" PRIu64, surface_id);

	err = OH_CameraManager_CreateVideoOutput(cap->manager, &cap->profile, surface_id_str, &cap->video_output);
	if (err != CAMERA_OK || cap->video_output == NULL) {
		blog(LOG_ERROR, LOG_PREFIX "CreateVideoOutput failed with %d", (int)err);
		goto fail;
	}

	OH_VideoOutput_RegisterCallback(cap->video_output, &video_output_callbacks);

	img_err = OH_ImageReceiverNative_OnImageArrive(cap->receiver, camera_capture_on_image_arrive, cap);
	if (img_err != IMAGE_SUCCESS) {
		blog(LOG_ERROR, LOG_PREFIX "OnImageArrive failed with %d", (int)img_err);
		goto fail;
	}

	err = OH_CameraManager_CreateCaptureSession(cap->manager, &cap->session);
	if (err != CAMERA_OK || cap->session == NULL) {
		blog(LOG_ERROR, LOG_PREFIX "CreateCaptureSession failed with %d", (int)err);
		goto fail;
	}

	/* SetSessionMode must run before BeginConfig. */
	err = OH_CaptureSession_SetSessionMode(cap->session, NORMAL_VIDEO);
	if (err != CAMERA_OK) {
		blog(LOG_ERROR, LOG_PREFIX "SetSessionMode failed with %d", (int)err);
		goto fail;
	}

	OH_CaptureSession_RegisterCallback(cap->session, &capture_session_callbacks);

	err = OH_CaptureSession_BeginConfig(cap->session);
	if (err != CAMERA_OK) {
		blog(LOG_ERROR, LOG_PREFIX "BeginConfig failed with %d", (int)err);
		goto fail;
	}

	err = OH_CaptureSession_AddInput(cap->session, cap->input);
	if (err != CAMERA_OK) {
		blog(LOG_ERROR, LOG_PREFIX "AddInput failed with %d", (int)err);
		goto fail;
	}

	err = OH_CaptureSession_AddVideoOutput(cap->session, cap->video_output);
	if (err != CAMERA_OK) {
		blog(LOG_ERROR, LOG_PREFIX "AddVideoOutput failed with %d", (int)err);
		goto fail;
	}

	err = OH_CaptureSession_CommitConfig(cap->session);
	if (err != CAMERA_OK) {
		blog(LOG_ERROR, LOG_PREFIX "CommitConfig failed with %d", (int)err);
		goto fail;
	}

	/* Clamp the requested frame rate into the profile's supported range.
	 * A failure here is not fatal: the stream runs at the profile default. */
	int32_t fps = cap->frame_rate;
	if (cap->profile.range.min > 0 && fps < (int32_t)cap->profile.range.min)
		fps = (int32_t)cap->profile.range.min;
	if (cap->profile.range.max > 0 && fps > (int32_t)cap->profile.range.max)
		fps = (int32_t)cap->profile.range.max;

	err = OH_VideoOutput_SetFrameRate(cap->video_output, fps, fps);
	if (err != CAMERA_OK)
		blog(LOG_WARNING, LOG_PREFIX "SetFrameRate(%d) failed with %d, using profile default", fps, (int)err);

	g_active_capture = cap;

	err = OH_VideoOutput_Start(cap->video_output);
	if (err != CAMERA_OK) {
		blog(LOG_ERROR, LOG_PREFIX "OH_VideoOutput_Start failed with %d", (int)err);
		g_active_capture = NULL;
		goto fail;
	}

	err = OH_CaptureSession_Start(cap->session);
	if (err != CAMERA_OK) {
		blog(LOG_ERROR, LOG_PREFIX "OH_CaptureSession_Start failed with %d", (int)err);
		g_active_capture = NULL;
		goto fail;
	}

	cap->running = true;

	blog(LOG_INFO, LOG_PREFIX "started camera '%s' (%s) at %ux%u format %d, %d fps (range %" PRIu32 "-%" PRIu32 ")",
	     device_id_buf, camera_position_to_string(device.cameraPosition), cap->width, cap->height,
	     (int)cap->profile.format, fps, cap->profile.range.min, cap->profile.range.max);

	pthread_mutex_unlock(&cap->frame_mutex);
	return true;

fail:
	camera_capture_teardown(cap);
	pthread_mutex_unlock(&cap->frame_mutex);
	return false;
}

static void camera_capture_stop(struct harmony_camera_capture *cap)
{
	pthread_mutex_lock(&cap->frame_mutex);
	camera_capture_teardown(cap);
	pthread_mutex_unlock(&cap->frame_mutex);
}

/* ------------------------------------------------------------------------ */
/* Source implementation                                                    */
/* ------------------------------------------------------------------------ */

static void camera_capture_read_settings(struct harmony_camera_capture *cap, obs_data_t *settings)
{
	snprintf(cap->device_id, sizeof(cap->device_id), "%s", obs_data_get_string(settings, "device_id"));
	snprintf(cap->resolution, sizeof(cap->resolution), "%s", obs_data_get_string(settings, "resolution"));
	cap->frame_rate = (int)obs_data_get_int(settings, "frame_rate");
	cap->camera_format = (int32_t)obs_data_get_int(settings, "video_format");
}

static void *camera_capture_create(obs_data_t *settings, obs_source_t *source)
{
	struct harmony_camera_capture *cap = bzalloc(sizeof(*cap));

	cap->source = source;
	pthread_mutex_init(&cap->frame_mutex, NULL);

	camera_capture_read_settings(cap, settings);

	if (!camera_capture_ensure_manager(cap))
		blog(LOG_WARNING, LOG_PREFIX "created without a camera manager; start will be retried on activation");

	return cap;
}

static void camera_capture_destroy(void *data)
{
	struct harmony_camera_capture *cap = data;

	camera_capture_stop(cap);

	pthread_mutex_lock(&cap->frame_mutex);
	if (cap->manager != NULL) {
		OH_Camera_DeleteCameraManager(cap->manager);
		cap->manager = NULL;
	}
	pthread_mutex_unlock(&cap->frame_mutex);

	pthread_mutex_destroy(&cap->frame_mutex);
	bfree(cap);
}

static void camera_capture_update(void *data, obs_data_t *settings)
{
	struct harmony_camera_capture *cap = data;

	const char *old_device_id = cap->device_id;
	const char *old_resolution = cap->resolution;
	const int32_t old_format = cap->camera_format;
	const int old_frame_rate = cap->frame_rate;
	const bool was_running = cap->running;

	const char *new_device_id = obs_data_get_string(settings, "device_id");
	const char *new_resolution = obs_data_get_string(settings, "resolution");
	const int32_t new_format = (int32_t)obs_data_get_int(settings, "video_format");
	const int new_frame_rate = (int)obs_data_get_int(settings, "frame_rate");

	/* Device, resolution or format changes require a new session; a frame
	 * rate change can be applied to the live video output. */
	const bool needs_restart = (strcmp(new_device_id, old_device_id) != 0) ||
				   (strcmp(new_resolution, old_resolution) != 0) || (new_format != old_format);
	const bool rate_changed = (new_frame_rate != old_frame_rate);

	camera_capture_read_settings(cap, settings);

	if (!needs_restart && rate_changed && cap->running && cap->video_output != NULL) {
		Camera_ErrorCode err = OH_VideoOutput_SetFrameRate(cap->video_output, cap->frame_rate,
								   cap->frame_rate);
		if (err != CAMERA_OK)
			blog(LOG_WARNING, LOG_PREFIX "live SetFrameRate(%d) failed with %d", cap->frame_rate,
			     (int)err);
	}

	if (needs_restart && was_running) {
		if (!camera_capture_start(cap))
			blog(LOG_ERROR, LOG_PREFIX "failed to restart camera after settings change");
	}
}

static uint32_t camera_capture_get_width(void *data)
{
	struct harmony_camera_capture *cap = data;
	return cap->width;
}

static uint32_t camera_capture_get_height(void *data)
{
	struct harmony_camera_capture *cap = data;
	return cap->height;
}

static void camera_capture_get_defaults(obs_data_t *settings)
{
	/* An empty device_id means "first supported camera", which keeps the
	 * default working across devices whose camera IDs differ. */
	obs_data_set_default_string(settings, "device_id", "");
	obs_data_set_default_string(settings, "resolution", "1920x1080");
	obs_data_set_default_int(settings, "frame_rate", 30);
	obs_data_set_default_int(settings, "video_format", CAMERA_FORMAT_YUV_420_SP);
}

static obs_properties_t *camera_capture_get_properties(void *data)
{
	struct harmony_camera_capture *cap = data;

	obs_properties_t *props = obs_properties_create();

	obs_property_t *device_list =
		obs_properties_add_list(props, "device_id", obs_module_text("Device"), OBS_COMBO_TYPE_LIST,
					OBS_COMBO_FORMAT_STRING);
	obs_property_t *resolution_list =
		obs_properties_add_list(props, "resolution", obs_module_text("Resolution"), OBS_COMBO_TYPE_EDITABLE,
					OBS_COMBO_FORMAT_STRING);
	obs_properties_add_int(props, "frame_rate", obs_module_text("FrameRate"), 1, 120, 1);
	obs_property_t *format_list =
		obs_properties_add_list(props, "video_format", obs_module_text("VideoFormat"), OBS_COMBO_TYPE_LIST,
					OBS_COMBO_FORMAT_INT);

	/* The settings view calls get_properties with NULL before the source
	 * exists; offer neutral fallbacks in that case. */
	const char *device_id = (cap != NULL) ? cap->device_id : "";

	Camera_Manager *manager = NULL;
	if (OH_Camera_GetCameraManager(&manager) != CAMERA_OK || manager == NULL) {
		blog(LOG_ERROR, LOG_PREFIX "properties: OH_Camera_GetCameraManager failed");
		manager = NULL;
	}

	Camera_Device selected_device = {0};
	char selected_id_buf[64] = "";
	bool have_device = false;

	if (manager != NULL) {
		Camera_Device *cameras = NULL;
		uint32_t size = 0;

		if (OH_CameraManager_GetSupportedCameras(manager, &cameras, &size) == CAMERA_OK && cameras != NULL) {
			for (uint32_t i = 0; i < size; i++) {
				const Camera_Device *camera = &cameras[i];
				if (camera->cameraId == NULL)
					continue;

				struct dstr label;
				dstr_init(&label);
				dstr_printf(&label, "%s camera %s (%s%s)", camera_position_to_string(camera->cameraPosition),
					    camera->cameraId, camera_type_to_string(camera->cameraType),
					    camera->connectionType == CAMERA_CONNECTION_REMOTE ? ", remote" : "");
				obs_property_list_add_string(device_list, label.array, camera->cameraId);
				dstr_free(&label);

				const bool remote_match =
					device_id != NULL && strcmp(device_id, "@remote") == 0 &&
					camera->connectionType == CAMERA_CONNECTION_REMOTE;
				if (!have_device && (remote_match || device_id[0] == '\0' ||
						     strcmp(camera->cameraId, device_id) == 0)) {
					snprintf(selected_id_buf, sizeof(selected_id_buf), "%s", camera->cameraId);
					selected_device = *camera;
					selected_device.cameraId = selected_id_buf;
					have_device = true;
				}
			}

			OH_CameraManager_DeleteSupportedCameras(manager, cameras, size);
		} else {
			blog(LOG_WARNING, LOG_PREFIX "properties: GetSupportedCameras returned no cameras");
		}
	}

	if (!obs_property_list_item_count(device_list))
		obs_property_list_add_string(device_list, "No cameras detected", "");

	/* Enumerate resolutions and formats from the selected device's video
	 * profiles; fall back to common values when unavailable. */
	Camera_OutputCapability *capability = NULL;
	if (manager != NULL && have_device && camera_capture_get_capability(manager, &selected_device, &capability)) {
		struct dstr res_label;
		dstr_init(&res_label);

		for (uint32_t i = 0; i < capability->videoProfilesSize; i++) {
			const Camera_VideoProfile *profile = capability->videoProfiles[i];
			if (profile == NULL)
				continue;

			char resolution[32];
			snprintf(resolution, sizeof(resolution), "%ux%u", profile->size.width, profile->size.height);

			/* De-duplicate by scanning what has been added so far. */
			bool seen = false;
			const size_t count = obs_property_list_item_count(resolution_list);
			for (size_t j = 0; j < count; j++) {
				if (strcmp(obs_property_list_item_name(resolution_list, j), resolution) == 0) {
					seen = true;
					break;
				}
			}
			if (seen)
				continue;

			dstr_printf(&res_label, "%ux%u", profile->size.width, profile->size.height);
			obs_property_list_add_string(resolution_list, res_label.array, resolution);
			dstr_resize(&res_label, 0);
		}

		dstr_free(&res_label);

		for (uint32_t i = 0; i < capability->videoProfilesSize; i++) {
			const Camera_VideoProfile *profile = capability->videoProfiles[i];
			if (profile == NULL)
				continue;

			bool seen = false;
			const size_t count = obs_property_list_item_count(format_list);
			for (size_t j = 0; j < count; j++) {
				if (obs_property_list_item_int(format_list, j) == (long long)profile->format) {
					seen = true;
					break;
				}
			}
			if (seen)
				continue;

			struct dstr label;
			dstr_init(&label);
			dstr_printf(&label, "%s (%d)", camera_format_to_string(profile->format), (int)profile->format);
			obs_property_list_add_int(format_list, label.array, (long long)profile->format);
			dstr_free(&label);
		}

		OH_CameraManager_DeleteSupportedCameraOutputCapability(manager, capability);
	}

	if (obs_property_list_item_count(resolution_list) == 0) {
		obs_property_list_add_string(resolution_list, "640x480", "640x480");
		obs_property_list_add_string(resolution_list, "1280x720", "1280x720");
		obs_property_list_add_string(resolution_list, "1920x1080", "1920x1080");
	}

	if (obs_property_list_item_count(format_list) == 0) {
		struct dstr label;
		dstr_init(&label);
		dstr_printf(&label, "%s (%d)", camera_format_to_string(CAMERA_FORMAT_YUV_420_SP),
			    (int)CAMERA_FORMAT_YUV_420_SP);
		obs_property_list_add_int(format_list, label.array, CAMERA_FORMAT_YUV_420_SP);
		dstr_free(&label);
	}

	if (manager != NULL)
		OH_Camera_DeleteCameraManager(manager);

	return props;
}

static void camera_capture_activate(void *data)
{
	struct harmony_camera_capture *cap = data;

	if (!camera_capture_start(cap))
		blog(LOG_ERROR, LOG_PREFIX "failed to start camera on activation");
}

static void camera_capture_deactivate(void *data)
{
	struct harmony_camera_capture *cap = data;

	camera_capture_stop(cap);
}

struct obs_source_info harmony_camera_capture_info = {
	.id = "harmony_camera_capture",
	.type = OBS_SOURCE_TYPE_INPUT,
	.output_flags = OBS_SOURCE_ASYNC_VIDEO,
	.get_name = camera_capture_get_name,
	.create = camera_capture_create,
	.destroy = camera_capture_destroy,
	.get_width = camera_capture_get_width,
	.get_height = camera_capture_get_height,
	.get_defaults = camera_capture_get_defaults,
	.get_properties = camera_capture_get_properties,
	.update = camera_capture_update,
	.activate = camera_capture_activate,
	.deactivate = camera_capture_deactivate,
};
