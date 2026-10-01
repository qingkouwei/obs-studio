/**
 * Typed declaration of libobs_bridge.so — the NAPI bridge between ArkTS and
 * the (future) cross-compiled libobs core.
 *
 * Every symbol declared here is implemented in ../napi_init.cpp /
 * ../obs_bridge.cpp. Methods whose implementation depends on libobs return a
 * napi error ("libobs core not linked") when the bridge is built in shell-only
 * mode (HAVE_LIBOBS undefined); the ArkTS wrapper (ets/napi/obsBridge.ets)
 * catches those and degrades gracefully.
 */

/** One scene, as reported by nativeGetScenes(). */
export interface NativeSceneEntry {
  /** Stable scene id (libobs source UUID when the core is linked). */
  id: string;
  name: string;
}

/** One source (scene item) inside a scene, as reported by nativeGetSources(). */
export interface NativeSourceEntry {
  /** Scene-item id, unique within the profile; pass to nativeRemoveSource / nativeSetSourceVisible. */
  id: string;
  /** UUID of the underlying obs_source_t ("" in shell-only mode). */
  sourceUuid: string;
  name: string;
  /** Source type id, e.g. "harmony_screen_capture", "image_source". */
  typeId: string;
  visible: boolean;
}

/** Audio track state reported by nativeGetAudioTracks(). */
export interface NativeAudioTrack {
  /** "desktop-audio" (loopback / 内录) or "mic-audio". */
  id: string;
  name: string;
  muted: boolean;
  /** Linear 0.0 .. 1.0 */
  volume: number;
  /**
   * Mirror of the native CaptureState enum:
   * 0 = Unsupported, 1 = Idle, 2 = Requesting (async authorization pending),
   * 3 = Running, 4 = NotAuthorized (user denied the privacy dialog),
   * 5 = Failed.
   */
  state: number;
  /** Whether the probe concluded the device can support this track at all. */
  supported: boolean;
}

/** Per-track metering sample returned by nativeGetOutputLevels(). */
export interface NativeOutputLevel {
  id: string;
  /** Linear peak amplitude 0.0 .. 1.0 since the last call. */
  peak: number;
  /** Linear RMS amplitude 0.0 .. 1.0 since the last call. */
  rms: number;
}

/** Output/streaming statistics snapshot. */
export interface NativeStreamStats {
  streaming: boolean;
  recording: boolean;
  bitrateKbps: number;
  droppedFrames: number;
  totalFrames: number;
  uptimeSeconds: number;
}

/** Callback pushed from the native stats thread via a threadsafe function. */
export type NativeStatsCallback = (stats: NativeStreamStats) => void;

export interface ObsBridgeNative {
  /** Start libobs (when linked) and the HarmonyOS audio capture tracks. */
  /**
   * @param configDir writable dir for OBS profiles/config (context.filesDir)
   * @param codeDir   bundle native lib dir holding every plugin .so
   *                  (context.bundleCodeDir + '/libs/arm64-v8a')
   * @param dataDir   writable dir already populated with the extracted rawfile
   *                  tree; must contain libobs/*.effect and obs-plugins/*
   */
  nativeInit(configDir: string, codeDir: string, dataDir: string): boolean;
  /** Stop all outputs, tear down audio capture and libobs. */
  nativeShutdown(): void;

  /** Bind the XComponent surface (registered by id at load time) as the preview canvas. */
  nativeAttachPreviewSurface(xcomponentId: string): boolean;
  /** Release the preview surface / EGL resources. */
  nativeDetachPreviewSurface(): void;

  nativeGetScenes(): NativeSceneEntry[];
  /** Returns the new scene id, or "" on failure. */
  nativeCreateScene(name: string): string;
  nativeRemoveScene(id: string): boolean;

  nativeGetSources(sceneId: string): NativeSourceEntry[];
  /** Returns the new scene-item id, or "" on failure. settingsJson is an obs_data JSON object. */
  nativeAddSource(sceneId: string, typeId: string, name: string, settingsJson: string): string;
  nativeRemoveSource(id: string): boolean;
  nativeSetSourceVisible(id: string, visible: boolean): boolean;

  nativeGetAudioTracks(): NativeAudioTrack[];
  nativeSetMute(trackId: string, muted: boolean): boolean;
  nativeSetVolume(trackId: string, volume: number): boolean;
  nativeGetOutputLevels(): NativeOutputLevel[];

  /**
   * Runtime probe for desktop audio loopback ("内录"). Official docs list
   * Phone/Tablet/TV for SystemCapability.Multimedia.Audio.PlaybackCapture —
   * PC/2in1 support is UNVERIFIED, so this probes the actual device libraries
   * (dlsym of OH_AudioCapturer_RequestPlaybackCaptureStart) instead of
   * assuming. Combine with canIUse() on the ArkTS side.
   */
  nativeCanCaptureSystemAudio(): boolean;

  /** configJson keys: "server" (rtmp URL), "key" (stream key), "videoBitrateKbps", "audioBitrateKbps". */
  nativeStartStreaming(configJson: string): boolean;
  nativeStopStreaming(): boolean;
  /** configJson keys: "path" (output file), "format". */
  nativeStartRecording(configJson: string): boolean;
  nativeStopRecording(): boolean;

  nativeGetStats(): NativeStreamStats;
  /**
   * Register a callback invoked ~1x/second from the native stats thread while
   * an output is active (push model — the UI should not poll for stats).
   * Pass null to unregister.
   */
  nativeSetStatsCallback(cb: NativeStatsCallback | null): boolean;
}

declare const obsBridgeNative: ObsBridgeNative;
export default obsBridgeNative;
