import { socket } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';
import { JpgmParser, JpgmFrame, JPGM_DEFAULT_PORT } from './JpgmProtocol';
import { Logger } from './Logger';

/**
 * ProgramFeedClient — phone side of the W3-C4 monitor leg: connects to the
 * producer's JPGM TCP server (same LAN, typed IP on the role page), decodes
 * each JPEG frame into a PixelMap and hands it to the console UI, so the
 * director screen shows the actual program picture instead of buttons only.
 *
 * Decoding is serialised (decodeFrame below) — imageSource.createPixelMap
 * is async and overlapping decodes of stale frames would burn the codec;
 * only ONE queued decode at a time, and frames arriving while busy REPLACE
 * the pending slot (the live picture matters more than history).
 */
const TAG = 'ProgramFeedClient';

export type FeedState = 'idle' | 'connecting' | 'connected' | 'error';

export class ProgramFeedClient {
  static onFrame: ((pm: image.PixelMap | undefined, info: string) => void) | null = null;
  static onState: ((state: FeedState, info: string) => void) | null = null;

  private static client: socket.TCPSocket | undefined = undefined;
  private static parser: JpgmParser = new JpgmParser();
  private static busy: boolean = false;
  private static pending: JpgmFrame | undefined = undefined;
  private static framesShown: number = 0;

  static connect(host: string, port: number = JPGM_DEFAULT_PORT): void {
    ProgramFeedClient.disconnect('re-connect');
    const client = socket.constructTCPSocketInstance();
    ProgramFeedClient.client = client;
    ProgramFeedClient.parser.reset();
    ProgramFeedClient.emitState('connecting', `连接 ${host}:${port}…`);

    client.on('message', (info: socket.SocketMessageInfo): void => {
      ProgramFeedClient.onData(info.message as ArrayBuffer);
    });
    client.on('close', (): void => {
      if (ProgramFeedClient.client === client) {
        ProgramFeedClient.emitState('idle', '制作端断开');
        ProgramFeedClient.client = undefined;
      }
    });

    const addr: socket.NetAddress = { address: host, port: port, family: 1 }; // 1 = IPv4
    const opts: socket.TCPConnectOptions = { address: addr, timeout: 5000 };
    client.connect(opts).then((): void => {
      if (ProgramFeedClient.client !== client) {
        return; // torn down while connecting
      }
      Logger.info(`${TAG}: connected to ${host}:${port}`);
      ProgramFeedClient.emitState('connected', `监听节目画面 ${host}`);
    }).catch((err: Object): void => {
      if (ProgramFeedClient.client !== client) {
        return;
      }
      Logger.warn(`${TAG}: connect failed: ${Logger.asError(err).message}`);
      ProgramFeedClient.emitState('error', '连接失败（确认制作端已开 OBS）');
      ProgramFeedClient.client = undefined;
    });
  }

  static disconnect(reason: string): void {
    const client = ProgramFeedClient.client;
    if (client === undefined) {
      return;
    }
    Logger.info(`${TAG}: disconnect (${reason})`);
    ProgramFeedClient.client = undefined;
    ProgramFeedClient.parser.reset();
    try {
      client.off('message');
      client.off('close');
    } catch (err) {
      Logger.warn(`${TAG}: off failed`);
    }
    client.close().catch((): void => {
      /* already gone */
    });
    ProgramFeedClient.emitState('idle', '');
  }

  private static onData(chunk: ArrayBuffer): void {
    ProgramFeedClient.parser.push(chunk);
    const frames = ProgramFeedClient.parser.frames;
    if (frames.length === 0) {
      return;
    }
    // Keep only the newest: older buffered frames are stale by definition.
    const newest = frames[frames.length - 1];
    const dropped = frames.length - 1;
    frames.length = 0;
    if (dropped > 0) {
      Logger.debug(`${TAG}: dropped ${dropped} stale frame(s)`);
    }
    ProgramFeedClient.decode(newest);
  }

  private static decode(frame: JpgmFrame): void {
    if (ProgramFeedClient.busy) {
      // Only ever queue one; replace the older queued frame.
      ProgramFeedClient.pending = frame;
      return;
    }
    ProgramFeedClient.busy = true;
    ProgramFeedClient.decodeOne(frame).finally((): void => {
      ProgramFeedClient.busy = false;
      const next = ProgramFeedClient.pending;
      ProgramFeedClient.pending = undefined;
      if (next !== undefined) {
        ProgramFeedClient.decode(next);
      }
    });
  }

  private static decodeOne(frame: JpgmFrame): Promise<void> {
    const src = image.createImageSource(frame.bytes);
    return src.createPixelMap().then((pm: image.PixelMap): void => {
      ProgramFeedClient.framesShown++;
      if (ProgramFeedClient.onFrame !== null) {
        ProgramFeedClient.onFrame(pm, `${frame.width}x${frame.height}`);
      }
      if (ProgramFeedClient.framesShown === 1 || ProgramFeedClient.framesShown % 120 === 0) {
        Logger.info(`${TAG}: displayed frame#${ProgramFeedClient.framesShown} seq=${frame.seq}`);
      }
    }).catch((err: Object): void => {
      Logger.warn(`${TAG}: decode failed: ${Logger.asError(err).message}`);
    }).finally((): void => {
      src.release();
    });
  }

  private static emitState(state: FeedState, info: string): void {
    if (ProgramFeedClient.onState !== null) {
      ProgramFeedClient.onState(state, info);
    }
  }
}
