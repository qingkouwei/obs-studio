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

    HarmonyOS remote camera source (W3-C1, producer role).

    Listens on a TCP port, accepts one peer at a time, reads RCTM-framed
    H.264 Annex-B access units (see remotecam-protocol.h) and feeds them to
    the OH_VideoDecoder hardware decoder. Decoded NV12 output is converted to
    RGBA on the CPU and delivered with obs_source_output_video() — the same
    proven path as plugins/harmony-camera (Maleoon rejects the GL_R8+GL_RG16
    NV12 upload, so packed RGBA is the only format that renders on device).

    Threading: one listener thread (accept loop) + the codec's own callback
    threads. The listener thread only parses headers and copies payloads into
    a small queue the input-buffer callback drains; decoded frames go straight
    to libobs from the output callback. No lock is held across
    obs_source_output_video().
******************************************************************************/

#include "harmony-remotecam.h"
#include "remotecam-protocol.h"

#include <arpa/inet.h>
#include <errno.h>
#include <inttypes.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <unistd.h>

#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avcodec_videodecoder.h>
#include <multimedia/player_framework/native_avcodec_audiodecoder.h>
#include <multimedia/player_framework/native_avmemory.h>
#include <multimedia/player_framework/native_averrors.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avmemory.h>

#include <util/bmem.h>

#define LOG_PREFIX "[harmony remote cam] "

#define H264_MIME "video/avc"
/* Same NDK constant the sender's OH_AudioEncoder_CreateByMime uses — the
 * wire has no codec-negotiation field, so both ends must agree by symbol,
 * not by hand-typed strings. */

#define AUDIO_SAMPLE_RATE 48000
#define AUDIO_CHANNELS 2

/* Pending input frame queue: the socket thread enqueues whole access units,
 * the onNeedInputBuffer callback dequeues one per free input buffer. Depth 4
 * is enough to ride out decoder hiccups; deeper would just add latency, so
 * the newest frame wins and stale ones drop (live video semantics). */
#define PENDING_MAX 4
#define PENDING_CHUNK (1920 * 1080 * 3 / 2 + 64 * 1024)
#define AUDIO_PENDING_MAX 8

struct pending_frame {
	uint8_t *data;
	size_t size;
	int64_t pts_ns;
	uint32_t flags;
};

struct remotecam_buf {
	struct pending_frame frames[PENDING_MAX];
	int head; /* oldest occupied slot  */
	int count;
	pthread_mutex_t mutex;
};

struct harmony_remotecam {
	/* settings */
	uint16_t port;

	/* socket */
	int listen_fd;
	int client_fd;
	pthread_t accept_thread;
	atomic_bool accept_stop;

	/* decoder */
	OH_AVCodec *decoder;
	pthread_mutex_t codec_mutex; /* serialises reset/flush vs callbacks */
	atomic_bool decoder_ready;   /* configured with a known resolution   */
	uint32_t width;
	uint32_t height;
	uint32_t stride;
	uint32_t slice_height;

	/* pending input queue */
	struct remotecam_buf pending;

	/* audio side (task #36): AAC frames ride the same socket flagged
	 * RCTM_FLAG_AUDIO; decoded to f32 interleaved and emitted with
	 * obs_source_output_audio. */
	OH_AVCodec *adec;
	pthread_mutex_t adec_mutex; /* serialises reset/flush vs callbacks */
	atomic_bool adec_ready;
	struct pending_frame adec_pending[AUDIO_PENDING_MAX];
	int adec_head;
	int adec_count;
	pthread_mutex_t adec_pending_mutex;
	uint32_t audio_rate;   /* from the stream-changed format; 0 = unknown */
	uint32_t audio_ch;
	int32_t audio_format;  /* OH_BitsPerSample of the decoded output */
	bool audio_sniffed;    /* output layout determined by data sniffing */
	/* Clock-domain bridge (10-05): incoming pts is the PEER's CLOCK_MONOTONIC,
	 * which differs from this device's by its uptime offset. libobs' audio
	 * mixer drops frames outside a small window around its own clock —
	 * feeding peer timestamps means every frame gets silently discarded
	 * (-91 dB digital silence in recordings). Anchor once and keep only
	 * the peer-side deltas: local = local_base + (peer_pts - peer_base). */
	int64_t audio_ts_sender_base;
	uint64_t audio_ts_local_base;
	uint8_t audio_csd[64]; /* cached AudioSpecificConfig AU (wire CONFIG)  */
	size_t audio_csd_size;
	bool audio_adts;       /* sniffed: AUs carry ADTS syncwords           */
	bool audio_disabled;   /* decoder never came up: drop audio silently  */
	uint8_t *audio_scratch;      /* deinterleave buffer, guarded by scratch_mutex */
	size_t audio_scratch_size;
	pthread_mutex_t scratch_mutex;

	/* source output */
	obs_source_t *source;
	volatile bool active;
};

/* ------------------------------------------------------------------------ */
/* Helpers                                                                   */
/* ------------------------------------------------------------------------ */

static bool read_full(int fd, void *buf, size_t len)
{
	uint8_t *p = buf;
	while (len > 0) {
		ssize_t n = recv(fd, p, len, 0);
		if (n == 0)
			return false; /* peer closed */
		if (n < 0) {
			if (errno == EINTR)
				continue;
			return false;
		}
		p += n;
		len -= (size_t)n;
	}
	return true;
}

/* Push one access unit into the pending queue, dropping the oldest entry if
 * full (live semantics: recency over completeness). */
static void pending_push(struct harmony_remotecam *rc, const uint8_t *data, size_t size, int64_t pts_ns, uint32_t flags)
{
	pthread_mutex_lock(&rc->pending.mutex);

	if (rc->pending.count == PENDING_MAX) {
		struct pending_frame *oldest = &rc->pending.frames[rc->pending.head];
		rc->pending.head = (rc->pending.head + 1) % PENDING_MAX;
		rc->pending.count--;
		bfree(oldest->data);
		oldest->data = NULL;
		oldest->size = 0;
	}

	int slot = (rc->pending.head + rc->pending.count) % PENDING_MAX;
	struct pending_frame *pf = &rc->pending.frames[slot];
	if (pf->size < size) {
		bfree(pf->data);
		pf->data = bmalloc(size);
		pf->size = size;
	}
	if (pf->data) {
		memcpy(pf->data, data, size);
		pf->pts_ns = pts_ns;
		pf->flags = flags;
		rc->pending.count++;
	}

	pthread_mutex_unlock(&rc->pending.mutex);
}

static bool pending_pop(struct harmony_remotecam *rc, struct pending_frame *out)
{
	pthread_mutex_lock(&rc->pending.mutex);
	if (rc->pending.count == 0) {
		pthread_mutex_unlock(&rc->pending.mutex);
		return false;
	}
	struct pending_frame *src = &rc->pending.frames[rc->pending.head];
	*out = *src;
	src->data = NULL; /* ownership moves to caller */
	src->size = 0;
	rc->pending.head = (rc->pending.head + 1) % PENDING_MAX;
	rc->pending.count--;
	pthread_mutex_unlock(&rc->pending.mutex);
	return true;
}

/* ------------------------------------------------------------------------ */
/* Decoder callbacks                                                         */
/* ------------------------------------------------------------------------ */

static void rc_on_error(OH_AVCodec *codec, int32_t error_code, void *user_data)
{
	struct harmony_remotecam *rc = user_data;
	UNUSED_PARAMETER(codec);
	blog(LOG_WARNING, LOG_PREFIX "decoder error %d (pts state reset)", (int)error_code);
	/* MediaCodec-style errors on OHOS often recover via Flush+Start. */
	pthread_mutex_lock(&rc->codec_mutex);
	if (rc->decoder && atomic_load(&rc->decoder_ready)) {
		OH_VideoDecoder_Flush(rc->decoder);
		OH_VideoDecoder_Start(rc->decoder);
	}
	pthread_mutex_unlock(&rc->codec_mutex);
}

static void rc_on_stream_changed(OH_AVCodec *codec, OH_AVFormat *format, void *user_data)
{
	struct harmony_remotecam *rc = user_data;
	UNUSED_PARAMETER(codec);

	int32_t w = 0, h = 0, stride = 0, slice = 0, pixfmt = 0;
	if (format) {
		OH_AVFormat_GetIntValue(format, OH_MD_KEY_WIDTH, &w);
		OH_AVFormat_GetIntValue(format, OH_MD_KEY_HEIGHT, &h);
		OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_STRIDE, &stride);
		OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_SLICE_HEIGHT, &slice);
		OH_AVFormat_GetIntValue(format, OH_MD_KEY_PIXEL_FORMAT, &pixfmt);
	}

	if (w > 0 && h > 0) {
		rc->width = (uint32_t)w;
		rc->height = (uint32_t)h;
		rc->stride = stride > 0 ? (uint32_t)stride : (uint32_t)w;
		rc->slice_height = slice > 0 ? (uint32_t)slice : (uint32_t)h;
		blog(LOG_INFO, LOG_PREFIX "stream format %ux%u stride=%u slice=%u pixfmt=%d", (unsigned)rc->width,
		     (unsigned)rc->height, (unsigned)rc->stride, (unsigned)rc->slice_height, (int)pixfmt);
		atomic_store(&rc->decoder_ready, true);
		/* Async video sources take their size from get_width/get_height,
		 * which the graphics thread re-queries — no explicit notify needed. */
	}
}

static void rc_on_need_input(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *user_data)
{
	struct harmony_remotecam *rc = user_data;

	struct pending_frame pf = {0};
	if (!pending_pop(rc, &pf)) {
		/* Nothing queued: hand the buffer back empty so the codec keeps
		 * asking. A tiny sleep avoids spinning hot at 1000 Hz on an idle
		 * camera peer — we still get called back quickly. */
		OH_AVCodecBufferAttr attr = {
			.pts = 0,
			.size = 0,
			.offset = 0,
			.flags = AVCODEC_BUFFER_FLAGS_NONE,
		};
		OH_AVBuffer_SetBufferAttr(buffer, &attr);
		OH_VideoDecoder_PushInputBuffer(codec, index);
		return;
	}

	uint32_t capacity = OH_AVBuffer_GetCapacity(buffer);
	if (pf.size > capacity) {
		blog(LOG_WARNING, LOG_PREFIX "AU too large (%zu > %u input capacity), dropped", pf.size, capacity);
		bfree(pf.data);
		OH_AVCodecBufferAttr attr = {.pts = 0, .size = 0, .offset = 0, .flags = AVCODEC_BUFFER_FLAGS_NONE};
		OH_AVBuffer_SetBufferAttr(buffer, &attr);
		OH_VideoDecoder_PushInputBuffer(codec, index);
		return;
	}

	void *addr = OH_AVBuffer_GetAddr(buffer);
	if (addr)
		memcpy(addr, pf.data, pf.size);
	bfree(pf.data);

	OH_AVCodecBufferAttr attr = {
		.pts = pf.pts_ns,
		.size = (uint32_t)pf.size,
		.offset = 0,
		.flags = (pf.flags & RCTM_FLAG_CONFIG) ? AVCODEC_BUFFER_FLAGS_CODEC_DATA
						       : (pf.flags & RCTM_FLAG_KEY ? AVCODEC_BUFFER_FLAGS_SYNC_FRAME
										    : AVCODEC_BUFFER_FLAGS_NONE),
	};
	OH_AVBuffer_SetBufferAttr(buffer, &attr);

	if (OH_VideoDecoder_PushInputBuffer(codec, index) != AV_ERR_OK)
		blog(LOG_WARNING, LOG_PREFIX "PushInputBuffer failed");
}

/* NV12 (from the decoder's linear output buffer) -> RGBA into frame.
 * Same BT.709 limited-range coefficients as plugins/harmony-camera, but the
 * planes are addressed directly: Y at base+stride*y, CbCr at
 * base+stride*slice_height + stride*(y/2) (semi-planar, UV interleaved). */
static void nv12_to_rgba(uint8_t *rgba, uint32_t rgba_linesize, const uint8_t *src, uint32_t width, uint32_t height,
			 uint32_t stride, uint32_t slice_height)
{
	const uint8_t *chroma = src + (size_t)stride * slice_height;

	for (uint32_t row = 0; row + 1 < height; row += 2) {
		const uint8_t *y0 = src + (size_t)row * stride;
		const uint8_t *y1 = src + (size_t)(row + 1) * stride;
		const uint8_t *cv = chroma + (size_t)(row / 2) * stride;
		uint8_t *o0 = rgba + (size_t)row * rgba_linesize;
		uint8_t *o1 = rgba + (size_t)(row + 1) * rgba_linesize;

		for (uint32_t col = 0; col + 1 < width; col += 2) {
			int32_t cb = (int32_t)cv[col] - 128;
			int32_t cr = (int32_t)cv[col + 1] - 128;

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

	if (height & 1) {
		const uint8_t *lsrc = rgba + (size_t)(height - 2) * rgba_linesize;
		memcpy(rgba + (size_t)(height - 1) * rgba_linesize, lsrc, rgba_linesize);
	}
}

static void rc_on_new_output(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *user_data)
{
	struct harmony_remotecam *rc = user_data;

	if (!rc->active) {
		OH_VideoDecoder_FreeOutputBuffer(codec, index);
		return;
	}

	OH_AVCodecBufferAttr attr = {0};
	OH_AVBuffer_GetBufferAttr(buffer, &attr);

	if ((attr.flags & AVCODEC_BUFFER_FLAGS_EOS) || attr.size == 0) {
		OH_VideoDecoder_FreeOutputBuffer(codec, index);
		return;
	}

	const uint32_t w = rc->width, h = rc->height;
	if (w > 0 && h > 0) {
		struct obs_source_frame *frame = obs_source_frame_create(VIDEO_FORMAT_RGBA, w, h);
		if (frame) {
			frame->full_range = true;
			const uint8_t *src = (const uint8_t *)OH_AVBuffer_GetAddr(buffer);
			if (src) {
				nv12_to_rgba(frame->data[0], frame->linesize[0], src, w, h, rc->stride,
					     rc->slice_height);
				frame->timestamp = (attr.pts > 0) ? (uint64_t)attr.pts : os_gettime_ns();
				obs_source_output_video(rc->source, frame);
			}
			obs_source_frame_destroy(frame);
		}
	}

	OH_VideoDecoder_FreeOutputBuffer(codec, index);
}

/* ------------------------------------------------------------------------ */
/* Decoder lifecycle                                                         */
/* ------------------------------------------------------------------------ */

static bool decoder_start(struct harmony_remotecam *rc)
{
	pthread_mutex_lock(&rc->codec_mutex);

	if (rc->decoder) {
		pthread_mutex_unlock(&rc->codec_mutex);
		return true;
	}

	OH_AVCodec *dec = OH_VideoDecoder_CreateByMime(H264_MIME);
	if (!dec) {
		pthread_mutex_unlock(&rc->codec_mutex);
		blog(LOG_ERROR, LOG_PREFIX "OH_VideoDecoder_CreateByMime(" H264_MIME ") failed");
		return false;
	}

	OH_AVFormat *fmt = OH_AVFormat_Create();
	OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_WIDTH, 1920);
	OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_HEIGHT, 1080);
	/* Hardware decoders emit NV12 by default on this device; do not force
	 * a format — the stream-changed callback reads the real geometry. */
	OH_AVErrCode cret = OH_VideoDecoder_Configure(dec, fmt);
	OH_AVFormat_Destroy(fmt);
	if (cret != AV_ERR_OK) {
		blog(LOG_ERROR, LOG_PREFIX "decoder Configure failed (%d)", (int)cret);
		OH_VideoDecoder_Destroy(dec);
		pthread_mutex_unlock(&rc->codec_mutex);
		return false;
	}

	OH_AVCodecCallback cb = {
		.onError = rc_on_error,
		.onStreamChanged = rc_on_stream_changed,
		.onNeedInputBuffer = rc_on_need_input,
		.onNewOutputBuffer = rc_on_new_output,
	};
	if (OH_VideoDecoder_RegisterCallback(dec, cb, rc) != AV_ERR_OK) {
		blog(LOG_ERROR, LOG_PREFIX "decoder RegisterCallback failed");
		OH_VideoDecoder_Destroy(dec);
		pthread_mutex_unlock(&rc->codec_mutex);
		return false;
	}

	if (OH_VideoDecoder_Start(dec) != AV_ERR_OK) {
		blog(LOG_ERROR, LOG_PREFIX "decoder Start failed");
		OH_VideoDecoder_Destroy(dec);
		pthread_mutex_unlock(&rc->codec_mutex);
		return false;
	}

	rc->decoder = dec;
	rc->width = 0;
	rc->height = 0;
	rc->stride = 0;
	rc->slice_height = 0;
	atomic_store(&rc->decoder_ready, false);
	blog(LOG_INFO, LOG_PREFIX "hardware H.264 decoder started");
	pthread_mutex_unlock(&rc->codec_mutex);
	return true;
}

static void decoder_stop(struct harmony_remotecam *rc)
{
	pthread_mutex_lock(&rc->codec_mutex);
	if (rc->decoder) {
		OH_VideoDecoder_Stop(rc->decoder);
		OH_VideoDecoder_Destroy(rc->decoder);
		rc->decoder = NULL;
		atomic_store(&rc->decoder_ready, false);
		blog(LOG_INFO, LOG_PREFIX "decoder stopped");
	}
	pthread_mutex_unlock(&rc->codec_mutex);
}

/* ------------------------------------------------------------------------ */
/* Audio path (task #36): AAC AU -> OH_AudioDecoder -> obs_source_output_audio */
/* ------------------------------------------------------------------------ */

static void adec_pending_push(struct harmony_remotecam *rc, uint8_t *data, size_t size, int64_t pts_ns,
			      uint32_t flags)
{
	pthread_mutex_lock(&rc->adec_pending_mutex);
	if (rc->adec_count == AUDIO_PENDING_MAX) {
		struct pending_frame *oldest = &rc->adec_pending[rc->adec_head];
		rc->adec_head = (rc->adec_head + 1) % AUDIO_PENDING_MAX;
		rc->adec_count--;
		bfree(oldest->data);
		oldest->data = NULL;
		oldest->size = 0;
	}
	int slot = (rc->adec_head + rc->adec_count) % AUDIO_PENDING_MAX;
	struct pending_frame *pf = &rc->adec_pending[slot];
	if (pf->size < size) {
		bfree(pf->data);
		pf->data = bmalloc(size);
		pf->size = size;
	}
	if (pf->data) {
		memcpy(pf->data, data, size);
		pf->pts_ns = pts_ns;
		pf->flags = flags;
		rc->adec_count++;
	}
	pthread_mutex_unlock(&rc->adec_pending_mutex);
}

static bool adec_pending_pop(struct harmony_remotecam *rc, struct pending_frame *out)
{
	pthread_mutex_lock(&rc->adec_pending_mutex);
	if (rc->adec_count == 0) {
		pthread_mutex_unlock(&rc->adec_pending_mutex);
		return false;
	}
	struct pending_frame *src = &rc->adec_pending[rc->adec_head];
	*out = *src;
	src->data = NULL;
	src->size = 0;
	rc->adec_head = (rc->adec_head + 1) % AUDIO_PENDING_MAX;
	rc->adec_count--;
	pthread_mutex_unlock(&rc->adec_pending_mutex);
	return true;
}

static void adec_on_error(OH_AVCodec *codec, int32_t error_code, void *user_data)
{
	UNUSED_PARAMETER(codec);
	struct harmony_remotecam *rc = user_data;
	(void)rc;
	blog(LOG_WARNING, LOG_PREFIX "audio decoder error %d", (int)error_code);
}

static void adec_on_stream_changed(OH_AVCodec *codec, OH_AVFormat *format, void *user_data)
{
	UNUSED_PARAMETER(codec);
	struct harmony_remotecam *rc = user_data;
	int32_t rate = 0, ch = 0, fmt = 0;
	if (format) {
		OH_AVFormat_GetIntValue(format, OH_MD_KEY_AUD_SAMPLE_RATE, &rate);
		OH_AVFormat_GetIntValue(format, OH_MD_KEY_AUD_CHANNEL_COUNT, &ch);
		OH_AVFormat_GetIntValue(format, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, &fmt);
	}
	if (rate > 0)
		rc->audio_rate = (uint32_t)rate;
	if (ch > 0)
		rc->audio_ch = (uint32_t)ch;
	rc->audio_format = fmt;
	/* Sane defaults keep audio alive even if the codec never reports. */
	if (rc->audio_rate == 0)
		rc->audio_rate = AUDIO_SAMPLE_RATE;
	if (rc->audio_ch == 0)
		rc->audio_ch = AUDIO_CHANNELS;
	blog(LOG_INFO, LOG_PREFIX "audio stream: %u Hz %u ch fmt=%d (ready)", rc->audio_rate, rc->audio_ch, fmt);
	atomic_store(&rc->adec_ready, true);
}

static void adec_on_need_input(OH_AVCodec *codec, uint32_t index, OH_AVMemory *mem, void *user_data)
{
	struct harmony_remotecam *rc = user_data;
	OH_AVCodecBufferAttr attr = {0};

	static int ni_probe;
	if (++ni_probe <= 3)
		blog(LOG_INFO, LOG_PREFIX "audio need_input #%d cap=%d", ni_probe, OH_AVMemory_GetSize(mem));

	struct pending_frame pf;
	if (rc->active && adec_pending_pop(rc, &pf)) {
		uint8_t *addr = OH_AVMemory_GetAddr(mem);
		int32_t cap = OH_AVMemory_GetSize(mem);
		static int feed_probe;
		if (++feed_probe <= 3)
			blog(LOG_INFO, LOG_PREFIX "audio feed #%d size=%zu cap=%d addr=%d", feed_probe, pf.size, cap,
			     addr != NULL);
		if (addr && pf.size <= (size_t)cap) {
			memcpy(addr, pf.data, pf.size);
			attr.pts = pf.pts_ns;
			attr.size = (uint32_t)pf.size;
			attr.flags = (pf.flags & RCTM_FLAG_CONFIG) ? AVCODEC_BUFFER_FLAGS_CODEC_DATA
								   : AVCODEC_BUFFER_FLAGS_NONE;
		}
		bfree(pf.data);
	}
	OH_AVErrCode push_ret = OH_AudioDecoder_PushInputData(codec, index, attr);
	static int push_probe;
	if (++push_probe <= 3 && attr.size > 0)
		blog(LOG_INFO, LOG_PREFIX "audio push #%d size=%u ret=%d", push_probe, attr.size, (int)push_ret);
}

static void adec_on_new_output(OH_AVCodec *codec, uint32_t index, OH_AVMemory *mem, OH_AVCodecBufferAttr *attr,
			       void *user_data)
{
	struct harmony_remotecam *rc = user_data;

	static int out_probe;
	if (++out_probe <= 3) {
		/* Energy of first 256 bytes: 0 = decoder emits pure silence,
		 * nonzero = payload fine and the fault is downstream. */
		uint32_t sum = 0;
		const uint8_t *p = (const uint8_t *)OH_AVMemory_GetAddr(mem);
		for (int i = 0; p && i < 256 && i < attr->size; i++)
			sum += p[i];
		blog(LOG_INFO, LOG_PREFIX "audio new_output #%d size=%d flags=0x%x byte_sum256=%u", out_probe,
		     attr ? attr->size : -1, attr ? attr->flags : 0, sum);
	}

	if (!rc->active || attr->size == 0 || (attr->flags & AVCODEC_BUFFER_FLAGS_EOS)) {
		OH_AudioDecoder_FreeOutputData(codec, index);
		return;
	}

	const uint8_t *src = (const uint8_t *)OH_AVMemory_GetAddr(mem);
	if (src && rc->audio_ch > 0) {
		/* Ask the decoder directly what it produced: the configured
		 * hint does not guarantee the delivered layout. (The returned
		 * format instance is owned by the codec — read, don't free.) */
		OH_AVFormat *desc = OH_AudioDecoder_GetOutputDescription(codec);
		int32_t rate = (int32_t)rc->audio_rate, ch = (int32_t)rc->audio_ch, fmt = rc->audio_format;
		bool fmt_from_codec = false;
		if (desc) {
			OH_AVFormat_GetIntValue(desc, OH_MD_KEY_AUD_SAMPLE_RATE, &rate);
			OH_AVFormat_GetIntValue(desc, OH_MD_KEY_AUD_CHANNEL_COUNT, &ch);
			if (OH_AVFormat_GetIntValue(desc, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, &fmt))
				fmt_from_codec = true;
		}
		if (rate <= 0)
			rate = AUDIO_SAMPLE_RATE;
		if (ch <= 0)
			ch = AUDIO_CHANNELS;

		/* Data sniffing (10-05): the OHOS AAC decoder emits S16 despite
		 * an F32 configure hint, reports no stream-changed, and its
		 * output description may not carry the format key — and feeding
		 * S16 bytes into a float deinterleave yields denormal garbage
		 * (mean -91 dB). Sniff once: valid float32 samples keep their
		 * top byte at the sign+exponent nibble (|x| < 2 → byte3 ∈
		 * {0x3F,0x3E,0x3D,0x3C,0x00,0xBE,0xBD,0xBC,0xBF}); S16 noise
		 * scatters across all 256 values. */
		if (!fmt_from_codec && !rc->audio_sniffed) {
			/* The decoder's first frames are legitimately silent
			 * (AAC warm-up) — all-zero bytes would sniff as S16 and
			 * mis-interleave real F32 output later. Only sniff a
			 * frame that carries energy; the F32 default stands until
			 * then (and 8192 B/AU = 1024 x 2ch x 4B is F32 geometry
			 * on this device, confirmed 10-05). */
			uint32_t energy = 0;
			for (int i = 0; i < attr->size; i += 64)
				energy += src[i];
			if (energy >= 8) {
				int n4 = (attr->size / 4) < 256 ? (attr->size / 4) : 256;
				int floaty = 0;
				for (int i = 0; i < n4; i++) {
					uint8_t top = src[i * 4 + 3];
					uint8_t hi = top & 0x7F;
					if (hi >= 0x3C && hi <= 0x3F)
						floaty++;
				}
				rc->audio_format = (floaty * 10 >= n4 * 7) ? SAMPLE_F32LE : SAMPLE_S16LE;
				rc->audio_sniffed = true;
				blog(LOG_INFO, LOG_PREFIX "audio format sniffed: %s (floaty %d/%d)",
				     rc->audio_format == SAMPLE_F32LE ? "F32" : "S16", floaty, n4);
				fmt = rc->audio_format;
			}
		}

		const bool is_float = (fmt == SAMPLE_F32LE);
		const uint32_t es = is_float ? 4 : 2;
		struct obs_source_audio audio = {0};
		audio.format = is_float ? AUDIO_FORMAT_FLOAT : AUDIO_FORMAT_16BIT;
		audio.samples_per_sec = (uint32_t)rate;
		audio.speakers = (ch >= 2) ? SPEAKERS_STEREO : SPEAKERS_MONO;

		if (ch == 2) {
			/* Stereo arrives INTERLEAVED but libobs async audio
			 * wants PLANES (16BIT: data[0]=L data[1]=R). Deinterleave
			 * into a scratch buffer under its own lock — adec_mutex
			 * stays free so stop() cannot deadlock against callbacks.
			 * Same trap applies to F32 stereo (device probe 10-05:
			 * feeding interleaved bytes as one float plane yields
			 * denormal garbage, mean -91 dB). */
			pthread_mutex_lock(&rc->scratch_mutex);
			const uint32_t frames = (uint32_t)((size_t)attr->size / (2 * es));
			if (frames > 0 && frames <= 1536) {
				if (rc->audio_scratch_size < (size_t)frames * es * 2) {
					bfree(rc->audio_scratch);
					rc->audio_scratch_size = (size_t)frames * es * 2;
					rc->audio_scratch = bmalloc(rc->audio_scratch_size);
				}
				if (rc->audio_scratch) {
					if (rc->audio_ts_sender_base == 0) {
						rc->audio_ts_sender_base = attr->pts;
						rc->audio_ts_local_base = os_gettime_ns();
					}
					if (is_float) {
						float *plane0 = (float *)rc->audio_scratch;
						float *plane1 = plane0 + frames;
						const float *in = (const float *)src;
						for (uint32_t i = 0; i < frames; i++) {
							plane0[i] = in[2 * i];
							plane1[i] = in[2 * i + 1];
						}
					} else {
						int16_t *plane0 = (int16_t *)rc->audio_scratch;
						int16_t *plane1 = plane0 + frames;
						const int16_t *in = (const int16_t *)src;
						for (uint32_t i = 0; i < frames; i++) {
							plane0[i] = in[2 * i];
							plane1[i] = in[2 * i + 1];
						}
					}
					audio.frames = frames;
					audio.data[0] = rc->audio_scratch;
					audio.data[1] = rc->audio_scratch + frames * es;
					audio.timestamp = rc->audio_ts_local_base +
							  ((int64_t)attr->pts - rc->audio_ts_sender_base);
					obs_source_output_audio(rc->source, &audio);
				}
			}
			pthread_mutex_unlock(&rc->scratch_mutex);
		} else if (ch == 1) {
			uint32_t frames = (uint32_t)((size_t)attr->size / es);
			if (frames > 1536)
				frames = 1536;
			audio.frames = frames;
			audio.data[0] = (uint8_t *)src;
			if (rc->audio_ts_sender_base == 0) {
				rc->audio_ts_sender_base = attr->pts;
				rc->audio_ts_local_base = os_gettime_ns();
			}
			audio.timestamp = rc->audio_ts_local_base + ((int64_t)attr->pts - rc->audio_ts_sender_base);
			obs_source_output_audio(rc->source, &audio);
		} else {
			static bool warned_layout = false;
			if (!warned_layout) {
				warned_layout = true;
				blog(LOG_WARNING, LOG_PREFIX "audio layout rate=%d ch=%d fmt=%d unhandled — video-only",
				     (int)rate, (int)ch, (int)fmt);
			}
		}
	}

	OH_AudioDecoder_FreeOutputData(codec, index);
}

static bool adec_start(struct harmony_remotecam *rc)
{
	pthread_mutex_lock(&rc->adec_mutex);
	if (rc->adec) {
		pthread_mutex_unlock(&rc->adec_mutex);
		return true;
	}
	if (rc->audio_disabled) {
		pthread_mutex_unlock(&rc->adec_mutex);
		return false;
	}

	OH_AVCodec *dec = OH_AudioDecoder_CreateByMime(OH_AVCODEC_MIMETYPE_AUDIO_AAC);
	if (!dec) {
		rc->audio_disabled = true;
		blog(LOG_WARNING, LOG_PREFIX "no AAC hardware decoder — feed stays video-only");
		pthread_mutex_unlock(&rc->adec_mutex);
		return false;
	}

	OH_AVFormat *fmt = OH_AVFormat_Create();
	OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_AUD_SAMPLE_RATE, (int32_t)rc->audio_rate);
	OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_AUD_CHANNEL_COUNT, (int32_t)rc->audio_ch);
	OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, SAMPLE_F32LE);
	/* The sender's OH_AudioEncoder emits ADTS-framed AUs (device probe
	 * 10-05: first AU starts 0xFFF1). ADTS is self-describing, so no
	 * AudioSpecificConfig CSD is needed — but the decoder must be TOLD
	 * to expect it, else it parses the 7-byte headers as raw payload
	 * and never emits a single frame. */
	OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_AAC_IS_ADTS, 1);
	if (rc->audio_csd_size > 0) {
		OH_AVFormat_SetBuffer(fmt, OH_MD_KEY_CODEC_CONFIG, rc->audio_csd, rc->audio_csd_size);
	}
	if (OH_AudioDecoder_Configure(dec, fmt) != AV_ERR_OK) {
		OH_AVFormat_Destroy(fmt);
		OH_AudioDecoder_Destroy(dec);
		rc->audio_disabled = true;
		blog(LOG_WARNING, LOG_PREFIX "audio decoder configure failed — video-only");
		pthread_mutex_unlock(&rc->adec_mutex);
		return false;
	}
	OH_AVFormat_Destroy(fmt);

	OH_AVCodecAsyncCallback cb = {
		.onError = adec_on_error,
		.onStreamChanged = adec_on_stream_changed,
		.onNeedInputData = adec_on_need_input,
		.onNeedOutputData = adec_on_new_output,
	};
	if (OH_AudioDecoder_SetCallback(dec, cb, rc) != AV_ERR_OK) {
		OH_AudioDecoder_Destroy(dec);
		rc->audio_disabled = true;
		blog(LOG_WARNING, LOG_PREFIX "audio decoder SetCallback failed — video-only");
		pthread_mutex_unlock(&rc->adec_mutex);
		return false;
	}
	if (OH_AudioDecoder_Prepare(dec) != AV_ERR_OK || OH_AudioDecoder_Start(dec) != AV_ERR_OK) {
		OH_AudioDecoder_Destroy(dec);
		rc->audio_disabled = true;
		blog(LOG_WARNING, LOG_PREFIX "audio decoder start failed — video-only");
		pthread_mutex_unlock(&rc->adec_mutex);
		return false;
	}

	rc->adec = dec;
	blog(LOG_INFO, LOG_PREFIX "AAC audio decoder started (%u Hz, %u ch)", rc->audio_rate, rc->audio_ch);
	pthread_mutex_unlock(&rc->adec_mutex);
	return true;
}

static void adec_stop(struct harmony_remotecam *rc)
{
	pthread_mutex_lock(&rc->adec_mutex);
	if (rc->adec) {
		OH_AudioDecoder_Stop(rc->adec);
		OH_AudioDecoder_Destroy(rc->adec);
		rc->adec = NULL;
		atomic_store(&rc->adec_ready, false);
		blog(LOG_INFO, LOG_PREFIX "audio decoder stopped");
	}
	pthread_mutex_unlock(&rc->adec_mutex);
}

/* ------------------------------------------------------------------------ */
/* Socket receive loop                                                       */
/* ------------------------------------------------------------------------ */

static void *rc_accept_thread(void *arg)
{
	struct harmony_remotecam *rc = arg;

	while (!atomic_load(&rc->accept_stop)) {
		struct sockaddr_in addr = {0};
		socklen_t len = sizeof(addr);
		int fd = accept(rc->listen_fd, (struct sockaddr *)&addr, &len);
		if (fd < 0) {
			if (errno == EINTR)
				continue;
			break; /* listener closed */
		}

		int one = 1;
		setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
		/* Dead-peer watchdog: when the sender is suspended (screen off) its
		 * socket neither sends nor closes — recv() would block the accept
		 * thread forever and later reconnects pile up in the listen queue
		 * unaccepted (observed 10-05: LISTEN Recv-Q=3, sender "connect
		 * timeout"). Live video pushes data every ~33 ms, so 10 s of
		 * silence means the peer is gone: drop it and re-arm accept. */
		struct timeval rcv_timeout = {.tv_sec = 10, .tv_usec = 0};
		setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rcv_timeout, sizeof(rcv_timeout));
		rc->client_fd = fd;

		int64_t frame_seq = 0;
		blog(LOG_INFO, LOG_PREFIX "peer connected from %s:%d", inet_ntoa(addr.sin_addr),
		     (int)ntohs(addr.sin_port));

		while (!atomic_load(&rc->accept_stop)) {
			/* magic(4) flags(4) pts(8) size(4) = 20 bytes big-endian */
			uint8_t hbuf[20];
			if (!read_full(fd, hbuf, sizeof(hbuf)))
				break;

			const uint32_t magic = (uint32_t)hbuf[0] << 24 | (uint32_t)hbuf[1] << 16 | (uint32_t)hbuf[2] << 8 |
					       hbuf[3];
			const uint32_t flags = (uint32_t)hbuf[4] << 24 | (uint32_t)hbuf[5] << 16 | (uint32_t)hbuf[6] << 8 |
					       hbuf[7];
			int64_t pts = 0;
			for (int i = 0; i < 8; i++)
				pts = (pts << 8) | hbuf[8 + i];
			const uint32_t size = (uint32_t)hbuf[16] << 24 | (uint32_t)hbuf[17] << 16 |
					      (uint32_t)hbuf[18] << 8 | hbuf[19];

			if (magic != RCTM_MAGIC || size == 0 || size > RCTM_MAX_FRAME) {
				blog(LOG_WARNING, LOG_PREFIX "bad frame header (magic %08x size %u), resetting peer",
				     magic, size);
				break;
			}

			uint8_t *payload = bmalloc(size);
			if (!read_full(fd, payload, size)) {
				bfree(payload);
				break;
			}

			if (flags & RCTM_FLAG_AUDIO) {
				/* Audio path. ADTS AUs are self-configuring, so
				 * the CONFIG flag (if ever present) is cached but
				 * not required. Feed gate: the decoder being
				 * STARTED (not yet "ready") — adec_ready only
				 * flips once the codec emits, so gating on it
				 * here would starve it (chicken-and-egg, found
				 * 10-05). The need-input callback drains the
				 * queue as soon as the codec asks. */
				if ((flags & RCTM_FLAG_CONFIG) && size <= sizeof(rc->audio_csd)) {
					memcpy(rc->audio_csd, payload, size);
					rc->audio_csd_size = size;
				}
				pthread_mutex_lock(&rc->adec_mutex);
				bool started = rc->adec != NULL;
				pthread_mutex_unlock(&rc->adec_mutex);
				if (!started && !rc->audio_disabled) {
					if (!adec_start(rc)) {
						bfree(payload);
						continue; /* video-only; drop the audio AU */
					}
				}
				if (!rc->audio_disabled) {
					adec_pending_push(rc, payload, size, pts, flags);
				}
				bfree(payload);
				continue;
			}

			if (!atomic_load(&rc->decoder_ready) || !rc->decoder) {
				if (!decoder_start(rc)) {
					bfree(payload);
					break;
				}
			}

			pending_push(rc, payload, size, pts, flags);
			bfree(payload);
			frame_seq++;
		}

		close(fd);
		rc->client_fd = -1;
		/* Reset audio for the next session: the CSD/params must be
		 * renegotiated from the new stream's first config AU. The
		 * timestamp anchor and format sniff are PEER-SESSION state —
		 * a new sender lives in a different CLOCK_MONOTONIC domain
		 * (10-05: the mac sine test polluted the anchor, then the
		 * phone stream's pts mapped wildly and every frame dropped
		 * -> -91 dB despite an otherwise healthy pipeline). */
		adec_stop(rc);
		rc->audio_disabled = false;
		rc->audio_csd_size = 0;
		rc->audio_sniffed = false;
		rc->audio_format = SAMPLE_F32LE;
		rc->audio_ts_sender_base = 0;
		rc->audio_ts_local_base = 0;
		blog(LOG_INFO, LOG_PREFIX "peer disconnected after %" PRId64 " frames", frame_seq);
	}

	return NULL;
}

/* ------------------------------------------------------------------------ */
/* OBS source plumbing                                                       */
/* ------------------------------------------------------------------------ */

static const char *remotecam_get_name(void *unused)
{
	UNUSED_PARAMETER(unused);
	return "Remote Camera (HarmonyOS)";
}

static void *remotecam_create(obs_data_t *settings, obs_source_t *source)
{
	struct harmony_remotecam *rc = bzalloc(sizeof(*rc));
	rc->source = source;
	rc->listen_fd = -1;
	rc->client_fd = -1;
	rc->port = RCTM_DEFAULT_PORT;
	atomic_store(&rc->accept_stop, false);
	atomic_store(&rc->decoder_ready, false);
	pthread_mutex_init(&rc->codec_mutex, NULL);
	pthread_mutex_init(&rc->pending.mutex, NULL);
	pthread_mutex_init(&rc->adec_mutex, NULL);
	pthread_mutex_init(&rc->adec_pending_mutex, NULL);
	pthread_mutex_init(&rc->scratch_mutex, NULL);
	atomic_store(&rc->adec_ready, false);
	rc->audio_rate = AUDIO_SAMPLE_RATE;
	rc->audio_ch = AUDIO_CHANNELS;
	rc->audio_format = SAMPLE_F32LE;
	for (int i = 0; i < PENDING_MAX; i++) {
		rc->pending.frames[i].data = NULL;
		rc->pending.frames[i].size = 0;
	}
	for (int i = 0; i < AUDIO_PENDING_MAX; i++) {
		rc->adec_pending[i].data = NULL;
		rc->adec_pending[i].size = 0;
	}

	if (settings) {
		const char *ps = obs_data_get_string(settings, "port");
		if (ps && *ps) {
			int p = atoi(ps);
			if (p > 0 && p < 65536)
				rc->port = (uint16_t)p;
		}
	}

	return rc;
}

static bool rc_listen(struct harmony_remotecam *rc)
{
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0) {
		blog(LOG_ERROR, LOG_PREFIX "socket() failed: %s", strerror(errno));
		return false;
	}
	int one = 1;
	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

	struct sockaddr_in sa = {0};
	sa.sin_family = AF_INET;
	sa.sin_addr.s_addr = INADDR_ANY;
	sa.sin_port = htons(rc->port);

	if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		blog(LOG_ERROR, LOG_PREFIX "bind(:%u) failed: %s", (unsigned)rc->port, strerror(errno));
		close(fd);
		return false;
	}
	if (listen(fd, 2) < 0) {
		blog(LOG_ERROR, LOG_PREFIX "listen() failed: %s", strerror(errno));
		close(fd);
		return false;
	}
	rc->listen_fd = fd;
	return true;
}

static void rc_stop_all(struct harmony_remotecam *rc)
{
	rc->active = false;

	if (rc->listen_fd >= 0) {
		atomic_store(&rc->accept_stop, true);
		shutdown(rc->listen_fd, SHUT_RDWR);
		close(rc->listen_fd);
		rc->listen_fd = -1;
		pthread_join(rc->accept_thread, NULL);
	}

	decoder_stop(rc);
	adec_stop(rc);

	pthread_mutex_lock(&rc->adec_pending_mutex);
	for (int i = 0; i < AUDIO_PENDING_MAX; i++) {
		bfree(rc->adec_pending[i].data);
		rc->adec_pending[i].data = NULL;
		rc->adec_pending[i].size = 0;
	}
	rc->adec_head = 0;
	rc->adec_count = 0;
	pthread_mutex_unlock(&rc->adec_pending_mutex);

	pthread_mutex_lock(&rc->pending.mutex);
	for (int i = 0; i < PENDING_MAX; i++) {
		bfree(rc->pending.frames[i].data);
		rc->pending.frames[i].data = NULL;
		rc->pending.frames[i].size = 0;
	}
	rc->pending.head = 0;
	rc->pending.count = 0;
	pthread_mutex_unlock(&rc->pending.mutex);
}

static void remotecam_destroy(void *data)
{
	struct harmony_remotecam *rc = data;
	rc_stop_all(rc);
	pthread_mutex_destroy(&rc->codec_mutex);
	pthread_mutex_destroy(&rc->pending.mutex);
	pthread_mutex_destroy(&rc->adec_mutex);
	pthread_mutex_destroy(&rc->adec_pending_mutex);
	pthread_mutex_destroy(&rc->scratch_mutex);
	for (int i = 0; i < AUDIO_PENDING_MAX; i++)
		bfree(rc->adec_pending[i].data);
	bfree(rc->audio_scratch);
	bfree(rc);
}

static void remotecam_activate(void *data)
{
	struct harmony_remotecam *rc = data;
	if (rc->active)
		return;
	rc->active = true;
	atomic_store(&rc->accept_stop, false);

	if (!rc_listen(rc)) {
		rc->active = false;
		return;
	}
	if (pthread_create(&rc->accept_thread, NULL, rc_accept_thread, rc) != 0) {
		blog(LOG_ERROR, LOG_PREFIX "failed to spawn accept thread");
		close(rc->listen_fd);
		rc->listen_fd = -1;
		rc->active = false;
	}
}

static void remotecam_deactivate(void *data)
{
	struct harmony_remotecam *rc = data;
	rc_stop_all(rc);
}

static void remotecam_update(void *data, obs_data_t *settings)
{
	struct harmony_remotecam *rc = data;
	if (!settings)
		return;
	const char *ps = obs_data_get_string(settings, "port");
	uint16_t want = rc->port;
	if (ps && *ps) {
		int p = atoi(ps);
		if (p > 0 && p < 65536)
			want = (uint16_t)p;
	}
	if (want != rc->port && rc->active) {
		rc->port = want;
		rc_stop_all(rc);
		remotecam_activate(rc);
	} else {
		rc->port = want;
	}
}

static uint32_t remotecam_get_width(void *data)
{
	struct harmony_remotecam *rc = data;
	return rc->width;
}

static uint32_t remotecam_get_height(void *data)
{
	struct harmony_remotecam *rc = data;
	return rc->height;
}

static obs_properties_t *remotecam_properties(void *data)
{
	UNUSED_PARAMETER(data);
	obs_properties_t *props = obs_properties_create();
	obs_properties_add_text(props, "port", "Listen port (TCP)", OBS_TEXT_DEFAULT);
	return props;
}

static void remotecam_get_defaults(obs_data_t *settings)
{
	/* The UI stores "port" as a text property (string) — keep the default
	 * in the same type so a fresh source reads it without a type miss. */
	char def[8];
	snprintf(def, sizeof(def), "%u", (unsigned)RCTM_DEFAULT_PORT);
	obs_data_set_default_string(settings, "port", def);
}

struct obs_source_info harmony_remotecam_info = {
	.id = "harmony_remote_camera",
	.type = OBS_SOURCE_TYPE_INPUT,
	/* Async video (RGBA frames from the decoder callback) plus async
	 * audio (PCM from the AAC decoder callback) — both emitted from
	 * codec threads via the *_output_* entry points. */
	.output_flags = OBS_SOURCE_ASYNC_VIDEO | OBS_SOURCE_AUDIO,
	.get_name = remotecam_get_name,
	.create = remotecam_create,
	.destroy = remotecam_destroy,
	.activate = remotecam_activate,
	.deactivate = remotecam_deactivate,
	.update = remotecam_update,
	.get_width = remotecam_get_width,
	.get_height = remotecam_get_height,
	.get_defaults = remotecam_get_defaults,
	.get_properties = remotecam_properties,
};
