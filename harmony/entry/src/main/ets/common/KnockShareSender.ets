import { harmonyShare, systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { fileUri } from '@kit.CoreFileKit';
import { Logger } from './Logger';

const TAG = 'KnockShareOut';

/**
 * KnockShareSender — the OUT half of W3 C2. The receiver side
 * (KnockShareReceiver) lands phone photos into a scene; this half takes a
 * finished recording in the app sandbox and shares it out: knock this
 * PC/2in1 against a nearby device and the mp4 flies over through the system
 * share sheet. No picker, no export step — the file leaves as-is.
 *
 * Mechanism (official knock-share best practice, bpta-application-knock-
 * file-share): register on('knockShare') while foregrounded; the callback
 * hands us a SharableTarget, and target.share(SharedData) completes the
 * transfer to whatever device just initiated the knock. Calling share()
 * inside the knock callback is the ONLY sanctioned moment — the target is a
 * one-shot credential tied to the physical gesture.
 *
 * The receiver side is window-scoped (RecvCapabilityRegistry.windowId); the
 * sender registration is NOT — on('knockShare') takes no registry — so this
 * class needs no window id and stays valid across window recreation. The
 * app must still be foreground for the knock to surface its sheet.
 */
export class KnockShareSender {
  private static listening: boolean = false;
  private static pendingPath: string = '';

  /**
   * Arm the knock listener for one payload. Calling again re-arms with the
   * newest path (e.g. record a second clip) without leaking a listener.
   *
   * @param filePath absolute sandbox path of the file to send
   * @param title     transient label shown on the receiving device
   */
  static arm(filePath: string, title: string): void {
    KnockShareSender.pendingPath = filePath;
    KnockShareSender.pendingTitle = title;
    if (KnockShareSender.listening) {
      Logger.info(`${TAG}: re-armed for ${filePath}`);
      return;
    }
    const cb: Callback<harmonyShare.SharableTarget> = (target: harmonyShare.SharableTarget) => {
      KnockShareSender.onKnock(target);
    };
    try {
      harmonyShare.on('knockShare', cb);
      KnockShareSender.callback = cb;
      KnockShareSender.listening = true;
      Logger.info(`${TAG}: listening, payload=${filePath}`);
    } catch (err) {
      Logger.error(`${TAG}: on('knockShare') failed`, Logger.asError(err as Object));
    }
  }

  private static pendingTitle: string = '';
  private static callback: Callback<harmonyShare.SharableTarget> | null = null;

  /** Re-arm after returning to the foreground with the last payload (if
   * any). stop() on background is mandatory — a knock answered while
   * backgrounded has no sheet to show. */
  static rearm(): void {
    if (KnockShareSender.pendingPath !== '' && !KnockShareSender.listening) {
      KnockShareSender.arm(KnockShareSender.pendingPath, KnockShareSender.pendingTitle);
    }
  }

  /** Disarm (background / window destroy). share() during background is an
   * error per official guidance, and a stranded listener would answer a
   * knock the user can no longer see the sheet for. */
  static stop(): void {
    if (!KnockShareSender.listening) {
      return;
    }
    try {
      if (KnockShareSender.callback !== null) {
        harmonyShare.off('knockShare', KnockShareSender.callback);
      }
    } catch (err) {
      Logger.warn(`${TAG}: off() failed: ${Logger.asError(err as Object).message}`);
    }
    KnockShareSender.callback = null;
    KnockShareSender.listening = false;
    Logger.info(`${TAG}: disarmed`);
  }

  private static onKnock(target: harmonyShare.SharableTarget): void {
    const path = KnockShareSender.pendingPath;
    if (path === '') {
      target.reject(harmonyShare.SharableErrorCode.NO_CONTENT_ERROR).catch((err: Object) => {
        Logger.warn(`${TAG}: reject failed: ${Logger.asError(err).message}`);
      });
      return;
    }
    const uri = fileUri.getUriFromPath(path);
    const record: systemShare.SharedRecord = {
      // The payload is a video clip; VIDEO is the registered general type
      // that every knock-capable device accepts for file transfers.
      utd: utd.UniformDataType.VIDEO,
      uri: uri,
      title: KnockShareSender.pendingTitle,
      description: 'QingStudio recording',
    };
    const data = new systemShare.SharedData(record);
    target.share(data).then(() => {
      Logger.info(`${TAG}: shared ${path}`);
    }).catch((err: Object) => {
      Logger.error(`${TAG}: share() failed`, Logger.asError(err));
    });
  }
}
