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

  /** Start the audioRecording continuous task if not already running. */
  static async acquire(context: common.UIAbilityContext, reason: string): Promise<void> {
    LongRunningTask.refCount += 1;
    if (LongRunningTask.taskActive) {
      return;
    }
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
      const modes: string[] = ['audioRecording'];
      const notification: backgroundTaskManager.ContinuousTaskNotification =
        await backgroundTaskManager.startBackgroundRunning(context, modes, agent);
      LongRunningTask.taskId = notification.continuousTaskId ?? -1;
      LongRunningTask.taskActive = true;
      Logger.info(`continuous task acquired (${reason})`);
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
  }
}
