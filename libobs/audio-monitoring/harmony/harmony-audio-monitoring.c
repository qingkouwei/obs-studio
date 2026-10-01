#include "harmony-audio-monitoring.h"

#include <ohaudio/native_audio_device_base.h>
#include <ohaudio/native_audio_routing_manager.h>

#include <inttypes.h>
#include <stdio.h>
#include <string.h>

#define LOG_PREFIX "[harmony audio monitoring] "

bool obs_audio_monitoring_available(void)
{
	return true;
}

/* OHAudio does not expose a stable, user-facing device id string the way
 * PulseAudio or CoreAudio do; the closest thing is the numeric id from
 * OH_AudioDeviceDescriptor_GetDeviceId, which is only guaranteed stable for as
 * long as the device stays connected. It is formatted as a decimal string here
 * so it can round-trip through OBS's monitoring_device_id setting (a char *) and
 * back via strtol() in harmony-audio-output.c. */
static bool format_device_id(uint32_t id, char *buf, size_t buf_size)
{
	const int written = snprintf(buf, buf_size, "%" PRIu32, id);

	return written > 0 && (size_t)written < buf_size;
}

void harmony_get_default_output_id(char **p_id)
{
	OH_AudioRoutingManager *routing_manager = NULL;
	OH_AudioDeviceDescriptorArray *devices = NULL;

	if (*p_id)
		return;

	if (OH_AudioManager_GetAudioRoutingManager(&routing_manager) == AUDIOCOMMON_RESULT_SUCCESS &&
	    routing_manager &&
	    OH_AudioRoutingManager_GetPreferredOutputDevice(routing_manager, AUDIOSTREAM_USAGE_MUSIC, &devices) ==
		    AUDIOCOMMON_RESULT_SUCCESS &&
	    devices && devices->size > 0 && devices->descriptors && devices->descriptors[0]) {
		uint32_t id = 0;

		if (OH_AudioDeviceDescriptor_GetDeviceId(devices->descriptors[0], &id) == AUDIOCOMMON_RESULT_SUCCESS) {
			char id_str[16];

			if (format_device_id(id, id_str, sizeof(id_str)))
				*p_id = bstrdup(id_str);
		}

		OH_AudioRoutingManager_ReleaseDevices(routing_manager, devices);
	}

	if (!*p_id)
		*p_id = bzalloc(1);
}

void obs_enum_audio_monitoring_devices(obs_enum_audio_device_cb cb, void *data)
{
	OH_AudioRoutingManager *routing_manager = NULL;
	OH_AudioDeviceDescriptorArray *devices = NULL;

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
		char *display_name = NULL;
		char id_str[16];
		uint32_t id = 0;

		if (!descriptor)
			continue;
		if (OH_AudioDeviceDescriptor_GetDeviceId(descriptor, &id) != AUDIOCOMMON_RESULT_SUCCESS)
			continue;
		if (!format_device_id(id, id_str, sizeof(id_str)))
			continue;

		/* Fall back to the raw id when OHAudio has no localized name for
		 * the device (e.g. a freshly paired Bluetooth sink). */
		if (OH_AudioDeviceDescriptor_GetDeviceDisplayName(descriptor, &display_name) !=
			    AUDIOCOMMON_RESULT_SUCCESS ||
		    !display_name)
			display_name = NULL;

		if (!cb(data, display_name ? display_name : id_str, id_str))
			break;
	}

	OH_AudioRoutingManager_ReleaseDevices(routing_manager, devices);
}

bool devices_match(const char *id1, const char *id2)
{
	char *default_id = NULL;
	bool match;

	if (!id1 || !id2)
		return false;

	if (strcmp(id1, "default") == 0) {
		harmony_get_default_output_id(&default_id);
		id1 = default_id;
	}
	if (strcmp(id2, "default") == 0) {
		harmony_get_default_output_id(&default_id);
		id2 = default_id;
	}

	match = strcmp(id1, id2) == 0;
	bfree(default_id);

	return match;
}
