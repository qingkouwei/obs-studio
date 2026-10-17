import { common, bundleManager } from '@kit.AbilityKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { KeyCode } from '@kit.InputKit';
import { ObsAppState, ObsController } from '../model/ObsModel';
import { Logger } from '../common/Logger';
import { RawFileExtractor } from '../common/RawFileExtractor';
import { PreviewCanvas } from '../components/PreviewCanvas';
import { SceneList } from '../components/SceneList';
import { SourceList } from '../components/SourceList';
import { FilterPanel } from '../components/FilterPanel';
import { TransitionPanel } from '../components/TransitionPanel';
import { AudioMixer } from '../components/AudioMixer';
import { TransportBar } from '../components/TransportBar';
import { SettingsPanel } from '../components/SettingsPanel';
import { WorksPanel } from '../components/WorksPanel';
import { CameraRolePage } from './CameraRolePage';
import { WebFeedHost } from '../common/WebFeedHost';
import { ProgramFeedServer } from '../common/ProgramFeedServer';

/**
 * Version stamp for the rawfile extraction cache. Bumping the bundle's
 * versionCode invalidates a previously extracted asset tree, so an app upgrade
 * that ships new .effect shaders or locale files cannot be shadowed by stale
 * copies left in filesDir. ASSET_STAMP covers dev-time rawfile changes that
 * do not bump versionCode (e.g. staging a plugin's data/ directory).
 */
const ASSET_STAMP = 'obs-plugins-data-v3';

function resolveBundleVersion(): string {
  try {
    const info = bundleManager.getBundleInfoForSelfSync(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
    return `${info.versionCode}-${ASSET_STAMP}`;
  } catch (err) {
    const e = err as BusinessError;
    Logger.warn(`could not read bundle versionCode (${e.code}); extracting unconditionally`);
    return '';
  }
}

/**
 * Index — the main OBS window for HarmonyOS PC (2in1).
 *
 * Desktop layout (large breakpoint, the norm on PC):
 *
 *   +-----------------------------------------------------------+
 *   | top bar: title · core status · bridge notices             |
 *   +----------------------------------------------+------------+
 *   | program/preview canvas (XComponent SURFACE)  | Scenes     |
 *   |                                              +------------+
 *   |                                              | Sources    |
 *   +----------------------------------------------+------------+
 *   | transport: RTMP target · Start/Stop · bitrate/drop/uptime |
 *   +-----------------------------------------------------------+
 *   | audio mixer: per-track meters, faders, mute                 |
 *   +-----------------------------------------------------------+
 *
 * Below the 1200vp breakpoint (narrow floating window / split view) the side
 * docks move under the canvas instead of beside it.
 */
@Entry
@ComponentV2
struct Index {
  @Local model: ObsAppState = ObsAppState.getInstance();
  @Local isLargeScreen: boolean = true;
  @Local settingsShown: boolean = false;
  /** Works (recordings) browser sheet. Its bindSheet lives on the TopBar
   * Row, NOT the main Column — two bindSheets on one node silently keep
   * only the last (10-06 lesson). */
  @Local worksShown: boolean = false;
  /** Right-dock width (vp), drag the handle between canvas and dock to
   * resize — user report 10-12: fixed 320 squeezed the sources/filters
   * stack while the mostly-empty scenes box hogged half the height. */
  @Local dockWidth: number = 360;
  /** Scenes-box height inside the dock; the sources stack takes the rest.
   * Draggable via the ⋯ handle between the two (10-12 user report). */
  @Local sceneDockH: number = 150;
  /** sceneDockH at the start of the current ⋯-handle pan (offsetY anchor). */
  private sceneDockH0: number = 150;
  /** Keyboard modifier edges tracked for the shortcut chords (see onKeyEvent). */
  @Local shiftHeld: boolean = false;
  @Local ctrlHeld: boolean = false;
  /** W3-C1 role fork: phones never boot the OBS core — they run the thin
   * wireless-camera role page instead. PC / 2in1 / tablet = producer. */
  @Local isProducer: boolean = true;
  private levelTimerId: number = -1;

  aboutToAppear(): void {
    try {
      this.isProducer = deviceInfo.deviceType !== 'phone';
    } catch (err) {
      Logger.warn('deviceType probe failed, defaulting to producer role');
    }
    if (!this.isProducer) {
      return;
    }
    let filesDir = '';
    let codeDir = '';
    let dataDir = '';
    try {
      const hostContext = this.getUIContext().getHostContext();
      if (hostContext !== undefined) {
        const ctx = hostContext as common.UIAbilityContext;
        filesDir = ctx.filesDir;
        // Native libraries are extracted here because module.json5 sets
        // extractNativeLibs: true. libobs dlopens its plugins by path, so this
        // directory — not filesDir — is the module search path.
        codeDir = `${ctx.bundleCodeDir}/libs/arm64-v8a`;
        dataDir = `${filesDir}/obsdata`;

        // Must happen before nativeInit: obs_reset_video() loads libobs's
        // .effect shaders through find_libobs_data_file(), which does a plain
        // filesystem lookup. rawfile has no filesystem path, so the assets have
        // to be materialised here first.
        RawFileExtractor.extract(ctx.resourceManager, dataDir, resolveBundleVersion());
      }
    } catch (err) {
      Logger.error('could not resolve app paths from UIContext', Logger.asError(err as Object));
    }

    // Start the native core (shell-only build: audio + surface seam only),
    // probe system-audio support honestly, install the push-mode stats
    // callback, and start polling level meters (meters are pull by design;
    // stats are push).
    ObsController.initialize(filesDir, codeDir, dataDir,
      this.getUIContext().getHostContext()!.resourceManager.getStringSync($r('app.string.scene_default').id),
      this.getUIContext().getHostContext() as common.UIAbilityContext);
    ObsController.installStatsCallback();
    this.levelTimerId = setInterval(() => {
      ObsController.pollLevels();
    }, 200);

    // W3-C4 monitor leg: serve the program picture to the phone console
    // (snapshot→JPEG→TCP, pure ArkTS; idles until a phone connects).
    ProgramFeedServer.init(this.getUIContext());

    try {
      // Breakpoint forensics 10-03: the 2in1 restores this window at
      // ~2090 px ≈ 1045 vp. The stock 1200 vp desktop breakpoint therefore
      // flipped the console into the stacked layout on every cold start
      // (dock hidden under the canvas → "the right panel is gone"). 900 vp
      // keeps the desktop layout for any realistic 2in1 window while
      // phones/split views still stack.
      const mediaQuery = this.getUIContext().getMediaQuery().matchMediaSync('(900vp<=width)');
      this.isLargeScreen = mediaQuery.matches;
      mediaQuery.on('change', (result) => {
        this.isLargeScreen = result.matches;
      });
    } catch (err) {
      Logger.warn(`media query unavailable: ${Logger.asError(err as Object).message}`);
    }
  }

  aboutToDisappear(): void {
    if (this.levelTimerId >= 0) {
      clearInterval(this.levelTimerId);
      this.levelTimerId = -1;
    }
    // Stop serving the program picture when the producer window goes away
    // (the snapshot target no longer exists).
    ProgramFeedServer.shutdown();
    // Note: no ObsBridge.shutdown() here — EntryAbility.onDestroy owns core
    // teardown so page reloads never kill a live broadcast.
  }

  @Builder
  TopBar() {
    Row({ space: 12 }) {
      Text('轻录')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.obs_text_primary'))
      Text(this.model.coreReady ? $r('app.string.core_ready') : $r('app.string.core_shell'))
        .fontSize(11)
        .fontColor(this.model.coreReady ?
        $r('app.color.obs_meter_ok') : $r('app.color.obs_meter_warn'))
      Blank()
      Button($r('app.string.works_title'))
        .type(ButtonType.Normal)
        .fontSize(12)
        .height(28)
        .fontColor($r('app.color.obs_text_primary'))
        .backgroundColor($r('app.color.obs_panel_border'))
        .borderRadius(4)
        .onClick(() => {
          this.worksShown = true;
        })
      Button($r('app.string.studio_toggle'))
        .type(ButtonType.Normal)
        .fontSize(12)
        .height(28)
        .fontColor($r('app.color.obs_text_primary'))
        .backgroundColor(this.model.studioMode ?
        $r('app.color.obs_accent') : $r('app.color.obs_panel_border'))
        .borderRadius(4)
        .enabled(this.model.coreReady)
        .onClick(() => {
          ObsController.toggleStudioMode();
        })
      Button($r('app.string.settings_title'))
        .type(ButtonType.Normal)
        .fontSize(12)
        .height(28)
        .fontColor($r('app.color.obs_text_primary'))
        .backgroundColor($r('app.color.obs_panel_border'))
        .borderRadius(4)
        .onClick(() => {
          this.settingsShown = true;
        })
      Text($r('app.string.app_subtitle'))
        .fontSize(11)
        .fontColor($r('app.color.obs_text_secondary'))
    }
    .width('100%')
    .height(44)
    .padding({ left: 12, right: 12 })
    /* Works browser sheet — mounted HERE (the TopBar row) rather than on
     * the main Column so it never collides with the settings sheet:
     * ArkUI keeps only the last bindSheet on a given node (10-06). */
    .bindSheet($$this.worksShown,
      this.WorksSheet(),
      {
        height: this.isLargeScreen ? '85%' : SheetSize.MEDIUM,
        width: this.isLargeScreen ? 760 : '100%',
        dragBar: true,
        showClose: false,
        backgroundColor: $r('app.color.obs_background')
      })
  }

  @Builder
  WorksSheet() {
    WorksPanel({
      model: this.model,
      onVisibleChange: (v: boolean) => {
        this.worksShown = v;
      }
    })
  }

  @Builder
  SideDocks() {
    Column() {
      // Scenes: fixed-ish height (a scene list rarely needs more than half a
      // screen). It used to share layoutWeight(1) 50/50 with the sources
      // stack, which left the crowded sources+filters+transitions column
      // clipped — user report 10-12.
      Column() {
        SceneList({ model: this.model })
      }
      .height(this.sceneDockH)
      .width('100%')
      .backgroundColor($r('app.color.obs_panel'))
      .borderRadius(6)

      // Drag handle: resize the scenes/sources split.
      Row() {
        Text('⋯')
          .fontSize(11)
          .fontColor($r('app.color.obs_text_secondary'))
      }
      .width('100%')
      .height(20)
      .justifyContent(FlexAlign.Center)
      .gesture(
        PanGesture({ direction: PanDirection.Vertical })
          .onActionStart(() => {
            this.sceneDockH0 = this.sceneDockH;
          })
          .onActionUpdate((e: GestureEvent) => {
            /* offsetY is CUMULATIVE from the gesture start — the old code
             * added it to the current height every callback, which
             * compounded and made the handle race away from the finger
             * (user report 10-13 #2). Anchor on the start height instead. */
            const next = this.sceneDockH0 + e.offsetY;
            if (next > 60 && next < 520) {
              this.sceneDockH = next;
            }
          })
      )

      // Sources / filters / transitions stack. NO Scroll wrapper: it
      // swallowed the source-row onClick (selection never set, so the
      // header 删除 stayed disabled and deletes "did nothing" — device
      // probe 10-14), while child buttons still worked. The row-2-hidden
      // problem is solved by the List's 3-row floor instead; in short
      // windows the stacked (<1200vp) layout already scrolls everything.
      // Sources / filters / transitions stack. In short floating windows the
      // three panels' natural heights exceed the column, so the whole stack
      // scrolls (the earlier "Scroll swallows clicks" attribution was wrong:
      // the dead clicks were the selection chain, fixed by making the row
      // name a Button; child Buttons inside a Scroll are empirically
      // clickable — the ↑↓ arrows worked while the wrapper was present).
      Scroll() {
        Column() {
          SourceList({ model: this.model })
          FilterPanel({ model: this.model })
          TransitionPanel({ model: this.model })
        }
        .width('100%')
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Auto)
      .align(Alignment.Top)
    }
    .width(this.isLargeScreen ? this.dockWidth : '100%')
    .height(this.isLargeScreen ? '100%' : 400)
  }

  @Builder
  NoticeBanner() {
    if (this.model.bridgeNotice !== null) {
      Row() {
        Text(this.model.bridgeNotice)
          .fontSize(11)
          .fontColor($r('app.color.obs_meter_warn'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text($r('app.string.dismiss'))
          .fontSize(11)
          .fontColor($r('app.color.obs_text_secondary'))
          .onClick(() => {
            this.model.bridgeNotice = null;
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 4, bottom: 4 })
      .backgroundColor('#2A2417')
    }
  }

  build() {
    if (!this.isProducer) {
      CameraRolePage()
    } else {
    Column() {
      this.TopBar()
      this.NoticeBanner()

      if (this.isLargeScreen) {
        Row({ space: 8 }) {
          Column() {
            if (this.model.studioMode) {
              // Studio: preview (left) + program (right), desktop order. The
              // main canvas (obs-preview-canvas, channel 0) IS the program
              // and keeps the gesture overlay; the second display renders
              // the private preview canvas. Take/Cut bar sits under them.
              Row({ space: 6 }) {
                Column() {
                  Text($r('app.string.studio_preview_label'))
                    .fontSize(11)
                    .fontColor($r('app.color.obs_text_secondary'))
                    .width('100%')
                  PreviewCanvas({ xcomponentId: 'obs-studio-preview-canvas', studioPreview: true })
                }
                .layoutWeight(1)
                .height('100%')

                Column() {
                  Text($r('app.string.studio_program_label'))
                    .fontSize(11)
                    .fontColor($r('app.color.obs_meter_ok'))
                    .width('100%')
                  PreviewCanvas({ xcomponentId: 'obs-preview-canvas', model: this.model })
                }
                .layoutWeight(1)
                .height('100%')
              }
              .width('100%')
              .layoutWeight(1)

              Row({ space: 8 }) {
                Button($r('app.string.studio_take'))
                  .type(ButtonType.Normal)
                  .fontSize(13)
                  .height(32)
                  .layoutWeight(1)
                  .fontColor($r('app.color.obs_text_primary'))
                  .backgroundColor('#2f6f3e')
                  .borderRadius(4)
                  .onClick(() => {
                    ObsController.takeScene();
                  })
                Button($r('app.string.studio_cut'))
                  .type(ButtonType.Normal)
                  .fontSize(13)
                  .height(32)
                  .layoutWeight(1)
                  .fontColor($r('app.color.obs_text_primary'))
                  .backgroundColor($r('app.color.obs_panel_border'))
                  .borderRadius(4)
                  .onClick(() => {
                    ObsController.cutScene();
                  })
              }
              .width('100%')
              .padding({ top: 6 })
            } else {
              PreviewCanvas({ xcomponentId: 'obs-preview-canvas', model: this.model })
            }
          }
          .layoutWeight(1)
          .height('100%')
          .constraintSize({ minHeight: 260 })

          this.SideDocks()
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 12, right: 12 })
        .alignItems(VerticalAlign.Top)
      } else {
        // Stacked layout (window < 1200vp, e.g. not maximized). The fixed
        // heights below sum to more than a small window, so the whole region
        // scrolls — otherwise the sources/filter panel is clipped out of
        // reach and no source can be added. Preview keeps a usable fixed
        // height rather than being squeezed to a sliver.
        Scroll() {
          Column({ space: 8 }) {
            Column() {
              PreviewCanvas({ xcomponentId: 'obs-preview-canvas', model: this.model })
            }
            .width('100%')
            .height(200)

            this.SideDocks()
          }
          .width('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .align(Alignment.Top)
        .padding({ left: 12, right: 12 })
      }

      Column() {
        TransportBar({ model: this.model })
      }
      .width('100%')
      .backgroundColor($r('app.color.obs_panel'))

      Column() {
        AudioMixer({ model: this.model })
      }
      .width('100%')
      .height(140)
      .backgroundColor($r('app.color.obs_panel'))
      .border({ width: { top: 1 }, color: $r('app.color.obs_panel_border') })

      // Off-screen Web nodes + snapshot pumps backing every browser source
      // (harmony-web). 0x0 + clipped: mounted in the tree so their children
      // are snapshot-able, invisible in the layout. See WebFeedHost.ets.
      WebFeedHost()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.obs_background'))
    /* Keyboard shortcuts (PC form factor — MatePad Edge keyboard cover).
     * Numbers switch program scenes (desktop parity), Ctrl+R toggles
     * recording, Ctrl+F toggles streaming, arrows nudge the selected source
     * (Shift = 10 px), Delete removes it. ArkUI dispatches key events to the
     * focused node first and a focused TextInput consumes character/arrow
     * keys, so these chords only fire when no field has focus. Ctrl/Shift
     * are tracked from their own Down/Up edges (KeyEvent carries no modifier
     * state — metaKey is the Win key only). */
    .onKeyEvent((event: KeyEvent) => {
      const code: number = event.keyCode;
      const down = event.type === KeyType.Down;
      if (code === KeyCode.KEYCODE_SHIFT_LEFT || code === KeyCode.KEYCODE_SHIFT_RIGHT) {
        this.shiftHeld = down;
        return false;
      }
      if (code === KeyCode.KEYCODE_CTRL_LEFT || code === KeyCode.KEYCODE_CTRL_RIGHT) {
        this.ctrlHeld = down;
        return false;
      }
      if (!down) {
        return false;
      }
      if (this.ctrlHeld && code === KeyCode.KEYCODE_R) {
        ObsController.toggleRecording();
        return true;
      }
      if (this.ctrlHeld && code === KeyCode.KEYCODE_F) {
        ObsController.toggleStreaming();
        return true;
      }
      if (code >= KeyCode.KEYCODE_1 && code <= KeyCode.KEYCODE_9) {
        const idx = code - KeyCode.KEYCODE_1;
        if (idx < this.model.scenes.length) {
          ObsController.selectScene(this.model.scenes[idx].id);
          return true;
        }
        return false;
      }
      const step: number = this.shiftHeld ? 10 : 1;
      switch (code) {
        case KeyCode.KEYCODE_DPAD_UP:
          ObsController.nudgeSelectedSource(0, -step);
          return true;
        case KeyCode.KEYCODE_DPAD_DOWN:
          ObsController.nudgeSelectedSource(0, step);
          return true;
        case KeyCode.KEYCODE_DPAD_LEFT:
          ObsController.nudgeSelectedSource(-step, 0);
          return true;
        case KeyCode.KEYCODE_DPAD_RIGHT:
          ObsController.nudgeSelectedSource(step, 0);
          return true;
        case KeyCode.KEYCODE_FORWARD_DEL:
        case KeyCode.KEYCODE_DEL:
          if (this.model.selectedSourceId !== '') {
            ObsController.removeSelectedSource();
            return true;
          }
          return false;
        default:
          return false;
      }
    })
    .bindSheet($$this.settingsShown,
      this.SettingsSheet(),
      {
        /* PC dialog semantics (user report 10-12): MEDIUM rendered a short
         * centered card whose content collided with the ✕ and pushed the
         * save button out of view — give it a real dialog size.
         * showClose OFF (10-13 #3/#4): the system ✕ is a dim grey glyph
         * that sat right on top of the 快捷键 tab; the bottom blue
         * 保存并关闭 button is the primary affordance, tap-outside also
         * dismisses. */
        height: this.isLargeScreen ? '85%' : SheetSize.MEDIUM,
        width: this.isLargeScreen ? 760 : '100%',
        dragBar: true,
        showClose: false,
        backgroundColor: $r('app.color.obs_background')
      })
    }
  }

  @Builder
  SettingsSheet() {
    SettingsPanel({
      model: this.model,
      onVisibleChange: (v: boolean) => {
        this.settingsShown = v;
      }
    })
  }
}
