import { liveViewManager } from '@kit.LiveViewKit';
import { wantAgent, WantAgent, common, Want } from '@kit.AbilityKit';
import { Logger } from './Logger';

const TAG = 'LiveView';
const REC_ID = 91001;
const LIVE_ID = 91002;
/** 401 = ArkTS parameter error (our bug), NOT an entitlement rejection.
 * Anything else nonzero after a well-formed call is the entitlement gate. */
const ERR_PARAMETER = 401;

/**
 * RecLiveWindow — W3 C5: a status-bar capsule + lock-screen widget while
 * recording or streaming, like the desktop's taskbar pulse but native.
 *
 * Entitlement reality (official Live View Kit rules): event scenarios
 * require an approved live-view entitlement, whose door is "published in
 * AppGallery + MAU ≥ 1000". Until that gate opens, startLiveView rejects —
 * so every call here is best-effort: an ENTITLEMENT-class rejection logs
 * the code and disables further attempts for the session. A parameter
 * error (401, device-verified when clickAction was missing) is OUR bug —
 * it logs loudly but does NOT trip the disable switch, so a fixed build
 * can still light up within the same session class. When the entitlement
 * lands this file needs zero changes; until then users see nothing worse
 * than "no capsule".
 *
 * event choice: TIMER (a running clock is exactly what REC is) with the
 * API-26 lifeCycleMode AUTO_STOP_WHEN_APP_TERMINATE — if our process dies
 * (the ANR family we root-caused), the system reaps the capsule; no zombie
 * "REC 3:12:45" stuck on the status bar.
 *
 * context arrives as a parameter from the callers (ObsController.appContext
 * / UIAbility this.context) — importing ObsModel here would close a module
 * cycle, since it calls into this class on every transport toggle.
 */
export class RecLiveWindow {
  /** First ENTITLEMENT rejection disables further attempts (logged once). */
  private static disabled: boolean = false;
  private static recActive: boolean = false;
  private static liveActive: boolean = false;
  /** clickAction is mandatory (device-verified 401 without it). Built once
   * per process; every live view shares the "open the app" agent. */
  private static agentPromise: Promise<Object> | null = null;

  static startRecording(context: common.UIAbilityContext | undefined): void {
    RecLiveWindow.post(REC_ID, 'REC', context, () => {
      RecLiveWindow.recActive = true;
    });
  }

  static stopRecording(): void {
    RecLiveWindow.cancel(REC_ID, () => {
      RecLiveWindow.recActive = false;
    });
  }

  static startStreaming(context: common.UIAbilityContext | undefined): void {
    RecLiveWindow.post(LIVE_ID, 'LIVE', context, () => {
      RecLiveWindow.liveActive = true;
    });
  }

  static stopStreaming(): void {
    RecLiveWindow.cancel(LIVE_ID, () => {
      RecLiveWindow.liveActive = false;
    });
  }

  /** Tapping the capsule/lock-screen widget raises the app — the natural
   * clickAction for a recording indicator, and required by the service. */
  private static clickAgent(context: common.UIAbilityContext): Promise<Object> {
    if (RecLiveWindow.agentPromise === null) {
      const want: Want = {
        bundleName: context.abilityInfo.bundleName,
        abilityName: context.abilityInfo.name
      };
      const info: wantAgent.WantAgentInfo = {
        wants: [want],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      RecLiveWindow.agentPromise = wantAgent.getWantAgent(info) as Promise<Object>;
    }
    return RecLiveWindow.agentPromise;
  }

  private static post(id: number, label: string, context: common.UIAbilityContext | undefined,
    onOk: () => void): void {
    if (RecLiveWindow.disabled || context === undefined) {
      return;
    }
    if (id === REC_ID ? RecLiveWindow.recActive : RecLiveWindow.liveActive) {
      return;
    }
    RecLiveWindow.clickAgent(context).then((agent: Object) => {
      RecLiveWindow.startWithAgent(id, label, agent, onOk);
    }).catch((err: Object) => {
      // startLiveView rejects also surface here (the inner promise chain
      // unwinds into this catch) — route through the same triage.
      const e = Logger.asError(err);
      const code = (err as Object as Record<string, number>).code ?? -1;
      RecLiveWindow.handleRejection(`start ${label}`, code, e.message);
    });
  }

  private static startWithAgent(id: number, label: string, agent: Object, onOk: () => void): void {
    const rich: liveViewManager.RichText = { text: label === 'REC' ? '正在录制屏幕' : '正在直播推流' };
    const primary: liveViewManager.PrimaryData = {
      title: `${label} · QingStudio`,
      content: [rich],
      keepTime: 5,
      clickAction: agent as WantAgent,
    };
    const capsule: liveViewManager.TimerCapsule = {
      type: liveViewManager.CapsuleType.CAPSULE_TYPE_TIMER,
      status: 1,
      content: label,
      // capsule.icon is runtime-mandatory too (fourth 401 layer, all
      // declared optional): rawfile filename per the official example.
      icon: 'capsule_rec.png',
      backgroundColor: '#FF317AF7',
      time: 0,
      isCountdown: false,
    };
    // LAYOUT_TYPE_DEFAULT = "extension area not displayed": the runtime
    // validator demands per-template required members (progress templates
    // want nodeIcons, both declared optional) — the base shape passes with
    // just layoutType, and a recording indicator needs no extension area.
    const layout: liveViewManager.LayoutData = {
      layoutType: liveViewManager.LayoutType.LAYOUT_TYPE_DEFAULT,
    };
    primary.layoutData = layout;
    const data: liveViewManager.LiveViewData = { primary: primary, capsule: capsule };
    const liveView: liveViewManager.LiveView = {
      id: id,
      event: 'TIMER',
      isMute: true,
      lifeCycleMode: liveViewManager.LifeCycleMode.AUTO_STOP_WHEN_APP_TERMINATE,
      liveViewData: data,
    };

    liveViewManager.startLiveView(liveView).then((result: liveViewManager.LiveViewResult) => {
      if (result.resultCode === 0) {
        Logger.info(`${TAG}: ${label} capsule started`);
        onOk();
      } else {
        RecLiveWindow.handleRejection(`start ${label}`, result.resultCode, result.message as string);
      }
    }).catch((err: Object) => {
      const e = Logger.asError(err);
      const code = (err as Object as Record<string, number>).code ?? -1;
      RecLiveWindow.handleRejection(`start ${label}`, code, e.message);
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
    const layout: liveViewManager.LayoutData = {
      layoutType: liveViewManager.LayoutType.LAYOUT_TYPE_DEFAULT,
    };
    primary.layoutData = layout;
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

  /** Split the two failure classes: a parameter error (401) is OUR bug —
   * log loudly but stay enabled so the next attempt (after a fix) can
   * still work within the session. Any other nonzero code is treated as
   * the entitlement gate and disables further attempts with one warn line. */
  private static handleRejection(what: string, code: number, message: string): void {
    if (code === ERR_PARAMETER) {
      Logger.error(`${TAG}: ${what} PARAMETER error (${message}) — this is a payload bug, not entitlement; ` +
        `staying enabled for the next attempt`);
      return;
    }
    if (RecLiveWindow.disabled) {
      return;
    }
    RecLiveWindow.disabled = true;
    Logger.warn(`${TAG}: ${what} rejected code=${code} msg=${message} — live window disabled for this ` +
      `session (expected pre-entitlement: AppGallery publish + MAU gate; see docs/harmonyos-w3-innovation-plan.md C5)`);
  }
}
