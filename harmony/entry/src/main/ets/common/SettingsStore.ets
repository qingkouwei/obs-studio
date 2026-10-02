import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from './Logger';

const STORE_NAME = 'obs-settings';

/**
 * Durable profile-level settings (resolution/fps, bitrates, RTMP target,
 * recording path) persisted through the app's preferences store — the
 * HarmonyOS equivalent of the desktop profile.ini. The whole bag is stored
 * as one JSON string under SETTINGS_KEY so schema evolution never needs a
 * migration: unknown keys survive a round-trip, missing keys fall back to
 * the defaults declared in ObsSettings.
 */
export class ObsSettings {
  /** Canvas geometry (applied via nativeResetVideo). */
  videoWidth: number = 1920;
  videoHeight: number = 1080;
  videoFps: number = 60;
  /** Video codec: 'h264' or 'hevc' (OH_VideoEncoder hardware path). */
  videoCodec: string = 'h264';
  /** Scene-switch transition: 0 = cut, else fade duration in ms. */
  sceneTransitionMs: number = 300;
  /** Recording encoder bitrates (kbps). */
  recordVideoKbps: number = 10000;
  recordAudioKbps: number = 192;
  /** Streaming encoder bitrates (kbps). */
  streamVideoKbps: number = 2500;
  streamAudioKbps: number = 160;
  /** RTMP target. */
  streamingServer: string = 'rtmp://192.168.0.100:1935/live';
  streamingKey: string = 'obs-test';
}

const SETTINGS_KEY = 'settings-json';

export class SettingsStore {
  private static store: preferences.Preferences | null = null;

  private static async open(context: common.UIAbilityContext): Promise<preferences.Preferences> {
    if (SettingsStore.store === null) {
      SettingsStore.store = await preferences.getPreferences(context, STORE_NAME);
    }
    return SettingsStore.store;
  }

  /** Load persisted settings; defaults on first run or any failure. */
  static async load(context: common.UIAbilityContext): Promise<ObsSettings> {
    const fresh = new ObsSettings();
    try {
      const store = await SettingsStore.open(context);
      const raw = await store.get(SETTINGS_KEY, '') as string;
      if (raw.length === 0) {
        return fresh;
      }
      const parsed = JSON.parse(raw) as ObsSettings;
      // Field-wise merge so keys added in future versions keep their defaults.
      const merged = new ObsSettings();
      if (typeof parsed.videoWidth === 'number') {
        merged.videoWidth = parsed.videoWidth;
      }
      if (typeof parsed.videoHeight === 'number') {
        merged.videoHeight = parsed.videoHeight;
      }
      if (typeof parsed.videoFps === 'number') {
        merged.videoFps = parsed.videoFps;
      }
      if (parsed.videoCodec === 'hevc' || parsed.videoCodec === 'h264') {
        merged.videoCodec = parsed.videoCodec;
      }
      if (typeof parsed.sceneTransitionMs === 'number' && parsed.sceneTransitionMs >= 0
        && parsed.sceneTransitionMs <= 5000) {
        merged.sceneTransitionMs = parsed.sceneTransitionMs;
      }
      if (typeof parsed.recordVideoKbps === 'number') {
        merged.recordVideoKbps = parsed.recordVideoKbps;
      }
      if (typeof parsed.recordAudioKbps === 'number') {
        merged.recordAudioKbps = parsed.recordAudioKbps;
      }
      if (typeof parsed.streamVideoKbps === 'number') {
        merged.streamVideoKbps = parsed.streamVideoKbps;
      }
      if (typeof parsed.streamAudioKbps === 'number') {
        merged.streamAudioKbps = parsed.streamAudioKbps;
      }
      if (typeof parsed.streamingServer === 'string') {
        merged.streamingServer = parsed.streamingServer;
      }
      if (typeof parsed.streamingKey === 'string') {
        merged.streamingKey = parsed.streamingKey;
      }
      return merged;
    } catch (err) {
      Logger.warn(`settings load failed, using defaults: ${Logger.asError(err as Object).message}`);
      return fresh;
    }
  }

  static async save(context: common.UIAbilityContext, settings: ObsSettings): Promise<void> {
    try {
      const store = await SettingsStore.open(context);
      await store.put(SETTINGS_KEY, JSON.stringify(settings));
      await store.flush();
    } catch (err) {
      Logger.error('settings save failed', Logger.asError(err as Object));
    }
  }
}
