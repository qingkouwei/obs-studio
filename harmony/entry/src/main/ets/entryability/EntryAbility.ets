import { UIAbility, AbilityConstant, Want, abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { window, promptAction, UIContext } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../common/Logger';
import { KnockShareReceiver } from '../common/KnockShareReceiver';
import { KnockShareSender } from '../common/KnockShareSender';
import { DirectorLink } from '../common/DirectorLink';
import { ObsBridge } from '../napi/obsBridge';
import { ObsAppState, ObsController } from '../model/ObsModel';
import { ContinuationCodec } from '../common/Continuation';
import { RecLiveWindow } from '../common/RecLiveWindow';

/**
 * UIAbility for OBS on HarmonyOS PC (2in1).
 *
 * PC-specific lifecycle concerns handled here:
 *  - windowWillClose (API 15+): the user clicked the window close button.
 *    If a broadcast or recording is live we MUST prompt instead of silently
 *    killing it; resolve(true) cancels the close, resolve(false) proceeds.
 *  - windowStageClose (API 14+): synchronous stage-close notification that
 *    cannot be cancelled reliably; used as the last line of defense to stop
 *    outputs so a closing window never leaks a live broadcast.
 *  - onDestroy: full native shutdown (outputs stopped, audio capture
 *    released, obs_shutdown()) so streaming cannot outlive the window.
 */
const USER_GRANT_PERMISSIONS: Permissions[] = [
  'ohos.permission.MICROPHONE',
  'ohos.permission.CUSTOM_SCREEN_CAPTURE',
  // Requested eagerly so camera capture works during bring-up. For release this
  // should move to a lazy request on first creation of a harmony_camera_capture
  // source: asking for the camera at launch when the user may never add one is
  // poor UX and invites review friction. Without a grant, Camera_Input_Open
  // fails with 7400102 (CAMERA_OPERATION_NOT_ALLOWED).
  'ohos.permission.CAMERA'
  // NOTE: ohos.permission.CUSTOM_SCREEN_RECORDING and
  // ohos.permission.INPUT_MONITORING are RESTRICTED — they cannot be requested
  // at runtime and only work in release builds whose AGC-approved profile
  // grants them. Everything depending on them (dialog-free recording, global
  // hotkeys) must stay disabled when the grant is absent.
];

export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Logger.info(`EntryAbility onCreate (launchReason=${launchParam.launchReason})`);
    // W3 C6: continuation TARGET. When this instance was launched by a
    // migration from another device, the source's onContinue payload is
    // delivered via want.parameters (cold start / multi-instance) — capture
    // it now; ObsController.initialize() applies it once the core is ready.
    if (launchParam.launchReason === AbilityConstant.LaunchReason.CONTINUATION) {
      ObsController.pendingContinuation = ContinuationCodec.decodeFromWant(want);
    }
  }

  onContinue(wantParam: Record<string, Object>): AbilityConstant.OnContinueResult {
    // W3 C6: continuation SOURCE. Serialize the settings bag into the
    // migration payload. Capture sessions (screen/camera/mic) deliberately
    // do NOT travel — they are device- and consent-bound; the target starts
    // with the same profile and recreates sources.
    const ok = ContinuationCodec.encode(ObsController.currentSettings(), wantParam);
    Logger.info(`onContinue ${ok ? 'encoded' : 'FAILED to encode'}`);
    return ok ? AbilityConstant.OnContinueResult.AGREE : AbilityConstant.OnContinueResult.REJECT;
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    Logger.info('onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err !== null && err !== undefined && err.code !== 0) {
        Logger.error('loadContent failed', err);
        return;
      }
      Logger.info('main page loaded');
      // A streaming/recording console wants the whole desktop. On PC/2in1 the
      // window otherwise restores to a small floating size, which drops the
      // UI into the stacked (< 1200vp) layout and clips the sources panel.
      // Maximize once the content is up; failures are non-fatal (a plain
      // tablet keeps its normal layout).
      try {
        const win = windowStage.getMainWindowSync();
        win.maximize().then(() => {
          Logger.info('main window maximized');
        }).catch((e: BusinessError) => {
          Logger.warn(`maximize skipped (code ${e.code})`);
        });
      } catch (e) {
        Logger.warn('getMainWindowSync for maximize failed');
      }
    });

    this.requestUserGrantPermissions();
    this.registerWindowCloseGuards(windowStage);
    // W3 C2a: knock-share image intake (phone Gallery -> this window adds an
    // image source). Foreground-window scoped; failures are logged only.
    KnockShareReceiver.start(this.context);
  }

  private requestUserGrantPermissions(): void {
    const atManager = abilityAccessCtrl.createAtManager();
    atManager.requestPermissionsFromUser(this.context, USER_GRANT_PERMISSIONS)
      .then((result) => {
        for (let i = 0; i < result.permissions.length; i++) {
          // 0 = granted, -1 = denied. Denials are not fatal: the mic track
          // reports Failed and screen-capture sources report errors.
          Logger.info(`permission ${result.permissions[i]} -> authResult ${result.authResults[i]}`);
        }
      })
      .catch((err: BusinessError) => {
        Logger.error('requestPermissionsFromUser failed', err);
      });
  }

  private registerWindowCloseGuards(windowStage: window.WindowStage): void {
    try {
      this.mainWindow = windowStage.getMainWindowSync();
    } catch (err) {
      Logger.error('getMainWindowSync failed', Logger.asError(err as Object));
      this.mainWindow = null;
    }

    // Async, cancellable close guard (PC title-bar close button, API 15+).
    if (this.mainWindow !== null) {
      try {
        this.mainWindow.on('windowWillClose', (): Promise<boolean> => {
          return this.handleWindowWillClose();
        });
      } catch (err) {
        // 801 = capability not supported on this device/window type; the
        // synchronous windowStageClose guard below still protects the stream.
        Logger.warn(`windowWillClose unavailable: ${Logger.asError(err as Object).message}`);
      }
    }

    // Synchronous stage-close notification (API 14+): cannot show a dialog,
    // so it only guarantees outputs are stopped before the stage goes away.
    try {
      windowStage.on('windowStageClose', (): void => {
        this.handleWindowStageClose();
      });
    } catch (err) {
      Logger.warn(`windowStageClose unavailable: ${Logger.asError(err as Object).message}`);
    }
  }

  /**
   * resolve(true)  -> keep the window open (close cancelled).
   * resolve(false) -> proceed with the close.
   */
  private handleWindowWillClose(): Promise<boolean> {
    const state = ObsAppState.getInstance();
    const live = state.stats.streaming || state.stats.recording;
    if (!live) {
      // Nothing to protect; allow the close immediately.
      return Promise.resolve(false);
    }
    if (this.mainWindow === null) {
      // No window handle to prompt from — refuse to kill a live broadcast
      // silently; the user can stop it and close again.
      Logger.warn('windowWillClose while live but no main window handle; cancelling close');
      return Promise.resolve(true);
    }
    return new Promise<boolean>((resolve: (keepOpen: boolean) => void) => {
      let uiContext: UIContext | undefined = undefined;
      try {
        uiContext = this.mainWindow?.getUIContext();
      } catch (err) {
        Logger.error('getUIContext failed', Logger.asError(err as Object));
      }
      if (uiContext === undefined) {
        resolve(true);
        return;
      }
      const dialogOptions: promptAction.ShowDialogOptions = {
        title: 'OBS is still live',
        message: state.stats.streaming
          ? 'You are streaming. Closing OBS will end the broadcast.'
          : 'You are recording. Closing OBS will finalize and stop the recording.',
        buttons: [
          { text: 'Cancel', color: '#9AA0A6' },
          { text: 'Stop and Close', color: '#E5484D' }
        ]
      };
      uiContext.getPromptAction().showDialog(dialogOptions)
        .then((response: promptAction.ShowDialogSuccessResponse) => {
          if (response.index === 1) {
            Logger.warn('user confirmed closing during a live session; stopping outputs');
            ObsBridge.stopStreaming();
            ObsBridge.stopRecording();
            resolve(false); // proceed with close
          } else {
            resolve(true); // cancelled: keep window and broadcast alive
          }
        })
        .catch((err: BusinessError) => {
          Logger.error('close-confirmation dialog failed', err);
          resolve(true); // on error, never kill a live broadcast
        });
    });
  }

  private handleWindowStageClose(): void {
    const state = ObsAppState.getInstance();
    if (state.stats.streaming || state.stats.recording) {
      // Last line of defense: stop the outputs synchronously so a closing
      // window can never leak a live broadcast or a half-written recording.
      Logger.warn('windowStageClose while outputs are active — stopping them');
      ObsBridge.stopStreaming();
      ObsBridge.stopRecording();
    }
  }

  onWindowStageDestroy(): void {
    Logger.info('onWindowStageDestroy');
    KnockShareReceiver.stop();
    KnockShareSender.stop();
    if (this.mainWindow !== null) {
      try {
        this.mainWindow.off('windowWillClose');
      } catch (err) {
        Logger.debug(`off(windowWillClose): ${Logger.asError(err as Object).message}`);
      }
      this.mainWindow = null;
    }
    // The preview XComponent is gone with the stage; release the native
    // surface/EGL resources before the core shuts down in onDestroy.
    ObsBridge.detachPreviewSurface();
  }

  onDestroy(): void {
    Logger.info('onDestroy — shutting down libobs core and audio capture');
    // W3 C5/C4: tear the live-window capsule and any director session down
    // before the core dies (stopLiveView needs our process alive).
    RecLiveWindow.stopRecording();
    RecLiveWindow.stopStreaming();
    DirectorLink.teardown('ability destroy');
    // Full teardown: stops streaming/recording even if the window closed
    // mid-broadcast, releases audio capturers and calls obs_shutdown().
    ObsBridge.shutdown();
  }

  onCollaborate(wantParam: Record<string, Object>): AbilityConstant.CollaborateResult {
    // W3 C4: a phone (same account, or same AppID after discovery+binding)
    // connected to this app through abilityConnectionManager — OBS becomes
    // the director console's sink. Accept/decline is delegated to
    // DirectorLink; we always AGREE to attempt the handshake and let the
    // session creation reject internally on malformed parameters.
    Logger.info('onCollaborate — director link handshake');
    DirectorLink.onCollaborate(wantParam, this.context);
    return 0; // CollaborateResult.AGREE
  }

  onForeground(): void {
    Logger.info('onForeground');
    // The knock receiver is window/foreground scoped (official guidance:
    // unregister when backgrounded); re-arm on return to front.
    KnockShareReceiver.start(this.context);
    KnockShareSender.rearm();
  }

  onBackground(): void {
    Logger.info('onBackground');
    KnockShareReceiver.stop();
    KnockShareSender.stop();
    // Long-running broadcasts must survive backgrounding. The app declares
    // ohos.permission.KEEP_BACKGROUND_RUNNING; the actual continuous task
    // (backgroundTaskManager.startBackgroundRunning with an AUDIO_RECORDING /
    // DATA_TRANSFER mode tied to a wantAgent) is started by the transport
    // layer when an output goes live. Not wired in this scaffold — see README.
  }
}
