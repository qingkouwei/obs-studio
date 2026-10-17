/******************************************************************************
    Copyright (C) 2026 by OBS Studio contributors

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 2 of the License, or
    (at your option) any later version.

    Shared wire format for the HarmonyOS "wireless camera" relay (W3-C1).

    A same-account peer device (phone = the peripheral role) captures its
    camera, encodes it to H.264 and streams it over a LAN TCP socket to the
    producer device (PC / 2in1 / tablet), which decodes it into a libobs
    source. The soft-bus knock signal (obs-knock://camfeed) only triggers the
    session; the bulk video always rides the socket because the collaboration
    text channel cannot carry a real-time H.264 bitstream (base64 inflation
    33% + throughput ceiling — see docs/harmonyos-w3-innovation-plan.md).

    Frame wire layout (all integers big-endian / network byte order):

        magic    u32   = RCTM_MAGIC
        flags    u32   = bitmask of RCTM_FLAG_*
        pts_ns   i64   = presentation timestamp, CLOCK_MONOTONIC nanoseconds
        size     u32   = payload length in bytes
        payload  [size]= one or more Annex-B access units (SPS/PPS/SEI/slices)

    A single TCP connection carries the whole session; the receiver accepts one
    client at a time and re-arms the listener when it drops.
******************************************************************************/

#pragma once

#include <stdint.h>

/* 'R' 'C' 'T' 'M' — Remote Camera Transmission. */
#define RCTM_MAGIC 0x5243544Du

/* Frame flags (sender sets, receiver reads). */
#define RCTM_FLAG_KEY 0x1u /* access unit starts with an IDR (random entry)   */
#define RCTM_FLAG_CONFIG \
	0x2u /* access unit is SPS/PPS only (codec config, no slice)  */
#define RCTM_FLAG_AUDIO \
	0x4u /* payload is an AAC (ADTS) audio access unit, not video; */
/* pts_ns still carries CLOCK_MONOTONIC ns from the capture callback. */

/* Default TCP port the producer listens on. Chosen in the registered-but-
 * rarely-used range to avoid clashing with common dev servers. */
#define RCTM_DEFAULT_PORT 25890u

/* Largest frame we will accept (a 4K keyframe at high bitrate). Anything
 * larger is treated as a stream desync and the connection is reset. */
#define RCTM_MAX_FRAME (8u * 1024u * 1024u)
