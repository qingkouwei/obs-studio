import { ObsSettings } from './SettingsStore';
import { Want } from '@kit.AbilityKit';
import { Logger } from './Logger';

const TAG = 'Continue';

/** JSON key under which the settings bag travels inside wantParam. */
export const CONTINUE_KEY = 'obs-settings';

/**
 * Continuation codec — W3 C6: the migration payload for onContinue.
 *
 * What migrates: the settings bag (canvas geometry, codec, bitrates, RTMP
 * target). NOT the scene/source graph — sources are capture sessions bound
 * to this device's hardware (screen, camera, mic); a migrated
 * "harmony_display_capture" on another machine would point at nothing, and
 * the privacy-consent dialogs are per-device anyway. The honest
 * desktop-analogue is "same profile, fresh sources", which is also what OBS
 * profile switching feels like.
 *
 * Transport: on this SDK the target receives the payload via want.parameters
 * (LaunchParam.lastInstanceData is absent from API 26's declaration set),
 * matching the official continuation best practices.
 */
export class ContinuationCodec {
  /** Encode a settings bag into the wantParam record. Returns false on
   * serialization failure (the caller should then REJECT the migration —
   * an empty payload on the far side is worse than a visible refusal). */
  static encode(settings: ObsSettings, wantParam: Record<string, Object>): boolean {
    try {
      wantParam[CONTINUE_KEY] = JSON.stringify(settings);
      return true;
    } catch (err) {
      Logger.error(`${TAG}: encode failed`, Logger.asError(err as Object));
      return false;
    }
  }

  /** Pull the payload out of the migration want (target side). */
  static decodeFromWant(want: Want): ObsSettings | null {
    const params = want.parameters;
    if (params === undefined || params === null) {
      Logger.info(`${TAG}: want has no parameters`);
      return null;
    }
    return ContinuationCodec.decode(params as Record<string, Object>);
  }

  /** Decode a wantParam/parameters record (cold-start target). Unknown or
   * absent keys fall back to defaults via the caller's merge — a
   * version-skewed migration must never crash the target device. */
  static decode(wantParam: Record<string, Object>): ObsSettings | null {
    const raw = wantParam[CONTINUE_KEY];
    if (typeof raw !== 'string') {
      Logger.info(`${TAG}: no payload in wantParam`);
      return null;
    }
    try {
      const parsed = JSON.parse(raw) as ObsSettings;
      // Minimal shape check: a bag without a canvas width is not our schema.
      if (typeof parsed.videoWidth !== 'number') {
        Logger.warn(`${TAG}: payload lacks videoWidth, ignoring`);
        return null;
      }
      Logger.info(`${TAG}: decoded ${parsed.videoWidth}x${parsed.videoHeight}@${parsed.videoFps}`);
      return parsed;
    } catch (err) {
      Logger.error(`${TAG}: decode failed`, Logger.asError(err as Object));
      return null;
    }
  }
}
