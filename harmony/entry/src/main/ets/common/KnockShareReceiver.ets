import { harmonyShare, systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { fileUri, fileIo } from '@kit.CoreFileKit';
import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from './Logger';
import { ObsController } from '../model/ObsModel';

const TAG = 'KnockShare';

/**
 * KnockShareReceiver — W3 innovation C2a: receive images (and links)
 * "knocked" from a phone onto this PC/2in1 window and feed them into the
 * current scene as image sources. No app needed on the phone side — the
 * system Gallery share sheet drives the knock (official best practice
 * bpta-application-knock-file-share / knock-share-pc-phones-mutually).
 *
 * Mechanics:
 * - on('dataReceive') registers with a RecvCapabilityRegistry carrying the
 *   main window's id (window-scoped on PC/2in1; the app must be foreground
 *   for the knock to land here — acceptable for the "add capture material
 *   while streaming" flow, since OBS is on screen while you stream).
 * - On the knock we hand receive() an existing sandbox directory; the
 *   framework writes the transferred files there and reports SharedRecord
 *   entries whose `uri` is directly open()/copy-able.
 * - Images are copied to files/knock-images/<name> (stable location) and
 *   added as image_source entries via the normal ObsController path.
 */
export class KnockShareReceiver {
  private static registry: harmonyShare.RecvCapabilityRegistry | null = null;
  private static active: boolean = false;
  /** Guards the await window inside startAsync: without it, the foreground
   * and windowStageCreate entry points race and register the listener twice
   * (observed on device: duplicate "listening" log lines). */
  private static pending: boolean = false;
  private static counter: number = 0;

  /** Fire-and-forget entry: logs failures, never rejects. */
  static start(context: common.UIAbilityContext): void {
    KnockShareReceiver.startAsync(context).catch((err: Object) => {
      Logger.warn(`${TAG}: register failed: ${Logger.asError(err).message}`);
    });
  }

  private static async startAsync(context: common.UIAbilityContext): Promise<void> {
    if (KnockShareReceiver.active || KnockShareReceiver.pending) {
      return;
    }
    KnockShareReceiver.pending = true;
    try {
      const win = await window.getLastWindow(context);
      const windowId = win.getWindowProperties().id;
      const dropDir = `${context.filesDir}/knock-drop`;
      if (!fileIo.accessSync(dropDir)) {
        fileIo.mkdirSync(dropDir, true);
      }
      const registry: harmonyShare.RecvCapabilityRegistry = {
        windowId: windowId,
        capabilities: [
          { utd: utd.UniformDataType.IMAGE, maxSupportedCount: 5 },
          // W3 C2 round-2 fix (device-verified 10-03): the sender shares
          // finished clips as VIDEO, but this registry only declared IMAGE +
          // PLAIN_TEXT — the capability handshake therefore refused us and
          // the system routed the knock to the Gallery instead. VIDEO must
          // be received for the clip-knock loop to land on OBS.
          { utd: utd.UniformDataType.VIDEO, maxSupportedCount: 1 },
          // W3 C1: a tiny text payload knocked from any device is a
          // control signal ("obs-knock://camera"), not content — receive
          // plain text too.
          { utd: utd.UniformDataType.PLAIN_TEXT, maxSupportedCount: 1 },
        ],
      };
      harmonyShare.on('dataReceive', registry, (target: harmonyShare.ReceivableTarget) => {
        const sandboxUri = fileUri.getUriFromPath(dropDir);
        const callback: harmonyShare.ReceiveCallback = {
          onDataReceived: (data: systemShare.SharedData) => {
            KnockShareReceiver.handleShared(data);
          },
          onResult: (code: harmonyShare.ShareResultCode) => {
            Logger.info(`${TAG}: receive result ${code}`);
          },
        };
        target.receive(sandboxUri, callback).catch((err: Object) => {
          Logger.error(`${TAG}: receive() failed`, Logger.asError(err));
        });
      });
      KnockShareReceiver.registry = registry;
      KnockShareReceiver.active = true;
      Logger.info(`${TAG}: listening (windowId=${windowId}, drop=${dropDir})`);
    } finally {
      KnockShareReceiver.pending = false;
    }
  }

  static stop(): void {
    if (KnockShareReceiver.active && KnockShareReceiver.registry !== null) {
      try {
        harmonyShare.off('dataReceive', KnockShareReceiver.registry);
      } catch (err) {
        Logger.warn(`${TAG}: off() failed: ${Logger.asError(err as Object).message}`);
      }
      KnockShareReceiver.registry = null;
      KnockShareReceiver.active = false;
    }
  }

  private static handleShared(data: systemShare.SharedData): void {
    const records: systemShare.SharedRecord[] = data.getRecords();
    for (const rec of records) {
      Logger.info(`${TAG}: record utd=${rec.utd} uri=${rec.uri ?? ''} content=${rec.content ?? ''}`);
      if (rec.content && KnockShareReceiver.isText(rec.utd)) {
        KnockShareReceiver.handleSignal(rec.content);
        continue;
      }
      if (rec.uri && KnockShareReceiver.isImage(rec.utd)) {
        KnockShareReceiver.acceptImage(rec.uri);
      } else if (rec.uri && KnockShareReceiver.isVideo(rec.utd)) {
        KnockShareReceiver.acceptVideo(rec.uri);
      }
    }
  }

  /** W3 C2: a finished clip knocked back into OBS lands in the sandbox and
   * is re-used as a media source when one is available; otherwise it is
   * simply kept (stable path logged) so the user can browse it. */
  private static acceptVideo(landedUri: string): void {
    try {
      KnockShareReceiver.counter += 1;
      const rawName = landedUri.split('/').pop() ?? `video-${KnockShareReceiver.counter}.mp4`;
      const name = `knock-${KnockShareReceiver.counter}-${rawName.replace(/[^A-Za-z0-9._-]/g, '_')}`;
      const dir = `${ObsController.filesDir}/knock-videos`;
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
      const dest = `${dir}/${name}`;
      const src = fileIo.openSync(landedUri, fileIo.OpenMode.READ_ONLY);
      fileIo.copyFileSync(src.fd, dest);
      fileIo.closeSync(src);
      Logger.info(`${TAG}: video landed -> ${dest}`);
    } catch (err) {
      Logger.error(`${TAG}: acceptVideo failed`, Logger.asError(err as Object));
    }
  }

  /** W3 C1 (revised): control-signal grammar. A knocked plain-text payload
   * of "obs-knock://camera" arms the wireless-camera receiver: the producer
   * adds the harmony_remote_camera source (RCTM over TCP), which the phone
   * role page then feeds with its camera stream. The old meaning (Service
   * Collaboration @remote camera) is retired — device-verified 10-04 that
   * third parties can never mount CAMERA_CONNECTION_REMOTE. Any other text
   * is logged and ignored — an unknown signal must never do anything
   * surprising. */
  private static handleSignal(content: string): void {
    const trimmed = content.trim();
    Logger.info(`${TAG}: signal payload "${trimmed}"`);
    if (trimmed === 'obs-knock://camera') {
      // Same dedup as the Sources-panel button (10-04).
      if (!ObsController.hasSourceNamed('无线机位')) {
        ObsController.addSource('harmony_remote_camera', '{}', '无线机位');
      }
    }
  }

  /** Copy one landed file into the images dir and add it as a source. */
  private static acceptImage(landedUri: string): void {
    try {
      KnockShareReceiver.counter += 1;
      const rawName = landedUri.split('/').pop() ?? `image-${KnockShareReceiver.counter}.png`;
      const name = `knock-${KnockShareReceiver.counter}-${rawName.replace(/[^A-Za-z0-9._-]/g, '_')}`;
      const dest = `${KnockShareReceiver.imagesDir()}/${name}`;
      const src = fileIo.openSync(landedUri, fileIo.OpenMode.READ_ONLY);
      fileIo.copyFileSync(src.fd, dest);
      fileIo.closeSync(src);
      Logger.info(`${TAG}: image landed -> ${dest}, adding as source`);
      ObsController.addSource('image_source', JSON.stringify({ file: dest }));
    } catch (err) {
      Logger.error(`${TAG}: acceptImage failed`, Logger.asError(err as Object));
    }
  }

  private static imagesDir(): string {
    const dir = `${ObsController.filesDir}/knock-images`;
    try {
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
    } catch (err) {
      // Directory already exists (access/mkdir race) is fine; anything else
      // will surface at copy time.
    }
    return dir;
  }

  /** Device-verified 10-03: the gallery knock arrives with the LEAF utd
   * name ("general.jpeg"), not the category ("image") we declared — a
   * substring test on 'image' silently dropped it (the file still landed
   * in knock-drop but no source was created). Match both the category
   * words and the known leaf extensions. */
  private static isImage(utdType: string): boolean {
    const t = utdType.toLowerCase();
    return t.indexOf('image') >= 0 || t.indexOf('jpeg') >= 0 || t.indexOf('jpg') >= 0
      || t.indexOf('png') >= 0 || t.indexOf('gif') >= 0 || t.indexOf('bmp') >= 0
      || t.indexOf('webp') >= 0 || t.indexOf('heic') >= 0;
  }

  private static isText(utdType: string): boolean {
    const t = utdType.toLowerCase();
    return t.indexOf('text') >= 0 || t === 'general.plain-text';
  }

  private static isVideo(utdType: string): boolean {
    const t = utdType.toLowerCase();
    return t.indexOf('video') >= 0 || t.indexOf('mp4') >= 0 || t.indexOf('mov') >= 0
      || t.indexOf('matroska') >= 0 || t.indexOf('mkv') >= 0;
  }
}
