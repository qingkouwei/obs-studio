/**
 * JPGM — "Program JPEG Monitor" wire format for the W3-C4 director console:
 * the producer (PC / 2in1 / tablet) ships its PROGRAM picture to the phone
 * over a LAN TCP socket, so the phone console is a true monitor-and-switch
 * desk instead of a blind button pad.
 *
 * The collaboration channel (abilityConnectionManager) is text-only, and
 * the C1 camera link runs H.264/RCTM in the phone→PC direction; the return
 * leg deliberately reuses neither: JPEG stills at ~8 fps are enough for a
 * preview monitor, and the ArkTS ImagePacker / imageSource pipeline means
 * zero native encoder code on either side.
 *
 * Frame layout (16-byte header, all integers big-endian / network order):
 *   magic   u32  = JPGM_MAGIC
 *   seq     u32  = frame counter (drops are visible as gaps)
 *   width   u16  = picture width  in px  (of the encoded JPEG)
 *   height  u16  = picture height in px
 *   size    u32  = JPEG payload length
 *   payload [size] = one JPEG image
 *
 * A receiver resyncs by scanning for the magic, so a torn frame only loses
 * one picture, never the connection.
 */

export const JPGM_MAGIC: number = 0x4A50474D; // 'J' 'P' 'G' 'M'
export const JPGM_HEADER_SIZE: number = 16;
export const JPGM_MAX_PAYLOAD: number = 8 * 1024 * 1024;

/** Default TCP port: one above the C1 camera feed (RCTM_DEFAULT_PORT). */
export const JPGM_DEFAULT_PORT: number = 25891;

export class JpgmFrame {
  bytes: ArrayBuffer;
  width: number;
  height: number;
  seq: number;

  constructor(bytes: ArrayBuffer, width: number, height: number, seq: number) {
    this.bytes = bytes;
    this.width = width;
    this.height = height;
    this.seq = seq;
  }
}

/** Serialize a JPEG buffer into a full JPGM frame (header + payload). */
export function jpgmEncode(jpeg: ArrayBuffer, width: number, height: number, seq: number): ArrayBuffer {
  const out = new ArrayBuffer(JPGM_HEADER_SIZE + jpeg.byteLength);
  const view = new DataView(out);
  view.setUint32(0, JPGM_MAGIC, false);
  view.setUint32(4, seq >>> 0, false);
  view.setUint16(8, width, false);
  view.setUint16(10, height, false);
  view.setUint32(12, jpeg.byteLength, false);
  const body = new Uint8Array(out, JPGM_HEADER_SIZE);
  body.set(new Uint8Array(jpeg));
  return out;
}

/**
 * Incremental frame extractor. Feed arriving TCP chunks; every complete
 * frame pops into `frames`. Garbage before the next magic is discarded
 * (connection resync). A declared payload over JPGM_MAX_PAYLOAD means we
 * mis-read a header — drop the buffer and rescan.
 */
export class JpgmParser {
  private acc: Uint8Array = new Uint8Array(0);
  readonly frames: JpgmFrame[] = [];

  push(chunk: ArrayBuffer): void {
    const incoming = new Uint8Array(chunk);
    const merged = new Uint8Array(this.acc.length + incoming.length);
    merged.set(this.acc);
    merged.set(incoming, this.acc.length);
    this.acc = merged;
    this.drain();
  }

  /** Consume every complete frame from the head of the accumulator. */
  private drain(): void {
    for (;;) {
      if (this.acc.length < JPGM_HEADER_SIZE) {
        return;
      }
      const head = new DataView(this.acc.buffer, this.acc.byteOffset, this.acc.length);
      if (head.getUint32(0, false) !== JPGM_MAGIC) {
        // Resync: skip to the next magic.
        const next = this.findMagic(1);
        if (next < 0) {
          // Keep the last 3 bytes (a magic may straddle chunks).
          this.acc = this.acc.slice(Math.max(0, this.acc.length - 3));
          return;
        }
        this.acc = this.acc.slice(next);
        continue;
      }
      const seq = head.getUint32(4, false);
      const width = head.getUint16(8, false);
      const height = head.getUint16(10, false);
      const size = head.getUint32(12, false);
      if (size > JPGM_MAX_PAYLOAD) {
        // Bogus header — rescan after the current magic.
        this.acc = this.acc.slice(4);
        continue;
      }
      if (this.acc.length < JPGM_HEADER_SIZE + size) {
        return; // partial frame, wait for more chunks
      }
      const payload = this.acc.slice(JPGM_HEADER_SIZE, JPGM_HEADER_SIZE + size);
      this.acc = this.acc.slice(JPGM_HEADER_SIZE + size);
      this.frames.push(new JpgmFrame(payload.buffer as ArrayBuffer, width, height, seq));
    }
  }

  private findMagic(from: number): number {
    for (let i = from; i + 4 <= this.acc.length; i++) {
      if (this.acc[i] === 0x4A && this.acc[i + 1] === 0x50 &&
        this.acc[i + 2] === 0x47 && this.acc[i + 3] === 0x4D) {
        return i;
      }
    }
    return -1;
  }

  reset(): void {
    this.acc = new Uint8Array(0);
    this.frames.length = 0;
  }
}
