#!/usr/bin/env python3
"""rctm-test-sender.py — exercise the HarmonyOS remote-camera receiver
(plugins/harmony-remotecam) from a desktop, without a phone peer.

Generates a moving test picture with ffmpeg (baseline H.264 Annex-B), splits
it at NAL start-code boundaries (the OH_VideoDecoder input contract only
requires each PushInputBuffer to hold whole NAL units, not whole access
units) and frames each run of complete NALs with the RCTM wire header from
plugins/harmony-remotecam/remotecam-protocol.h:

    magic u32 | flags u32 | pts_ns i64 | size u32 | payload   (all big-endian)

flags are always 0 — the decoder parses SPS/PPS/IDR from the bitstream
itself and renegotiates geometry via its stream-changed callback, so the
SYNC_FRAME / CODEC_DATA hints are informational only and we leave them off
to keep this tool minimal and unambiguous.

Usage:
    python3 rctm-test-sender.py <device-ip> [--port 25890] [--size 1280x720]
                               [--fps 15] [--bitrate 2000k] [--minutes 5]

Requires ffmpeg on PATH (brew install ffmpeg). Run while the tablet app is
in the foreground with a "无线机位" (harmony_remote_camera) source added on
the listen port; the canvas should fill with the testsrc pattern.
"""
import argparse
import socket
import struct
import subprocess
import sys
import time

MAGIC = 0x5243544D
CHUNK = 32 * 1024


def find_sc(buf, start):
    """Return (pos, sc_len) of the first Annex-B start code at index >= start,
    or (-1, 0). A 4-byte code (00 00 00 01) is reported as pos pointing at
    the first of the three zeros so the caller can cut cleanly before it."""
    i = start
    n = len(buf)
    while i < n - 3:
        if buf[i] == 0 and buf[i + 1] == 0:
            if buf[i + 2] == 1:
                return i, 3
            if buf[i + 2] == 0 and buf[i + 3] == 1:
                return i, 4
        i += 1
    return -1, 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("host")
    ap.add_argument("--port", type=int, default=25890)
    ap.add_argument("--size", default="1280x720")
    ap.add_argument("--fps", type=int, default=15)
    ap.add_argument("--bitrate", default="2000k")
    ap.add_argument("--minutes", type=float, default=5.0)
    args = ap.parse_args()

    w, h = (int(x) for x in args.size.lower().split("x"))

    s = socket.create_connection((args.host, args.port), timeout=10)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    print(f"connected to {args.host}:{args.port}: {args.size}@{args.fps} {args.bitrate}", flush=True)

    ff = subprocess.Popen(
        [
            "ffmpeg", "-hide_banner", "-loglevel", "error",
            "-f", "lavfi", "-i", f"testsrc=size={w}x{h}:rate={args.fps}",
            "-t", str(int(args.minutes * 60)),
            "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
            "-pix_fmt", "yuv420p",
            "-profile:v", "baseline", "-level", "3.1",
            "-x264-params", f"keyint={args.fps * 2}:min-keyint={args.fps}:scenecut=0",
            "-b:v", args.bitrate, "-maxrate", args.bitrate, "-bufsize", "2M",
            "-f", "h264", "pipe:1",
        ],
        stdout=subprocess.PIPE,
    )
    assert ff.stdout is not None

    buf = bytearray()
    start_ns = time.monotonic_ns()
    sent = 0
    total_bytes = 0

    def emit(payload):
        nonlocal sent, total_bytes
        if not payload:
            return
        pts = time.monotonic_ns() - start_ns
        s.sendall(struct.pack(">IIqI", MAGIC, 0, pts, len(payload)) + payload)
        sent += 1
        total_bytes += len(payload) + 20
        if sent % 30 == 0:
            el = (time.monotonic_ns() - start_ns) / 1e9
            print(f"  {sent} msgs, {total_bytes/1e6:.2f} MB (~{total_bytes*8/el/1000:.0f} kbit/s)", flush=True)

    try:
        while True:
            data = ff.stdout.read(CHUNK)
            if not data:
                break
            buf += data
            # Cut at the LAST start code fully present in buf: everything up to
            # it is a whole number of complete NALs (each begins with a start
            # code); the tail is the incomplete last NAL and rolls over.
            pos, _ = find_sc(buf, 0)
            if pos < 0:
                continue
            last = pos
            while True:
                p2, _ = find_sc(buf, last + 3)
                if p2 < 0:
                    break
                last = p2
            # Keep from the last start code onward, send everything before it.
            # If last == 0 there is only one start code so far -> nothing to cut.
            if last == 0:
                continue
            emit(bytes(buf[:last]))
            del buf[:last]
        # stream done: flush the final complete NAL still in buf
        if buf:
            emit(bytes(buf))
    finally:
        ff.kill()
        try:
            s.close()
        except OSError:
            pass

    el = (time.monotonic_ns() - start_ns) / 1e9
    print(f"done: {sent} messages in {el:.1f}s, {total_bytes/1e6:.2f} MB")


if __name__ == "__main__":
    sys.exit(main())
