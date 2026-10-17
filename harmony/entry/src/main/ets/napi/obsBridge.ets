import obsBridgeNative from 'libobs_bridge.so';
import {
  NativeAudioTrack,
  NativeCameraSenderStatus,
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
export class StreamStatsSnapshot {  streaming: boolean = false;
  recording: boolean = false;
  bitrateKbps: number = 0;
  droppedFrames: number = 0;
  totalFrames: number = 0;
  uptimeSeconds: number = 0;

  static empty(): StreamStatsSnapshot {
    return new StreamStatsSnapshot();
  }
}

/** Axis-aligned bounding box of a scene item in canvas px (top-left origin). */
export class SourceBounds {
  x: number = 0;
  y: number = 0;
  w: number = 0;
  h: number = 0;
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

  /* ---- Studio mode ---- */

  static setPreviewScene(id: string): boolean {
    try {
      return obsBridgeNative.nativeSetPreviewScene(id);
    } catch (err) {
      Logger.error(`nativeSetPreviewScene(${id}) failed`, Logger.asError(err as Object));
      return false;
    }
  }

  static getPreviewSceneId(): string {
    try {
      return obsBridgeNative.nativeGetPreviewSceneId();
    } catch (err) {
      Logger.error('nativeGetPreviewSceneId failed', Logger.asError(err as Object));
      return '';
    }
  }

  static attachStudioPreviewSurface(xcomponentId: string): boolean {
    try {
      return obsBridgeNative.nativeAttachStudioPreviewSurface(xcomponentId);
    } catch (err) {
      Logger.error('nativeAttachStudioPreviewSurface failed', Logger.asError(err as Object));
      return false;
    }
  }

  static detachStudioPreviewSurface(): void {
    try {
      obsBridgeNative.nativeDetachStudioPreviewSurface();
    } catch (err) {
      Logger.error('nativeDetachStudioPreviewSurface failed', Logger.asError(err as Object));
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

  static renameScene(id: string, name: string): boolean {
    try {
      return obsBridgeNative.nativeRenameScene(id, name);
    } catch (err) {
      Logger.error(`nativeRenameScene(${id}) failed`, Logger.asError(err as Object));
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

  /**
   * harmony-web (ArkWeb browser source) frame feed — push one BGRA snapshot
   * into an async video source. itemId is the scene-item id the source was
   * added under (SourceItemModel.id); pass timestampNs=0 to let the bridge
   * stamp its own CLOCK_MONOTONIC (single clock domain, see WebFeed.ets).
   * Returns false (never throws) when the source is gone or the buffer is
   * short — the pump treats false as "retire this entry".
   */
  static webSourceFeed(itemId: string, width: number, height: number, rgba: ArrayBuffer,
    timestampNs: number): boolean {
    try {
      return obsBridgeNative.nativeWebSourceFeed(itemId, width, height, rgba, timestampNs);
    } catch (err) {
      Logger.error(`nativeWebSourceFeed(${itemId}) failed`, Logger.asError(err as Object));
      return false;
    }
  }

  /** JSON of the source's stored settings ('' when gone) — lets WebFeed
   * rebuild its registry from libobs state after a scene reload. */
  static getSourceSettings(itemId: string): string {
    try {
      return obsBridgeNative.nativeGetSourceSettings(itemId);
    } catch (err) {
      Logger.error(`nativeGetSourceSettings(${itemId}) failed`, Logger.asError(err as Object));
      return '';
    }
  }

  /** Merge a settings patch into a source's stored settings and push it
   * through the plugin's update() (per-source settings sheets write back
   * here). True on success; false when the item is gone or the JSON is bad. */
  static setSourceSettings(itemId: string, settingsJson: string): boolean {
    try {
      return obsBridgeNative.nativeSetSourceSettings(itemId, settingsJson);
    } catch (err) {
      Logger.error(`nativeSetSourceSettings(${itemId}) failed`, Logger.asError(err as Object));
      return false;
    }
  }

  /* ---- Media transport ---- */

  static mediaControl(id: string, action: string): boolean {
    try {
      return obsBridgeNative.nativeMediaControl(id, action);
    } catch (err) {
      Logger.error(`nativeMediaControl(${id}, ${action}) failed`, Logger.asError(err as Object));
      return false;
    }
  }

  /** JSON '{"time":ms,"duration":ms,"state":"..."}' ('' when gone). */
  static getMediaState(id: string): string {
    try {
      return obsBridgeNative.nativeGetMediaState(id);
    } catch (err) {
      Logger.error(`nativeGetMediaState(${id}) failed`, Logger.asError(err as Object));
      return '';
    }
  }

  static mediaSeek(id: string, ms: number): boolean {
    try {
      return obsBridgeNative.nativeMediaSeek(id, ms);
    } catch (err) {
      Logger.error(`nativeMediaSeek(${id}) failed`, Logger.asError(err as Object));
      return false;
    }
  }

  /* ---- Advanced audio props ---- */

  /** JSON '{"sync":ms,"monitor":0|1|2}' ('' when gone). */
  static getSourceAudioProps(id: string): string {
    try {
      return obsBridgeNative.nativeGetSourceAudioProps(id);
    } catch (err) {
      Logger.error(`nativeGetSourceAudioProps(${id}) failed`, Logger.asError(err as Object));
      return '';
    }
  }

  static setSourceAudioProps(id: string, syncOffsetMs: number, monitoringType: number): boolean {
    try {
      return obsBridgeNative.nativeSetSourceAudioProps(id, syncOffsetMs, monitoringType);
    } catch (err) {
      Logger.error(`nativeSetSourceAudioProps(${id}) failed`, Logger.asError(err as Object));
      return false;
    }
  }

  /* ---- Generic property schema ---- */

  /** JSON array of property descriptors ('[]' when unavailable). */
  static getPropertySchema(itemId: string, filterName: string): string {
    try {
      return obsBridgeNative.nativeGetPropertySchema(itemId, filterName);
    } catch (err) {
      Logger.error(`nativeGetPropertySchema(${itemId}) failed`, Logger.asError(err as Object));
      return '[]';
    }
  }

  static setFilterSettings(itemId: string, filterName: string, settingsJson: string): boolean {
    try {
      return obsBridgeNative.nativeSetFilterSettings(itemId, filterName, settingsJson);
    } catch (err) {
      Logger.error(`nativeSetFilterSettings(${itemId}) failed`, Logger.asError(err as Object));
      return false;
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

  /** Canvas-px bounding box of a scene item; null when unavailable. */
  static getSourceBounds(id: string): SourceBounds | null {
    try {
      const raw = obsBridgeNative.nativeGetSourceBounds(id);
      if (raw === '' || raw === undefined) {
        return null;
      }
      const parsed = JSON.parse(raw) as SourceBounds;
      return parsed;
    } catch (err) {
      Logger.error('nativeGetSourceBounds failed', Logger.asError(err as Object));
      return null;
    }
  }

  static setSourcePosition(id: string, x: number, y: number): boolean {
    try {
      return obsBridgeNative.nativeSetSourcePosition(id, x, y);
    } catch (err) {
      Logger.error('nativeSetSourcePosition failed', Logger.asError(err as Object));
      return false;
    }
  }

  /** Absolute rendered rect (canvas px) — the corner-handle resize
   * commits here; clears any bounds mode and derives the scale. */
  static setSourceRect(id: string, x: number, y: number, w: number, h: number): boolean {
    try {
      return obsBridgeNative.nativeSetSourceRect(id, x, y, w, h);
    } catch (err) {
      Logger.error('nativeSetSourceRect failed', Logger.asError(err as Object));
      return false;
    }
  }

  static scaleSourceBy(id: string, factor: number): boolean {
    try {
      return obsBridgeNative.nativeScaleSourceBy(id, factor);
    } catch (err) {
      Logger.error('nativeScaleSourceBy failed', Logger.asError(err as Object));
      return false;
    }
  }

  /** Source context menu (desktop parity): rotation in degrees + axis
   * mirrors (absolute values, the ArkTS layer tracks the current state). */
  static setSourceTransform(id: string, rotDeg: number, flipX: boolean, flipY: boolean): boolean {
    try {
      return obsBridgeNative.nativeSetSourceTransform(id, rotDeg, flipX, flipY);
    } catch (err) {
      Logger.error(`nativeSetSourceTransform(${id}) failed`, Logger.asError(err as Object));
      return false;
    }
  }

  /** Bounds preset: 'fit' (scale inner, centred) | 'stretch' | 'none'. */
  static setSourceBoundsFit(id: string, mode: string): boolean {
    try {
      return obsBridgeNative.nativeSetSourceBoundsFit(id, mode);
    } catch (err) {
      Logger.error(`nativeSetSourceBoundsFit(${id}) failed`, Logger.asError(err as Object));
      return false;
    }
  }

  /** Absolute size in canvas px (w/h <= 0 keeps that axis). */
  static setSourceSize(id: string, w: number, h: number): boolean {
    try {
      return obsBridgeNative.nativeSetSourceSize(id, w, h);
    } catch (err) {
      Logger.error(`nativeSetSourceSize(${id}) failed`, Logger.asError(err as Object));
      return false;
    }
  }

  static setSourceLocked(id: string, locked: boolean): boolean {
    try {
      return obsBridgeNative.nativeSetSourceLocked(id, locked);
    } catch (err) {
      Logger.error(`nativeSetSourceLocked(${id}) failed`, Logger.asError(err as Object));
      return false;
    }
  }

  /** dir: 'up' | 'down' | 'top' | 'bottom'. */
  static setSourceOrder(id: string, dir: string): boolean {
    try {
      return obsBridgeNative.nativeSetSourceOrder(id, dir);
    } catch (err) {
      Logger.error(`nativeSetSourceOrder(${id}, ${dir}) failed`, Logger.asError(err as Object));
      return false;
    }
  }

  /** Current transform as JSON '{"rot":..,"flipX":..,"flipY":..}' ('' when
   * the item is gone) — the menu's toggles read it before computing the
   * next absolute state. */
  static getSourceTransform(id: string): string {
    try {
      return obsBridgeNative.nativeGetSourceTransform(id);
    } catch (err) {
      Logger.error(`nativeGetSourceTransform(${id}) failed`, Logger.asError(err as Object));
      return '';
    }
  }

  /** Reference-copy a scene item; returns the new item id or ''. */
  static duplicateSource(id: string): string {
    try {
      return obsBridgeNative.nativeDuplicateSource(id);
    } catch (err) {
      Logger.error(`nativeDuplicateSource(${id}) failed`, Logger.asError(err as Object));
      return '';
    }
  }

  static renameSource(id: string, name: string): boolean {
    try {
      return obsBridgeNative.nativeRenameSource(id, name);
    } catch (err) {
      Logger.error(`nativeRenameSource(${id}) failed`, Logger.asError(err as Object));
      return false;
    }
  }

  /** W3-C1 wireless-camera sender (phone role). Returns false + a message
   * instead of throwing so the role page can surface the reason. */
  static startCameraSender(host: string, port: number, bitrateKbps: number): string | undefined {
    try {
      obsBridgeNative.nativeStartCameraSender(host, port, bitrateKbps);
      return undefined;
    } catch (err) {
      const e = Logger.asError(err as Object);
      Logger.error('nativeStartCameraSender failed', e);
      return e.message;
    }
  }

  static stopCameraSender(): void {
    try {
      obsBridgeNative.nativeStopCameraSender();
    } catch (err) {
      Logger.error('nativeStopCameraSender failed', Logger.asError(err as Object));
    }
  }

  static cameraSenderStatus(): NativeCameraSenderStatus | undefined {
    try {
      return obsBridgeNative.nativeCameraSenderStatus();
    } catch (err) {
      Logger.error('nativeCameraSenderStatus failed', Logger.asError(err as Object));
      return undefined;
    }
  }

  static selectScene(id: string, durationMs: number = 0): boolean {
    try {
      return obsBridgeNative.nativeSelectScene(id, durationMs);
    } catch (err) {
      Logger.error('nativeSelectScene failed', Logger.asError(err as Object));
      return false;
    }
  }

  /** JSON array of registered transition types [{"id","name"}] ('' or '[]'
   * when the core is unavailable) — the 转场动画 dock populates from this. */
  static getTransitionTypes(): string {
    try {
      return obsBridgeNative.nativeGetTransitionTypes();
    } catch (err) {
      Logger.error('nativeGetTransitionTypes failed', Logger.asError(err as Object));
      return '';
    }
  }

  /** Swap the program transition shell to another transition type. */
  static setTransitionType(id: string): boolean {
    try {
      return obsBridgeNative.nativeSetTransitionType(id);
    } catch (err) {
      Logger.error(`nativeSetTransitionType(${id}) failed`, Logger.asError(err as Object));
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

  /** Lazy desktop-loopback starter — call when the user adds the desktop
   * audio source. The boot-time request popped the system privacy dialog on
   * every cold start (session consent, 10-13); idempotent + fire-and-forget,
   * the authorization outcome surfaces through the mixer's track poll. */
  static ensureDesktopAudio(): void {
    try {
      obsBridgeNative.nativeEnsureDesktopAudio();
    } catch (err) {
      Logger.error('nativeEnsureDesktopAudio failed', Logger.asError(err as Object));
    }
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
