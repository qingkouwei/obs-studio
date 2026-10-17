import { socket } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';
import { jpgmEncode, JPGM_DEFAULT_PORT } from './JpgmProtocol';
import { Logger } from './Logger';

/**
 * ProgramFeedServer — producer side (PC / 2in1 / tablet) of the W3-C4
 * monitor leg: ships the PROGRAM picture to the phone director console so
 * it stops being a blind button pad (user report 10-17: the phone screen
 * felt like a demo, not an extension of the PC app).
 *
 * Pipeline is deliberately pure ArkTS: componentSnapshot of the program
 * XComponent (the same readback the #44 browser source proved out) →
 * ImagePacker JPEG → JPGM-framed TCP to the single connected phone. No
 * native encoder, no libobs touch, nothing to rebuild in the .so chain;
 * ~7 fps stills are what a monitoring preview needs. The heavy control
 * path (scene cut / REC) stays on the collaboration channel (DirectorLink).
 *
 * A snapshot only fires while a phone is connected — no client, no cost.
 * The newest connection wins (a re-connect from the phone kicks the stale
 * session rather than leaking pumps).
 */
const TAG = 'ProgramFeed';
const FRAME_INTERVAL_MS: number = 150;
const JPEG_QUALITY: number = 60;
const SNAPSHOT_ID: string = 'obs-preview-canvas';

export class ProgramFeedServer {
  private static server: socket.TCPSocketServer | undefined = undefined;
  private static peer: socket.TCPSocketConnection | undefined = undefined;
  private static packer: image.ImagePacker | undefined = undefined;
  private static uiContext: UIContext | undefined = undefined;
  private static pumpTimer: number = -1;
  private static inFlight: boolean = false;
  private static seq: number = 0;
  private static sentFrames: number = 0;
  private static fails: number = 0;

  /** Called once from the producer page's host component aboutToAppear. */
  static init(uiContext: UIContext): void {
    if (ProgramFeedServer.server !== undefined) {
      return;
    }
    ProgramFeedServer.uiContext = uiContext;
    ProgramFeedServer.packer = image.createImagePacker();
    const server: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
    server.on('connect', (peer: socket.TCPSocketConnection): void => {
      ProgramFeedServer.onAccept(peer);
    });
    const addr: socket.NetAddress = {
      address: '0.0.0.0',
      port: JPGM_DEFAULT_PORT,
      family: 1 // NetAddress: 1 = IPv4, 2 = IPv6 (NOT the C AF_INET constant)
    };
    server.listen(addr).then((): void => {
      Logger.info(`${TAG}: listening on :${JPGM_DEFAULT_PORT}`);
    }).catch((err: Object): void => {
      Logger.error(`${TAG}: listen failed: ${Logger.asError(err).message}`);
    });
    ProgramFeedServer.server = server;
  }

  static shutdown(): void {
    ProgramFeedServer.stopPump();
    const peer = ProgramFeedServer.peer;
    if (peer !== undefined) {
      try {
        peer.off('close');
      } catch (err) {
        Logger.warn(`${TAG}: off(close) failed`);
      }
      ProgramFeedServer.peer = undefined;
    }
    const server = ProgramFeedServer.server;
    if (server !== undefined) {
      try {
        server.off('connect');
      } catch (err) {
        Logger.warn(`${TAG}: off(connect) failed`);
      }
      ProgramFeedServer.server = undefined;
    }
    const packer = ProgramFeedServer.packer;
    if (packer !== undefined) {
      packer.release();
      ProgramFeedServer.packer = undefined;
    }
    ProgramFeedServer.uiContext = undefined;
  }

  private static onAccept(peer: socket.TCPSocketConnection): void {
    if (ProgramFeedServer.peer !== undefined) {
      // Newest wins: drop the stale session's pump before switching.
      ProgramFeedServer.stopPump();
      ProgramFeedServer.peer = undefined;
    }
    ProgramFeedServer.peer = peer;
    peer.on('close', (): void => {
      if (ProgramFeedServer.peer === peer) {
        Logger.info(`${TAG}: phone disconnected`);
        ProgramFeedServer.peer = undefined;
        ProgramFeedServer.stopPump();
      }
    });
    Logger.info(`${TAG}: phone connected, starting pump`);
    ProgramFeedServer.startPump();
  }

  private static startPump(): void {
    ProgramFeedServer.stopPump();
    ProgramFeedServer.pumpTimer = setInterval((): void => {
      ProgramFeedServer.tick();
    }, FRAME_INTERVAL_MS);
  }

  private static stopPump(): void {
    if (ProgramFeedServer.pumpTimer >= 0) {
      clearInterval(ProgramFeedServer.pumpTimer);
      ProgramFeedServer.pumpTimer = -1;
    }
  }

  private static tick(): void {
    const peer = ProgramFeedServer.peer;
    const packer = ProgramFeedServer.packer;
    const ctx = ProgramFeedServer.uiContext;
    if (peer === undefined || packer === undefined || ctx === undefined) {
      return;
    }
    if (ProgramFeedServer.inFlight) {
      return; // snapshot/pack is async — never stack them (WebFeed lesson)
    }
    ProgramFeedServer.inFlight = true;
    ctx.getComponentSnapshot().get(SNAPSHOT_ID)
      .then((pm: image.PixelMap): Promise<ArrayBuffer> => {
        const info: image.ImageInfo = pm.getImageInfoSync();
        const w: number = info.size.width;
        const h: number = info.size.height;
        const opts: image.PackingOption = { format: 'image/jpeg', quality: JPEG_QUALITY };
        const seq: number = ProgramFeedServer.seq;
        const p: Promise<ArrayBuffer> = packer.packToData(pm, opts).then((jpeg: ArrayBuffer): ArrayBuffer => {
          pm.release();
          // Encode geometry into the frame only after a successful pack.
          return ProgramFeedServer.wrap(jpeg, w, h, seq);
        }).catch((err: Object): never => {
          pm.release();
          throw new Error(`pack stage: ${ProgramFeedServer.errText(err)}`);
        });
        return p;
      })
      .then((frame: ArrayBuffer): void => {
        ProgramFeedServer.broadcast(peer, frame);
      })
      .catch((err: Object): void => {
        if (ProgramFeedServer.fails++ % 20 === 0) {
          Logger.warn(`${TAG}: frame failed: ${ProgramFeedServer.errText(err)}`);
        }
      })
      .finally((): void => {
        ProgramFeedServer.inFlight = false;
      });
  }

  /** ArkTS rejections are not always Error objects (code/message fields);
   * squeeze whatever detail the payload carries into one line. */
  private static errText(err: Object): string {
    const e = err as Record<string, Object>;
    const parts: string[] = [];
    if (typeof e['message'] === 'string') {
      parts.push(e['message'] as string);
    }
    if (e['code'] !== undefined) {
      parts.push(`code=${String(e['code'])}`);
    }
    if (parts.length === 0) {
      parts.push(String(err));
      try {
        parts.push(JSON.stringify(err));
      } catch (err2) {
        /* non-serialisable */
      }
    }
    return parts.join(' ');
  }

  private static wrap(jpeg: ArrayBuffer, w: number, h: number, seq: number): ArrayBuffer {
    ProgramFeedServer.seq = (seq + 1) >>> 0;
    return jpgmEncode(jpeg, w, h, seq);
  }

  private static broadcast(peer: socket.TCPSocketConnection, frame: ArrayBuffer): void {
    const options: socket.TCPSendOptions = { data: frame };
    peer.send(options).then((): void => {
      ProgramFeedServer.sentFrames++;
      if (ProgramFeedServer.sentFrames === 1 || ProgramFeedServer.sentFrames % 300 === 0) {
        Logger.info(`${TAG}: sent frame#${ProgramFeedServer.sentFrames} (${frame.byteLength} B)`);
      }
    }).catch((err: Object): void => {
      // A dead socket must not spam: tear the session; the phone reconnects.
      Logger.warn(`${TAG}: send failed, dropping client: ${Logger.asError(err).message}`);
      ProgramFeedServer.peer = undefined;
      ProgramFeedServer.stopPump();
    });
  }
}
