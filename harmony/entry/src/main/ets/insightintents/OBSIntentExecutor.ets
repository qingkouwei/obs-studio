import { InsightIntentExecutor, insightIntent } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { Logger } from '../common/Logger';

const TAG = 'OBSIntent';

/** Kinds the voice assistant can ask for. Values must match the
 * intentName fields in resources/base/profile/insight_intent.json. */
export type ObsActionKind = 'StartLive' | 'StartRecording';

/**
 * IntentActions — a tiny pending queue bridging the insight-intent executor
 * and the OBS controller.
 *
 * Timing problem (from the official lifecycle order): on a COLD start the
 * executor fires after onWindowStageCreate but BEFORE the main page's
 * aboutToAppear() runs ObsController.initialize() — at that moment libobs is
 * not up, scenes do not exist, and toggleStreaming/toggleRecording would
 * fail against an uninitialized core. On a WARM start the controller is
 * ready and we want the action now. One queue covers both: whoever is ready
 * first drains it.
 */
export class IntentActions {
  private static queue: ObsActionKind[] = [];
  private static controllerReady: boolean = false;

  /** Called by the executor. */
  static push(kind: ObsActionKind): void {
    Logger.info(`${TAG}: action pushed (${kind}, ready=${IntentActions.controllerReady})`);
    if (IntentActions.controllerReady) {
      IntentActions.drainOne(kind);
      return;
    }
    IntentActions.queue.push(kind);
  }

  /** Called by ObsController.initialize() when the core is up. */
  static markReady(): void {
    IntentActions.controllerReady = true;
    const pending = IntentActions.queue;
    IntentActions.queue = [];
    for (const kind of pending) {
      // Let initialize() finish its own refresh cycle first.
      IntentActions.drainOne(kind);
    }
  }

  static markNotReady(): void {
    IntentActions.controllerReady = false;
  }

  private static drainOne(kind: ObsActionKind): void {
    setTimeout(() => {
      try {
        IntentDispatcher.dispatch(kind);
      } catch (err) {
        Logger.error(`${TAG}: dispatch failed`, Logger.asError(err as Object));
      }
    }, 800);
  }
}

/** Indirection so the queue file does not hard-import ObsModel at module
 * load (the executor is loaded by the framework very early; keeping its
 * import graph light avoids init-order surprises). Registered by ObsModel
 * at first initialize(). */
export class IntentDispatcher {
  static handler: ((kind: ObsActionKind) => void) | null = null;

  static register(handler: (kind: ObsActionKind) => void): void {
    IntentDispatcher.handler = handler;
  }

  static dispatch(kind: ObsActionKind): void {
    if (IntentDispatcher.handler === null) {
      Logger.warn(`${TAG}: no dispatcher registered, dropping ${kind}`);
      return;
    }
    Logger.info(`${TAG}: dispatching ${kind}`);
    IntentDispatcher.handler(kind);
  }
}

/**
 * OBSIntentExecutor — W3 C3: "小艺，用 OBS 开始直播/开始录制".
 *
 * Registered in insight_intent.json (domain MediaDomain, foreground mode,
 * bound to EntryAbility). The framework launches/raises our UIAbility and
 * calls this hook; we queue the action and report success — the queue
 * drains when the controller is ready (cold start) or immediately (warm).
 */
export default class OBSIntentExecutor extends InsightIntentExecutor {
  onExecuteInUIAbilityForegroundMode(name: string, param: Record<string, Object>,
    pageLoader: window.WindowStage): insightIntent.ExecuteResult {
    Logger.info(`${TAG}: onExecute(${name})`);
    let code = 0;
    switch (name) {
      case 'StartLive':
      case 'StartRecording':
        IntentActions.push(name);
        break;
      default:
        code = 404;
        Logger.warn(`${TAG}: unsupported intent ${name}`);
        break;
    }
    const result: insightIntent.ExecuteResult = {
      code: code,
      result: {
        message: code === 0 ? 'Execute insight intent succeed.' : 'Unsupported insight intent.',
      },
    };
    return result;
  }
}
