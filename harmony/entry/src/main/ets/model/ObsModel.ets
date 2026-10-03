import { NativeAudioTrack, NativeFilterEntry, NativeOutputLevel, NativeSceneEntry,
  NativeSourceEntry, NativeStreamStats } from 'libobs_bridge.so';
import { ObsBridge, SystemAudioCapability } from '../napi/obsBridge';
import { Logger } from '../common/Logger';
import { LongRunningTask } from '../common/LongRunningTask';
import { KnockShareSender } from '../common/KnockShareSender';
import { IntentActions, IntentDispatcher, ObsActionKind } from '../insightintents/OBSIntentExecutor';
import { ObsSettings, SettingsStore } from '../common/SettingsStore';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { picker } from '@kit.CoreFileKit';

/**
 * Observable application state for the OBS ArkUI frontend, plus the
 * ObsController that mediates between the UI and the native bridge.
 *
 * State management: V2 (@ObservedV2 + @Trace). @Trace properties of these
 * classes drive UI refreshes inside @ComponentV2 structs; the singleton
 * ObsAppState is shared by reference through @Param, so every panel updates
 * when the bridge pushes new data (stats callback, level polling, track
 * state changes).
 */

/** High-level state of the streaming output, as surfaced in the top bar. */
export enum ConnectionState {
  Idle = 'idle',
  Starting = 'starting',
  Live = 'live',
  Stopping = 'stopping',
  Recording = 'recording',
  Error = 'error'
}

/** Mirror of the native CaptureState enum (cpp/types/libobs_bridge/index.d.ts). */
export enum CaptureState {
  Unsupported = 0,
  Idle = 1,
  Requesting = 2,
  Running = 3,
  NotAuthorized = 4,
  Failed = 5
}

@ObservedV2
export class SceneItemModel {
  @Trace id: string = '';
  @Trace name: string = '';

  constructor(id: string, name: string) {
    this.id = id;
    this.name = name;
  }
}

@ObservedV2
export class SourceItemModel {
  @Trace id: string = '';
  @Trace sourceUuid: string = '';
  @Trace name: string = '';
  @Trace typeId: string = '';
  @Trace visible: boolean = true;

  constructor(id: string, sourceUuid: string, name: string, typeId: string, visible: boolean) {
    this.id = id;
    this.sourceUuid = sourceUuid;
    this.name = name;
    this.typeId = typeId;
    this.visible = visible;
  }
}

@ObservedV2
export class FilterItemModel {
  @Trace name: string = '';
  @Trace typeId: string = '';
  @Trace enabled: boolean = true;

  constructor(name: string, typeId: string, enabled: boolean) {
    this.name = name;
    this.typeId = typeId;
    this.enabled = enabled;
  }
}

@ObservedV2
export class AudioTrackModel {
  @Trace id: string = '';
  @Trace name: string = '';
  @Trace muted: boolean = false;
  /** Linear 0..1 */
  @Trace volume: number = 1.0;
  /** Linear 0..1, refreshed by level polling. */
  @Trace peak: number = 0;
  @Trace rms: number = 0;
  @Trace state: CaptureState = CaptureState.Idle;
  @Trace supported: boolean = true;

  constructor(id: string, name: string) {
    this.id = id;
    this.name = name;
  }
}

@ObservedV2
export class StreamStatsModel {
  @Trace streaming: boolean = false;
  @Trace recording: boolean = false;
  @Trace bitrateKbps: number = 0;
  @Trace droppedFrames: number = 0;
  @Trace totalFrames: number = 0;
  @Trace uptimeSeconds: number = 0;
}

/** Observable copy of the two-part system-audio probe result. */
@ObservedV2
export class SystemAudioStatus {
  @Trace probed: boolean = false;
  @Trace syscapReported: boolean = false;
  @Trace nativeProbeOk: boolean = false;
  @Trace supported: boolean = false;
}

@ObservedV2
export class ObsAppState {
  private static sharedInstance: ObsAppState | null = null;

  static getInstance(): ObsAppState {
    if (ObsAppState.sharedInstance === null) {
      ObsAppState.sharedInstance = new ObsAppState();
    }
    return ObsAppState.sharedInstance;
  }

  /** True when nativeInit() reported a fully started libobs core. */
  @Trace coreReady: boolean = false;
  /** Human-readable reason the core (or a call) is unavailable; shown in the UI. */
  @Trace bridgeNotice: Resource | null = null;

  @Trace scenes: SceneItemModel[] = [];
  @Trace selectedSceneId: string = '';
  @Trace sources: SourceItemModel[] = [];
  @Trace selectedSourceId: string = '';

  /** Filters of the currently selected source (refreshed on selection change). */
  @Trace filters: FilterItemModel[] = [];
  /** Filter type ids the staged obs-filters plugin actually registered. */
  @Trace filterTypes: string[] = [];

  @Trace audioTracks: AudioTrackModel[] = [];
  @Trace stats: StreamStatsModel = new StreamStatsModel();
  @Trace connectionState: ConnectionState = ConnectionState.Idle;
  @Trace systemAudio: SystemAudioStatus = new SystemAudioStatus();

  /** Editable RTMP target — mirrored into the settings panel and persisted. */
  @Trace streamingServer: string = 'rtmp://192.168.0.100:1935/live';
  @Trace streamingKey: string = 'obs-test';
  /** Filled with a sandbox path at init time; user can change it later. */
  @Trace recordingPath: string = '';

  /** Settings panel mirror (persisted via SettingsStore on save). */
  @Trace setVideoWidth: number = 1920;
  @Trace setVideoHeight: number = 1080;
  @Trace setVideoFps: number = 60;
  /** 'h264' | 'hevc' — video encoder codec for both outputs. */
  @Trace setVideoCodec: string = 'h264';

  /** Scene-switch transition (0 = cut, else fade duration ms). Persisted with
   * the profile bag as sceneTransitionMs. */
  @Trace sceneTransitionMs: number = 300;
  @Trace setRecordVideoKbps: number = 10000;
  @Trace setRecordAudioKbps: number = 192;
  @Trace setStreamVideoKbps: number = 2500;
  @Trace setStreamAudioKbps: number = 160;

  @Trace sceneNameCounter: number = 1;
  @Trace sourceNameCounter: number = 1;
}

/** Typed payload for nativeStartStreaming(configJson). */
class StreamingConfig {
  server: string = '';
  key: string = '';
  videoBitrateKbps: number = 2500;
  audioBitrateKbps: number = 160;
}

/** Typed payload for nativeStartRecording(configJson). */
class RecordingConfig {
  path: string = '';
  format: string = 'mp4';
  videoBitrateKbps: number = 10000;
  audioBitrateKbps: number = 192;
  /** 'h264' | 'hevc' — hardware codec for the recording's video track. */
  videoCodec: string = 'h264';
}

/**
 * Mediator between the UI and the bridge. All native calls funnel through
 * here so state updates and error handling live in one place.
 */
export class ObsController {
  private static model: ObsAppState = ObsAppState.getInstance();
  /** UIAbility context, used for continuous-task acquire/release. */
  static appContext: common.UIAbilityContext | undefined = undefined;
  /** Sandbox files dir captured at init — image sources are copied here so
   * libobs can open them with a plain path (media URIs are not open()able by
   * native code without a URI-permission handshake). */
  static filesDir: string = '';

  /** Called once from the main page's aboutToAppear(). */
  static initialize(configDir: string, codeDir: string, dataDir: string, defaultSceneName: string = 'Scene 1',
    context?: common.UIAbilityContext): void {
    const model = ObsController.model;
    if (context) {
      ObsController.appContext = context;
    }
    ObsController.filesDir = configDir;
    model.recordingPath = `${configDir}/recording.mp4`;
    const coreOk = ObsBridge.init(configDir, codeDir, dataDir);
    model.coreReady = coreOk;
    model.bridgeNotice = coreOk ? null : $r('app.string.notice_core');
    ObsController.probeSystemAudio();
    ObsController.refreshTracks();
    ObsController.refreshScenes();
    if (coreOk && model.scenes.length === 0) {
      ObsController.createScene(defaultSceneName);
    }
    if (coreOk && context) {
      ObsController.loadSettings(context);
    }
    // W3 C3: insight-intent bridge. Register the action handler and release
    // anything the voice assistant queued while the core was still booting
    // (cold start fires the executor before this line; warm start drains
    // instantly).
    IntentDispatcher.register((kind: ObsActionKind) => {
      // The toggles are exactly that — toggles — so a voice "start" landing
      // while already live would STOP. Guard: start intents are no-ops when
      // the corresponding output is already running.
      if (kind === 'StartLive' && !model.stats.streaming && model.coreReady) {
        ObsController.toggleStreaming();
      } else if (kind === 'StartRecording' && !model.stats.recording && model.coreReady) {
        ObsController.toggleRecording();
      } else {
        Logger.info(`intent ${kind} ignored (busy or core not ready)`);
      }
    });
    IntentActions.markReady();
  }

  /**
   * Restore persisted settings; the canvas geometry additionally applies
   * itself (nativeResetVideo) when it differs from the core's boot default.
   */
  static async loadSettings(context: common.UIAbilityContext): Promise<void> {
    try {
      const model = ObsController.model;
      const s = await SettingsStore.load(context);
      Logger.info(`settings loaded: ${s.videoWidth}x${s.videoHeight}@${s.videoFps}`);
      model.setVideoWidth = s.videoWidth;
      model.setVideoHeight = s.videoHeight;
      model.setVideoFps = s.videoFps;
      model.setVideoCodec = s.videoCodec;
      model.sceneTransitionMs = s.sceneTransitionMs;
      model.setRecordVideoKbps = s.recordVideoKbps;
      model.setRecordAudioKbps = s.recordAudioKbps;
      model.setStreamVideoKbps = s.streamVideoKbps;
      model.setStreamAudioKbps = s.streamAudioKbps;
      model.streamingServer = s.streamingServer;
      model.streamingKey = s.streamingKey;

      const current = ObsBridge.getVideoInfo();
      if (current.width !== s.videoWidth || current.height !== s.videoHeight || current.fps !== s.videoFps) {
        if (ObsBridge.resetVideo(s.videoWidth, s.videoHeight, s.videoFps)) {
          Logger.info(`video settings restored: ${s.videoWidth}x${s.videoHeight}@${s.videoFps}`);
        } else {
          Logger.warn(`resetVideo ${s.videoWidth}x${s.videoHeight}@${s.videoFps} rejected, keeping ${current.width}x${current.height}@${current.fps}`);
        }
      } else {
        Logger.info('loadSettings: canvas already matches persisted geometry');
      }
    } catch (err) {
      Logger.error('loadSettings crashed', Logger.asError(err as Object));
    }
  }

  /** Persist the current settings mirror. */
  static saveSettings(): void {
    const model = ObsController.model;
    if (!ObsController.appContext) {
      return;
    }
    const s = new ObsSettings();
    s.videoWidth = model.setVideoWidth;
    s.videoHeight = model.setVideoHeight;
    s.videoFps = model.setVideoFps;
    s.videoCodec = model.setVideoCodec;
    s.recordVideoKbps = model.setRecordVideoKbps;
    s.recordAudioKbps = model.setRecordAudioKbps;
    s.streamVideoKbps = model.setStreamVideoKbps;
    s.streamAudioKbps = model.setStreamAudioKbps;
    s.streamingServer = model.streamingServer;
    s.streamingKey = model.streamingKey;
    SettingsStore.save(ObsController.appContext, s);
  }

  /** Apply the canvas geometry from the settings panel. */
  static applyVideoSettings(): void {
    const model = ObsController.model;
    if (model.stats.recording || model.stats.streaming) {
      model.bridgeNotice = $r('app.string.settings_output_busy');
      return;
    }
    if (ObsBridge.resetVideo(model.setVideoWidth, model.setVideoHeight, model.setVideoFps)) {
      Logger.info(`canvas reset: ${model.setVideoWidth}x${model.setVideoHeight}@${model.setVideoFps}`);
      ObsController.saveSettings();
      model.bridgeNotice = null;
    } else {
      model.bridgeNotice = $r('app.string.notice_reset_video_fail');
    }
  }

  static shutdown(): void {
    ObsBridge.setStatsCallback(null);
    ObsBridge.shutdown();
  }

  /** Push-mode stats: native thread -> model (~1 Hz while an output is active). */
  static installStatsCallback(): void {
    const model = ObsController.model;
    ObsBridge.setStatsCallback((native: NativeStreamStats): void => {
      model.stats.streaming = native.streaming;
      model.stats.recording = native.recording;
      model.stats.bitrateKbps = native.bitrateKbps;
      model.stats.droppedFrames = native.droppedFrames;
      model.stats.totalFrames = native.totalFrames;
      model.stats.uptimeSeconds = native.uptimeSeconds;
      ObsController.updateConnectionState();
      // Track authorization can resolve asynchronously after the privacy
      // dialog; piggyback a track refresh on the stats heartbeat.
      ObsController.refreshTracks();
    });
  }

  private static updateConnectionState(): void {
    const model = ObsController.model;
    const stats = model.stats;
    if (stats.streaming) {
      model.connectionState = ConnectionState.Live;
    } else if (stats.recording) {
      model.connectionState = ConnectionState.Recording;
    } else if (model.connectionState === ConnectionState.Live ||
      model.connectionState === ConnectionState.Recording ||
      model.connectionState === ConnectionState.Starting) {
      model.connectionState = ConnectionState.Idle;
    }
  }

  static probeSystemAudio(): void {
    const capability: SystemAudioCapability = ObsBridge.canCaptureSystemAudio();
    const status = ObsController.model.systemAudio;
    status.probed = capability.probed;
    status.syscapReported = capability.syscapReported;
    status.nativeProbeOk = capability.nativeProbeOk;
    status.supported = capability.supported;
  }

  static refreshScenes(): void {
    const model = ObsController.model;
    const nativeScenes: NativeSceneEntry[] = ObsBridge.getScenes();
    const scenes: SceneItemModel[] = [];
    let selectedStillExists = false;
    for (const entry of nativeScenes) {
      scenes.push(new SceneItemModel(entry.id, entry.name));
      if (entry.id === model.selectedSceneId) {
        selectedStillExists = true;
      }
    }
    model.scenes = scenes;
    if (!selectedStillExists) {
      model.selectedSceneId = scenes.length > 0 ? scenes[0].id : '';
    }
    ObsController.refreshSources();
  }

  static refreshSources(): void {
    const model = ObsController.model;
    if (model.selectedSceneId === '') {
      model.sources = [];
      return;
    }
    const nativeSources: NativeSourceEntry[] = ObsBridge.getSources(model.selectedSceneId);
    const sources: SourceItemModel[] = [];
    for (const entry of nativeSources) {
      sources.push(new SourceItemModel(entry.id, entry.sourceUuid, entry.name, entry.typeId,
        entry.visible));
    }
    model.sources = sources;
    if (!sources.some((source: SourceItemModel): boolean => source.id === model.selectedSourceId)) {
      model.selectedSourceId = '';
    }
    ObsController.refreshFilters();
  }

  /** Reload the filter list of the currently selected source. */
  static refreshFilters(): void {
    const model = ObsController.model;
    if (model.selectedSourceId === '') {
      model.filters = [];
      return;
    }
    const nativeFilters: NativeFilterEntry[] = ObsBridge.getFilters(model.selectedSourceId);
    const filters: FilterItemModel[] = [];
    for (const entry of nativeFilters) {
      filters.push(new FilterItemModel(entry.name, entry.typeId, entry.enabled));
    }
    model.filters = filters;
    if (model.filterTypes.length === 0) {
      model.filterTypes = ObsBridge.getFilterTypes();
    }
  }

  /** Scene cut: bind the program channel to another scene (desktop parity). */
  static selectScene(id: string): void {
    const model = ObsController.model;
    if (ObsBridge.selectScene(id, model.sceneTransitionMs)) {
      model.selectedSceneId = id;
      ObsController.refreshSources();
    }
  }

  static addFilterToSelectedSource(filterTypeId: string): void {
    const model = ObsController.model;
    if (model.selectedSourceId === '') {
      return;
    }
    if (ObsBridge.addFilter(model.selectedSourceId, filterTypeId)) {
      ObsController.refreshFilters();
    } else {
      model.bridgeNotice = $r('app.string.notice_add_filter_fail', filterTypeId);
    }
  }

  static removeFilterFromSelectedSource(filterName: string): void {
    const model = ObsController.model;
    if (model.selectedSourceId === '') {
      return;
    }
    if (ObsBridge.removeFilter(model.selectedSourceId, filterName)) {
      ObsController.refreshFilters();
    }
  }

  static setFilterEnabled(filterName: string, enabled: boolean): void {
    const model = ObsController.model;
    if (model.selectedSourceId === '') {
      return;
    }
    if (ObsBridge.setFilterEnabled(model.selectedSourceId, filterName, enabled)) {
      ObsController.refreshFilters();
    }
  }

  static createScene(name: string): void {
    const model = ObsController.model;
    const id = ObsBridge.createScene(name);
    if (id !== '') {
      model.sceneNameCounter += 1;
      ObsController.refreshScenes();
      model.selectedSceneId = id;
      ObsController.refreshSources();
    } else {
      model.bridgeNotice = $r('app.string.notice_scene_fail', name);
    }
  }

  static removeSelectedScene(): void {
    const model = ObsController.model;
    if (model.selectedSceneId === '') {
      return;
    }
    if (ObsBridge.removeScene(model.selectedSceneId)) {
      model.selectedSceneId = '';
      ObsController.refreshScenes();
    }
  }

  static addSource(typeId: string, settingsJson: string = '{}'): void {
    const model = ObsController.model;
    if (model.selectedSceneId === '') {
      model.bridgeNotice = $r('app.string.notice_pick_scene');
      return;
    }
    const name = `${typeId} ${model.sourceNameCounter}`;
    const id = ObsBridge.addSource(model.selectedSceneId, typeId, name, settingsJson);
    if (id !== '') {
      model.sourceNameCounter += 1;
      ObsController.refreshSources();
    } else {
      model.bridgeNotice = $r('app.string.notice_add_source_fail', typeId);
    }
  }

  /**
   * Image source via the system file picker (W2 二档前端). The picker hands
   * back a media-library URI; native code cannot open() it directly, so the
   * bytes are copied into the app sandbox (files/img-<n>.<ext>) and the copy
   * path becomes the source's "file" setting — the same trick the desktop
   * build uses when a scene references a file outside the profile.
   */
  static async addImageSourcePicked(): Promise<void> {
    const model = ObsController.model;
    if (model.selectedSceneId === '') {
      model.bridgeNotice = $r('app.string.notice_pick_scene');
      return;
    }
    try {
      const ctx = ObsController.appContext;
      if (!ctx) {
        return;
      }
      const docPicker = new picker.DocumentViewPicker(ctx);
      const uris = await docPicker.select({
        maxSelectNumber: 1,
        fileSuffixFilters: ['.png', '.jpg', '.jpeg', '.webp', '.bmp', '.gif']
      });
      if (uris.length === 0) {
        return;
      }
      const copied = ObsController.copyUriToSandbox(uris[0]);
      if (copied === '') {
        model.bridgeNotice = $r('app.string.notice_image_copy_fail');
        return;
      }
      ObsController.addSource('image_source', JSON.stringify({ file: copied }));
    } catch (err) {
      Logger.error('image picker failed', Logger.asError(err as Object));
      model.bridgeNotice = $r('app.string.notice_image_copy_fail');
    }
  }

  /** Copy one picker URI into filesDir; returns the sandbox path or ''. */
  private static copyUriToSandbox(uri: string): string {
    try {
      const src = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const name = decodeURIComponent(uri.split('/').pop() ?? 'image')
        .replace(/[^A-Za-z0-9._-]/g, '_');
      const suffix = `_${Date.now()}`;
      const dot = name.lastIndexOf('.');
      const base = dot > 0 ? name.slice(0, dot) : name;
      const ext = dot > 0 ? name.slice(dot) : '.png';
      const dest = `${ObsController.filesDir}/img-${base.slice(0, 48)}${suffix}${ext}`;
      const dst = fileIo.openSync(dest, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      const buf = new ArrayBuffer(fileIo.statSync(src.fd).size);
      fileIo.readSync(src.fd, buf);
      fileIo.writeSync(dst.fd, buf);
      fileIo.closeSync(src);
      fileIo.closeSync(dst);
      Logger.info(`image copied to sandbox: ${dest} (${buf.byteLength} bytes)`);
      return dest;
    } catch (err) {
      Logger.error('image copy failed', Logger.asError(err as Object));
      return '';
    }
  }

  /** Text source with the given content (font defaults merge in libobs). */
  static addTextSource(text: string): void {
    ObsController.addSource('text_ft2_source', JSON.stringify({ text: text }));
  }

  static removeSelectedSource(): void {
    const model = ObsController.model;
    if (model.selectedSourceId === '') {
      return;
    }
    if (ObsBridge.removeSource(model.selectedSourceId)) {
      model.selectedSourceId = '';
      ObsController.refreshSources();
    }
  }

  static setSourceVisible(id: string, visible: boolean): void {
    if (ObsBridge.setSourceVisible(id, visible)) {
      ObsController.refreshSources();
    }
  }

  static refreshTracks(): void {
    const model = ObsController.model;
    const nativeTracks: NativeAudioTrack[] = ObsBridge.getAudioTracks();
    if (model.audioTracks.length !== nativeTracks.length) {
      const tracks: AudioTrackModel[] = [];
      for (const native of nativeTracks) {
        tracks.push(new AudioTrackModel(native.id, native.name));
      }
      model.audioTracks = tracks;
    }
    for (let i = 0; i < nativeTracks.length && i < model.audioTracks.length; i++) {
      const native: NativeAudioTrack = nativeTracks[i];
      const track: AudioTrackModel = model.audioTracks[i];
      track.muted = native.muted;
      track.volume = native.volume;
      track.state = native.state as CaptureState;
      track.supported = native.supported;
    }
  }

  /** Called by the UI on a ~200 ms timer to refresh the mixer meters. */
  static pollLevels(): void {
    const model = ObsController.model;
    const levels: NativeOutputLevel[] = ObsBridge.getOutputLevels();
    for (const level of levels) {
      const track = model.audioTracks.find((candidate: AudioTrackModel): boolean =>
      candidate.id === level.id);
      if (track !== undefined) {
        track.peak = level.peak;
        track.rms = level.rms;
      }
    }
    // Loopback authorization is async (privacy dialog); keep track states fresh.
    ObsController.refreshTracks();
  }

  static setTrackMute(trackId: string, muted: boolean): void {
    if (ObsBridge.setMute(trackId, muted)) {
      ObsController.refreshTracks();
    }
  }

  static setTrackVolume(trackId: string, volume: number): void {
    if (ObsBridge.setVolume(trackId, volume)) {
      ObsController.refreshTracks();
    }
  }

  static toggleStreaming(): void {
    const model = ObsController.model;
    if (model.stats.streaming) {
      model.connectionState = ConnectionState.Stopping;
      ObsBridge.stopStreaming();
      const stats = ObsBridge.getStats();
      model.stats.streaming = stats.streaming;
      ObsController.updateConnectionState();
      if (!model.stats.streaming && !model.stats.recording && ObsController.appContext) {
        LongRunningTask.release(ObsController.appContext, 'stream stopped');
      }
      return;
    }
    const config = new StreamingConfig();
    config.server = model.streamingServer;
    config.key = model.streamingKey;
    config.videoBitrateKbps = model.setStreamVideoKbps;
    config.audioBitrateKbps = model.setStreamAudioKbps;
    model.connectionState = ConnectionState.Starting;
    const started = ObsBridge.startStreaming(JSON.stringify(config));
    if (started) {
      // Optimistic: flip the button to Stop without waiting for the first
      // stats push from the native thread.
      model.stats.streaming = true;
      Logger.info('stream start accepted by native');
      model.bridgeNotice = null;
      if (ObsController.appContext) {
        LongRunningTask.acquire(ObsController.appContext, 'stream started');
      }
    } else {
      model.connectionState = ConnectionState.Error;
      model.bridgeNotice = $r('app.string.notice_stream_fail');
    }
  }

  static toggleRecording(): void {
    const model = ObsController.model;
    if (model.stats.recording) {
      ObsBridge.stopRecording();
      const stats = ObsBridge.getStats();
      model.stats.recording = stats.recording;
      ObsController.updateConnectionState();
      if (!model.stats.recording && !model.stats.streaming && ObsController.appContext) {
        LongRunningTask.release(ObsController.appContext, 'record stopped');
      }
      // W3 C2: the finished clip is now knock-shareable — arm the sender so
      // tapping this window against a nearby device flies the mp4 out.
      try {
        if (!model.stats.recording && fileIo.accessSync(model.recordingPath)) {
          KnockShareSender.arm(model.recordingPath, `QingStudio-${Date.now()}`);
        }
      } catch (err) {
        Logger.warn(`knock-share arm skipped: ${Logger.asError(err as Object).message}`);
      }
      return;
    }
    const config = new RecordingConfig();
    config.path = model.recordingPath;
    config.videoBitrateKbps = model.setRecordVideoKbps;
    config.audioBitrateKbps = model.setRecordAudioKbps;
    config.videoCodec = model.setVideoCodec;
    const started = ObsBridge.startRecording(JSON.stringify(config));
    if (started) {
      // Optimistic: the stats thread may not have started pushing yet, and
      // the button label must flip to Stop so a second tap stops.
      model.stats.recording = true;
      Logger.info(`recording start accepted by native -> ${config.path}`);
      model.bridgeNotice = null;
      ObsController.updateConnectionState();
      if (ObsController.appContext) {
        LongRunningTask.acquire(ObsController.appContext, 'record started');
      }
    } else {
      model.connectionState = ConnectionState.Error;
      model.bridgeNotice = $r('app.string.notice_record_fail');
    }
  }
}
