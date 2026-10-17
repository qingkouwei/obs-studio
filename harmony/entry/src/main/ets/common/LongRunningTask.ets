import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, wantAgent, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from './Logger';

/**
 * LongRunningTask — Background Tasks Kit wrapper for the audioRecording
 * continuous task.
 *
 * Why this exists (verified on device 2026-10-02): OBS holds an audio
 * capturer (mic + PlaybackCapture loopback) while recording/streaming. When
 * the display times out, the suspend manager kills any process that
 * "has media and not apply background_task or Resource::AUDIO" with
 * ILLEGAL_AUDIO_CAPTURER_BY_SUSPEND. The official pattern (architecture
 * guide "harcorecord"): request the continuous task when the capture starts
 * and release it when it stops — start() is awaited BEFORE returning so
 * there is no race between task registration and the user backgrounding
 * the app.
 *
 * module.json5 declares backgroundModes: ["audioRecording"] and the app
 * holds ohos.permission.KEEP_BACKGROUND_RUNNING.
 *
 * Policy compliance: the task is only started by explicit user action
 * (tapping 开始直播/开始录制), stopped as soon as the output stops, and the
 * system shows a persistent notification while active (user-perceivable).
 */
export class LongRunningTask {
  private static taskActive: boolean = false;
  private static refCount: number = 0;
  private static taskId: number = -1;
  private static cancelWatched: boolean = false;
  /** The mode set the currently active task was started with — an acquire
   * with modes outside this set (record started narrow, then stream
   * started wants dataTransfer too) restarts the task with the union. */
  private static currentModes: string[] = [];

  /** One-shot listener that logs WHY the system cancelled our task
   * (official guide continuous-task: user removing the notification,
   * consistency check, load warning, etc. all surface as a reason code).
   * Without this a background kill looks identical to a silent success. */
  private static watchCancel(): void {
    if (LongRunningTask.cancelWatched) {
      return;
    }
    LongRunningTask.cancelWatched = true;
    try {
      backgroundTaskManager.on('continuousTaskCancel', (info: backgroundTaskManager.ContinuousTaskCancelInfo) => {
        Logger.warn(`continuous task CANCELLED id=${info.id} reason=${info.reason} ` +
          '(3=user removed notification, 7=audioRecording not running, ' +
          '11=used illegally, 12=system load warning)');
        LongRunningTask.taskActive = false;
        LongRunningTask.taskId = -1;
      });
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(`on(continuousTaskCancel) failed: code=${e.code} msg=${e.message}`);
    }
  }

  /** Start the continuous task if not already running. `modes` declares
   * EVERY background business the session really runs — the system
   * cross-checks declared types against actual behaviour and suspends or
   * kills on mismatch (official continuous-task 运行限制):
   *   recording: audioRecording (mic + loopback capture) + taskKeeping
   *              (compositing/encoding load exceeds an audio-only profile)
   *   streaming: + dataTransfer (RTMP upload is a network transfer, and
   *              we are unmanaged socket I/O, not ohos.request) */
  static async acquire(context: common.UIAbilityContext, reason: string,
    modes: string[] = ['audioRecording']): Promise<void> {
    LongRunningTask.refCount += 1;
    if (LongRunningTask.taskActive) {
      // Upgrade path: the task is alive but the declared modes no longer
      // cover what we are actually doing (e.g. recording first, streaming
      // second). Restart with the union so the consistency check passes.
      // refCount already counts this holder; stopInternal/startWithModes
      // must not touch it.
      const missing = modes.filter((m: string): boolean => LongRunningTask.currentModes.indexOf(m) < 0);
      if (missing.length > 0) {
        const union: string[] = LongRunningTask.currentModes.concat(missing);
        Logger.info(`continuous task upgrading (${reason}) +${missing.join('+')}`);
        LongRunningTask.taskActive = false;
        await LongRunningTask.stopInternal(context, 'upgrade');
        await LongRunningTask.startWithModes(context, reason, union);
      }
      return;
    }
    await LongRunningTask.startWithModes(context, reason, modes);
  }

  private static async startWithModes(context: common.UIAbilityContext, reason: string,
    modes: string[]): Promise<void> {
    LongRunningTask.watchCancel();
    try {
      const want: Want = {
        bundleName: context.abilityInfo.bundleName,
        abilityName: context.abilityInfo.name
      };
      const wants: Array<Want> = [want];
      const info: wantAgent.WantAgentInfo = {
        wants: wants,
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent = await wantAgent.getWantAgent(info);
      // API 21+ multi-type overload: string[] modes -> ContinuousTaskNotification
      try {
        const notification: backgroundTaskManager.ContinuousTaskNotification =
          await backgroundTaskManager.startBackgroundRunning(context, modes, agent);
        LongRunningTask.taskId = notification.continuousTaskId ?? -1;
        LongRunningTask.taskActive = true;
        LongRunningTask.currentModes = modes;
        Logger.info(`continuous task acquired (${reason}) modes=${modes.join('+')}`);
        return;
      } catch (inner) {
        const ie = inner as BusinessError;
        // taskKeeping needs no ACL on PC/2in1 but does on other form
        // factors; dataTransfer is always open. If the rich combo is
        // rejected, fall back to the audioRecording-only baseline we have
        // shipped with since 10-02 rather than losing all keep-alive.
        Logger.warn(`modes=${modes.join('+')} rejected (code=${ie.code}), ` +
          'falling back to audioRecording');
        const notification: backgroundTaskManager.ContinuousTaskNotification =
          await backgroundTaskManager.startBackgroundRunning(context, ['audioRecording'], agent);
        LongRunningTask.taskId = notification.continuousTaskId ?? -1;
        LongRunningTask.taskActive = true;
        LongRunningTask.currentModes = ['audioRecording'];
        Logger.info(`continuous task acquired baseline (${reason}) modes=audioRecording`);
      }
    } catch (err) {
      const e = err as BusinessError;
      // Failure must not block the foreground output; the user just loses
      // screen-off/background durability.
      Logger.error(`startBackgroundRunning failed (${reason}): code=${e.code} msg=${e.message}`);
    }
  }

  /** Release the task when the last active output stops. */
  static async release(context: common.UIAbilityContext, reason: string): Promise<void> {
    LongRunningTask.refCount = Math.max(0, LongRunningTask.refCount - 1);
    if (LongRunningTask.refCount > 0 || !LongRunningTask.taskActive) {
      return;
    }
    await LongRunningTask.stopInternal(context, reason);
  }

  /** Stop the live task without touching refCount (release decrements it
   * first; the upgrade path keeps its holder while swapping modes). */
  private static async stopInternal(context: common.UIAbilityContext, reason: string): Promise<void> {
    try {
      if (LongRunningTask.taskId >= 0) {
        await backgroundTaskManager.stopBackgroundRunning(context, LongRunningTask.taskId);
        LongRunningTask.taskId = -1;
      } else {
        await backgroundTaskManager.stopBackgroundRunning(context);
      }
      Logger.info(`continuous task released (${reason})`);
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(`stopBackgroundRunning failed (${reason}): code=${e.code} msg=${e.message}`);
    }
    LongRunningTask.taskActive = false;
    LongRunningTask.currentModes = [];
  }
}
