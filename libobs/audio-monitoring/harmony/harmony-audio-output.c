#include "harmony-audio-monitoring.h"

#include <ohaudio/native_audio_device_base.h>
#include <ohaudio/native_audio_device_enhance_manager.h>
#include <ohaudio/native_audio_manager.h>
#include <ohaudio/native_audio_routing_manager.h>
#include <ohaudio/native_audiorenderer.h>
#include <ohaudio/native_audiostreambuilder.h>

#include <inttypes.h>
#include <stdlib.h>
#include <string.h>

#define LOG_PREFIX "[harmony audio monitoring] "

/* OHAudio wants interleaved S16LE; libobs mixes as float planar. S16LE has been
 * available since API 10 (F32LE only since API 17) and is what
 * plugins/harmony-audio already negotiates for the capture direction, so the
 * same format is used here for consistency. */
#define MONITOR_SAMPLE_FORMAT AUDIOSTREAM_SAMPLE_S16LE
#define MONITOR_AUDIO_FORMAT AUDIO_FORMAT_16BIT

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

/* Interleaved S16LE, so this is a single plane of frames*channels samples,
 * matching pulseaudio-output.c's process_s16(). */
static void process_volume(int16_t *data, size_t samples, float vol)
{
	int16_t *end = data + samples;

	while (data < end)
		*(data++) *= vol;
}

/* Runs on OHAudio's own callback thread and must never block. If libobs's audio
 * thread happens to be mid-push (holding playback_mutex), fill this callback's
 * buffer with silence instead of waiting on the lock, and count it as a drop. */
static OH_AudioData_Callback_Result on_write_data(OH_AudioRenderer *renderer, void *user_data, void *audio_data,
						  int32_t audio_data_size)
{
	struct audio_monitor *monitor = user_data;
	size_t want;
	size_t available;
	size_t to_copy;

	UNUSED_PARAMETER(renderer);

	if (!audio_data || audio_data_size <= 0)
		return AUDIO_DATA_CALLBACK_RESULT_VALID;

	want = (size_t)audio_data_size;

	if (pthread_mutex_trylock(&monitor->playback_mutex) != 0) {
		memset(audio_data, 0, want);
		os_atomic_inc_long(&monitor->drops);
		return AUDIO_DATA_CALLBACK_RESULT_VALID;
	}

	available = monitor->new_data.size;
	to_copy = available < want ? available : want;

	if (to_copy > 0)
		deque_pop_front(&monitor->new_data, audio_data, to_copy);
	if (to_copy < want) {
		memset((uint8_t *)audio_data + to_copy, 0, want - to_copy);
		os_atomic_inc_long(&monitor->drops);
	}

	pthread_mutex_unlock(&monitor->playback_mutex);
	return AUDIO_DATA_CALLBACK_RESULT_VALID;
}

static void on_audio_playback(void *param, obs_source_t *source, const struct audio_data *audio_data, bool muted)
{
	struct audio_monitor *monitor = param;
	uint8_t *resample_data[MAX_AV_PLANES];
	uint32_t resample_frames;
	uint64_t ts_offset;
	float vol = source->user_volume;
	bool success;
	size_t bytes;

	UNUSED_PARAMETER(muted);

	if (!monitor->renderer || !monitor->resampler)
		return;

	if (os_atomic_load_long(&source->activate_refs) == 0)
		return;

	success = audio_resampler_resample(monitor->resampler, resample_data, &resample_frames, &ts_offset,
					   (const uint8_t *const *)audio_data->data, (uint32_t)audio_data->frames);
	if (!success || resample_frames == 0)
		return;

	bytes = (size_t)monitor->bytes_per_frame * resample_frames;

	if (!close_float(vol, 1.0f, EPSILON))
		process_volume((int16_t *)resample_data[0], (size_t)resample_frames * monitor->channels, vol);

	pthread_mutex_lock(&monitor->playback_mutex);
	deque_push_back(&monitor->new_data, resample_data[0], bytes);
	monitor->packets++;
	monitor->frames += resample_frames;

	/* Hold the renderer back until enough audio is buffered, otherwise it
	 * would start pulling immediately and underrun into silence before the
	 * first real samples ever arrive. This mirrors the PulseAudio backend's
	 * "stay corked until tlength is reached" behaviour. */
	if (!monitor->started && monitor->new_data.size >= monitor->wait_size) {
		if (OH_AudioRenderer_Start(monitor->renderer) == AUDIOSTREAM_SUCCESS) {
			monitor->started = true;
			blog(LOG_INFO, LOG_PREFIX "started monitoring in '%s'", monitor->device);
		} else {
			blog(LOG_WARNING, LOG_PREFIX "OH_AudioRenderer_Start failed");
		}
	}
	pthread_mutex_unlock(&monitor->playback_mutex);
}

/* Routes the renderer to a specific output device, mirroring what
 * plugins/harmony-audio/mic-capture.c does for the capture direction. A failure
 * here is deliberately not fatal: OHAudio falls back to the system default
 * output device, which is a usable (if less precise) result, so
 * audio_monitor_init() carries on regardless. */
static void select_output_device(struct audio_monitor *monitor, const char *id)
{
	OH_AudioDeviceEnhanceManager *enhance_manager = NULL;
	OH_AudioRoutingManager *routing_manager = NULL;
	OH_AudioDeviceDescriptorArray *devices = NULL;
	OH_AudioManager *audio_manager = NULL;
	bool supported = false;
	bool selected = false;
	uint32_t device_id;
	char *end = NULL;
	long parsed;

	if (!id || !*id || strcmp(id, "default") == 0)
		return;

	parsed = strtol(id, &end, 10);
	if (!end || end == id || *end != '\0' || parsed <= 0 || parsed > (long)UINT32_MAX) {
		blog(LOG_WARNING, LOG_PREFIX "invalid monitoring device id '%s'", id);
		return;
	}
	device_id = (uint32_t)parsed;

	/* Initializes the audio manager singleton; the NDK exposes no release
	 * function for the handle (same as mic-capture.c). */
	if (OH_GetAudioManager(&audio_manager) != AUDIOCOMMON_RESULT_SUCCESS) {
		blog(LOG_WARNING, LOG_PREFIX "OH_GetAudioManager failed");
		return;
	}

	if (OH_AudioManager_GetAudioDeviceEnhanceManager(&enhance_manager) != AUDIOCOMMON_RESULT_SUCCESS ||
	    !enhance_manager) {
		blog(LOG_WARNING, LOG_PREFIX "audio device enhance manager unavailable");
		return;
	}

	if (OH_AudioDeviceEnhanceManager_IsEnhancedRoutingSupported(enhance_manager, &supported) !=
		    AUDIOCOMMON_RESULT_SUCCESS ||
	    !supported) {
		blog(LOG_WARNING, LOG_PREFIX "enhanced routing not supported; using system default output device");
		return;
	}

	if (OH_AudioManager_GetAudioRoutingManager(&routing_manager) != AUDIOCOMMON_RESULT_SUCCESS ||
	    !routing_manager) {
		blog(LOG_WARNING, LOG_PREFIX "audio routing manager unavailable");
		return;
	}

	if (OH_AudioRoutingManager_GetDevices(routing_manager, AUDIO_DEVICE_FLAG_OUTPUT, &devices) !=
		    AUDIOCOMMON_RESULT_SUCCESS ||
	    !devices) {
		blog(LOG_WARNING, LOG_PREFIX "failed to enumerate output devices");
		return;
	}

	/* descriptors is checked per-iteration rather than up front so that a
	 * malformed (but non-NULL) response still falls through to
	 * ReleaseDevices below instead of leaking it. */
	for (uint32_t i = 0; devices->descriptors && i < devices->size; i++) {
		OH_AudioDeviceDescriptor *descriptor = devices->descriptors[i];
		uint32_t cur_id = 0;

		if (!descriptor)
			continue;
		if (OH_AudioDeviceDescriptor_GetDeviceId(descriptor, &cur_id) != AUDIOCOMMON_RESULT_SUCCESS)
			continue;
		if (cur_id != device_id)
			continue;

		const OH_AudioCommon_Result result = OH_AudioDeviceEnhanceManager_SelectOutputDeviceForAudioRenderer(
			enhance_manager, monitor->renderer, descriptor);
		if (result != AUDIOCOMMON_RESULT_SUCCESS) {
			blog(LOG_WARNING, LOG_PREFIX "SelectOutputDeviceForAudioRenderer failed with %d", (int)result);
		} else {
			blog(LOG_INFO, LOG_PREFIX "routed monitoring to output device %" PRIu32, device_id);
			selected = true;
		}
		break;
	}

	if (!selected)
		blog(LOG_WARNING, LOG_PREFIX "output device %" PRIu32 " not found; using system default", device_id);

	OH_AudioRoutingManager_ReleaseDevices(routing_manager, devices);
}

static bool audio_monitor_init(struct audio_monitor *monitor, obs_source_t *source)
{
	const struct audio_output_info *info = audio_output_get_info(obs->audio.audio);
	OH_AudioStream_SampleFormat actual_format = MONITOR_SAMPLE_FORMAT;
	OH_AudioStreamBuilder *builder = NULL;
	OH_AudioRenderer *renderer = NULL;
	OH_AudioStream_Result result;
	struct resample_info from;
	struct resample_info to;
	int32_t actual_rate = 0;
	int32_t actual_channels = 0;
	const char *id;

	pthread_mutex_init_value(&monitor->playback_mutex);

	monitor->source = source;

	id = obs->audio.monitoring_device_id;
	if (!id)
		return false;

	if (source->info.output_flags & OBS_SOURCE_DO_NOT_SELF_MONITOR) {
		obs_data_t *s = obs_source_get_settings(source);
		const char *s_dev_id = obs_data_get_string(s, "device_id");
		bool match = devices_match(s_dev_id, id);
		obs_data_release(s);

		if (match) {
			monitor->ignore = true;
			blog(LOG_INFO, LOG_PREFIX "prevented feedback-loop in '%s'", s_dev_id);
			return true;
		}
	}

	if (strcmp(id, "default") == 0)
		harmony_get_default_output_id(&monitor->device);
	else
		monitor->device = bstrdup(id);

	if (!monitor->device)
		return false;

	monitor->samples_per_sec = info->samples_per_sec;
	monitor->speakers = info->speakers;
	monitor->channels = get_audio_channels(info->speakers);
	if (monitor->channels == 0) {
		/* SPEAKERS_UNKNOWN: fall back to stereo, the same default the
		 * other backends use when they cannot map the layout. */
		monitor->channels = 2;
		monitor->speakers = SPEAKERS_STEREO;
	}

	if (OH_AudioStreamBuilder_Create(&builder, AUDIOSTREAM_TYPE_RENDERER) != AUDIOSTREAM_SUCCESS || !builder) {
		blog(LOG_ERROR, LOG_PREFIX "OH_AudioStreamBuilder_Create failed");
		return false;
	}

	OH_AudioStreamBuilder_SetSamplingRate(builder, (int32_t)monitor->samples_per_sec);
	OH_AudioStreamBuilder_SetChannelCount(builder, (int32_t)monitor->channels);
	OH_AudioStreamBuilder_SetSampleFormat(builder, MONITOR_SAMPLE_FORMAT);
	OH_AudioStreamBuilder_SetEncodingType(builder, AUDIOSTREAM_ENCODING_TYPE_RAW);
	OH_AudioStreamBuilder_SetRendererInfo(builder, AUDIOSTREAM_USAGE_MUSIC);
	/* monitor is already the final heap address here (audio_monitor_create()
	 * allocates it before calling this function, unlike the PulseAudio
	 * backend's build-on-stack-then-bmemdup approach) precisely so that this
	 * pointer stays valid for as long as the renderer lives. */
	OH_AudioStreamBuilder_SetRendererWriteDataCallback(builder, on_write_data, monitor);

	result = OH_AudioStreamBuilder_GenerateRenderer(builder, &renderer);
	OH_AudioStreamBuilder_Destroy(builder);
	builder = NULL;

	if (result != AUDIOSTREAM_SUCCESS || !renderer) {
		blog(LOG_ERROR, LOG_PREFIX "GenerateRenderer failed with %d", (int)result);
		return false;
	}

	monitor->renderer = renderer;

	/* The service is free to hand back a different geometry than requested
	 * (mic-capture.c deals with the same thing on the capture side), so
	 * query what was actually negotiated before building the resampler. */
	if (OH_AudioRenderer_GetSamplingRate(renderer, &actual_rate) == AUDIOSTREAM_SUCCESS && actual_rate > 0)
		monitor->samples_per_sec = (uint32_t)actual_rate;
	if (OH_AudioRenderer_GetChannelCount(renderer, &actual_channels) == AUDIOSTREAM_SUCCESS &&
	    actual_channels > 0) {
		monitor->channels = (uint32_t)actual_channels;
		monitor->speakers = channels_to_speaker_layout(monitor->channels);
		if (monitor->speakers == SPEAKERS_UNKNOWN) {
			monitor->channels = 2;
			monitor->speakers = SPEAKERS_STEREO;
		}
	}
	if (OH_AudioRenderer_GetSampleFormat(renderer, &actual_format) == AUDIOSTREAM_SUCCESS &&
	    actual_format != MONITOR_SAMPLE_FORMAT) {
		blog(LOG_WARNING,
		     LOG_PREFIX "renderer negotiated unexpected sample format %d (wanted %d); monitoring audio may be "
				"distorted",
		     (int)actual_format, (int)MONITOR_SAMPLE_FORMAT);
	}

	monitor->bytes_per_frame = monitor->channels * (uint32_t)sizeof(int16_t);

	from.samples_per_sec = info->samples_per_sec;
	from.speakers = info->speakers;
	from.format = AUDIO_FORMAT_FLOAT_PLANAR;

	to.samples_per_sec = monitor->samples_per_sec;
	to.speakers = monitor->speakers;
	to.format = MONITOR_AUDIO_FORMAT;

	monitor->resampler = audio_resampler_create(&to, &from);
	if (!monitor->resampler) {
		blog(LOG_WARNING, LOG_PREFIX "failed to create resampler");
		return false;
	}

	/* ~25ms of audio, matching the PulseAudio backend's tlength, buffered
	 * before the renderer is allowed to start pulling (see
	 * on_audio_playback). */
	monitor->wait_size = (size_t)monitor->bytes_per_frame * monitor->samples_per_sec / 40;

	select_output_device(monitor, monitor->device);

	blog(LOG_INFO, LOG_PREFIX "monitoring '%s' via device '%s' (%" PRIu32 " Hz, %" PRIu32 " ch)",
	     obs_source_get_name(source), monitor->device, monitor->samples_per_sec, monitor->channels);

	return true;
}

static void harmony_stop_playback(struct audio_monitor *monitor)
{
	OH_AudioRenderer *renderer = monitor->renderer;
	monitor->renderer = NULL;

	/* Stop/Release may block until an in-flight on_write_data callback
	 * returns, so this must happen before new_data is freed below - and, as
	 * in plugins/harmony-audio, without holding any lock the callback itself
	 * needs. */
	const OH_AudioStream_Result result = OH_AudioRenderer_Stop(renderer);
	if (result != AUDIOSTREAM_SUCCESS && result != AUDIOSTREAM_ERROR_ILLEGAL_STATE)
		blog(LOG_WARNING, LOG_PREFIX "OH_AudioRenderer_Stop returned %d", (int)result);

	OH_AudioRenderer_Release(renderer);

	blog(LOG_INFO, LOG_PREFIX "stopped monitoring in '%s'", monitor->device);
	blog(LOG_INFO, LOG_PREFIX "got %" PRIuFAST32 " packets with %" PRIuFAST64 " frames, %ld dropped callbacks",
	     monitor->packets, monitor->frames, os_atomic_load_long(&monitor->drops));

	monitor->packets = 0;
	monitor->frames = 0;
}

static inline void audio_monitor_free(struct audio_monitor *monitor)
{
	if (monitor->ignore)
		return;

	if (monitor->source)
		obs_source_remove_audio_capture_callback(monitor->source, on_audio_playback, monitor);

	/* Unlike the push-based PulseAudio backend, on_write_data runs on
	 * OHAudio's own thread and reads new_data directly, so the renderer must
	 * be stopped and released before the deque it pulls from is freed.
	 * Stopping first also guarantees no further on_write_data callback can
	 * be in flight by the time deque_free() runs. */
	if (monitor->renderer)
		harmony_stop_playback(monitor);

	audio_resampler_destroy(monitor->resampler);
	deque_free(&monitor->new_data);

	bfree(monitor->device);
}

static void audio_monitor_init_final(struct audio_monitor *monitor)
{
	if (monitor->ignore)
		return;

	obs_source_add_audio_capture_callback(monitor->source, on_audio_playback, monitor);
}

struct audio_monitor *audio_monitor_create(obs_source_t *source)
{
	struct audio_monitor *monitor = bzalloc(sizeof(*monitor));

	if (!audio_monitor_init(monitor, source))
		goto fail;

	pthread_mutex_lock(&obs->audio.monitoring_mutex);
	da_push_back(obs->audio.monitors, &monitor);
	pthread_mutex_unlock(&obs->audio.monitoring_mutex);

	audio_monitor_init_final(monitor);
	return monitor;

fail:
	audio_monitor_free(monitor);
	bfree(monitor);
	return NULL;
}

void audio_monitor_reset(struct audio_monitor *monitor)
{
	obs_source_t *source = monitor->source;
	bool success;

	audio_monitor_free(monitor);
	memset(monitor, 0, sizeof(*monitor));

	success = audio_monitor_init(monitor, source);
	if (success)
		audio_monitor_init_final(monitor);
}

void audio_monitor_destroy(struct audio_monitor *monitor)
{
	if (monitor) {
		audio_monitor_free(monitor);

		pthread_mutex_lock(&obs->audio.monitoring_mutex);
		da_erase_item(obs->audio.monitors, &monitor);
		pthread_mutex_unlock(&obs->audio.monitoring_mutex);

		bfree(monitor);
	}
}
