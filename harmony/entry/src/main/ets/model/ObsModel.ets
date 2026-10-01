import { NativeAudioTrack, NativeOutputLevel, NativeSceneEntry, NativeSourceEntry,
  NativeStreamStats } from 'libobs_bridge.so';
import { ObsBridge, SystemAudioCapability } from '../napi/obsBridge';
import { Logger } from '../common/Logger';

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
  @Trace bridgeNotice: string = '';

  @Trace scenes: SceneItemModel[] = [];
  @Trace selectedSceneId: string = '';
  @Trace sources: SourceItemModel[] = [];
  @Trace selectedSourceId: string = '';

  @Trace audioTracks: AudioTrackModel[] = [];
  @Trace stats: StreamStatsModel = new StreamStatsModel();
  @Trace connectionState: ConnectionState = ConnectionState.Idle;
  @Trace systemAudio: SystemAudioStatus = new SystemAudioStatus();

  /** Editable RTMP target (a full settings dialog replaces this later). */
  @Trace streamingServer: string = 'rtmp://192.168.31.19:1935/live';
  @Trace streamingKey: string = 'obs-test';
  /** Filled with a sandbox path at init time; user can change it later. */
  @Trace recordingPath: string = '';

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
}

/**
 * Mediator between the UI and the bridge. All native calls funnel through
 * here so state updates and error handling live in one place.
 */
export class ObsController {
  private static model: ObsAppState = ObsAppState.getInstance();

  /** Called once from the main page's aboutToAppear(). */
  static initialize(configDir: string, codeDir: string, dataDir: string): void {
    const model = ObsController.model;
    model.recordingPath = `${configDir}/recording.mp4`;
    const coreOk = ObsBridge.init(configDir, codeDir, dataDir);
    model.coreReady = coreOk;
    model.bridgeNotice = coreOk ? '' :
      'libobs core is not linked in this build — UI shell + audio meters only ' +
        '(rebuild the bridge with -DOBS_HARMONY_PREFIX=<staging>).';
    ObsController.probeSystemAudio();
    ObsController.refreshTracks();
    ObsController.refreshScenes();
    if (coreOk && model.scenes.length === 0) {
      ObsController.createScene('Scene 1');
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
      model.bridgeNotice = `Could not create scene '${name}' (see log for the native error).`;
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

  static addSource(typeId: string): void {
    const model = ObsController.model;
    if (model.selectedSceneId === '') {
      model.bridgeNotice = 'Select or create a scene before adding sources.';
      return;
    }
    const name = `${typeId} ${model.sourceNameCounter}`;
    const id = ObsBridge.addSource(model.selectedSceneId, typeId, name, '{}');
    if (id !== '') {
      model.sourceNameCounter += 1;
      ObsController.refreshSources();
    } else {
      model.bridgeNotice = `Could not add source '${typeId}' — is the plugin staged?`;
    }
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
      return;
    }
    const config = new StreamingConfig();
    config.server = model.streamingServer;
    config.key = model.streamingKey;
    model.connectionState = ConnectionState.Starting;
    const started = ObsBridge.startStreaming(JSON.stringify(config));
    if (started) {
      // Optimistic: flip the button to Stop without waiting for the first
      // stats push from the native thread.
      model.stats.streaming = true;
      Logger.info('stream start accepted by native');
      model.bridgeNotice = '';
    } else {
      model.connectionState = ConnectionState.Error;
      model.bridgeNotice = 'Failed to start streaming — check the RTMP target and the log.';
    }
  }

  static toggleRecording(): void {
    const model = ObsController.model;
    if (model.stats.recording) {
      ObsBridge.stopRecording();
      const stats = ObsBridge.getStats();
      model.stats.recording = stats.recording;
      ObsController.updateConnectionState();
      return;
    }
    const config = new RecordingConfig();
    config.path = model.recordingPath;
    const started = ObsBridge.startRecording(JSON.stringify(config));
    if (started) {
      // Optimistic: the stats thread may not have started pushing yet, and
      // the button label must flip to Stop so a second tap stops.
      model.stats.recording = true;
      Logger.info(`recording start accepted by native -> ${config.path}`);
      model.bridgeNotice = '';
      ObsController.updateConnectionState();
    } else {
      model.connectionState = ConnectionState.Error;
      model.bridgeNotice = 'Failed to start recording — check the output path and the log.';
    }
  }
}
