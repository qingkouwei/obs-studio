import obsBridgeNative from 'libobs_bridge.so';
import {
  NativeAudioTrack,
  NativeFilterEntry,
  NativeOutputLevel,
  NativeSceneEntry,
  NativeSourceEntry,
  NativeStreamStats,
  NativeVideoInfo
} from 'libobs_bridge.so';
import { Logger } from '../common/Logger';

/**
 * Typed, defensive ArkTS wrapper over libobs_bridge.so.
 *
 * Contract with the C++ side (cpp/types/libobs_bridge/index.d.ts):
 * every method can throw — either a real error, or the canonical
 * "libobs core is not linked in this build (HAVE_LIBOBS undefined)" error
 * produced by the shell-only bridge. NOTHING here is allowed to let a native
 * error escape: every call is wrapped, logged, and degraded to a safe default
 * so a broken/missing core never takes down the UI.
 */

/** Result of the honest two-part system-audio (desktop loopback) probe. */
export class SystemAudioCapability {
  /** canIUse('SystemCapability.Multimedia.Audio.PlaybackCapture') on this device. */
  syscapReported: boolean = false;
  /** Native probe: loopback symbol + AVScreenCapture symbol present and API >= 23. */
  nativeProbeOk: boolean = false;
  /** True only when BOTH probes pass. PC/2in1 support is unverified upstream. */
  supported: boolean = false;
  probed: boolean = false;
}

/** Snapshot returned by getStats() when the native call fails. */
export class StreamStatsSnapshot {
  streaming: boolean = false;
  recording: boolean = false;
  bitrateKbps: number = 0;
  droppedFrames: number = 0;
  totalFrames: number = 0;
  uptimeSeconds: number = 0;

  static empty(): StreamStatsSnapshot {
    return new StreamStatsSnapshot();
  }
}

export class ObsBridge {
  /** Start the core (when linked) + the HarmonyOS audio capture tracks. */
  static init(configDir: string, codeDir: string, dataDir: string): boolean {
    try {
      return obsBridgeNative.nativeInit(configDir, codeDir, dataDir);
    } catch (err) {
      Logger.error('nativeInit failed (running shell-only)', Logger.asError(err as Object));
      return false;
    }
  }

  /** Stop outputs, audio capture and libobs. Safe to call when never started. */
  static shutdown(): void {
    try {
      obsBridgeNative.nativeShutdown();
    } catch (err) {
      Logger.error('nativeShutdown failed', Logger.asError(err as Object));
    }
  }

  static attachPreviewSurface(xcomponentId: string): boolean {
    try {
      return obsBridgeNative.nativeAttachPreviewSurface(xcomponentId);
    } catch (err) {
      Logger.error('nativeAttachPreviewSurface failed', Logger.asError(err as Object));
      return false;
    }
  }

  static detachPreviewSurface(): void {
    try {
      obsBridgeNative.nativeDetachPreviewSurface();
    } catch (err) {
      Logger.error('nativeDetachPreviewSurface failed', Logger.asError(err as Object));
    }
  }

  static getScenes(): NativeSceneEntry[] {
    try {
      return obsBridgeNative.nativeGetScenes();
    } catch (err) {
      Logger.error('nativeGetScenes failed', Logger.asError(err as Object));
      return [];
    }
  }

  static createScene(name: string): string {
    try {
      return obsBridgeNative.nativeCreateScene(name);
    } catch (err) {
      Logger.error(`nativeCreateScene('${name}') failed`, Logger.asError(err as Object));
      return '';
    }
  }

  static removeScene(id: string): boolean {
    try {
      return obsBridgeNative.nativeRemoveScene(id);
    } catch (err) {
      Logger.error('nativeRemoveScene failed', Logger.asError(err as Object));
      return false;
    }
  }

  static getSources(sceneId: string): NativeSourceEntry[] {
    try {
      return obsBridgeNative.nativeGetSources(sceneId);
    } catch (err) {
      Logger.error('nativeGetSources failed', Logger.asError(err as Object));
      return [];
    }
  }

  static addSource(sceneId: string, typeId: string, name: string, settingsJson: string): string {
    try {
      return obsBridgeNative.nativeAddSource(sceneId, typeId, name, settingsJson);
    } catch (err) {
      Logger.error(`nativeAddSource(${typeId}) failed`, Logger.asError(err as Object));
      return '';
    }
  }

  static removeSource(id: string): boolean {
    try {
      return obsBridgeNative.nativeRemoveSource(id);
    } catch (err) {
      Logger.error('nativeRemoveSource failed', Logger.asError(err as Object));
      return false;
    }
  }

  static setSourceVisible(id: string, visible: boolean): boolean {
    try {
      return obsBridgeNative.nativeSetSourceVisible(id, visible);
    } catch (err) {
      Logger.error('nativeSetSourceVisible failed', Logger.asError(err as Object));
      return false;
    }
  }

  static selectScene(id: string): boolean {
    try {
      return obsBridgeNative.nativeSelectScene(id);
    } catch (err) {
      Logger.error('nativeSelectScene failed', Logger.asError(err as Object));
      return false;
    }
  }

  /** Current canvas geometry; 1080p60 default when the core is unavailable. */
  static getVideoInfo(): NativeVideoInfo {
    try {
      return obsBridgeNative.nativeGetVideoInfo();
    } catch (err) {
      Logger.error('nativeGetVideoInfo failed', Logger.asError(err as Object));
      const fallback: NativeVideoInfo = { width: 1920, height: 1080, fps: 60 };
      return fallback;
    }
  }

  static resetVideo(width: number, height: number, fps: number): boolean {
    try {
      return obsBridgeNative.nativeResetVideo(width, height, fps);
    } catch (err) {
      Logger.error('nativeResetVideo failed', Logger.asError(err as Object));
      return false;
    }
  }

  static getFilterTypes(): string[] {
    try {
      return obsBridgeNative.nativeGetFilterTypes();
    } catch (err) {
      Logger.error('nativeGetFilterTypes failed', Logger.asError(err as Object));
      return [];
    }
  }

  static getFilters(sourceId: string): NativeFilterEntry[] {
    try {
      return obsBridgeNative.nativeGetFilters(sourceId);
    } catch (err) {
      Logger.error('nativeGetFilters failed', Logger.asError(err as Object));
      return [];
    }
  }

  static addFilter(sourceId: string, filterTypeId: string): boolean {
    try {
      return obsBridgeNative.nativeAddFilter(sourceId, filterTypeId);
    } catch (err) {
      Logger.error(`nativeAddFilter(${filterTypeId}) failed`, Logger.asError(err as Object));
      return false;
    }
  }

  static removeFilter(sourceId: string, filterName: string): boolean {
    try {
      return obsBridgeNative.nativeRemoveFilter(sourceId, filterName);
    } catch (err) {
      Logger.error('nativeRemoveFilter failed', Logger.asError(err as Object));
      return false;
    }
  }

  static setFilterEnabled(sourceId: string, filterName: string, enabled: boolean): boolean {
    try {
      return obsBridgeNative.nativeSetFilterEnabled(sourceId, filterName, enabled);
    } catch (err) {
      Logger.error('nativeSetFilterEnabled failed', Logger.asError(err as Object));
      return false;
    }
  }

  static getAudioTracks(): NativeAudioTrack[] {
    try {
      return obsBridgeNative.nativeGetAudioTracks();
    } catch (err) {
      Logger.error('nativeGetAudioTracks failed', Logger.asError(err as Object));
      return [];
    }
  }

  static setMute(trackId: string, muted: boolean): boolean {
    try {
      return obsBridgeNative.nativeSetMute(trackId, muted);
    } catch (err) {
      Logger.error('nativeSetMute failed', Logger.asError(err as Object));
      return false;
    }
  }

  static setVolume(trackId: string, volume: number): boolean {
    try {
      return obsBridgeNative.nativeSetVolume(trackId, volume);
    } catch (err) {
      Logger.error('nativeSetVolume failed', Logger.asError(err as Object));
      return false;
    }
  }

  static getOutputLevels(): NativeOutputLevel[] {
    try {
      return obsBridgeNative.nativeGetOutputLevels();
    } catch (err) {
      // Level polling is high frequency; log at debug level to avoid spam.
      Logger.debug(`nativeGetOutputLevels failed: ${Logger.asError(err as Object).message}`);
      return [];
    }
  }

  /**
   * Honest runtime probe for desktop audio loopback ("内录").
   *
   * Official docs list Phone/Tablet/TV for
   * SystemCapability.Multimedia.Audio.PlaybackCapture — PC/2in1 support is
   * UNVERIFIED, so we probe both layers instead of assuming:
   *   1. ArkTS syscap database (canIUse), and
   *   2. the actual device libraries from native (dlsym of the API 23 async
   *      loopback entry point + runtime API level).
   * The UI surfaces both results.
   */
  static canCaptureSystemAudio(): SystemAudioCapability {
    const capability = new SystemAudioCapability();
    try {
      capability.syscapReported = canIUse('SystemCapability.Multimedia.Audio.PlaybackCapture');
    } catch (err) {
      Logger.error('canIUse(PlaybackCapture) threw', Logger.asError(err as Object));
      capability.syscapReported = false;
    }
    try {
      capability.nativeProbeOk = obsBridgeNative.nativeCanCaptureSystemAudio();
    } catch (err) {
      Logger.error('nativeCanCaptureSystemAudio failed', Logger.asError(err as Object));
      capability.nativeProbeOk = false;
    }
    capability.supported = capability.syscapReported && capability.nativeProbeOk;
    capability.probed = true;
    Logger.info(`system audio probe: syscap=${capability.syscapReported} ` +
      `native=${capability.nativeProbeOk} => supported=${capability.supported}`);
    return capability;
  }

  static startStreaming(configJson: string): boolean {
    try {
      return obsBridgeNative.nativeStartStreaming(configJson);
    } catch (err) {
      Logger.error('nativeStartStreaming failed', Logger.asError(err as Object));
      return false;
    }
  }

  static stopStreaming(): boolean {
    try {
      return obsBridgeNative.nativeStopStreaming();
    } catch (err) {
      Logger.error('nativeStopStreaming failed', Logger.asError(err as Object));
      return false;
    }
  }

  static startRecording(configJson: string): boolean {
    try {
      return obsBridgeNative.nativeStartRecording(configJson);
    } catch (err) {
      Logger.error('nativeStartRecording failed', Logger.asError(err as Object));
      return false;
    }
  }

  static stopRecording(): boolean {
    try {
      return obsBridgeNative.nativeStopRecording();
    } catch (err) {
      Logger.error('nativeStopRecording failed', Logger.asError(err as Object));
      return false;
    }
  }

  static getStats(): StreamStatsSnapshot {
    try {
      const native: NativeStreamStats = obsBridgeNative.nativeGetStats();
      const snapshot = new StreamStatsSnapshot();
      snapshot.streaming = native.streaming;
      snapshot.recording = native.recording;
      snapshot.bitrateKbps = native.bitrateKbps;
      snapshot.droppedFrames = native.droppedFrames;
      snapshot.totalFrames = native.totalFrames;
      snapshot.uptimeSeconds = native.uptimeSeconds;
      return snapshot;
    } catch (err) {
      Logger.debug(`nativeGetStats failed: ${Logger.asError(err as Object).message}`);
      return StreamStatsSnapshot.empty();
    }
  }

  /**
   * Register (or with null, unregister) the push-mode stats callback. The
   * native stats thread calls it ~1x/second while an output is active; the
   * UI must not poll for stats.
   */
  static setStatsCallback(cb: ((stats: NativeStreamStats) => void) | null): boolean {
    try {
      return obsBridgeNative.nativeSetStatsCallback(cb);
    } catch (err) {
      Logger.error('nativeSetStatsCallback failed', Logger.asError(err as Object));
      return false;
    }
  }
}
