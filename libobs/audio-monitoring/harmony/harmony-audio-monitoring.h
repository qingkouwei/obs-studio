#pragma once

#include <ohaudio/native_audiostream_base.h>

#include "../../media-io/audio-resampler.h"
#include "../../util/deque.h"
#include "../../util/threading.h"
#include "../../obs-internal.h"

/* One monitor per monitored source, owned by libobs's audio-monitoring layer
 * (obs->audio.monitors). Unlike the push-based PulseAudio backend, OHAudio's
 * renderer is pull-based: it calls back on its own thread whenever it needs
 * more samples. new_data is the ring buffer bridging libobs's audio thread
 * (push side, on_audio_playback) and OHAudio's callback thread (pull side,
 * on_write_data); see harmony-audio-output.c for the locking discipline that
 * keeps the callback thread from ever blocking. */
struct audio_monitor {
	obs_source_t *source;
	OH_AudioRenderer *renderer;
	char *device;

	enum speaker_layout speakers;
	uint32_t samples_per_sec;
	uint32_t channels;
	uint32_t bytes_per_frame;

	uint_fast32_t packets;
	uint_fast64_t frames;
	volatile long drops;

	struct deque new_data;
	audio_resampler_t *resampler;

	size_t wait_size;
	bool started;
	bool ignore;

	pthread_mutex_t playback_mutex;
};

/* Resolves "default" to the id string of whatever output device OHAudio
 * currently prefers, or an empty string when routing information is
 * unavailable. *p_id must be NULL on entry; the caller owns (and must bfree())
 * the result. */
void harmony_get_default_output_id(char **p_id);

bool devices_match(const char *id1, const char *id2);
