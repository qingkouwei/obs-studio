import { AudioTrackModel, ObsAppState, ObsController, SourceItemModel } from '../model/ObsModel';
import { ObsBridge, SourceBounds } from '../napi/obsBridge';
import { DragDropReceiver } from '../common/DragDropReceiver';
import { Logger } from '../common/Logger';

/**
 * SourceList — the sources dock for the currently selected scene.
 * Per-row visibility toggle maps to obs_sceneitem_set_visible; add/remove map
 * to obs_source_create + obs_scene_add / obs_sceneitem_remove through the
 * bridge. In shell-only builds the add buttons are disabled (core not linked).
 */
/**
 * Every source the HarmonyOS build can actually create. The ids must match the
 * strings each plugin passes to obs_register_source() exactly — a mismatch is
 * invisible at compile time and surfaces only as "source type not found" when
 * the button is tapped on a device.
 */
interface SourceTypeEntry {
  label: Resource;
  id: string;
}

/* --- settings-sheet value helpers --------------------------------------- */
/* ArkTS Record access returns Object|undefined; these normalise to defaults
 * without fighting the type system. */
function strAt(rec: Record<string, Object>, key: string, def: string): string {
  const v: Object | undefined = rec[key];
  return typeof v === 'string' ? v : def;
}

function numAt(rec: Record<string, Object>, key: string, def: number): number {
  const v: Object | undefined = rec[key];
  return typeof v === 'number' ? v : def;
}

function boolAt(rec: Record<string, Object>, key: string, def: boolean): boolean {
  const v: Object | undefined = rec[key];
  return typeof v === 'boolean' ? v : def;
}

/** True for the two capture source types that own an audio mixer track. The
 * mixer is now source-driven, so the settings sheet keys volume/mute off the
 * SOURCE UUID (each mic/desktop instance has its own track), not a fixed id. */
function isAudioSourceType(typeId: string): boolean {
  return typeId === 'harmony_mic_capture' || typeId === 'harmony_desktop_audio';
}

/** libobs stores colours as 0xAABBGGRR (alpha byte first, red in the LOW
 * byte — OBS_GET_R masks the low byte). Render that to '#RRGGBB' for the
 * swatches; alpha is ignored (text colour is always opaque). */
function obsColorToHex(color: number): string {
  const c: number = color >>> 0;
  const r: number = c & 0xFF;
  const g: number = (c >>> 8) & 0xFF;
  const b: number = (c >>> 16) & 0xFF;
  const hex: (n: number) => string = (n: number): string => n.toString(16).padStart(2, '0').toUpperCase();
  return `#${hex(r)}${hex(g)}${hex(b)}`;
}

/** '#RRGGBB' back into libobs' 0xAABBGGRR packing (opaque). */
function hexToObsColor(hexStr: string): number {
  let s: string = hexStr.trim();
  if (s.startsWith('#')) {
    s = s.substring(1);
  }
  if (s.length !== 6) {
    return 0xFFFFFFFF;
  }
  const r: number = parseInt(s.substring(0, 2), 16);
  const g: number = parseInt(s.substring(2, 4), 16);
  const b: number = parseInt(s.substring(4, 6), 16);
  return ((0xFF << 24) | (b << 16) | (g << 8) | r) >>> 0;
}

const SOURCE_TYPES: SourceTypeEntry[] = [
  { label: $r('app.string.src_display'), id: 'harmony_display_capture' },
  { label: $r('app.string.src_window'), id: 'harmony_window_capture' },
  { label: $r('app.string.src_camera'), id: 'harmony_camera_capture' },
  // W3 C1 (revised): the phone-role peer streams its camera to this device
  // over LAN TCP; the harmony-remotecam plugin listens, hard-decodes H.264
  // and feeds the canvas. The old @remote sentinel (Service Collaboration
  // camera) is retired — device-verified 10-04: CAMERA_CONNECTION_REMOTE is
  // only ever enumerated for the system camera app, third parties cannot
  // mount it, and the collab kit's dialog API returns snapshots, not a
  // continuous stream.
  { label: $r('app.string.src_wireless_cam'), id: 'harmony_remote_camera' },
  { label: $r('app.string.src_mic'), id: 'harmony_mic_capture' },
  { label: $r('app.string.src_desktop'), id: 'harmony_desktop_audio' },
  { label: $r('app.string.src_image'), id: '@picker:image_source' },
  { label: $r('app.string.src_slideshow'), id: '@picker:slideshow' },
  { label: $r('app.string.src_color'), id: 'color_source' },
  { label: $r('app.string.src_media'), id: '@picker:ffmpeg_source' },
  { label: $r('app.string.src_text'), id: '@dialog:text_ft2_source' },
  { label: $r('app.string.src_web'), id: '@dialog:harmony_web_source' },
];

/** Device-backed sources are exclusive: a second instance of the same
 * capturer in one scene either fails to open (Camera Kit rejects the
 * re-open) or duplicates the same stream — device-verified 10-04, three
 * camera sources from three taps. One per scene, like the fixed audio
 * tracks; image/text stay freely addable. Maps the button id to the
 * display name the dedup guard looks for in the source list. */
const SINGLETON_SOURCES: Record<string, string> = {
  'harmony_display_capture': '屏幕捕获',
  'harmony_window_capture': '窗口捕获',
  'harmony_camera_capture': '摄像头',
  'harmony_remote_camera': '无线机位',
  'harmony_mic_capture': '麦克风',
  'harmony_desktop_audio': '桌面音频',
};

@ComponentV2
export struct SourceList {
  @Param @Require model: ObsAppState;
  /** Text-source input sheet (add flow). */
  @Local textSheetOpen: boolean = false;
  @Local textDraft: string = '';
  /** Browser-source input sheet (url + viewport, add flow). */
  @Local webSheetOpen: boolean = false;
  @Local webUrl: string = 'https://';
  @Local webWidth: string = '800';
  @Local webHeight: string = '600';
  /** Per-source settings sheet: opens with the row's gear button; the sheet
   * reads the source's live settings (getSourceSettingsRecord) and writes a
   * patch back (setSourceSettings) on 应用. Which widgets show depends on
   * sheetTypeId. */
  @Local sheetOpen: boolean = false;
  @Local sheetItemId: string = '';
  @Local sheetTypeName: string = '';
  @Local sheetTypeId: string = '';
  /** Widget mirrors (strings for text inputs, boolean for switches, number
   * for sliders). Re-seeded every time the sheet opens. */
  @Local sheetText: string = '';
  @Local sheetFontFace: string = 'Sans Serif';
  @Local sheetFontSize: number = 72;
  @Local sheetTextColorHex: string = '#FFFFFF';
  @Local sheetUrl: string = '';
  @Local sheetWebWidth: string = '800';
  @Local sheetWebHeight: string = '600';
  @Local sheetFps: number = 30;
  @Local sheetCursor: boolean = true;
  @Local sheetPinSize: boolean = false;
  @Local sheetWinWidth: string = '0';
  @Local sheetWinHeight: string = '0';
  @Local sheetCameraPosition: string = '';
  @Local sheetCameraRes: string = '1920x1080';
  @Local sheetPort: string = '25890';
  /** Audio-source widgets. The mixer is source-driven: a mic/desktop capture
   * row seeds these from ITS track (matched by source uuid), and volume/mute
   * apply live to that source. sheetTrackId holds the source uuid for audio
   * sources and '' for everything else. */
  @Local sheetTrackId: string = '';
  @Local sheetVolume: number = 1.0;
  @Local sheetMuted: boolean = false;
  /** Media (ffmpeg_source) widgets. */
  @Local sheetLooping: boolean = true;
  @Local sheetSpeed: number = 100;
  /** Colour-source widgets (libobs 0xAABBGGRR packed). */
  @Local sheetColorHex: string = '#202020';
  @Local sheetColorW: string = '1920';
  @Local sheetColorH: string = '1080';
  /** Slideshow widgets. */
  @Local sheetSlideTime: number = 4000;
  @Local sheetTrSpeed: number = 700;
  @Local sheetSlideLoop: boolean = true;
  /** Media transport mirrors, refreshed by a 500ms poll while the sheet is
   * open on a media source. seekPos tracks the slider during a drag so the
   * poll does not yank it back mid-gesture. */
  @Local sheetMediaTime: number = 0;
  @Local sheetMediaDuration: number = 0;
  @Local sheetMediaState: string = 'none';
  @Local sheetMediaSeekPos: number = -1;
  private mediaPollTimer: number = -1;
  /** Advanced audio props (sync offset ms + monitoring type 0/1/2). Shown
   * for sources that carry audio (mic / desktop / media). */
  @Local sheetHasAudioProps: boolean = false;
  @Local sheetSyncMs: number = 0;
  @Local sheetMonitor: number = 0;
  /** Numeric transform (desktop 变换 parity): position / size / rotation
   * committed on field submit. Visual sources only. */
  @Local sheetHasTransform: boolean = false;
  @Local sheetPosX: string = '0';
  @Local sheetPosY: string = '0';
  @Local sheetW: string = '0';
  @Local sheetH: string = '0';
  @Local sheetRot: string = '0';
  /** Context menu (long-press a source row OR the canvas): the desktop
   * right-click menu, trimmed to what the bridge can express. The canvas
   * gesture signals through model.contextMenuSeq; this component owns the
   * sheet state itself. */
  @Local menuOpen: boolean = false;
  @Local menuSource: SourceItemModel | null = null;

  /** Canvas long-press request channel (PreviewInteractor bumps seq). */
  @Monitor('model.contextMenuSeq')
  onCanvasMenuRequest(_mon: IMonitor): void {
    const id = this.model.contextMenuSourceId;
    if (id === '') {
      return;
    }
    const found = this.model.sources.find((s: SourceItemModel): boolean => s.id === id);
    if (found !== undefined) {
      this.menuSource = found;
      this.menuOpen = true;
    }
  }
  /** Rename dialog (second sheet node — bindSheet must not stack on one
   * node, 10-06 lesson). */
  @Local renameOpen: boolean = false;
  @Local renameDraft: string = '';

  aboutToDisappear(): void {
    this.stopMediaPoll();
  }

  @Builder
  TextSourceSheet() {
    Column({ space: 10 }) {
      Text($r('app.string.text_source_title'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.obs_text_primary'))
        .width('100%')
        .margin({ top: 14 })
      TextArea({ text: this.textDraft, placeholder: $r('app.string.text_source_hint') })
        .fontSize(13)
        .height(120)
        .width('100%')
        .backgroundColor($r('app.color.obs_panel_border'))
        .fontColor($r('app.color.obs_text_primary'))
        .onChange((v: string) => {
          this.textDraft = v;
        })
      Button($r('app.string.text_source_add'))
        .type(ButtonType.Normal)
        .fontSize(13)
        .height(32)
        .width('100%')
        .fontColor($r('app.color.obs_text_primary'))
        .backgroundColor($r('app.color.obs_accent'))
        .borderRadius(4)
        .enabled(this.textDraft.trim().length > 0)
        .onClick(() => {
          ObsController.addTextSource(this.textDraft);
          this.textSheetOpen = false;
        })
      Button($r('app.string.text_source_cancel'))
        .type(ButtonType.Normal)
        .fontSize(13)
        .height(32)
        .width('100%')
        .fontColor($r('app.color.obs_text_secondary'))
        .backgroundColor($r('app.color.obs_panel_border'))
        .borderRadius(4)
        .onClick(() => {
          this.textSheetOpen = false;
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 12 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.obs_background'))
  }

  @Builder
  WebSourceSheet() {
    Column({ space: 10 }) {
      Text($r('app.string.web_source_title'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.obs_text_primary'))
        .width('100%')
        .margin({ top: 14 })
      TextInput({ text: this.webUrl, placeholder: $r('app.string.web_source_hint') })
        .fontSize(13)
        .height(36)
        .width('100%')
        .backgroundColor($r('app.color.obs_panel_border'))
        .fontColor($r('app.color.obs_text_primary'))
        .onChange((v: string) => {
          this.webUrl = v;
        })
      Row({ space: 10 }) {
        TextInput({ text: this.webWidth, placeholder: $r('app.string.web_source_w') })
          .type(InputType.Number)
          .fontSize(13)
          .height(36)
          .layoutWeight(1)
          .backgroundColor($r('app.color.obs_panel_border'))
          .fontColor($r('app.color.obs_text_primary'))
          .onChange((v: string) => {
            this.webWidth = v;
          })
        TextInput({ text: this.webHeight, placeholder: $r('app.string.web_source_h') })
          .type(InputType.Number)
          .fontSize(13)
          .height(36)
          .layoutWeight(1)
          .backgroundColor($r('app.color.obs_panel_border'))
          .fontColor($r('app.color.obs_text_primary'))
          .onChange((v: string) => {
            this.webHeight = v;
          })
      }
      .width('100%')
      Button($r('app.string.web_source_add'))
        .type(ButtonType.Normal)
        .fontSize(13)
        .height(32)
        .width('100%')
        .fontColor($r('app.color.obs_text_primary'))
        .backgroundColor($r('app.color.obs_accent'))
        .borderRadius(4)
        .enabled(this.webUrl.trim().length > 8)
        .onClick(() => {
          const w: number = parseInt(this.webWidth, 10) > 0 ? parseInt(this.webWidth, 10) : 800;
          const h: number = parseInt(this.webHeight, 10) > 0 ? parseInt(this.webHeight, 10) : 600;
          ObsController.addWebSource(this.webUrl.trim(), Math.min(w, 3840), Math.min(h, 2160));
          this.webSheetOpen = false;
        })
      Button($r('app.string.web_source_cancel'))
        .type(ButtonType.Normal)
        .fontSize(13)
        .height(32)
        .width('100%')
        .fontColor($r('app.color.obs_text_secondary'))
        .backgroundColor($r('app.color.obs_panel_border'))
        .borderRadius(4)
        .onClick(() => {
          this.webSheetOpen = false;
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 12 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.obs_background'))
  }

  /* ------------------------------------------------------------------ */
  /* Per-source settings sheet                                          */
  /* ------------------------------------------------------------------ */

  /** Seed the widget mirrors from the source's live settings and open the
   * sheet. libobs owns the values; this is a one-shot read, the sheet then
   * writes a patch back on 应用 (no live preview writes). */
  private openSettings(source: SourceItemModel): void {
    this.model.selectedSourceId = source.id;
    ObsController.refreshFilters();
    this.sheetItemId = source.id;
    this.sheetTypeId = source.typeId;
    this.sheetTypeName = source.name;
    const fetched: Record<string, Object> | null = ObsController.getSourceSettingsRecord(source.id);
    const rec: Record<string, Object> = fetched !== null ? fetched : {};

    const fv: Object | undefined = rec['font'];
    const font: Record<string, Object> | undefined =
      (fv !== undefined && typeof fv === 'object') ? fv as Record<string, Object> : undefined;
    this.sheetText = strAt(rec, 'text', '');
    this.sheetFontFace = font !== undefined ? strAt(font, 'face', 'Sans Serif') : 'Sans Serif';
    this.sheetFontSize = font !== undefined ? numAt(font, 'size', 72) : 72;
    this.sheetTextColorHex = obsColorToHex(numAt(rec, 'color1', 0xFFFFFFFF));
    this.sheetUrl = strAt(rec, 'url', '');
    this.sheetWebWidth = String(numAt(rec, 'width', 800));
    this.sheetWebHeight = String(numAt(rec, 'height', 600));
    this.sheetFps = numAt(rec, 'frame_rate', 30);
    this.sheetCursor = boolAt(rec, 'capture_cursor', true);
    this.sheetPinSize = boolAt(rec, 'pin_size', false);
    this.sheetWinWidth = String(numAt(rec, 'width', 0));
    this.sheetWinHeight = String(numAt(rec, 'height', 0));
    this.sheetCameraPosition = strAt(rec, 'camera_position', '');
    this.sheetCameraRes = strAt(rec, 'resolution', '1920x1080');
    this.sheetPort = strAt(rec, 'port', '25890');
    this.sheetLooping = boolAt(rec, 'looping', true);
    this.sheetSpeed = numAt(rec, 'speed_percent', 100);
    this.sheetColorHex = obsColorToHex(numAt(rec, 'color', 0xFF202020));
    this.sheetColorW = String(numAt(rec, 'width', 1920));
    this.sheetColorH = String(numAt(rec, 'height', 1080));
    this.sheetSlideTime = numAt(rec, 'slide_time', 4000);
    this.sheetTrSpeed = numAt(rec, 'transition_speed', 700);
    this.sheetSlideLoop = boolAt(rec, 'loop', true);

    /* Audio sources map to one of the two fixed mixer tracks. Seed the
     * widgets from the live track (refreshTracks runs on the mixer timer,
     * so model.audioTracks is fresh). */
    this.sheetTrackId = '';
    this.sheetVolume = 1.0;
    this.sheetMuted = false;
    if (isAudioSourceType(source.typeId) && source.sourceUuid !== '') {
      this.sheetTrackId = source.sourceUuid;
      const track: AudioTrackModel | undefined = this.model.audioTracks.find(
        (candidate: AudioTrackModel): boolean => candidate.id === this.sheetTrackId);
      if (track !== undefined) {
        this.sheetVolume = track.volume;
        this.sheetMuted = track.muted;
      }
    }

    /* Media transport: seed once and start a slow poll so the slider and
     * state label track playback. Only media sources report duration > 0. */
    this.stopMediaPoll();
    this.sheetMediaSeekPos = -1;
    if (source.typeId === 'ffmpeg_source') {
      this.pollMedia();
      this.mediaPollTimer = setInterval(() => {
        this.pollMedia();
      }, 500);
    }

    /* Advanced audio props: only sources that actually carry audio expose
     * sync offset / monitoring. */
    this.sheetHasAudioProps = isAudioSourceType(source.typeId) || source.typeId === 'ffmpeg_source';
    this.sheetSyncMs = 0;
    this.sheetMonitor = 0;
    if (this.sheetHasAudioProps) {
      const ap: Record<string, Object> | null = ObsController.getSourceAudioProps(source.id);
      if (ap !== null) {
        this.sheetSyncMs = numAt(ap, 'sync', 0);
        this.sheetMonitor = numAt(ap, 'monitor', 0);
      }
    }

    /* Numeric transform: visual sources only. Seed from bounds + rotation. */
    this.sheetHasTransform = !isAudioSourceType(source.typeId);
    this.sheetPosX = '0';
    this.sheetPosY = '0';
    this.sheetW = '0';
    this.sheetH = '0';
    this.sheetRot = '0';
    if (this.sheetHasTransform) {
      const b: SourceBounds | null = ObsBridge.getSourceBounds(source.id);
      if (b !== null) {
        this.sheetPosX = String(Math.round(b.x));
        this.sheetPosY = String(Math.round(b.y));
        this.sheetW = String(Math.round(b.w));
        this.sheetH = String(Math.round(b.h));
      }
      const tr: Record<string, Object> | null = ObsController.getSourceTransform(source.id);
      if (tr !== null) {
        this.sheetRot = String(Math.round(numAt(tr, 'rot', 0)));
      }
    }

    this.sheetOpen = true;
  }

  private pollMedia(): void {
    const st: Record<string, Object> | null = ObsController.getMediaState(this.sheetItemId);
    if (st === null) {
      return;
    }
    this.sheetMediaTime = numAt(st, 'time', 0);
    this.sheetMediaDuration = numAt(st, 'duration', 0);
    this.sheetMediaState = strAt(st, 'state', 'none');
  }

  private stopMediaPoll(): void {
    if (this.mediaPollTimer >= 0) {
      clearInterval(this.mediaPollTimer);
      this.mediaPollTimer = -1;
    }
  }

  /** mm:ss for the transport readout. */
  private fmtMs(ms: number): string {
    const total = Math.max(0, Math.floor(ms / 1000));
    const m = Math.floor(total / 60);
    const s = total % 60;
    return `${m}:${s < 10 ? '0' : ''}${s}`;
  }

  /** Commit the numeric transform fields (position / size / rotation).
   * Each field commits independently on submit so a half-filled form does
   * not clobber the rest; rotation keeps the current mirror state. */
  private applyTransform(): void {
    const id = this.sheetItemId;
    const px = parseInt(this.sheetPosX, 10);
    const py = parseInt(this.sheetPosY, 10);
    if (!isNaN(px) && !isNaN(py)) {
      ObsBridge.setSourcePosition(id, px, py);
    }
    const w = parseInt(this.sheetW, 10);
    const h = parseInt(this.sheetH, 10);
    if (!isNaN(w) || !isNaN(h)) {
      ObsController.setSourceSize(id, isNaN(w) ? 0 : w, isNaN(h) ? 0 : h);
    }
    const rot = parseInt(this.sheetRot, 10);
    if (!isNaN(rot)) {
      const tr: Record<string, Object> | null = ObsController.getSourceTransform(id);
      const fx = tr !== null && boolAt(tr, 'flipX', false);
      const fy = tr !== null && boolAt(tr, 'flipY', false);
      ObsController.setSourceTransform(id, ((rot % 360) + 360) % 360, fx, fy);
    }
    this.model.bridgeNotice = $r('app.string.notice_settings_applied');
  }

  /** Merge-type patch build + write-back. Keys omitted from the patch keep
   * their current value (obs_data_apply on the native side). */
  private applySettings(): void {
    const patch: Record<string, Object> = {};
    const t: string = this.sheetTypeId;
    if (t === 'text_ft2_source') {
      const font: Record<string, Object> = {
        'face': this.sheetFontFace, 'size': this.sheetFontSize, 'flags': 0, 'style': ''
      };
      const c: number = hexToObsColor(this.sheetTextColorHex);
      patch['text'] = this.sheetText;
      patch['font'] = font;
      patch['color1'] = c;
      patch['color2'] = c;
    } else if (t === 'harmony_web_source') {
      const w: number = parseInt(this.sheetWebWidth, 10) > 0 ? parseInt(this.sheetWebWidth, 10) : 800;
      const h: number = parseInt(this.sheetWebHeight, 10) > 0 ? parseInt(this.sheetWebHeight, 10) : 600;
      patch['url'] = this.sheetUrl;
      patch['width'] = Math.min(w, 3840);
      patch['height'] = Math.min(h, 2160);
    } else if (t === 'harmony_display_capture') {
      patch['frame_rate'] = this.sheetFps;
      patch['capture_cursor'] = this.sheetCursor;
    } else if (t === 'harmony_window_capture') {
      patch['frame_rate'] = this.sheetFps;
      patch['capture_cursor'] = this.sheetCursor;
      patch['pin_size'] = this.sheetPinSize;
      if (this.sheetPinSize) {
        const pw: number = parseInt(this.sheetWinWidth, 10);
        const ph: number = parseInt(this.sheetWinHeight, 10);
        patch['width'] = pw > 0 ? Math.min(pw, 8192) : 1920;
        patch['height'] = ph > 0 ? Math.min(ph, 8192) : 1080;
      } else {
        /* 0 = follow (native display seed + window-rect tracking). */
        patch['width'] = 0;
        patch['height'] = 0;
      }
    } else if (t === 'harmony_camera_capture') {
      /* Clearing device_id lets the position preference pick the device. */
      patch['camera_position'] = this.sheetCameraPosition;
      patch['device_id'] = '';
      patch['resolution'] = this.sheetCameraRes;
    } else if (t === 'harmony_remote_camera') {
      const p: number = parseInt(this.sheetPort, 10);
      if (p > 0 && p < 65536) {
        patch['port'] = String(p);
      }
    } else if (t === 'ffmpeg_source') {
      patch['looping'] = this.sheetLooping;
      patch['speed_percent'] = Math.max(1, Math.min(200, Math.round(this.sheetSpeed)));
    } else if (t === 'color_source') {
      const cw: number = parseInt(this.sheetColorW, 10);
      const ch: number = parseInt(this.sheetColorH, 10);
      patch['color'] = hexToObsColor(this.sheetColorHex);
      patch['width'] = cw > 0 ? Math.min(cw, 8192) : 1920;
      patch['height'] = ch > 0 ? Math.min(ch, 8192) : 1080;
    } else if (t === 'slideshow') {
      patch['slide_time'] = Math.max(50, Math.round(this.sheetSlideTime));
      patch['transition_speed'] = Math.max(0, Math.round(this.sheetTrSpeed));
      patch['loop'] = this.sheetSlideLoop;
    } else {
      return; /* audio types live in the mixer; image has no tunables yet */
    }
    const ok: boolean = ObsController.setSourceSettings(this.sheetItemId, patch);
    if (ok) {
      this.model.bridgeNotice = $r('app.string.notice_settings_applied');
      this.sheetOpen = false;
    } else {
      this.model.bridgeNotice = $r('app.string.notice_settings_failed');
    }
  }

  /* ---- context menu actions (desktop right-click parity) ---- */

  /** Toggle one transform axis: read the absolute state, flip it, write
   * back (the bridge takes absolute values, the menu is the toggle). */
  private flipAxis(axis: string): void {
    const src = this.menuSource;
    if (src === null) {
      return;
    }
    const t: Record<string, Object> | null = ObsController.getSourceTransform(src.id);
    if (t === null) {
      return;
    }
    const rot: number = numAt(t, 'rot', 0);
    let flipX: boolean = boolAt(t, 'flipX', false);
    let flipY: boolean = boolAt(t, 'flipY', false);
    if (axis === 'x') {
      flipX = !flipX;
    } else {
      flipY = !flipY;
    }
    ObsController.setSourceTransform(src.id, rot, flipX, flipY);
    this.menuOpen = false;
  }

  private rotateBy(degrees: number): void {
    const src = this.menuSource;
    if (src === null) {
      return;
    }
    const t: Record<string, Object> | null = ObsController.getSourceTransform(src.id);
    const rot: number = (t !== null ? numAt(t, 'rot', 0) : 0) + degrees;
    ObsController.setSourceTransform(src.id, ((rot % 360) + 360) % 360,
      t !== null && boolAt(t, 'flipX', false), t !== null && boolAt(t, 'flipY', false));
    this.menuOpen = false;
  }

  private boundsFit(mode: string): void {
    const src = this.menuSource;
    if (src !== null) {
      ObsController.setSourceBoundsFit(src.id, mode);
    }
    this.menuOpen = false;
  }

  private dupSource(): void {
    const src = this.menuSource;
    if (src !== null) {
      ObsController.duplicateSource(src.id);
    }
    this.menuOpen = false;
  }

  private delSource(): void {
    const src = this.menuSource;
    if (src !== null) {
      ObsController.removeSourceById(src.id);
    }
    this.menuOpen = false;
  }

  private openRename(): void {
    const src = this.menuSource;
    if (src !== null) {
      this.renameDraft = src.name;
      this.renameOpen = true;
    }
    this.menuOpen = false;
  }

  private applyRename(): void {
    const src = this.menuSource;
    if (src !== null && this.renameDraft.trim() !== '') {
      ObsController.renameSource(src.id, this.renameDraft);
    }
    this.renameOpen = false;
  }

  @Builder
  MenuRow(label: string, action: () => void) {
    Text(label)
      .fontSize(13)
      .fontColor($r('app.color.obs_text_primary'))
      .width('100%')
      .padding({ top: 9, bottom: 9, left: 4 })
      .onClick(action)
  }

  @Builder
  SourceMenuSheet() {
    Column() {
      Text(this.menuSource !== null ? this.menuSource.name : '')
        .fontSize(12)
        .fontColor($r('app.color.obs_text_secondary'))
        .width('100%')
        .margin({ top: 12, bottom: 4 })
      this.MenuRow('设置', () => {
        const src = this.menuSource;
        this.menuOpen = false;
        if (src !== null) {
          this.openSettings(src);
        }
      })
      this.MenuRow('变换 > 旋转 90°', () => {
        this.rotateBy(90);
      })
      this.MenuRow('变换 > 水平翻转', () => {
        this.flipAxis('x');
      })
      this.MenuRow('变换 > 垂直翻转', () => {
        this.flipAxis('y');
      })
      this.MenuRow('缩放至全屏', () => {
        this.boundsFit('fit');
      })
      this.MenuRow('拉伸至全屏', () => {
        this.boundsFit('stretch');
      })
      this.MenuRow('取消缩放', () => {
        this.boundsFit('none');
      })
      this.MenuRow('复制（引用）', () => {
        this.dupSource();
      })
      this.MenuRow('重命名', () => {
        this.openRename();
      })
      this.MenuRow('删除', () => {
        this.delSource();
      })
      /* Explicit dismiss: this sheet turned off the system ✕ (dim grey,
       * unreadable — user report 10-14 #1). Tapping a row already closes
       * it; this is the cancel path. */
      Button() {
        Text('取消').fontSize(13).fontColor($r('app.color.obs_text_secondary'))
      }
        .type(ButtonType.Normal)
        .height(32)
        .width('100%')
        .margin({ top: 6 })
        .backgroundColor($r('app.color.obs_panel_border'))
        .borderRadius(4)
        .onClick(() => {
          this.menuOpen = false;
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 12 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.obs_background'))
  }

  @Builder
  RenameSheet() {
    Column({ space: 10 }) {
      Text('重命名')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.obs_text_primary'))
        .width('100%')
        .margin({ top: 14 })
      TextInput({ text: this.renameDraft })
        .fontSize(13)
        .height(36)
        .width('100%')
        .backgroundColor($r('app.color.obs_panel_border'))
        .fontColor($r('app.color.obs_text_primary'))
        .onChange((v: string) => {
          this.renameDraft = v;
        })
      Button('确定')
        .type(ButtonType.Normal)
        .fontSize(13)
        .height(32)
        .width('100%')
        .fontColor($r('app.color.obs_text_primary'))
        .backgroundColor($r('app.color.obs_accent'))
        .borderRadius(4)
        .onClick(() => {
          this.applyRename();
        })
      Button('取消')
        .type(ButtonType.Normal)
        .fontSize(13)
        .height(32)
        .width('100%')
        .fontColor($r('app.color.obs_text_secondary'))
        .backgroundColor($r('app.color.obs_panel_border'))
        .borderRadius(4)
        .onClick(() => {
          this.renameOpen = false;
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 12 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.obs_background'))
  }

  @Builder
  SheetLabel(text: string) {
    Text(text)
      .fontSize(12)
      .fontColor($r('app.color.obs_text_secondary'))
      .width('100%')
  }

  @Builder
  ColorSwatch(hex: string) {
    Button() {
    }
      .type(ButtonType.Circle)
      .width(28)
      .height(28)
      .backgroundColor(hex)
      .border({
        width: this.sheetTextColorHex === hex ? 3 : 1,
        color: this.sheetTextColorHex === hex ? $r('app.color.obs_accent') : $r('app.color.obs_panel_border')
      })
      .onClick(() => {
        this.sheetTextColorHex = hex;
      })
  }

  /** Same swatch, but writing the colour-source field. */
  @Builder
  ColorSwatchBlock(hex: string) {
    Button() {
    }
      .type(ButtonType.Circle)
      .width(28)
      .height(28)
      .backgroundColor(hex)
      .border({
        width: this.sheetColorHex === hex ? 3 : 1,
        color: this.sheetColorHex === hex ? $r('app.color.obs_accent') : $r('app.color.obs_panel_border')
      })
      .onClick(() => {
        this.sheetColorHex = hex;
      })
  }

  @Builder
  SettingsSheet() {
    Scroll() {
      Column({ space: 10 }) {
        Row() {
          Text(`${this.sheetTypeName} 设置`)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.obs_text_primary'))
            .layoutWeight(1)
          /* Blue 关闭 top-right (user report 10-14 #1): the system ✕ is a
           * dim grey glyph with no color API — every sheet now turns it
           * off (showClose:false) and carries its own accent button. */
          Button() {
            Text('关闭').fontSize(13).fontWeight(FontWeight.Medium).fontColor(Color.White)
          }
            .type(ButtonType.Normal)
            .height(32)
            .padding({ left: 14, right: 14 })
            .backgroundColor($r('app.color.obs_accent'))
            .borderRadius(6)
            .onClick(() => {
              this.sheetOpen = false;
            })
        }
        .width('100%')
        .margin({ top: 14 })

        if (this.sheetTypeId === 'text_ft2_source') {
          this.SheetLabel('文字内容')
          TextArea({ text: this.sheetText })
            .fontSize(13)
            .height(80)
            .width('100%')
            .backgroundColor($r('app.color.obs_panel_border'))
            .fontColor($r('app.color.obs_text_primary'))
            .onChange((v: string) => {
              this.sheetText = v;
            })
          this.SheetLabel(`字号 ${this.sheetFontSize}`)
          Slider({ value: this.sheetFontSize, min: 16, max: 300, step: 4 })
            .width('100%')
            .onChange((v: number) => {
              this.sheetFontSize = Math.round(v);
            })
          this.SheetLabel('颜色')
          Row({ space: 8 }) {
            this.ColorSwatch('#FFFFFF')
            this.ColorSwatch('#000000')
            this.ColorSwatch('#E53935')
            this.ColorSwatch('#43A047')
            this.ColorSwatch('#1E88E5')
            this.ColorSwatch('#FDD835')
          }
          .width('100%')
        } else if (this.sheetTypeId === 'harmony_web_source') {
          this.SheetLabel('网页地址')
          TextInput({ text: this.sheetUrl })
            .fontSize(13)
            .height(36)
            .width('100%')
            .backgroundColor($r('app.color.obs_panel_border'))
            .fontColor($r('app.color.obs_text_primary'))
            .onChange((v: string) => {
              this.sheetUrl = v;
            })
          this.SheetLabel('视口尺寸')
          Row({ space: 10 }) {
            TextInput({ text: this.sheetWebWidth })
              .type(InputType.Number)
              .fontSize(13)
              .height(36)
              .layoutWeight(1)
              .backgroundColor($r('app.color.obs_panel_border'))
              .fontColor($r('app.color.obs_text_primary'))
              .onChange((v: string) => {
                this.sheetWebWidth = v;
              })
            TextInput({ text: this.sheetWebHeight })
              .type(InputType.Number)
              .fontSize(13)
              .height(36)
              .layoutWeight(1)
              .backgroundColor($r('app.color.obs_panel_border'))
              .fontColor($r('app.color.obs_text_primary'))
              .onChange((v: string) => {
                this.sheetWebHeight = v;
              })
          }
          .width('100%')
        } else if (this.sheetTypeId === 'harmony_display_capture') {
          this.SheetLabel(`帧率上限 ${this.sheetFps} fps`)
          Slider({ value: this.sheetFps, min: 5, max: 60, step: 5 })
            .width('100%')
            .onChange((v: number) => {
              this.sheetFps = Math.round(v);
            })
          Row() {
            this.SheetLabel('捕获鼠标指针')
            Blank()
            Toggle({ type: ToggleType.Switch, isOn: this.sheetCursor })
              .selectedColor($r('app.color.obs_accent'))
              .onChange((isOn: boolean) => {
                this.sheetCursor = isOn;
              })
          }
          .width('100%')
        } else if (this.sheetTypeId === 'harmony_window_capture') {
          this.SheetLabel(`帧率上限 ${this.sheetFps} fps`)
          Slider({ value: this.sheetFps, min: 5, max: 60, step: 5 })
            .width('100%')
            .onChange((v: number) => {
              this.sheetFps = Math.round(v);
            })
          Row() {
            this.SheetLabel('捕获鼠标指针')
            Blank()
            Toggle({ type: ToggleType.Switch, isOn: this.sheetCursor })
              .selectedColor($r('app.color.obs_accent'))
              .onChange((isOn: boolean) => {
                this.sheetCursor = isOn;
              })
          }
          .width('100%')
          Row() {
            this.SheetLabel('固定采集尺寸（默认跟随窗口）')
            Blank()
            Toggle({ type: ToggleType.Switch, isOn: this.sheetPinSize })
              .selectedColor($r('app.color.obs_accent'))
              .onChange((isOn: boolean) => {
                this.sheetPinSize = isOn;
              })
          }
          .width('100%')
          if (this.sheetPinSize) {
            Row({ space: 10 }) {
              TextInput({ text: this.sheetWinWidth, placeholder: '宽' })
                .type(InputType.Number)
                .fontSize(13)
                .height(36)
                .layoutWeight(1)
                .backgroundColor($r('app.color.obs_panel_border'))
                .fontColor($r('app.color.obs_text_primary'))
                .onChange((v: string) => {
                  this.sheetWinWidth = v;
                })
              TextInput({ text: this.sheetWinHeight, placeholder: '高' })
                .type(InputType.Number)
                .fontSize(13)
                .height(36)
                .layoutWeight(1)
                .backgroundColor($r('app.color.obs_panel_border'))
                .fontColor($r('app.color.obs_text_primary'))
                .onChange((v: string) => {
                  this.sheetWinHeight = v;
                })
            }
            .width('100%')
          }
        } else if (this.sheetTypeId === 'harmony_camera_capture') {
          this.SheetLabel('镜头')
          Row({ space: 8 }) {
            Button('后置')
              .type(ButtonType.Normal)
              .fontSize(12)
              .height(30)
              .layoutWeight(1)
              .fontColor($r('app.color.obs_text_primary'))
              .backgroundColor(this.sheetCameraPosition !== 'Front' ?
              $r('app.color.obs_accent') : $r('app.color.obs_panel_border'))
              .borderRadius(4)
              .onClick(() => {
                this.sheetCameraPosition = 'Back';
              })
            Button('前置')
              .type(ButtonType.Normal)
              .fontSize(12)
              .height(30)
              .layoutWeight(1)
              .fontColor($r('app.color.obs_text_primary'))
              .backgroundColor(this.sheetCameraPosition === 'Front' ?
              $r('app.color.obs_accent') : $r('app.color.obs_panel_border'))
              .borderRadius(4)
              .onClick(() => {
                this.sheetCameraPosition = 'Front';
              })
          }
          .width('100%')
          this.SheetLabel('分辨率')
          Row({ space: 8 }) {
            Button('720p')
              .type(ButtonType.Normal)
              .fontSize(12)
              .height(30)
              .layoutWeight(1)
              .fontColor($r('app.color.obs_text_primary'))
              .backgroundColor(this.sheetCameraRes === '1280x720' ?
              $r('app.color.obs_accent') : $r('app.color.obs_panel_border'))
              .borderRadius(4)
              .onClick(() => {
                this.sheetCameraRes = '1280x720';
              })
            Button('1080p')
              .type(ButtonType.Normal)
              .fontSize(12)
              .height(30)
              .layoutWeight(1)
              .fontColor($r('app.color.obs_text_primary'))
              .backgroundColor(this.sheetCameraRes === '1920x1080' ?
              $r('app.color.obs_accent') : $r('app.color.obs_panel_border'))
              .borderRadius(4)
              .onClick(() => {
                this.sheetCameraRes = '1920x1080';
              })
            Button('4K')
              .type(ButtonType.Normal)
              .fontSize(12)
              .height(30)
              .layoutWeight(1)
              .fontColor($r('app.color.obs_text_primary'))
              .backgroundColor(this.sheetCameraRes === '3840x2160' ?
              $r('app.color.obs_accent') : $r('app.color.obs_panel_border'))
              .borderRadius(4)
              .onClick(() => {
                this.sheetCameraRes = '3840x2160';
              })
          }
          .width('100%')
        } else if (this.sheetTypeId === 'harmony_remote_camera') {
          this.SheetLabel('监听端口')
          TextInput({ text: this.sheetPort })
            .type(InputType.Number)
            .fontSize(13)
            .height(36)
            .width('100%')
            .backgroundColor($r('app.color.obs_panel_border'))
            .fontColor($r('app.color.obs_text_primary'))
            .onChange((v: string) => {
              this.sheetPort = v;
            })
          Text('改端口后手机推流端也要用同一端口重新连接')
            .fontSize(11)
            .fontColor($r('app.color.obs_text_secondary'))
            .width('100%')
        } else if (this.sheetTypeId === 'ffmpeg_source') {
          /* Transport: play/pause/restart/stop + seek slider + mm:ss readout.
           * The slider tracks sheetMediaSeekPos while dragging so the 500ms
           * poll cannot yank it back; the seek commits on release. */
          if (this.sheetMediaDuration > 0) {
            Row({ space: 6 }) {
              Button() {
                Text(this.sheetMediaState === 'playing' ? '⏸' : '▶')
                  .fontSize(14)
                  .fontColor($r('app.color.obs_text_primary'))
              }
                .type(ButtonType.Normal)
                .width(40)
                .height(30)
                .backgroundColor($r('app.color.obs_panel_border'))
                .borderRadius(4)
                .onClick(() => {
                  ObsController.mediaControl(this.sheetItemId,
                    this.sheetMediaState === 'playing' ? 'pause' : 'play');
                  this.pollMedia();
                })
              Button() {
                Text('⟲').fontSize(14).fontColor($r('app.color.obs_text_primary'))
              }
                .type(ButtonType.Normal)
                .width(40)
                .height(30)
                .backgroundColor($r('app.color.obs_panel_border'))
                .borderRadius(4)
                .onClick(() => {
                  ObsController.mediaControl(this.sheetItemId, 'restart');
                  this.pollMedia();
                })
              Button() {
                Text('■').fontSize(14).fontColor($r('app.color.obs_text_primary'))
              }
                .type(ButtonType.Normal)
                .width(40)
                .height(30)
                .backgroundColor($r('app.color.obs_panel_border'))
                .borderRadius(4)
                .onClick(() => {
                  ObsController.mediaControl(this.sheetItemId, 'stop');
                  this.pollMedia();
                })
              Text(`${this.fmtMs(this.sheetMediaSeekPos >= 0 ? this.sheetMediaSeekPos : this.sheetMediaTime)}` +
                ` / ${this.fmtMs(this.sheetMediaDuration)}`)
                .fontSize(11)
                .fontColor($r('app.color.obs_text_secondary'))
                .layoutWeight(1)
                .textAlign(TextAlign.End)
            }
            .width('100%')

            Slider({
              value: this.sheetMediaSeekPos >= 0 ? this.sheetMediaSeekPos : this.sheetMediaTime,
              min: 0, max: this.sheetMediaDuration, step: 250
            })
              .width('100%')
              .onChange((v: number, mode: SliderChangeMode) => {
                if (mode === SliderChangeMode.Moving || mode === SliderChangeMode.Click) {
                  this.sheetMediaSeekPos = v;
                } else if (mode === SliderChangeMode.End) {
                  ObsController.mediaSeek(this.sheetItemId, v);
                  this.sheetMediaSeekPos = -1;
                  this.pollMedia();
                }
              })
          }
          Row() {
            this.SheetLabel('循环播放')
            Blank()
            Toggle({ type: ToggleType.Switch, isOn: this.sheetLooping })
              .selectedColor($r('app.color.obs_accent'))
              .onChange((isOn: boolean) => {
                this.sheetLooping = isOn;
              })
          }
          .width('100%')
          this.SheetLabel(`播放速度 ${this.sheetSpeed}%`)
          Slider({ value: this.sheetSpeed, min: 25, max: 200, step: 25 })
            .width('100%')
            .onChange((v: number) => {
              this.sheetSpeed = Math.round(v);
            })
        } else if (this.sheetTypeId === 'color_source') {
          this.SheetLabel('颜色')
          Row({ space: 8 }) {
            this.ColorSwatchBlock('#202020')
            this.ColorSwatchBlock('#000000')
            this.ColorSwatchBlock('#FFFFFF')
            this.ColorSwatchBlock('#E53935')
            this.ColorSwatchBlock('#43A047')
            this.ColorSwatchBlock('#1E88E5')
          }
          .width('100%')
          this.SheetLabel('尺寸')
          Row({ space: 10 }) {
            TextInput({ text: this.sheetColorW, placeholder: '宽' })
              .type(InputType.Number)
              .fontSize(13)
              .height(36)
              .layoutWeight(1)
              .backgroundColor($r('app.color.obs_panel_border'))
              .fontColor($r('app.color.obs_text_primary'))
              .onChange((v: string) => {
                this.sheetColorW = v;
              })
            TextInput({ text: this.sheetColorH, placeholder: '高' })
              .type(InputType.Number)
              .fontSize(13)
              .height(36)
              .layoutWeight(1)
              .backgroundColor($r('app.color.obs_panel_border'))
              .fontColor($r('app.color.obs_text_primary'))
              .onChange((v: string) => {
                this.sheetColorH = v;
              })
          }
          .width('100%')
        } else if (this.sheetTypeId === 'slideshow') {
          this.SheetLabel(`单张停留 ${Math.round(this.sheetSlideTime / 100) / 10} 秒`)
          Slider({ value: this.sheetSlideTime, min: 500, max: 15000, step: 500 })
            .width('100%')
            .onChange((v: number) => {
              this.sheetSlideTime = Math.round(v);
            })
          this.SheetLabel(`切换动画 ${this.sheetTrSpeed} ms`)
          Slider({ value: this.sheetTrSpeed, min: 0, max: 2000, step: 100 })
            .width('100%')
            .onChange((v: number) => {
              this.sheetTrSpeed = Math.round(v);
            })
          Row() {
            this.SheetLabel('循环播放')
            Blank()
            Toggle({ type: ToggleType.Switch, isOn: this.sheetSlideLoop })
              .selectedColor($r('app.color.obs_accent'))
              .onChange((isOn: boolean) => {
                this.sheetSlideLoop = isOn;
              })
          }
          .width('100%')
        } else if (this.sheetTrackId !== '') {
          this.SheetLabel(`音量 ${Math.round(this.sheetVolume * 100)}%`)
          Slider({ value: this.sheetVolume, min: 0, max: 1, step: 0.01 })
            .width('100%')
            .onChange((v: number) => {
              this.sheetVolume = v;
              ObsController.setTrackVolume(this.sheetTrackId, v);
            })
          Row() {
            this.SheetLabel('静音')
            Blank()
            Toggle({ type: ToggleType.Switch, isOn: this.sheetMuted })
              .selectedColor($r('app.color.obs_accent'))
              .onChange((isOn: boolean) => {
                this.sheetMuted = isOn;
                ObsController.setTrackMute(this.sheetTrackId, isOn);
              })
          }
          .width('100%')
        } else {
          Text('该源暂无可调参数')
            .fontSize(12)
            .fontColor($r('app.color.obs_text_secondary'))
            .width('100%')
        }

        /* Numeric transform (desktop 变换 parity): precise position / size /
         * rotation for visual sources, complementing drag & pinch. */
        if (this.sheetHasTransform) {
          this.SheetLabel('变换（位置 / 尺寸 / 旋转）')
          Row({ space: 8 }) {
            TextInput({ text: this.sheetPosX, placeholder: 'X' })
              .type(InputType.Number)
              .fontSize(12)
              .height(32)
              .layoutWeight(1)
              .backgroundColor($r('app.color.obs_panel_border'))
              .fontColor($r('app.color.obs_text_primary'))
              .onChange((v: string) => {
                this.sheetPosX = v;
              })
            TextInput({ text: this.sheetPosY, placeholder: 'Y' })
              .type(InputType.Number)
              .fontSize(12)
              .height(32)
              .layoutWeight(1)
              .backgroundColor($r('app.color.obs_panel_border'))
              .fontColor($r('app.color.obs_text_primary'))
              .onChange((v: string) => {
                this.sheetPosY = v;
              })
          }
          .width('100%')
          Row({ space: 8 }) {
            TextInput({ text: this.sheetW, placeholder: '宽' })
              .type(InputType.Number)
              .fontSize(12)
              .height(32)
              .layoutWeight(1)
              .backgroundColor($r('app.color.obs_panel_border'))
              .fontColor($r('app.color.obs_text_primary'))
              .onChange((v: string) => {
                this.sheetW = v;
              })
            TextInput({ text: this.sheetH, placeholder: '高' })
              .type(InputType.Number)
              .fontSize(12)
              .height(32)
              .layoutWeight(1)
              .backgroundColor($r('app.color.obs_panel_border'))
              .fontColor($r('app.color.obs_text_primary'))
              .onChange((v: string) => {
                this.sheetH = v;
              })
            TextInput({ text: this.sheetRot, placeholder: '°' })
              .type(InputType.Number)
              .fontSize(12)
              .height(32)
              .layoutWeight(1)
              .backgroundColor($r('app.color.obs_panel_border'))
              .fontColor($r('app.color.obs_text_primary'))
              .onChange((v: string) => {
                this.sheetRot = v;
              })
          }
          .width('100%')
          Button('应用变换')
            .type(ButtonType.Normal)
            .fontSize(12)
            .height(30)
            .width('100%')
            .fontColor($r('app.color.obs_text_primary'))
            .backgroundColor($r('app.color.obs_panel_border'))
            .borderRadius(4)
            .onClick(() => {
              this.applyTransform();
            })
        }

        /* Advanced audio props (desktop 高级音频属性 parity): sync offset
         * and monitoring type. Applied live, like the mixer controls. */
        if (this.sheetHasAudioProps) {
          this.SheetLabel(`同步偏移 ${this.sheetSyncMs} ms`)
          Slider({ value: this.sheetSyncMs, min: -1000, max: 1000, step: 10 })
            .width('100%')
            .onChange((v: number) => {
              this.sheetSyncMs = Math.round(v);
              ObsController.setSourceAudioProps(this.sheetItemId, this.sheetSyncMs, this.sheetMonitor);
            })
          this.SheetLabel('监听类型')
          Row({ space: 6 }) {
            Button('关')
              .type(ButtonType.Normal)
              .fontSize(12)
              .height(30)
              .layoutWeight(1)
              .fontColor($r('app.color.obs_text_primary'))
              .backgroundColor(this.sheetMonitor === 0 ?
              $r('app.color.obs_accent') : $r('app.color.obs_panel_border'))
              .borderRadius(4)
              .onClick(() => {
                this.sheetMonitor = 0;
                ObsController.setSourceAudioProps(this.sheetItemId, this.sheetSyncMs, 0);
              })
            Button('仅监听')
              .type(ButtonType.Normal)
              .fontSize(12)
              .height(30)
              .layoutWeight(1)
              .fontColor($r('app.color.obs_text_primary'))
              .backgroundColor(this.sheetMonitor === 1 ?
              $r('app.color.obs_accent') : $r('app.color.obs_panel_border'))
              .borderRadius(4)
              .onClick(() => {
                this.sheetMonitor = 1;
                ObsController.setSourceAudioProps(this.sheetItemId, this.sheetSyncMs, 1);
              })
            Button('监听并输出')
              .type(ButtonType.Normal)
              .fontSize(12)
              .height(30)
              .layoutWeight(1)
              .fontColor($r('app.color.obs_text_primary'))
              .backgroundColor(this.sheetMonitor === 2 ?
              $r('app.color.obs_accent') : $r('app.color.obs_panel_border'))
              .borderRadius(4)
              .onClick(() => {
                this.sheetMonitor = 2;
                ObsController.setSourceAudioProps(this.sheetItemId, this.sheetSyncMs, 2);
              })
          }
          .width('100%')
        }

        /* Audio sources apply live (they drive the mixer track); everything
         * else writes a settings patch on 应用. */
        if (this.sheetTrackId === '') {
          Button('应用')
            .type(ButtonType.Normal)
            .fontSize(13)
            .height(32)
            .width('100%')
            .fontColor($r('app.color.obs_text_primary'))
            .backgroundColor($r('app.color.obs_accent'))
            .borderRadius(4)
            .onClick(() => {
              this.applySettings();
            })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 16 })
      .alignItems(HorizontalAlign.Start)
      .backgroundColor($r('app.color.obs_background'))
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Auto)
  }

  /** Select a source row. Bound to the LEAF Text nodes: on this ROM neither
   * the row-level nor the Column-level onClick fires (the row carries a
   * LongPressGesture whose arbitration eats container taps — device probe
   * 10-14 logged nothing for both, while the leaf Buttons in the same row
   * worked). Leaves are the empirically reliable hit layer. */
  private selectRow(id: string): void {
    Logger.info(`source row clicked: ${id}`);
    this.model.selectedSourceId = id;
    ObsController.refreshFilters();
  }

  build() {
    Column({ space: 6 }) {
      Row() {
        Text($r('app.string.sources'))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.obs_text_secondary'))
        Blank()
        /* Labeled delete (user report 10-13 #2: the old glyph '-' looked
         * identical enabled/disabled, so taps on it read as "delete does
         * nothing"; a row-local × in the cramped 42px row gets clipped and
         * misses touches). A text button with an obvious dimmed disabled
         * state + row-tap-to-select makes the flow discoverable: tap the
         * row (it highlights), then 删除. */
        Button() {
          Text('删除').fontSize(12).fontColor($r('app.color.obs_text_primary'))
        }
          .type(ButtonType.Normal)
          .backgroundColor($r('app.color.obs_panel_border'))
          .borderRadius(4)
          .height(26)
          .padding({ left: 10, right: 10 })
          .enabled(this.model.coreReady && this.model.selectedSourceId !== '')
          .opacity(this.model.selectedSourceId === '' ? 0.4 : 1)
          .onClick(() => {
            Logger.info('source header 删除 clicked');
            ObsController.removeSelectedSource();
          })
          /* Menu sheet anchors here: every bindSheet needs its own node
           * (two on one node silently drop the earlier one, 10-06). */
          .bindSheet($$this.menuOpen,
            this.SourceMenuSheet(),
            {
              height: SheetSize.FIT_CONTENT,
              dragBar: true,
              showClose: false,
              backgroundColor: $r('app.color.obs_background')
            })
      }

      // Wrapping rather than a single Row: six source types do not fit the dock
      // width, and on a narrow floating window or split view they would be
      // clipped off the edge with no way to reach them.
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(SOURCE_TYPES, (entry: SourceTypeEntry) => {
          Button(entry.label)
            .type(ButtonType.Normal)
            .fontSize(11)
            .fontColor($r('app.color.obs_text_primary'))
            .backgroundColor($r('app.color.obs_panel_border'))
            .borderRadius(4)
            .height(24)
            .margin({ right: 6, bottom: 6 })
            .enabled(this.model.coreReady && this.model.selectedSceneId !== '')
            .onClick(() => {
              if (entry.id === '@picker:image_source') {
                ObsController.addImageSourcePicked();
              } else if (entry.id === '@picker:slideshow') {
                ObsController.addSlideshowSourcePicked();
              } else if (entry.id === '@picker:ffmpeg_source') {
                ObsController.addMediaSourcePicked();
              } else if (entry.id === 'color_source') {
                ObsController.addColorSource();
              } else if (entry.id === '@dialog:text_ft2_source') {
                this.textDraft = '';
                this.textSheetOpen = true;
              } else if (entry.id === '@dialog:harmony_web_source') {
                this.webSheetOpen = true;
              } else {
                const singletonName: string | undefined = SINGLETON_SOURCES[entry.id];
                if (singletonName !== undefined) {
                  if (!ObsController.hasSourceNamed(singletonName)) {
                    ObsController.addSource(entry.id, '{}', singletonName);
                  }
                } else {
                  ObsController.addSource(entry.id);
                }
              }
            })
        }, (entry: SourceTypeEntry) => entry.id)
      }
      .bindSheet($$this.webSheetOpen,
        this.WebSourceSheet(),
        {
          height: SheetSize.FIT_CONTENT,
          dragBar: true,
          showClose: false,
          backgroundColor: $r('app.color.obs_background')
        })
      .width('100%')

      List({ space: 2 }) {
        ForEach(this.model.sources, (source: SourceItemModel) => {
          ListItem() {
            Row({ space: 6 }) {
              // Eye toggle: obs_sceneitem_set_visible
              Toggle({ type: ToggleType.Switch, isOn: source.visible })
                .selectedColor($r('app.color.obs_accent'))
                .width(34)
                .height(20)
                .onChange((isOn: boolean) => {
                  ObsController.setSourceVisible(source.id, isOn);
                })
              /* Selection is a transparent BUTTON wrapping the name block:
               * on this ROM neither Row-level, Column-level nor leaf-Text
               * onClick fires inside a row that also carries a
               * LongPressGesture (gesture arbitration eats them — device
               * probes 10-14 logged nothing for all three), while Button
               * and Toggle children in the same row respond reliably.
               * A Button is the one empirically safe hit layer. */
              Button() {
                Column() {
                  Text(source.name)
                    .fontSize(13)
                    .fontColor($r('app.color.obs_text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(source.typeId)
                    .fontSize(10)
                    .fontColor($r('app.color.obs_text_secondary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .alignItems(HorizontalAlign.Start)
                .width('100%')
              }
              .type(ButtonType.Normal)
              .backgroundColor(Color.Transparent)
              .layoutWeight(1)
              .height(40)
              .onClick(() => {
                this.selectRow(source.id);
              })

              /* Row actions as SymbolGlyph system icons (user report
               * 10-14 #3: "正一点的设置图标"). sys.symbol resources are
               * compile-time checked (a bad name FAILS the build — the
               * safe failure mode the runtime-invisible ✕ taught us),
               * and the 32vp glyphs keep the name column readable. */
              Button() {
                SymbolGlyph($r('sys.symbol.gearshape'))
                  .fontSize(15)
                  .fontColor([$r('app.color.obs_text_secondary')])
              }
                .type(ButtonType.Normal)
                .backgroundColor(Color.Transparent)
                .width(32)
                .height(34)
                .onClick(() => {
                  this.openSettings(source);
                })
              /* Lock: while ON the source ignores canvas drag/pinch on
               * the canvas (desktop lock icon parity). Filled + accent
               * tint when engaged. */
              Button() {
                SymbolGlyph(source.locked ? $r('sys.symbol.lock_fill') : $r('sys.symbol.lock'))
                  .fontSize(15)
                  .fontColor([source.locked ? $r('app.color.obs_accent') : $r('app.color.obs_text_secondary')])
              }
                .type(ButtonType.Normal)
                .backgroundColor(Color.Transparent)
                .width(32)
                .height(34)
                .onClick(() => {
                  ObsController.setSourceLocked(source.id, !source.locked);
                })
              /* Z-order: move up / down in the scene draw order (desktop
               * dock arrow parity). Arrows render reliably (device-checked). */
              Button() {
                Text('↑').fontSize(14).fontColor($r('app.color.obs_text_primary'))
              }
                .type(ButtonType.Normal)
                .backgroundColor($r('app.color.obs_panel_border'))
                .borderRadius(4)
                .width(30)
                .height(34)
                .onClick(() => {
                  ObsController.setSourceOrder(source.id, 'up');
                })
              Button() {
                Text('↓').fontSize(14).fontColor($r('app.color.obs_text_primary'))
              }
                .type(ButtonType.Normal)
                .backgroundColor($r('app.color.obs_panel_border'))
                .borderRadius(4)
                .width(30)
                .height(34)
                .onClick(() => {
                  ObsController.setSourceOrder(source.id, 'down');
                })
              /* Delete as a proper (red-tinted) button — user report
               * 10-14 #3: "删除文字换成按钮". */
              Button() {
                SymbolGlyph($r('sys.symbol.trash'))
                  .fontSize(15)
                  .fontColor([$r('app.color.obs_live')])
              }
                .type(ButtonType.Normal)
                .backgroundColor(Color.Transparent)
                .width(32)
                .height(34)
                .onClick(() => {
                  Logger.info(`row delete clicked: ${source.id}`);
                  ObsController.removeSourceById(source.id);
                })
            }
            .width('100%')
            .height(46)
            .padding({ left: 6, right: 8 })
            .borderRadius(4)
            .backgroundColor(source.id === this.model.selectedSourceId ?
            $r('app.color.obs_panel_border') : Color.Transparent)
            /* Desktop right-click parity: long-press opens the menu
             * (2in1 pointer devices also get contextmenu via onRightClick
             * where the shell delivers it). */
            .gesture(LongPressGesture().onAction(() => {
              this.menuSource = source;
              this.menuOpen = true;
            }))
          }
        }, (source: SourceItemModel) => source.id)
      }
      .width('100%')
      /* FIXED 3-row height (46px rows): inside the dock's Scroll wrapper
       * layoutWeight collapses to zero and the rows clipped away (device
       * 10-14). A fixed box the List scrolls within is deterministic at
       * every window height. */
      .height(140)
      .scrollBar(BarState.Auto)
      /* Per-source settings sheet lives on its own node: a second bindSheet
       * on the same node silently overrides the first (10-06 lesson). */
      .bindSheet($$this.sheetOpen,
        this.SettingsSheet(),
        {
          height: SheetSize.MEDIUM,
          dragBar: true,
          showClose: false,
          backgroundColor: $r('app.color.obs_background'),
          onDisappear: () => {
            this.stopMediaPoll();
          }
        })

      if (this.model.selectedSceneId === '') {
        Text($r('app.string.select_scene_first'))
          .fontSize(11)
          .fontColor($r('app.color.obs_text_secondary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ bottom: 4 })
      }
    }
    .width('100%')
    /* Natural height (header + add-buttons + the fixed-height list): the
     * dock wraps this panel in a Scroll, where layoutWeight collapses to
     * zero and clip() then hid the rows entirely (device 10-14). */
    .padding(8)
    .alignItems(HorizontalAlign.Start)
    // W3 C6: drop intake — images dragged from the file manager / gallery
    // (or off a phone's screen bezel) land as sources in this scene. The
    // predicate paints correct OS feedback for unsupported payloads.
    .allowDrop(DragDropReceiver.allowedTypes())
    .onDrop((event: DragEvent) => {
      const data = event.getData();
      if (data !== null && data !== undefined) {
        DragDropReceiver.handleDrop(data);
      }
    })
    /* Rename dialog: its own node (see bindSheet rule above). */
    .bindSheet($$this.renameOpen,
      this.RenameSheet(),
      {
        height: SheetSize.FIT_CONTENT,
        dragBar: true,
        showClose: false,
        backgroundColor: $r('app.color.obs_background')
      })
    .bindSheet($$this.textSheetOpen,
      this.TextSourceSheet(),
      {
        height: SheetSize.MEDIUM,
        dragBar: true,
        showClose: false,
        backgroundColor: $r('app.color.obs_background')
      })
  }
}
