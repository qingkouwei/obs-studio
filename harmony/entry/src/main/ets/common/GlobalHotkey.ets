import { inputConsumer, KeyCode } from '@kit.InputKit';
import { abilityAccessCtrl, Permissions, bundleManager, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from './Logger';
import { ObsController } from '../model/ObsModel';

/**
 * Global (application-level) shortcut keys for the producer host.
 *
 * Why this exists: on a PC/2in1 the operator is usually working inside the
 * window that is BEING captured — OBS sits unfocused or minimized while the
 * user demonstrates something. Desktop OBS solves this with global hotkeys;
 * without them the operator has to bring OBS to the front before every
 * start/stop, which is unacceptable for a live demo or a screencast.
 *
 * Permission note (verified 10-17 against the SDK d.ts): the
 * `inputConsumer.on('hotkeyChange')` declaration carries NO @permission tag,
 * so the API itself does not require a grant. Our manifest nevertheless
 * declares the RESTRICTED `ohos.permission.INPUT_MONITORING` for this
 * feature (AGC restricted-permission application), and we gate registration
 * on that grant so release builds without the approval never register — the
 * same "disabled when the grant is absent" contract documented in
 * EntryAbility's USER_GRANT_PERMISSIONS note.
 *
 * Hotkeys (OBS-desktop parity):
 *   Ctrl+Shift+R  start / stop recording
 *   Ctrl+Shift+S  start / stop streaming
 */
const PERMISSION_INPUT_MONITORING: Permissions = 'ohos.permission.INPUT_MONITORING';

interface HotkeyBinding {
  label: string;
  options: inputConsumer.HotkeyOptions;
  callback: (opts: inputConsumer.HotkeyOptions) => void;
}

const CTRL: number = KeyCode.KEYCODE_CTRL_LEFT;
const SHIFT: number = KeyCode.KEYCODE_SHIFT_LEFT;

export class GlobalHotkey {
  private static bindings: HotkeyBinding[] = [];
  private static registered = false;

  /** Register the producer hotkeys. Safe to call more than once. */
  static register(context: common.UIAbilityContext): boolean {
    if (GlobalHotkey.registered) {
      return true;
    }
    if (!GlobalHotkey.hasGrant(context)) {
      Logger.warn('global hotkeys NOT registered: INPUT_MONITORING not granted');
      return false;
    }
    GlobalHotkey.build();
    for (const b of GlobalHotkey.bindings) {
      try {
        inputConsumer.on('hotkeyChange', b.options, b.callback);
        Logger.info(`hotkey registered: ${b.label}`);
      } catch (err) {
        const e = err as BusinessError;
        // 801 capability unsupported / 4200002 taken by system / 4200003
        // taken by another app — none of these are fatal, the app keeps
        // working with in-window shortcuts only.
        Logger.warn(`hotkey ${b.label} registration failed: ${e.code} ${e.message}`);
      }
    }
    GlobalHotkey.registered = true;
    return true;
  }

  static unregister(): void {
    if (!GlobalHotkey.registered) {
      return;
    }
    for (const b of GlobalHotkey.bindings) {
      try {
        inputConsumer.off('hotkeyChange', b.options, b.callback);
      } catch (err) {
        Logger.warn(`hotkey ${b.label} unregister failed: ${(err as BusinessError).message}`);
      }
    }
    GlobalHotkey.bindings = [];
    GlobalHotkey.registered = false;
  }

  private static build(): void {
    GlobalHotkey.bindings = [
      {
        label: 'Ctrl+Shift+R (record)',
        options: { preKeys: [CTRL, SHIFT], finalKey: KeyCode.KEYCODE_R, isRepeat: false },
        callback: (): void => {
          Logger.info('hotkey: toggle recording');
          ObsController.toggleRecording();
        }
      },
      {
        label: 'Ctrl+Shift+S (stream)',
        options: { preKeys: [CTRL, SHIFT], finalKey: KeyCode.KEYCODE_S, isRepeat: false },
        callback: (): void => {
          Logger.info('hotkey: toggle streaming');
          ObsController.toggleStreaming();
        }
      }
    ];
  }

  /** Restricted permissions cannot be requested at runtime — only checked. */
  private static hasGrant(context: common.UIAbilityContext): boolean {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const tokenId: number = (bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION)).appInfo.accessTokenId;
      const state = atManager.checkAccessTokenSync(tokenId, PERMISSION_INPUT_MONITORING);
      Logger.info(`INPUT_MONITORING grant state = ${state}`);
      void context;
      return state === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (err) {
      Logger.warn(`permission probe failed: ${(err as BusinessError).message}`);
      return false;
    }
  }
}
