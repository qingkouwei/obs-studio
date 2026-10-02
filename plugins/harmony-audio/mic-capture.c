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

    HarmonyOS microphone capture source, backed by OHAudio with
    AUDIOSTREAM_SOURCE_TYPE_MIC. Unlike the loopback source this uses the
    normal synchronous OH_AudioCapturer_Start path.

    Device selection uses the API 26 OH_AudioDeviceEnhanceManager routing
    extension (SelectInputDeviceForAudioCapturer). If the device does not
    support enhanced routing, or no device_id is configured, the system
    default/preferred input device is used.
******************************************************************************/

#include "harmony-audio.h"

#include <util/platform.h>

#include <pthread.h>

#include <ohaudio/native_audiocapturer.h>
#include <ohaudio/native_audiostreambuilder.h>
#include <ohaudio/native_audiostream_base.h>
#include <ohaudio/native_audio_manager.h>
#include <ohaudio/native_audio_routing_manager.h>
#include <ohaudio/native_audio_device_base.h>
#include <ohaudio/native_audio_device_enhance_manager.h>

#define LOG_PREFIX "[harmony mic capture] "

#define MIC_SAMPLE_RATE 48000
#define MIC_CHANNELS 2

struct harmony_mic_capture {
	obs_source_t *source;

	OH_AudioCapturer *capturer;
	audio_resampler_t *resampler;

	pthread_mutex_t mutex;
	bool active;

	int device_id;
	uint32_t sample_rate;
	uint32_t channels;
};

static const char *mic_capture_get_name(void *unused)
{
	UNUSED_PARAMETER(unused);
	return obs_module_text("HarmonyMicCapture");
}

static enum speaker_layout channels_to_speaker_layout(uint32_t channels)
{
	switch (channels) {
	case 1:
		return SPEAKERS_MONO;
	case 2:
		return SPEAKERS_STEREO;
	case 3:
		return SPEAKERS_2POINT1;
	case 4:
		return SPEAKERS_4POINT0;
	case 5:
		return SPEAKERS_4POINT1;
	case 6:
		return SPEAKERS_5POINT1;
	case 8:
		return SPEAKERS_7POINT1;
	default:
		return SPEAKERS_UNKNOWN;
	}
}

static void mic_capture_destroy_resampler(struct harmony_mic_capture *mic)
{
	if (mic->resampler != NULL) {
		audio_resampler_destroy(mic->resampler);
		mic->resampler = NULL;
	}
}

static bool mic_capture_create_resampler(struct harmony_mic_capture *mic)
{
	struct resample_info src = {0};
	struct resample_info dst = {0};

	mic_capture_destroy_resampler(mic);

	src.samples_per_sec = mic->sample_rate;
	src.format = AUDIO_FORMAT_16BIT; /* OHAudio delivers S16LE interleaved */
	src.speakers = channels_to_speaker_layout(mic->channels);

	dst.samples_per_sec = MIC_SAMPLE_RATE;
	dst.format = AUDIO_FORMAT_FLOAT;
	dst.speakers = SPEAKERS_STEREO;

	mic->resampler = audio_resampler_create(&dst, &src);
	if (mic->resampler == NULL) {
		blog(LOG_ERROR, LOG_PREFIX "failed to create resampler (%u Hz, %u ch)", mic->sample_rate,
		     mic->channels);
		return false;
	}

	return true;
}

static void mic_capture_on_read_data(OH_AudioCapturer *capturer, void *user_data, void *audio_data,
				     int32_t audio_data_size)
{
	struct harmony_mic_capture *mic = user_data;

	pthread_mutex_lock(&mic->mutex);

	if (!mic->active || mic->resampler == NULL || audio_data == NULL || audio_data_size <= 0) {
		pthread_mutex_unlock(&mic->mutex);
		return;
	}

	const uint32_t frame_bytes = mic->channels * sizeof(int16_t);
	if (frame_bytes == 0) {
		pthread_mutex_unlock(&mic->mutex);
		return;
	}

	const uint32_t in_frames = (uint32_t)audio_data_size / frame_bytes;
	const uint8_t *input[MAX_AV_PLANES] = {(const uint8_t *)audio_data};
	uint8_t *output[MAX_AV_PLANES] = {0};
	uint32_t out_frames = 0;
	uint64_t ts_offset = 0;

	if (audio_resampler_resample(mic->resampler, output, &out_frames, &ts_offset, input, in_frames) &&
	    out_frames > 0) {
		struct obs_source_audio out = {0};

		out.data[0] = output[0];
		out.data[1] = (mic->channels > 1) ? output[1] : NULL;
		out.frames = out_frames;
		out.speakers = SPEAKERS_STEREO;
		out.format = AUDIO_FORMAT_FLOAT;
		out.samples_per_sec = MIC_SAMPLE_RATE;
		out.timestamp = os_gettime_ns() - ts_offset;

		obs_source_output_audio(mic->source, &out);
	}

	pthread_mutex_unlock(&mic->mutex);

	UNUSED_PARAMETER(capturer);
}

/* Pins the capturer to the configured input device via the API 26 device
 * enhance manager. Returns true when routing was applied, false when it is
 * unavailable (system default routing then applies). */
static bool mic_capture_select_device(struct harmony_mic_capture *mic, int device_id)
{
	if (device_id <= 0)
		return false;

	OH_AudioDeviceEnhanceManager *enhance_manager = NULL;
	OH_AudioRoutingManager *routing_manager = NULL;
	OH_AudioDeviceDescriptorArray *devices = NULL;
	bool selected = false;

	/* Initializes the audio manager singleton; the NDK exposes no release
	 * function for the handle. */
	OH_AudioManager *audio_manager = NULL;
	if (OH_GetAudioManager(&audio_manager) != AUDIOCOMMON_RESULT_SUCCESS) {
		blog(LOG_WARNING, LOG_PREFIX "OH_GetAudioManager failed");
		return false;
	}

	if (OH_AudioManager_GetAudioDeviceEnhanceManager(&enhance_manager) != AUDIOCOMMON_RESULT_SUCCESS ||
	    enhance_manager == NULL) {
		blog(LOG_WARNING, LOG_PREFIX "audio device enhance manager unavailable");
		return false;
	}

	bool supported = false;
	if (OH_AudioDeviceEnhanceManager_IsEnhancedRoutingSupported(enhance_manager, &supported) !=
		    AUDIOCOMMON_RESULT_SUCCESS ||
	    !supported) {
		blog(LOG_WARNING, LOG_PREFIX "enhanced routing not supported; using system default input device");
		return false;
	}

	if (OH_AudioManager_GetAudioRoutingManager(&routing_manager) != AUDIOCOMMON_RESULT_SUCCESS ||
	    routing_manager == NULL) {
		blog(LOG_WARNING, LOG_PREFIX "audio routing manager unavailable");
		return false;
	}

	if (OH_AudioRoutingManager_GetDevices(routing_manager, AUDIO_DEVICE_FLAG_INPUT, &devices) !=
		    AUDIOCOMMON_RESULT_SUCCESS ||
	    devices == NULL) {
		blog(LOG_WARNING, LOG_PREFIX "failed to enumerate input devices");
		return false;
	}

	for (uint32_t i = 0; i < devices->size; i++) {
		OH_AudioDeviceDescriptor *descriptor = devices->descriptors[i];
		uint32_t id = 0;

		if (descriptor == NULL)
			continue;
		if (OH_AudioDeviceDescriptor_GetDeviceId(descriptor, &id) != AUDIOCOMMON_RESULT_SUCCESS)
			continue;
		if ((int)id != device_id)
			continue;

		const OH_AudioCommon_Result result = OH_AudioDeviceEnhanceManager_SelectInputDeviceForAudioCapturer(
			enhance_manager, mic->capturer, descriptor);
		if (result != AUDIOCOMMON_RESULT_SUCCESS) {
			blog(LOG_WARNING, LOG_PREFIX "SelectInputDeviceForAudioCapturer failed with %d", (int)result);
		} else {
			blog(LOG_INFO, LOG_PREFIX "routed capture to input device %d", device_id);
			selected = true;
		}
		break;
	}

	if (!selected)
		blog(LOG_WARNING, LOG_PREFIX "input device %d not found; using system default", device_id);

	OH_AudioRoutingManager_ReleaseDevices(routing_manager, devices);
	return selected;
}

static bool mic_capture_start(struct harmony_mic_capture *mic)
{
	OH_AudioStreamBuilder *builder = NULL;
	OH_AudioCapturer *capturer = NULL;
	bool success = false;

	pthread_mutex_lock(&mic->mutex);

	if (mic->capturer != NULL) {
		pthread_mutex_unlock(&mic->mutex);
		return true;
	}

	OH_AudioStream_Result result = OH_AudioStreamBuilder_Create(&builder, AUDIOSTREAM_TYPE_CAPTURER);
	if (result != AUDIOSTREAM_SUCCESS || builder == NULL) {
		blog(LOG_ERROR, LOG_PREFIX "OH_AudioStreamBuilder_Create failed with %d", (int)result);
		goto fail;
	}

	OH_AudioStreamBuilder_SetSamplingRate(builder, MIC_SAMPLE_RATE);
	OH_AudioStreamBuilder_SetChannelCount(builder, MIC_CHANNELS);
	OH_AudioStreamBuilder_SetSampleFormat(builder, AUDIOSTREAM_SAMPLE_S16LE);
	OH_AudioStreamBuilder_SetEncodingType(builder, AUDIOSTREAM_ENCODING_TYPE_RAW);
	OH_AudioStreamBuilder_SetCapturerInfo(builder, AUDIOSTREAM_SOURCE_TYPE_MIC);
	OH_AudioStreamBuilder_SetCapturerReadDataCallback(builder, mic_capture_on_read_data, mic);

	result = OH_AudioStreamBuilder_GenerateCapturer(builder, &capturer);
	/* The builder has done its job; destroy it immediately as required. */
	OH_AudioStreamBuilder_Destroy(builder);
	builder = NULL;

	if (result != AUDIOSTREAM_SUCCESS || capturer == NULL) {
		blog(LOG_ERROR, LOG_PREFIX "GenerateCapturer failed with %d", (int)result);
		goto fail;
	}

	mic->capturer = capturer;
	blog(LOG_DEBUG, LOG_PREFIX "capturer generated, selecting device");
	mic_capture_select_device(mic, mic->device_id);
	blog(LOG_DEBUG, LOG_PREFIX "device selected, calling Start");

	result = OH_AudioCapturer_Start(capturer);
	blog(LOG_DEBUG, LOG_PREFIX "Start returned %d", (int)result);
	if (result != AUDIOSTREAM_SUCCESS) {
		blog(LOG_ERROR, LOG_PREFIX "OH_AudioCapturer_Start failed with %d", (int)result);
		OH_AudioCapturer_Release(capturer);
		mic->capturer = NULL;
		goto fail;
	}

	int32_t sample_rate = MIC_SAMPLE_RATE;
	int32_t channels = MIC_CHANNELS;
	OH_AudioCapturer_GetSamplingRate(capturer, &sample_rate);
	OH_AudioCapturer_GetChannelCount(capturer, &channels);

	mic->sample_rate = (sample_rate > 0) ? (uint32_t)sample_rate : MIC_SAMPLE_RATE;
	mic->channels = (channels > 0) ? (uint32_t)channels : MIC_CHANNELS;

	if (!mic_capture_create_resampler(mic)) {
		OH_AudioCapturer_Stop(capturer);
		OH_AudioCapturer_Release(capturer);
		mic->capturer = NULL;
		goto fail;
	}

	mic->active = true;
	blog(LOG_INFO, LOG_PREFIX "microphone capture started (%u Hz, %u ch)", mic->sample_rate, mic->channels);
	success = true;

fail:
	pthread_mutex_unlock(&mic->mutex);
	return success;
}

/* Detach first, then stop/release outside the mutex: OH_AudioCapturer_Stop may
 * block until an in-flight read callback returns and that callback needs the
 * mutex. */
static void mic_capture_stop(struct harmony_mic_capture *mic)
{
	pthread_mutex_lock(&mic->mutex);

	OH_AudioCapturer *capturer = mic->capturer;
	mic->capturer = NULL;
	mic->active = false;

	pthread_mutex_unlock(&mic->mutex);

	if (capturer == NULL)
		return;

	const OH_AudioStream_Result result = OH_AudioCapturer_Stop(capturer);
	if (result != AUDIOSTREAM_SUCCESS)
		blog(LOG_WARNING, LOG_PREFIX "OH_AudioCapturer_Stop returned %d", (int)result);

	OH_AudioCapturer_Release(capturer);

	pthread_mutex_lock(&mic->mutex);
	mic_capture_destroy_resampler(mic);
	pthread_mutex_unlock(&mic->mutex);
}

static void *mic_capture_create(obs_data_t *settings, obs_source_t *source)
{
	struct harmony_mic_capture *mic = bzalloc(sizeof(*mic));

	mic->source = source;
	pthread_mutex_init(&mic->mutex, NULL);

	mic->device_id = (int)obs_data_get_int(settings, "device_id");
	return mic;
}

static void mic_capture_destroy(void *data)
{
	struct harmony_mic_capture *mic = data;

	mic_capture_stop(mic);
	pthread_mutex_destroy(&mic->mutex);
	bfree(mic);
}

static void mic_capture_update(void *data, obs_data_t *settings)
{
	struct harmony_mic_capture *mic = data;

	const int new_device_id = (int)obs_data_get_int(settings, "device_id");

	pthread_mutex_lock(&mic->mutex);
	const bool device_changed = (new_device_id != mic->device_id);
	const bool was_active = (mic->capturer != NULL);
	mic->device_id = new_device_id;
	pthread_mutex_unlock(&mic->mutex);

	if (device_changed && was_active) {
		mic_capture_stop(mic);
		if (!mic_capture_start(mic))
			blog(LOG_ERROR, LOG_PREFIX "failed to restart capture after device change");
	}
}

static void mic_capture_activate(void *data)
{
	struct harmony_mic_capture *mic = data;

	if (!mic_capture_start(mic))
		blog(LOG_ERROR, LOG_PREFIX "failed to start microphone capture");
}

static void mic_capture_deactivate(void *data)
{
	struct harmony_mic_capture *mic = data;

	mic_capture_stop(mic);
}

static void mic_capture_get_defaults(obs_data_t *settings)
{
	obs_data_set_default_int(settings, "device_id", 0);
}

static obs_properties_t *mic_capture_get_properties(void *data)
{
	UNUSED_PARAMETER(data);

	obs_properties_t *props = obs_properties_create();

	obs_property_t *devices = obs_properties_add_list(props, "device_id", obs_module_text("MicCapture.Device"),
							  OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_INT);
	obs_property_list_add_int(devices, obs_module_text("MicCapture.Device.Default"), 0);

	OH_AudioRoutingManager *routing_manager = NULL;
	OH_AudioDeviceDescriptorArray *devices_array = NULL;

	if (OH_AudioManager_GetAudioRoutingManager(&routing_manager) == AUDIOCOMMON_RESULT_SUCCESS &&
	    routing_manager != NULL &&
	    OH_AudioRoutingManager_GetDevices(routing_manager, AUDIO_DEVICE_FLAG_INPUT, &devices_array) ==
		    AUDIOCOMMON_RESULT_SUCCESS &&
	    devices_array != NULL) {
		for (uint32_t i = 0; i < devices_array->size; i++) {
			OH_AudioDeviceDescriptor *descriptor = devices_array->descriptors[i];
			uint32_t id = 0;
			char *display_name = NULL;

			if (descriptor == NULL)
				continue;
			if (OH_AudioDeviceDescriptor_GetDeviceId(descriptor, &id) != AUDIOCOMMON_RESULT_SUCCESS)
				continue;

			if (OH_AudioDeviceDescriptor_GetDeviceDisplayName(descriptor, &display_name) !=
				    AUDIOCOMMON_RESULT_SUCCESS ||
			    display_name == NULL) {
				obs_property_list_add_int(devices, obs_module_text("MicCapture.Device.Unknown"),
							  (long long)id);
			} else {
				obs_property_list_add_int(devices, display_name, (long long)id);
			}
		}

		OH_AudioRoutingManager_ReleaseDevices(routing_manager, devices_array);
	}

	return props;
}

struct obs_source_info harmony_mic_capture_info = {
	.id = "harmony_mic_capture",
	.type = OBS_SOURCE_TYPE_INPUT,
	.output_flags = OBS_SOURCE_AUDIO,
	.get_name = mic_capture_get_name,
	.create = mic_capture_create,
	.destroy = mic_capture_destroy,
	.update = mic_capture_update,
	.activate = mic_capture_activate,
	.deactivate = mic_capture_deactivate,
	.get_defaults = mic_capture_get_defaults,
	.get_properties = mic_capture_get_properties,
};
