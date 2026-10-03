import { liveViewManager } from '@kit.LiveViewKit';
import { Logger } from './Logger';

const TAG = 'LiveView';
const REC_ID = 91001;
const LIVE_ID = 91002;

/**
 * RecLiveWindow — W3 C5: a status-bar capsule + lock-screen widget while
 * recording or streaming, like the desktop's taskbar pulse but native.
 *
 * Entitlement reality (official Live View Kit rules): event scenarios
 * require an approved live-view entitlement, whose door is "published in
 * AppGallery + MAU ≥ 1000". Until that gate opens, startLiveView rejects
 * with a resultCode — so every call here is best-effort: the FIRST failure
 * logs the code and disables further attempts for the session. When the
 * entitlement lands, this file needs zero changes; until then users see
 * nothing worse than "no capsule".
 *
 * event choice: TIMER (a running clock is exactly what REC is) with the
 * API-26 lifeCycleMode AUTO_STOP_WHEN_APP_TERMINATE — if our process dies
 * (the ANR family we root-caused), the system reaps the capsule; no zombie
 * "REC 3:12:45" stuck on the status bar.
 */
export class RecLiveWindow {
  /** First rejection disables further attempts (and says so once, loudly). */
  private static disabled: boolean = false;
  private static recActive: boolean = false;
  private static liveActive: boolean = false;

  static startRecording(): void {
    RecLiveWindow.post(REC_ID, 'REC', () => {
      RecLiveWindow.recActive = true;
    });
  }

  static stopRecording(): void {
    RecLiveWindow.cancel(REC_ID, () => {
      RecLiveWindow.recActive = false;
    });
  }

  static startStreaming(): void {
    RecLiveWindow.post(LIVE_ID, 'LIVE', () => {
      RecLiveWindow.liveActive = true;
    });
  }

  static stopStreaming(): void {
    RecLiveWindow.cancel(LIVE_ID, () => {
      RecLiveWindow.liveActive = false;
    });
  }

  private static post(id: number, label: string, onOk: () => void): void {
    if (RecLiveWindow.disabled) {
      return;
    }
    if (id === REC_ID ? RecLiveWindow.recActive : RecLiveWindow.liveActive) {
      return;
    }
    const rich: liveViewManager.RichText = { text: label === 'REC' ? '正在录制屏幕' : '正在直播推流' };
    const primary: liveViewManager.PrimaryData = {
      title: `${label} · QingStudio`,
      content: [rich],
      keepTime: 5,
    };
    const capsule: liveViewManager.TimerCapsule = {
      type: liveViewManager.CapsuleType.CAPSULE_TYPE_TIMER,
      status: 1,
      content: label,
      time: 0,
      isCountdown: false,
    };
    const data: liveViewManager.LiveViewData = { primary: primary, capsule: capsule };
    const liveView: liveViewManager.LiveView = {
      id: id,
      event: 'TIMER',
      lifeCycleMode: liveViewManager.LifeCycleMode.AUTO_STOP_WHEN_APP_TERMINATE,
      liveViewData: data,
    };

    liveViewManager.startLiveView(liveView).then((result: liveViewManager.LiveViewResult) => {
      if (result.resultCode === 0) {
        Logger.info(`${TAG}: ${label} capsule started`);
        onOk();
      } else {
        RecLiveWindow.rejectOnce(`start ${label}`, result.resultCode, result.message as string);
      }
    }).catch((err: Object) => {
      RecLiveWindow.rejectOnce(`start ${label}`, -1, Logger.asError(err).message);
    });
  }

  private static cancel(id: number, onDone: () => void): void {
    const wasActive = id === REC_ID ? RecLiveWindow.recActive : RecLiveWindow.liveActive;
    onDone();
    if (RecLiveWindow.disabled || !wasActive) {
      return;
    }
    const rich: liveViewManager.RichText = { text: '已结束' };
    const primary: liveViewManager.PrimaryData = { title: 'QingStudio', content: [rich], keepTime: 3 };
    const data: liveViewManager.LiveViewData = { primary: primary };
    const liveView: liveViewManager.LiveView = {
      id: id,
      event: 'TIMER',
      liveViewData: data,
    };
    liveViewManager.stopLiveView(liveView).then((result: liveViewManager.LiveViewResult) => {
      if (result.resultCode !== 0) {
        Logger.info(`${TAG}: stop (${id}) resultCode=${result.resultCode} (capsule likely never opened)`);
      }
    }).catch((err: Object) => {
      Logger.info(`${TAG}: stop (${id}) failed: ${Logger.asError(err).message}`);
    });
  }

  /** Any nonzero rejection after a start attempt = "not our entitlement
   * yet". Disable silently from now on; one loud line for the audit trail. */
  private static rejectOnce(what: string, code: number, message: string): void {
    if (RecLiveWindow.disabled) {
      return;
    }
    RecLiveWindow.disabled = true;
    Logger.warn(`${TAG}: ${what} rejected code=${code} msg=${message} — live window disabled for this ` +
      `session (expected pre-entitlement: AppGallery publish + MAU gate; see docs/harmonyos-w3-innovation-plan.md C5)`);
  }
}
