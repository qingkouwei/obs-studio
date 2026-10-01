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

    HarmonyOS desktop audio loopback ("内录") source, backed by the API 23+
    playback-capture path of OHAudio.

    IMPORTANT: loopback start is asynchronous. The source is built with
    OH_AudioStreamBuilder_SetPlaybackCaptureMode and started with
    OH_AudioCapturer_RequestPlaybackCaptureStart (never OH_AudioCapturer_Start,
    which is illegal for playback capture). The request result arrives later in
    OH_AudioCapturer_OnPlaybackCaptureStartCallback as SUCCESS, FAILED or
    NOT_AUTHORIZED (the system shows a privacy dialog the user may deny). All
    three outcomes are modelled by enum loopback_state below; audio is only
    forwarded to OBS once the state is RUNNING.
******************************************************************************/

#include "harmony-audio.h"

#include <util/platform.h>

#include <pthread.h>

#include <ohaudio/native_audiocapturer.h>
#include <ohaudio/native_audiostreambuilder.h>
#include <ohaudio/native_audiostream_base.h>

#define LOG_PREFIX "[harmony desktop audio] "

#define LOOPBACK_SAMPLE_RATE 48000
#define LOOPBACK_CHANNELS 2

enum loopback_state {
	LOOPBACK_STATE_IDLE,
	LOOPBACK_STATE_REQUESTING,
	LOOPBACK_STATE_RUNNING,
	LOOPBACK_STATE_UNAUTHORIZED,
	LOOPBACK_STATE_FAILED,
};

struct harmony_desktop_audio {
	obs_source_t *source;

	OH_AudioCapturer *capturer;
	audio_resampler_t *resampler;

	pthread_mutex_t mutex;
	enum loopback_state state;
	bool pending_stop;

	uint32_t mode;
	uint32_t sample_rate;
	uint32_t channels;
};

static const char *desktop_audio_get_name(void *unused)
{
	UNUSED_PARAMETER(unused);
	return obs_module_text("HarmonyDesktopAudio");
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

static void desktop_audio_destroy_resampler(struct harmony_desktop_audio *da)
{
	if (da->resampler != NULL) {
		audio_resampler_destroy(da->resampler);
		da->resampler = NULL;
	}
}

static bool desktop_audio_create_resampler(struct harmony_desktop_audio *da)
{
	struct resample_info src = {0};
	struct resample_info dst = {0};

	desktop_audio_destroy_resampler(da);

	src.samples_per_sec = da->sample_rate;
	src.format = AUDIO_FORMAT_16BIT; /* OHAudio delivers S16LE interleaved */
	src.speakers = channels_to_speaker_layout(da->channels);

	dst.samples_per_sec = LOOPBACK_SAMPLE_RATE;
	dst.format = AUDIO_FORMAT_FLOAT;
	dst.speakers = SPEAKERS_STEREO;

	da->resampler = audio_resampler_create(&dst, &src);
	if (da->resampler == NULL) {
		blog(LOG_ERROR, LOG_PREFIX "failed to create resampler (%u Hz, %u ch)", da->sample_rate, da->channels);
		return false;
	}

	return true;
}

static void desktop_audio_on_read_data(OH_AudioCapturer *capturer, void *user_data, void *audio_data,
				       int32_t audio_data_size)
{
	struct harmony_desktop_audio *da = user_data;

	pthread_mutex_lock(&da->mutex);

	if (da->state != LOOPBACK_STATE_RUNNING || da->resampler == NULL || audio_data == NULL ||
	    audio_data_size <= 0) {
		pthread_mutex_unlock(&da->mutex);
		return;
	}

	const uint32_t frame_bytes = da->channels * sizeof(int16_t);
	if (frame_bytes == 0) {
		pthread_mutex_unlock(&da->mutex);
		return;
	}

	const uint32_t in_frames = (uint32_t)audio_data_size / frame_bytes;
	const uint8_t *input[MAX_AV_PLANES] = {(const uint8_t *)audio_data};
	uint8_t *output[MAX_AV_PLANES] = {0};
	uint32_t out_frames = 0;
	uint64_t ts_offset = 0;

	if (audio_resampler_resample(da->resampler, output, &out_frames, &ts_offset, input, in_frames) &&
	    out_frames > 0) {
		struct obs_source_audio out = {0};

		out.data[0] = output[0];
		out.data[1] = (da->channels > 1) ? output[1] : NULL;
		out.frames = out_frames;
		out.speakers = SPEAKERS_STEREO;
		out.format = AUDIO_FORMAT_FLOAT;
		out.samples_per_sec = LOOPBACK_SAMPLE_RATE;
		out.timestamp = os_gettime_ns() - ts_offset;

		obs_source_output_audio(da->source, &out);
	}

	pthread_mutex_unlock(&da->mutex);

	UNUSED_PARAMETER(capturer);
}

static void desktop_audio_on_start_state(OH_AudioCapturer *capturer, void *user_data,
					 OH_AudioStream_PlaybackCaptureStartState state)
{
	struct harmony_desktop_audio *da = user_data;

	pthread_mutex_lock(&da->mutex);

	switch (state) {
	case AUDIOSTREAM_PLAYBACKCAPTURE_START_STATE_SUCCESS:
		da->state = LOOPBACK_STATE_RUNNING;
		blog(LOG_INFO, LOG_PREFIX "playback capture authorized and running");
		break;
	case AUDIOSTREAM_PLAYBACKCAPTURE_START_STATE_NOT_AUTHORIZED:
		da->state = LOOPBACK_STATE_UNAUTHORIZED;
		da->pending_stop = true;
		blog(LOG_ERROR,
		     LOG_PREFIX "playback capture NOT AUTHORIZED: the user denied the system privacy dialog; "
				"stopping the loopback source");
		break;
	case AUDIOSTREAM_PLAYBACKCAPTURE_START_STATE_FAILED:
	default:
		da->state = LOOPBACK_STATE_FAILED;
		da->pending_stop = true;
		blog(LOG_ERROR, LOG_PREFIX "playback capture start failed (state %d)", (int)state);
		break;
	}

	pthread_mutex_unlock(&da->mutex);

	UNUSED_PARAMETER(capturer);
}

/* Detaches the capturer from the source first so concurrent callbacks stop
 * touching it, then stops/releases it outside the mutex: OH_AudioCapturer_Stop
 * may block until an in-flight read callback returns, and that callback needs
 * the mutex. The resampler is destroyed last, after Stop+Release guarantee no
 * further callbacks will run. Keeps the source object alive so the user can
 * re-enable/retry it from the UI. */
static void desktop_audio_stop(struct harmony_desktop_audio *da)
{
	pthread_mutex_lock(&da->mutex);

	OH_AudioCapturer *capturer = da->capturer;
	da->capturer = NULL;
	da->state = LOOPBACK_STATE_IDLE;
	da->pending_stop = false;

	pthread_mutex_unlock(&da->mutex);

	if (capturer == NULL)
		return;

	const OH_AudioStream_Result result = OH_AudioCapturer_Stop(capturer);
	if (result != AUDIOSTREAM_SUCCESS)
		blog(LOG_WARNING, LOG_PREFIX "OH_AudioCapturer_Stop returned %d", (int)result);

	OH_AudioCapturer_Release(capturer);

	pthread_mutex_lock(&da->mutex);
	desktop_audio_destroy_resampler(da);
	pthread_mutex_unlock(&da->mutex);
}

static bool desktop_audio_start(struct harmony_desktop_audio *da)
{
	OH_AudioStreamBuilder *builder = NULL;
	OH_AudioCapturer *capturer = NULL;
	bool success = false;

	pthread_mutex_lock(&da->mutex);

	if (da->capturer != NULL) {
		pthread_mutex_unlock(&da->mutex);
		return true;
	}

	OH_AudioStream_Result result = OH_AudioStreamBuilder_Create(&builder, AUDIOSTREAM_TYPE_CAPTURER);
	if (result != AUDIOSTREAM_SUCCESS || builder == NULL) {
		blog(LOG_ERROR, LOG_PREFIX "OH_AudioStreamBuilder_Create failed with %d", (int)result);
		goto fail;
	}

	OH_AudioStreamBuilder_SetSamplingRate(builder, LOOPBACK_SAMPLE_RATE);
	OH_AudioStreamBuilder_SetChannelCount(builder, LOOPBACK_CHANNELS);
	OH_AudioStreamBuilder_SetSampleFormat(builder, AUDIOSTREAM_SAMPLE_S16LE);
	OH_AudioStreamBuilder_SetEncodingType(builder, AUDIOSTREAM_ENCODING_TYPE_RAW);
	OH_AudioStreamBuilder_SetCapturerReadDataCallback(builder, desktop_audio_on_read_data, da);
	OH_AudioStreamBuilder_SetPlaybackCaptureMode(builder, da->mode);

	result = OH_AudioStreamBuilder_GenerateCapturer(builder, &capturer);
	/* The builder has done its job; destroy it immediately as required. */
	OH_AudioStreamBuilder_Destroy(builder);
	builder = NULL;

	if (result != AUDIOSTREAM_SUCCESS || capturer == NULL) {
		blog(LOG_ERROR, LOG_PREFIX "GenerateCapturer failed with %d", (int)result);
		goto fail;
	}

	/* Query what the service actually gave us; loopback devices may not
	 * honour the requested geometry. */
	int32_t sample_rate = LOOPBACK_SAMPLE_RATE;
	int32_t channels = LOOPBACK_CHANNELS;
	OH_AudioCapturer_GetSamplingRate(capturer, &sample_rate);
	OH_AudioCapturer_GetChannelCount(capturer, &channels);

	da->capturer = capturer;
	da->sample_rate = (sample_rate > 0) ? (uint32_t)sample_rate : LOOPBACK_SAMPLE_RATE;
	da->channels = (channels > 0) ? (uint32_t)channels : LOOPBACK_CHANNELS;

	if (!desktop_audio_create_resampler(da)) {
		OH_AudioCapturer_Release(capturer);
		da->capturer = NULL;
		goto fail;
	}

	/* Async start: AUDIOSTREAM_SUCCESS only means the request was
	 * submitted; the authoritative result arrives in
	 * desktop_audio_on_start_state. Do NOT call OH_AudioCapturer_Start
	 * here - playback capture forbids it. */
	da->state = LOOPBACK_STATE_REQUESTING;
	result = OH_AudioCapturer_RequestPlaybackCaptureStart(capturer, desktop_audio_on_start_state, da);
	if (result != AUDIOSTREAM_SUCCESS) {
		blog(LOG_ERROR, LOG_PREFIX "RequestPlaybackCaptureStart failed with %d", (int)result);
		OH_AudioCapturer_Release(capturer);
		da->capturer = NULL;
		desktop_audio_destroy_resampler(da);
		da->state = LOOPBACK_STATE_FAILED;
		goto fail;
	}

	blog(LOG_INFO, LOG_PREFIX "playback capture requested (mode 0x%x, %u Hz, %u ch); awaiting authorization",
	     da->mode, da->sample_rate, da->channels);
	success = true;

fail:
	pthread_mutex_unlock(&da->mutex);
	return success;
}

static void *desktop_audio_create(obs_data_t *settings, obs_source_t *source)
{
	struct harmony_desktop_audio *da = bzalloc(sizeof(*da));

	da->source = source;
	da->state = LOOPBACK_STATE_IDLE;
	pthread_mutex_init(&da->mutex, NULL);

	da->mode = (uint32_t)obs_data_get_int(settings, "mode");
	return da;
}

static void desktop_audio_destroy(void *data)
{
	struct harmony_desktop_audio *da = data;

	desktop_audio_stop(da);
	pthread_mutex_destroy(&da->mutex);
	bfree(da);
}

static void desktop_audio_update(void *data, obs_data_t *settings)
{
	struct harmony_desktop_audio *da = data;

	const uint32_t new_mode = (uint32_t)obs_data_get_int(settings, "mode");

	pthread_mutex_lock(&da->mutex);
	const bool mode_changed = (new_mode != da->mode);
	const bool was_active = (da->capturer != NULL);
	da->mode = new_mode;
	pthread_mutex_unlock(&da->mutex);

	if (mode_changed && was_active) {
		desktop_audio_stop(da);
		if (!desktop_audio_start(da))
			blog(LOG_ERROR, LOG_PREFIX "failed to restart loopback after mode change");
	}
}

static void desktop_audio_activate(void *data)
{
	struct harmony_desktop_audio *da = data;

	if (!desktop_audio_start(da))
		blog(LOG_ERROR, LOG_PREFIX "failed to start desktop audio loopback");
}

static void desktop_audio_deactivate(void *data)
{
	struct harmony_desktop_audio *da = data;

	desktop_audio_stop(da);
}

static void desktop_audio_video_tick(void *data, float seconds)
{
	struct harmony_desktop_audio *da = data;

	UNUSED_PARAMETER(seconds);

	/* Deferred teardown: the unauthorized/failed verdict arrives on an
	 * OHAudio thread; releasing the capturer there could deadlock against
	 * the callback dispatch, so the cleanup runs here on the OBS tick. */
	pthread_mutex_lock(&da->mutex);
	const bool needs_stop = da->pending_stop;
	pthread_mutex_unlock(&da->mutex);

	if (needs_stop)
		desktop_audio_stop(da);
}

static void desktop_audio_get_defaults(obs_data_t *settings)
{
	obs_data_set_default_int(settings, "mode", AUDIOSTREAM_PLAYBACKCAPTURE_MODE_DEFAULT);
}

static obs_properties_t *desktop_audio_get_properties(void *data)
{
	UNUSED_PARAMETER(data);

	obs_properties_t *props = obs_properties_create();

	/* The mode bits are OR-able per native_audiostream_base.h. */
	obs_property_t *mode = obs_properties_add_list(props, "mode", obs_module_text("DesktopAudio.Mode"),
						       OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_INT);
	obs_property_list_add_int(mode, obs_module_text("DesktopAudio.Mode.Default"),
				  AUDIOSTREAM_PLAYBACKCAPTURE_MODE_DEFAULT);
	obs_property_list_add_int(mode, obs_module_text("DesktopAudio.Mode.Media"),
				  AUDIOSTREAM_PLAYBACKCAPTURE_MODE_MEDIA);
	obs_property_list_add_int(mode, obs_module_text("DesktopAudio.Mode.ExcludingSelf"),
				  AUDIOSTREAM_PLAYBACKCAPTURE_MODE_EXCLUDING_SELF);
	obs_property_list_add_int(mode, obs_module_text("DesktopAudio.Mode.MediaExcludingSelf"),
				  AUDIOSTREAM_PLAYBACKCAPTURE_MODE_MEDIA |
					  AUDIOSTREAM_PLAYBACKCAPTURE_MODE_EXCLUDING_SELF);

	return props;
}

struct obs_source_info harmony_desktop_audio_info = {
	.id = "harmony_desktop_audio",
	.type = OBS_SOURCE_TYPE_INPUT,
	.output_flags = OBS_SOURCE_AUDIO,
	.get_name = desktop_audio_get_name,
	.create = desktop_audio_create,
	.destroy = desktop_audio_destroy,
	.update = desktop_audio_update,
	.activate = desktop_audio_activate,
	.deactivate = desktop_audio_deactivate,
	.video_tick = desktop_audio_video_tick,
	.get_defaults = desktop_audio_get_defaults,
	.get_properties = desktop_audio_get_properties,
};
