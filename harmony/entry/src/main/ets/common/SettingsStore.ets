import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from './Logger';

const STORE_NAME = 'obs-settings';

/** One remembered RTMP target (server + stream key), recorded every time a
 * stream actually starts (user request 10-17). Newest first, capped. */
export class StreamTargetEntry {
  server: string = '';
  key: string = '';
}

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
  /** Transition type id for scene switches (fade/slide/swipe/...). */
  transitionId: string = 'fade_transition';
  /** Source snapping (desktop 源对齐). */
  snapEnabled: boolean = true;
  snapThreshold: number = 10;
  snapToEdges: boolean = true;
  /** Output confirmations (desktop 输出 group). */
  confirmStartRecord: boolean = false;
  confirmStopRecord: boolean = false;
  confirmStartStream: boolean = false;
  confirmStopStream: boolean = false;
  autoRecordOnStream: boolean = false;
  autoStopRecordOnStreamStop: boolean = false;
  /** Preview guides (desktop 参考线). */
  guideSafeAreas: boolean = false;
  guideCenter: boolean = false;
  guideScale: boolean = false;
  /** Recording encoder bitrates (kbps). */
  recordVideoKbps: number = 10000;
  recordAudioKbps: number = 192;
  /** Streaming encoder bitrates (kbps). */
  streamVideoKbps: number = 2500;
  streamAudioKbps: number = 160;
  /** RTMP target. */
  streamingServer: string = 'rtmp://192.168.0.105:1935/live';
  streamingKey: string = 'obs-test';
}

const SETTINGS_KEY = 'settings-json';
const CAMFEED_HOST_KEY = 'camfeed-host';
const STREAM_TARGETS_KEY = 'stream-targets-json';
/** Cap for the remembered-target list (user request 10-17). */
const MAX_STREAM_TARGETS = 10;

export class SettingsStore {
  private static store: preferences.Preferences | null = null;

  /** Remembered RTMP targets, newest first. Invalid rows are dropped so a
   * hand-edited store never feeds garbage into the picker. */
  static async loadStreamTargets(context: common.UIAbilityContext): Promise<StreamTargetEntry[]> {
    try {
      const store = await SettingsStore.open(context);
      const raw = await store.get(STREAM_TARGETS_KEY, '') as string;
      if (raw.length === 0) {
        return [];
      }
      const parsed = JSON.parse(raw) as StreamTargetEntry[];
      if (!Array.isArray(parsed)) {
        return [];
      }
      return parsed.filter((e: StreamTargetEntry): boolean =>
        e !== null && e !== undefined && typeof e.server === 'string' && e.server.length > 0 &&
          typeof e.key === 'string');
    } catch (err) {
      Logger.warn(`stream targets load failed: ${Logger.asError(err as Object).message}`);
      return [];
    }
  }

  /** Upsert one target: exact duplicates move to the front, otherwise the
   * entry is prepended and the list is capped. */
  static async rememberStreamTarget(context: common.UIAbilityContext, server: string,
    key: string): Promise<StreamTargetEntry[]> {
    const list = await SettingsStore.loadStreamTargets(context);
    const entry = new StreamTargetEntry();
    entry.server = server;
    entry.key = key;
    const kept: StreamTargetEntry[] = list.filter((e: StreamTargetEntry): boolean =>
      !(e.server === server && e.key === key));
    kept.unshift(entry);
    const capped = kept.slice(0, MAX_STREAM_TARGETS);
    try {
      const store = await SettingsStore.open(context);
      await store.put(STREAM_TARGETS_KEY, JSON.stringify(capped));
      await store.flush();
    } catch (err) {
      Logger.warn('stream targets save failed');
    }
    return capped;
  }

  static async forgetStreamTarget(context: common.UIAbilityContext, server: string,
    key: string): Promise<StreamTargetEntry[]> {
    const list = await SettingsStore.loadStreamTargets(context);
    const kept = list.filter((e: StreamTargetEntry): boolean => !(e.server === server && e.key === key));
    try {
      const store = await SettingsStore.open(context);
      await store.put(STREAM_TARGETS_KEY, JSON.stringify(kept));
      await store.flush();
    } catch (err) {
      Logger.warn('stream targets save failed');
    }
    return kept;
  }

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
      if (typeof parsed.transitionId === 'string' && parsed.transitionId.length > 0) {
        merged.transitionId = parsed.transitionId;
      }
      if (typeof parsed.snapEnabled === 'boolean') {
        merged.snapEnabled = parsed.snapEnabled;
      }
      if (typeof parsed.snapThreshold === 'number' && parsed.snapThreshold >= 1 && parsed.snapThreshold <= 100) {
        merged.snapThreshold = parsed.snapThreshold;
      }
      if (typeof parsed.snapToEdges === 'boolean') {
        merged.snapToEdges = parsed.snapToEdges;
      }
      if (typeof parsed.confirmStartRecord === 'boolean') {
        merged.confirmStartRecord = parsed.confirmStartRecord;
      }
      if (typeof parsed.confirmStopRecord === 'boolean') {
        merged.confirmStopRecord = parsed.confirmStopRecord;
      }
      if (typeof parsed.confirmStartStream === 'boolean') {
        merged.confirmStartStream = parsed.confirmStartStream;
      }
      if (typeof parsed.confirmStopStream === 'boolean') {
        merged.confirmStopStream = parsed.confirmStopStream;
      }
      if (typeof parsed.autoRecordOnStream === 'boolean') {
        merged.autoRecordOnStream = parsed.autoRecordOnStream;
      }
      if (typeof parsed.autoStopRecordOnStreamStop === 'boolean') {
        merged.autoStopRecordOnStreamStop = parsed.autoStopRecordOnStreamStop;
      }
      if (typeof parsed.guideSafeAreas === 'boolean') {
        merged.guideSafeAreas = parsed.guideSafeAreas;
      }
      if (typeof parsed.guideCenter === 'boolean') {
        merged.guideCenter = parsed.guideCenter;
      }
      if (typeof parsed.guideScale === 'boolean') {
        merged.guideScale = parsed.guideScale;
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

  /** W3-C1 wireless-camera role: remember the last producer address so
   * re-arming the feed is one tap. Separate key from the settings bag —
   * it is device-pairing state, not OBS profile config. */
  static async loadCamfeedHost(context: common.UIAbilityContext): Promise<string> {
    try {
      const store = await SettingsStore.open(context);
      return await store.get(CAMFEED_HOST_KEY, '') as string;
    } catch (err) {
      Logger.warn('camfeed host load failed');
      return '';
    }
  }

  static async saveCamfeedHost(context: common.UIAbilityContext, host: string): Promise<void> {
    try {
      const store = await SettingsStore.open(context);
      await store.put(CAMFEED_HOST_KEY, host);
      await store.flush();
    } catch (err) {
      Logger.warn('camfeed host save failed');
    }
  }
}
