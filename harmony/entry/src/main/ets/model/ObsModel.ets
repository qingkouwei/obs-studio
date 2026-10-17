import { NativeAudioTrack, NativeFilterEntry, NativeOutputLevel, NativeSceneEntry,
  NativeSourceEntry, NativeStreamStats } from 'libobs_bridge.so';
import { ObsBridge, SystemAudioCapability } from '../napi/obsBridge';
import { Logger } from '../common/Logger';
import { LongRunningTask } from '../common/LongRunningTask';
import { KnockShareSender } from '../common/KnockShareSender';
import { RecLiveWindow } from '../common/RecLiveWindow';
import { IntentActions, IntentDispatcher, ObsActionKind } from '../insightintents/OBSIntentExecutor';
import { ObsSettings, SettingsStore, StreamTargetEntry } from '../common/SettingsStore';
import { WebFeedEntry, WebFeedRegistry } from '../common/WebFeed';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';

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
  /** Scene-item lock: locked items ignore canvas drag/pinch. */
  @Trace locked: boolean = false;

  constructor(id: string, sourceUuid: string, name: string, typeId: string, visible: boolean, locked: boolean = false) {
    this.id = id;
    this.sourceUuid = sourceUuid;
    this.name = name;
    this.typeId = typeId;
    this.visible = visible;
    this.locked = locked;
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

/** One registered transition type offered by the 转场动画 dock. */
@ObservedV2
export class TransitionOptionModel {
  @Trace id: string = '';
  @Trace name: string = '';

  constructor(id: string, name: string) {
    this.id = id;
    this.name = name;
  }
}

/** Observable copy of the two-part system-audio probe result. */
@ObservedV2
export class SystemAudioStatus {
  @Trace probed: boolean = false;
  @Trace syscapReported: boolean = false;
  @Trace nativeProbeOk: boolean = false;
  @Trace supported: boolean = false;
}

/** One finished recording shown in the works list (user request 10-15). */
export class RecordingEntry {
  path: string = '';
  name: string = '';
  size: number = 0;
  mtimeMs: number = 0;
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

  /** Studio mode (session-only, not persisted): program/preview split with
   * the second canvas. previewSceneId = what's staged on the preview. */
  @Trace studioMode: boolean = false;
  @Trace previewSceneId: string = '';

  /** Source context menu request channel (desktop right-click parity). The
   * canvas long-press (PreviewInteractor) writes sourceId + bumps seq; the
   * SourceList owns the actual sheet and @Monitors seq to open it. Row
   * long-press opens the sheet directly without touching this channel. */
  @Trace contextMenuSourceId: string = '';
  @Trace contextMenuSeq: number = 0;

  /** Filters of the currently selected source (refreshed on selection change). */
  @Trace filters: FilterItemModel[] = [];
  /** Filter type ids the staged obs-filters plugin actually registered. */
  @Trace filterTypes: string[] = [];

  @Trace audioTracks: AudioTrackModel[] = [];
  @Trace stats: StreamStatsModel = new StreamStatsModel();
  @Trace connectionState: ConnectionState = ConnectionState.Idle;
  @Trace systemAudio: SystemAudioStatus = new SystemAudioStatus();

  /** Editable RTMP target — mirrored into the settings panel and persisted. */
  @Trace streamingServer: string = 'rtmp://192.168.0.105:1935/live';
  @Trace streamingKey: string = 'obs-test';
  /** Remembered RTMP targets (server+key), newest first — filled at init
   * from SettingsStore, appended whenever a stream really starts. */
  @Trace streamTargets: StreamTargetEntry[] = [];
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
  /** Scene-switch transition type id for scene switches (fade/slide/swipe/
   * fade_to_color/wipe). Persisted as transitionId. */
  @Trace sceneTransitionId: string = 'fade_transition';

  /* ---- Source snapping (desktop 源对齐 parity) ---- */
  @Trace snapEnabled: boolean = true;
  /** Snap threshold in CANVAS px (desktop shows it as a sensitivity number;
   * we expose the raw px so the effect is predictable). */
  @Trace snapThreshold: number = 10;
  @Trace snapToEdges: boolean = true;

  /* ---- Preview guides (desktop 界面 > 参考线 parity) ---- */
  /** Safe-area rectangles (action 90% / title 80%). */
  @Trace guideSafeAreas: boolean = false;
  /** Centre crosshair. */
  @Trace guideCenter: boolean = false;
  /** Border scaling guides (4:3 / 1:1 / 4:5 inner boxes). */
  @Trace guideScale: boolean = false;

  /* ---- Output confirmations (desktop 输出 group parity) ---- */
  @Trace confirmStartRecord: boolean = false;
  @Trace confirmStopRecord: boolean = false;
  @Trace confirmStartStream: boolean = false;
  @Trace confirmStopStream: boolean = false;
  /** Streaming start also starts recording (desktop 直播时自动开始录制). */
  @Trace autoRecordOnStream: boolean = false;
  /** ...and streaming stop also stops that recording (desktop 停止直播后
   * 自动停止录制; only meaningful while autoRecordOnStream is on). */
  @Trace autoStopRecordOnStreamStop: boolean = false;
  /** Registered transition types the 转场动画 dock offers, populated once
   * from nativeGetTransitionTypes after the core is ready. */
  @Trace transitionOptions: TransitionOptionModel[] = [];
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
  /** W3 C6: settings bag captured by EntryAbility.onCreate on a CONTINUATION
   * cold start; initialize() applies and clears it once the core is up. */
  static pendingContinuation: ObsSettings | null = null;

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
    if (coreOk) {
      ObsController.refreshTransitionOptions();
    }
    if (coreOk && model.scenes.length === 0) {
      ObsController.createScene(defaultSceneName);
    }
    if (coreOk && context) {
      ObsController.loadSettings(context);
    }
    // W3 C6: a continuation payload from another device wins over the local
    // disk profile (the user just chose "keep working over there").
    if (ObsController.pendingContinuation !== null) {
      const migrated = ObsController.pendingContinuation;
      ObsController.pendingContinuation = null;
      Logger.info('applying migrated settings (continuation target)');
      ObsController.applySettings(migrated);
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
      const s = await SettingsStore.load(context);
      Logger.info(`settings loaded: ${s.videoWidth}x${s.videoHeight}@${s.videoFps}`);
      ObsController.applySettings(s);
      ObsController.model.streamTargets = await SettingsStore.loadStreamTargets(context);
    } catch (err) {
      Logger.error('loadSettings crashed', Logger.asError(err as Object));
    }
  }

  /** Push one picker row into the active fields (user request 10-17). */
  static applyStreamTarget(e: StreamTargetEntry): void {
    const model = ObsController.model;
    model.streamingServer = e.server;
    model.streamingKey = e.key;
    ObsController.saveSettings();
  }

  /** Drop one remembered target and refresh the list. */
  static async forgetStreamTarget(e: StreamTargetEntry): Promise<void> {
    if (!ObsController.appContext) {
      return;
    }
    ObsController.model.streamTargets =
      await SettingsStore.forgetStreamTarget(ObsController.appContext, e.server, e.key);
  }

  /** Snapshot the live settings mirror into a serializable bag (used by
   * saveSettings and the onContinue migration source). */
  static currentSettings(): ObsSettings {
    const model = ObsController.model;
    const s = new ObsSettings();
    s.videoWidth = model.setVideoWidth;
    s.videoHeight = model.setVideoHeight;
    s.videoFps = model.setVideoFps;
    s.videoCodec = model.setVideoCodec;
    s.sceneTransitionMs = model.sceneTransitionMs;
    s.transitionId = model.sceneTransitionId;
    s.snapEnabled = model.snapEnabled;
    s.snapThreshold = model.snapThreshold;
    s.snapToEdges = model.snapToEdges;
    s.confirmStartRecord = model.confirmStartRecord;
    s.confirmStopRecord = model.confirmStopRecord;
    s.confirmStartStream = model.confirmStartStream;
    s.confirmStopStream = model.confirmStopStream;
    s.autoRecordOnStream = model.autoRecordOnStream;
    s.autoStopRecordOnStreamStop = model.autoStopRecordOnStreamStop;
    s.guideSafeAreas = model.guideSafeAreas;
    s.guideCenter = model.guideCenter;
    s.guideScale = model.guideScale;
    s.recordVideoKbps = model.setRecordVideoKbps;
    s.recordAudioKbps = model.setRecordAudioKbps;
    s.streamVideoKbps = model.setStreamVideoKbps;
    s.streamAudioKbps = model.setStreamAudioKbps;
    s.streamingServer = model.streamingServer;
    s.streamingKey = model.streamingKey;
    return s;
  }

  /** Write a settings bag into the live mirror and reset the canvas if the
   * geometry differs. Shared by loadSettings (disk) and the continuation
   * target (migrated payload). */
  static applySettings(s: ObsSettings): void {
    const model = ObsController.model;
    model.setVideoWidth = s.videoWidth;
    model.setVideoHeight = s.videoHeight;
    model.setVideoFps = s.videoFps;
    model.setVideoCodec = s.videoCodec;
    model.sceneTransitionMs = s.sceneTransitionMs;
    model.sceneTransitionId = s.transitionId;
    /* Re-arm the native transition shell type after a cold start (the shell
     * is created lazily on first scene switch, so setting the id here is
     * enough — but if a shell already exists from a previous session state
     * in-process, the native call rebuilds it). */
    ObsBridge.setTransitionType(s.transitionId);
    model.snapEnabled = s.snapEnabled;
    model.snapThreshold = s.snapThreshold;
    model.snapToEdges = s.snapToEdges;
    model.confirmStartRecord = s.confirmStartRecord;
    model.confirmStopRecord = s.confirmStopRecord;
    model.confirmStartStream = s.confirmStartStream;
    model.confirmStopStream = s.confirmStopStream;
    model.autoRecordOnStream = s.autoRecordOnStream;
    model.autoStopRecordOnStreamStop = s.autoStopRecordOnStreamStop;
    model.guideSafeAreas = s.guideSafeAreas;
    model.guideCenter = s.guideCenter;
    model.guideScale = s.guideScale;
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
  }

  /** Persist the current settings mirror. */
  static saveSettings(): void {
    if (!ObsController.appContext) {
      return;
    }
    SettingsStore.save(ObsController.appContext, ObsController.currentSettings());
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
    } else if (model.connectionState !== ConnectionState.Idle &&
      model.connectionState !== ConnectionState.Error) {
      // No output is running any more — collapse every transient state
      // (Live/Recording/Starting/Stopping) back to Idle. Stopping was
      // originally missing here, which left the label stuck at
      // "连接中…/停止中…" forever after a stop (bug seen on-device 10-03).
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
    /* Desktop parity: obs_scene_enum_items walks BOTTOM→TOP (draw order),
     * but every OBS front-end shows the top-most source FIRST in the
     * sources list. Without the reversal, pressing ↑ (which correctly
     * raises z-order) moved the row DOWN on screen — "上下移动还是有问题"
     * (user report 10-14). The canvas hit-test also relies on this order
     * (first visible box wins = top-most). */
    for (let i = nativeSources.length - 1; i >= 0; i--) {
      const entry = nativeSources[i];
      sources.push(new SourceItemModel(entry.id, entry.sourceUuid, entry.name, entry.typeId,
        entry.visible, entry.locked));
    }
    model.sources = sources;
    if (!sources.some((source: SourceItemModel): boolean => source.id === model.selectedSourceId)) {
      model.selectedSourceId = '';
    }
    ObsController.reconcileWebFeeds(sources);
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

  /** Populate the transition-type list from the registered sources (once
   * after core init). */
  static refreshTransitionOptions(): void {
    const model = ObsController.model;
    const json = ObsBridge.getTransitionTypes();
    if (json === '' || json === '[]') {
      return;
    }
    try {
      const arr = JSON.parse(json) as Record<string, string>[];
      const opts: TransitionOptionModel[] = [];
      for (const entry of arr) {
        const id: string = entry['id'] ?? '';
        const name: string = entry['name'] ?? id;
        if (id !== '') {
          opts.push(new TransitionOptionModel(id, name));
        }
      }
      model.transitionOptions = opts;
    } catch (err) {
      Logger.error('refreshTransitionOptions parse failed', Logger.asError(err as Object));
    }
  }

  /** Switch the scene-transition type (rebuilds the program shell around
   * the visible source) and persist the choice. */
  static setTransitionId(id: string): void {
    const model = ObsController.model;
    if (model.sceneTransitionId === id) {
      return;
    }
    if (ObsBridge.setTransitionType(id)) {
      model.sceneTransitionId = id;
      ObsController.saveSettings();
    } else {
      model.bridgeNotice = $r('app.string.notice_transition_fail');
    }
  }

  /** Update the scene-transition duration (ms) and persist. */
  static setTransitionMs(ms: number): void {
    const model = ObsController.model;
    const clamped = Math.max(0, Math.min(5000, Math.round(ms)));
    model.sceneTransitionMs = clamped;
    ObsController.saveSettings();
  }

  /** Nudge the selected source by (dx,dy) canvas px (keyboard arrows). */
  static nudgeSelectedSource(dx: number, dy: number): void {
    const model = ObsController.model;
    const id = model.selectedSourceId;
    if (id === '') {
      return;
    }
    const src = model.sources.find((candidate: SourceItemModel): boolean => candidate.id === id);
    if (src !== undefined && src.locked) {
      return;
    }
    const b = ObsBridge.getSourceBounds(id);
    if (b !== null) {
      ObsBridge.setSourcePosition(id, b.x + dx, b.y + dy);
    }
  }

  /** Scene cut: bind the program channel to another scene (desktop parity).
   * Always the PROGRAM channel — the phone director console (DirectorLink)
   * drives this directly; the scene-list click goes through pickScene(). */
  static selectScene(id: string): void {
    const model = ObsController.model;
    if (ObsBridge.selectScene(id, model.sceneTransitionMs)) {
      model.selectedSceneId = id;
      ObsController.refreshSources();
    }
  }

  /* ---- Studio mode (desktop 工作室模式 parity) ----
   * Program = main canvas (records/streams); preview = private canvas the
   * operator stages on. Scene-list clicks edit the preview while studio
   * mode is on; 切到 (Take) runs the transition preview→program, 切断 (Cut)
   * hard-cuts it. Session-only state: the preview canvas is not persisted,
   * and the second display only exists while the toggle is on. */

  /** Flip studio mode. On: seed the preview canvas with the current program
   * scene (so the second display has content the moment it mounts). Off:
   * tear the second display down (the canvas itself stays for re-entry). */
  static toggleStudioMode(): void {
    const model = ObsController.model;
    model.studioMode = !model.studioMode;
    if (model.studioMode) {
      let seed: string = model.selectedSceneId;
      if (seed === '' && model.scenes.length > 0) {
        seed = model.scenes[0].id;
      }
      if (seed !== '' && ObsBridge.setPreviewScene(seed)) {
        model.previewSceneId = seed;
      }
    } else {
      ObsBridge.detachStudioPreviewSurface();
    }
  }

  /** Scene-list click router: studio on → stage on the preview; studio off
   * → the classic one-tap program cut. */
  static pickScene(id: string): void {
    const model = ObsController.model;
    if (!model.studioMode) {
      ObsController.selectScene(id);
      return;
    }
    if (ObsBridge.setPreviewScene(id)) {
      model.previewSceneId = id;
    }
  }

  /** Take: transition the previewed scene onto the program channel. */
  static takeScene(): void {
    const model = ObsController.model;
    if (model.previewSceneId === '') {
      return;
    }
    if (ObsBridge.selectScene(model.previewSceneId, model.sceneTransitionMs)) {
      model.selectedSceneId = model.previewSceneId;
      ObsController.refreshSources();
    }
  }

  /** Cut: hard-switch the previewed scene onto the program channel. */
  static cutScene(): void {
    const model = ObsController.model;
    if (model.previewSceneId === '') {
      return;
    }
    if (ObsBridge.selectScene(model.previewSceneId, 0)) {
      model.selectedSceneId = model.previewSceneId;
      ObsController.refreshSources();
    }
  }

  static addFilterToSelectedSource(filterTypeId: string): boolean {
    const model = ObsController.model;
    if (model.selectedSourceId === '') {
      return false;
    }
    if (ObsBridge.addFilter(model.selectedSourceId, filterTypeId)) {
      ObsController.refreshFilters();
      return true;
    }
    model.bridgeNotice = $r('app.string.notice_add_filter_fail', filterTypeId);
    return false;
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

  /** Scene context-menu actions (desktop parity, by id). */
  static removeSceneById(id: string): void {
    const model = ObsController.model;
    if (ObsBridge.removeScene(id)) {
      if (model.selectedSceneId === id) {
        model.selectedSceneId = '';
      }
      if (model.previewSceneId === id) {
        model.previewSceneId = '';
      }
      ObsController.refreshScenes();
    }
  }

  static renameSceneById(id: string, name: string): void {
    if (name.trim() === '') {
      return;
    }
    if (ObsBridge.renameScene(id, name.trim())) {
      ObsController.refreshScenes();
    }
  }

  static addSource(typeId: string, settingsJson: string = '{}', explicitName: string = ''): void {
    const model = ObsController.model;
    if (model.selectedSceneId === '') {
      model.bridgeNotice = $r('app.string.notice_pick_scene');
      return;
    }
    const name = explicitName !== '' ? explicitName : `${typeId} ${model.sourceNameCounter}`;
    const id = ObsBridge.addSource(model.selectedSceneId, typeId, name, settingsJson);
    if (id !== '') {
      model.sourceNameCounter += 1;
      ObsController.refreshSources();
      /* Desktop audio lazy start (10-13): the loopback capturer — and its
       * session-scoped system consent dialog — is only requested when the
       * user actually adds the source, not at every cold boot. */
      if (typeId === 'harmony_desktop_audio') {
        ObsBridge.ensureDesktopAudio();
      }
    } else {
      model.bridgeNotice = $r('app.string.notice_add_source_fail', typeId);
    }
  }

  /** True when the current scene already hosts a source whose name starts
   * with prefix — the guard behind the (idempotent) remote-camera button:
   * repeated taps used to pile up identical camera sources (user report
   * 10-04). refreshSources() must have run at least once for this to see
   * live state; the button flow always has. */
  static hasSourceNamed(prefix: string): boolean {
    const model = ObsController.model;
    for (const src of model.sources) {
      if (src.name.indexOf(prefix) === 0) {
        return true;
      }
    }
    return false;
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

  /** Media (video/audio file) source via the system document picker. The
   * ffmpeg_source plugin is registered unconditionally by obs-ffmpeg (its
   * OHOS exclusion only covers VAAPI encoders), so this is just an intake:
   * copy into the sandbox (native open() cannot read picker URIs) and
   * create the source with is_local_file + local_file — the same settings
   * desktop OBS writes for a media source. */
  static async addMediaSourcePicked(): Promise<void> {
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
        fileSuffixFilters: ['.mp4', '.mov', '.mkv', '.webm', '.avi', '.flv', '.ts', '.mp3', '.aac', '.m4a', '.wav',
          '.flac']
      });
      if (uris.length === 0) {
        return;
      }
      const copied = ObsController.copyUriToSandbox(uris[0]);
      if (copied === '') {
        model.bridgeNotice = $r('app.string.notice_image_copy_fail');
        return;
      }
      const settings: Record<string, Object> = {
        'input': copied,
        'is_local_file': true,
        'local_file': copied,
        'looping': true,
        'hw_decode': false
      };
      ObsController.addSource('ffmpeg_source', JSON.stringify(settings));
    } catch (err) {
      Logger.error('media picker failed', Logger.asError(err as Object));
      model.bridgeNotice = $r('app.string.notice_image_copy_fail');
    }
  }

  /** Solid colour source (desktop 色块). Full-canvas by default so it works
   * as a backdrop / lower-third plate; colour uses libobs' 0xAABBGGRR
   * packing, same as the text source swatches. Default is mid-grey, not the
   * near-black desktop ships — on our black canvas a #202020 block is
   * created but invisible, which reads as "the button did nothing"
   * (device-verified 10-12). Size follows the LIVE canvas, not a hard-coded
   * 1920x1080: at the 720p default a 1080-sized block overflows the canvas
   * and its fit-to-canvas bounds clamp it to a 16:9 letterbox (device
   * 10-13: grey rect stopped short of the canvas edges). */
  static addColorSource(): void {
    const vi = ObsBridge.getVideoInfo();
    const settings: Record<string, Object> = {
      'color': 0xFF808080,
      'width': vi.width,
      'height': vi.height
    };
    ObsController.addSource('color_source', JSON.stringify(settings));
  }

  /** Image slideshow source (desktop 图像幻灯片放映): multi-pick images,
   * copy each into the sandbox, hand the plugin its files array of
   * {value: path} objects (obs-slideshow-mk2 reads S_FILES that shape). */
  static async addSlideshowSourcePicked(): Promise<void> {
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
        maxSelectNumber: 20,
        fileSuffixFilters: ['.png', '.jpg', '.jpeg', '.webp', '.bmp', '.gif']
      });
      if (uris.length === 0) {
        return;
      }
      const files: Record<string, Object>[] = [];
      for (const uri of uris) {
        const copied = ObsController.copyUriToSandbox(uri);
        if (copied !== '') {
          const entry: Record<string, Object> = { 'value': copied };
          files.push(entry);
        }
      }
      if (files.length === 0) {
        model.bridgeNotice = $r('app.string.notice_image_copy_fail');
        return;
      }
      const settings: Record<string, Object> = {
        'files': files,
        'slide_time': 4000,
        'transition_speed': 700,
        'transition': 'fade',
        'slide_mode': 'mode_auto',
        'playback_mode': 'loop',
        'loop': true,
        'use_custom_size': '1920x1080'
      };
      ObsController.addSource('slideshow', JSON.stringify(settings));
    } catch (err) {
      Logger.error('slideshow picker failed', Logger.asError(err as Object));
      model.bridgeNotice = $r('app.string.notice_image_copy_fail');
    }
  }

  /** Copy one picker/drag URI into filesDir; returns the sandbox path or ''. */
  static copyUriToSandbox(uri: string): string {
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

  /** Text source with the given content. Font defaults are NOT inherited
   * from the plugin here: text-freetype2's v2 default size is 256px, which
   * fits only a handful of glyphs on our 3120-wide canvas and reads as
   * "nothing appeared". Pin a readable 72px instead. face uses the "Sans
   * Serif" generic that find-font-ohos.c guarantees to alias to a real
   * system face (colour stays the plugin default white). */
  static addTextSource(text: string): void {
    const font: Record<string, Object> = {
      'face': 'Sans Serif', 'size': 72, 'flags': 0, 'style': ''
    };
    const settings: Record<string, Object> = {
      'text': text,
      'font': font
    };
    ObsController.addSource('text_ft2_source', JSON.stringify(settings));
  }

  /** Browser source: create the libobs item (url/viewport live in its
   * settings — single source of truth) and let refreshSources()'s reconcile
   * pass spin up the matching off-screen Web node + snapshot pump. */
  static addWebSource(url: string, width: number, height: number): void {
    const settings: Record<string, number | string> = {
      'url': url, 'width': width, 'height': height, 'refresh_ms': 100
    };
    ObsController.addSource('harmony_web_source', JSON.stringify(settings), '浏览器');
  }

  /** Diff model.sources against the WebFeed registry: every
   * harmony_web_source item gets an entry (rebuilt from its libobs settings,
   * which is how scene reloads restore the feed); items that disappeared
   * drop theirs. Entries are upserted with new objects on any change so the
   * host's ForEach key rebuilds a Web node when url/size edits land. */
  static reconcileWebFeeds(sources: SourceItemModel[]): void {
    const liveIds: string[] = [];
    for (const src of sources) {
      if (src.typeId !== 'harmony_web_source' || !src.visible) {
        continue;
      }
      liveIds.push(src.id);
      const json: string = ObsBridge.getSourceSettings(src.id);
      if (json === '') {
        continue; // transiently gone (scene swap mid-refresh)
      }
      let parsed: Record<string, number | string>;
      try {
        parsed = JSON.parse(json) as Record<string, number | string>;
      } catch (_e) {
        continue;
      }
      const url: string = typeof parsed.url === 'string' ? parsed.url : '';
      const width: number = typeof parsed.width === 'number' && parsed.width > 0 ? parsed.width : 800;
      const height: number = typeof parsed.height === 'number' && parsed.height > 0 ? parsed.height : 600;
      const refreshMs: number = typeof parsed.refresh_ms === 'number' && parsed.refresh_ms >= 33
        ? parsed.refresh_ms : 100;
      const existing: WebFeedEntry | undefined = WebFeedRegistry.get(src.id);
      if (existing === undefined || existing.url !== url || existing.width !== width ||
          existing.height !== height || existing.refreshMs !== refreshMs) {
        WebFeedRegistry.upsert(new WebFeedEntry(src.id, url !== '' ? url : 'about:blank', width, height, refreshMs));
      }
    }
    // Retire entries whose item vanished or went invisible.
    for (const entry of WebFeedRegistry.entries.slice()) {
      if (!liveIds.includes(entry.itemId)) {
        WebFeedRegistry.drop(entry.itemId);
      }
    }
  }

  static removeSelectedSource(): void {
    const model = ObsController.model;
    Logger.info(`removeSelectedSource: selected='${model.selectedSourceId}'`);
    if (model.selectedSourceId === '') {
      return;
    }
    ObsController.removeSourceById(model.selectedSourceId);
  }

  static setSourceVisible(id: string, visible: boolean): void {
    if (ObsBridge.setSourceVisible(id, visible)) {
      ObsController.refreshSources();
    }
  }

  /** Toggle the scene-item lock (desktop lock icon). Locked items ignore
   * canvas drag/pinch. */
  static setSourceLocked(id: string, locked: boolean): void {
    if (ObsBridge.setSourceLocked(id, locked)) {
      ObsController.refreshSources();
    }
  }

  /** Move the item in the scene draw order: 'up' | 'down' | 'top' | 'bottom'. */
  static setSourceOrder(id: string, dir: string): void {
    if (ObsBridge.setSourceOrder(id, dir)) {
      ObsController.refreshSources();
    }
  }

  /* ---- Source context menu actions (desktop parity, #49) ---- */

  static setSourceTransform(id: string, rotDeg: number, flipX: boolean, flipY: boolean): void {
    ObsBridge.setSourceTransform(id, rotDeg, flipX, flipY);
  }

  /** Current transform record ('rot' deg, 'flipX'/'flipY' bool) or null. */
  static getSourceTransform(id: string): Record<string, Object> | null {
    const json = ObsBridge.getSourceTransform(id);
    if (json === '') {
      return null;
    }
    try {
      return JSON.parse(json) as Record<string, Object>;
    } catch (err) {
      Logger.error('getSourceTransform parse failed', Logger.asError(err as Object));
      return null;
    }
  }

  static setSourceBoundsFit(id: string, mode: string): void {
    if (ObsBridge.setSourceBoundsFit(id, mode)) {
      ObsController.refreshSources();
    }
  }

  /** Absolute size in canvas px (w/h <= 0 keeps that axis). */
  static setSourceSize(id: string, w: number, h: number): void {
    if (ObsBridge.setSourceSize(id, w, h)) {
      ObsController.refreshSources();
    }
  }

  static duplicateSource(id: string): void {
    if (ObsBridge.duplicateSource(id) !== '') {
      ObsController.refreshSources();
    } else {
      ObsController.model.bridgeNotice = $r('app.string.notice_dup_fail');
    }
  }

  /** Remove one source by item id (context menu; removeSelectedSource only
   * covers the selected row). */
  static removeSourceById(id: string): void {
    const model = ObsController.model;
    const ok = ObsBridge.removeSource(id);
    Logger.info(`removeSourceById('${id}') native=${ok}`);
    if (ok) {
      if (model.selectedSourceId === id) {
        model.selectedSourceId = '';
      }
      ObsController.refreshSources();
    }
  }

  static renameSource(id: string, name: string): void {
    if (name.trim() === '') {
      return;
    }
    if (ObsBridge.renameSource(id, name.trim())) {
      ObsController.refreshSources();
    }
  }

  /** Read a source's settings as a key/value record (null when gone or no
   * settings). The per-source settings sheet initialises its widgets from
   * this. */
  static getSourceSettingsRecord(itemId: string): Record<string, Object> | null {
    const json = ObsBridge.getSourceSettings(itemId);
    if (json === '') {
      return null;
    }
    try {
      return JSON.parse(json) as Record<string, Object>;
    } catch (err) {
      Logger.error(`getSourceSettingsRecord parse failed`, Logger.asError(err as Object));
      return null;
    }
  }

  /** Merge a settings patch into a source (obs_data_apply semantics on the
   * native side — omitted keys keep their value) and let the plugin's
   * update() react. The settings sheet's only write path. */
  static setSourceSettings(itemId: string, patch: Record<string, Object>): boolean {
    return ObsBridge.setSourceSettings(itemId, JSON.stringify(patch));
  }

  /* ---- Media transport (ffmpeg_source playback) ---- */

  static mediaControl(itemId: string, action: string): void {
    ObsBridge.mediaControl(itemId, action);
  }

  static mediaSeek(itemId: string, ms: number): void {
    ObsBridge.mediaSeek(itemId, ms);
  }

  /** Media state record or null ('' when the item is gone). */
  static getMediaState(itemId: string): Record<string, Object> | null {
    const json = ObsBridge.getMediaState(itemId);
    if (json === '') {
      return null;
    }
    try {
      return JSON.parse(json) as Record<string, Object>;
    } catch (err) {
      Logger.error('getMediaState parse failed', Logger.asError(err as Object));
      return null;
    }
  }

  /* ---- Advanced audio props (sync offset / monitoring) ---- */

  static getSourceAudioProps(itemId: string): Record<string, Object> | null {
    const json = ObsBridge.getSourceAudioProps(itemId);
    if (json === '') {
      return null;
    }
    try {
      return JSON.parse(json) as Record<string, Object>;
    } catch (err) {
      Logger.error('getSourceAudioProps parse failed', Logger.asError(err as Object));
      return null;
    }
  }

  static setSourceAudioProps(itemId: string, syncOffsetMs: number, monitoringType: number): boolean {
    return ObsBridge.setSourceAudioProps(itemId, syncOffsetMs, monitoringType);
  }

  /* ---- Generic property renderer plumbing ---- */

  static getPropertySchema(itemId: string, filterName: string): string {
    return ObsBridge.getPropertySchema(itemId, filterName);
  }

  static setFilterSettings(itemId: string, filterName: string, patchJson: string): boolean {
    return ObsBridge.setFilterSettings(itemId, filterName, patchJson);
  }

  static refreshTracks(): void {
    const model = ObsController.model;
    const nativeTracks: NativeAudioTrack[] = ObsBridge.getAudioTracks();
    /* Rebuild by source-uuid identity: tracks come and go with the sources
     * in the scene, and the native enumeration order may shift when one is
     * removed — an index-based diff would mislabel meters (10-17 refactor:
     * the mixer is now source-driven). Existing rows are reused so the
     * @Trace objects (and their bound sliders) survive refreshes. */
    const tracks: AudioTrackModel[] = [];
    for (const native of nativeTracks) {
      let track: AudioTrackModel | undefined = model.audioTracks.find(
        (candidate: AudioTrackModel): boolean => candidate.id === native.id);
      if (track === undefined) {
        track = new AudioTrackModel(native.id, native.name);
      }
      track.name = native.name;
      track.muted = native.muted;
      track.volume = native.volume;
      track.state = native.state as CaptureState;
      track.supported = native.supported;
      tracks.push(track);
    }
    model.audioTracks = tracks;
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
      RecLiveWindow.stopStreaming();
      // Desktop 停止直播后自动停止录制 parity: only fires when the user
      // opted in AND a recording is running (typically the one the
      // autoRecordOnStream linkage started).
      if (model.autoStopRecordOnStreamStop && model.stats.recording) {
        ObsController.toggleRecording();
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
      /* Remember this target for the picker (user request 10-17): only on
       * a start the core actually accepted, so typos never enter history. */
      if (ObsController.appContext && model.streamingServer !== '') {
        SettingsStore.rememberStreamTarget(ObsController.appContext,
          model.streamingServer, model.streamingKey)
          .then((list: StreamTargetEntry[]): void => {
            model.streamTargets = list;
          });
      }
      if (ObsController.appContext) {
        LongRunningTask.acquire(ObsController.appContext, 'stream started',
          ['audioRecording', 'dataTransfer', 'taskKeeping']);
      }
      RecLiveWindow.startStreaming(ObsController.appContext);
      // Desktop 直播时自动开始录制 parity: piggyback a recording start on a
      // successful stream start when the user opted in. Stopping the stream
      // does NOT stop the recording (desktop behaves the same — the two
      // outputs are independent once running).
      if (model.autoRecordOnStream && !model.stats.recording) {
        ObsController.toggleRecording();
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
      RecLiveWindow.stopRecording();
      // W3 C2: the finished clip is now knock-shareable — arm the sender so
      // tapping this window against a nearby device flies the mp4 out.
      try {
        if (!model.stats.recording && fileIo.accessSync(model.recordingPath)) {
          KnockShareSender.arm(model.recordingPath, `轻录-${Date.now()}`);
        }
      } catch (err) {
        Logger.warn(`knock-share arm skipped: ${Logger.asError(err as Object).message}`);
      }
      return;
    }
    const config = new RecordingConfig();
    /* Timestamped file name (user request 10-14): the old fixed
     * recording.mp4 silently overwrote the previous take. Each session now
     * writes recording-<epochMs>.mp4; model.recordingPath keeps pointing at
     * the finished file afterwards (knock-share + album export read it). */
    model.recordingPath = `${ObsController.filesDir}/recording-${Date.now()}.mp4`;
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
        LongRunningTask.acquire(ObsController.appContext, 'record started',
          ['audioRecording', 'taskKeeping']);
      }
      RecLiveWindow.startRecording(ObsController.appContext);
    } else {
      model.connectionState = ConnectionState.Error;
      model.bridgeNotice = $r('app.string.notice_record_fail');
    }
  }

  /** Export the last finished recording into the system album (user
   * request 10-14). The sandbox file is invisible to Gallery, so we hand it
   * to photoAccessHelper: showAssetsCreationDialog pops the system consent
   * sheet and returns a writable media-library uri, then we stream the
   * sandbox bytes into it. No extra permission needed (user-consent flow).
   * Returns true when the copy completed. */
  static async exportLastRecordingToAlbum(): Promise<boolean> {
    const model = ObsController.model;
    const src = model.recordingPath;
    if (src === '' || !fileIo.accessSync(src)) {
      Logger.warn('exportToAlbum: no finished recording at ' + src);
      model.bridgeNotice = $r('app.string.notice_export_none');
      return false;
    }
    return ObsController.exportRecordingToAlbum(src);
  }

  /** Export ONE recording (sandbox path) into the system album — the
   * generic form used by the works list (user request 10-15). */
  static async exportRecordingToAlbum(src: string): Promise<boolean> {
    const model = ObsController.model;
    const ctx = ObsController.appContext;
    if (src === '' || ctx === undefined || !fileIo.accessSync(src)) {
      Logger.warn('exportToAlbum: missing file ' + src);
      model.bridgeNotice = $r('app.string.notice_export_none');
      return false;
    }
    try {
      const base = src.substring(src.lastIndexOf('/') + 1); // recording-<ts>.mp4
      const title = base.replace(/\.mp4$/i, '');
      const config: photoAccessHelper.PhotoCreationConfig = {
        title: title,
        fileNameExtension: 'mp4',
        photoType: photoAccessHelper.PhotoType.VIDEO
      };
      const uris: string[] =
        await photoAccessHelper.getPhotoAccessHelper(ctx)
          // Official guide passes the RAW sandbox path (no file:// prefix)
          // as srcFileUris; a file:// URI yields 14000011 (device 10-15).
          .showAssetsCreationDialog([src], [config]);
      if (uris.length === 0 || uris[0] === '') {
        Logger.warn('exportToAlbum: dialog returned no uri (user cancelled?)');
        return false;
      }
      const dst = fileIo.openSync(uris[0], fileIo.OpenMode.WRITE_ONLY);
      const from = fileIo.openSync(src, fileIo.OpenMode.READ_ONLY);
      try {
        fileIo.copyFileSync(from.fd, dst.fd);
        const st = fileIo.statSync(src);
        Logger.info(`exportToAlbum: copied ${st.size} bytes -> ${uris[0]}`);
      } finally {
        fileIo.closeSync(from.fd);
        fileIo.closeSync(dst.fd);
      }
      model.bridgeNotice = $r('app.string.notice_export_done');
      return true;
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(`exportToAlbum failed: code=${e.code} msg=${e.message}`);
      model.bridgeNotice = $r('app.string.notice_export_fail');
      return false;
    }
  }

  /* ---- Works list (user request 10-15) -------------------------------- */

  /** List every recording in filesDir, newest first. Only files that
   * match our own naming scheme (recording-<ms>.mp4 / recording.mp4) are
   * offered — never the file a live recording is writing into. */
  static listRecordings(): RecordingEntry[] {
    const model = ObsController.model;
    const dir = ObsController.filesDir;
    const out: RecordingEntry[] = [];
    if (dir === '') {
      return out;
    }
    try {
      const names = fileIo.listFileSync(dir);
      for (const name of names) {
        if (!name.endsWith('.mp4') || !name.startsWith('recording')) {
          continue;
        }
        const full = `${dir}/${name}`;
        if (full === model.recordingPath && model.stats.recording) {
          continue; // still being written
        }
        try {
          const st = fileIo.statSync(full);
          if (st.size <= 0) {
            continue;
          }
          const e: RecordingEntry = { path: full, name: name, size: st.size, mtimeMs: st.mtime * 1000 };
          out.push(e);
        } catch (err) {
          // vanished between list and stat — skip
        }
      }
    } catch (err) {
      Logger.error('listRecordings failed', Logger.asError(err as Object));
    }
    out.sort((a: RecordingEntry, b: RecordingEntry): number => b.mtimeMs - a.mtimeMs);
    return out;
  }

  /** Delete one recording from the sandbox (works list). */
  static deleteRecording(path: string): boolean {
    try {
      fileIo.unlinkSync(path);
      Logger.info(`recording deleted: ${path}`);
      return true;
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(`deleteRecording failed: code=${e.code} msg=${e.message}`);
      return false;
    }
  }
}
