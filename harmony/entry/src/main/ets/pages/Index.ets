import { common, bundleManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ObsAppState, ObsController } from '../model/ObsModel';
import { Logger } from '../common/Logger';
import { RawFileExtractor } from '../common/RawFileExtractor';
import { PreviewCanvas } from '../components/PreviewCanvas';
import { SceneList } from '../components/SceneList';
import { SourceList } from '../components/SourceList';
import { FilterPanel } from '../components/FilterPanel';
import { AudioMixer } from '../components/AudioMixer';
import { TransportBar } from '../components/TransportBar';

/**
 * Version stamp for the rawfile extraction cache. Bumping the bundle's
 * versionCode invalidates a previously extracted asset tree, so an app upgrade
 * that ships new .effect shaders or locale files cannot be shadowed by stale
 * copies left in filesDir. ASSET_STAMP covers dev-time rawfile changes that
 * do not bump versionCode (e.g. staging a plugin's data/ directory).
 */
const ASSET_STAMP = 'obs-plugins-data-v2';

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
  private levelTimerId: number = -1;

  aboutToAppear(): void {
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

    try {
      const mediaQuery = this.getUIContext().getMediaQuery().matchMediaSync('(1200vp<=width)');
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
    // Note: no ObsBridge.shutdown() here — EntryAbility.onDestroy owns core
    // teardown so page reloads never kill a live broadcast.
  }

  @Builder
  TopBar() {
    Row({ space: 12 }) {
      Text('OBS Studio')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.obs_text_primary'))
      Text(this.model.coreReady ? $r('app.string.core_ready') : $r('app.string.core_shell'))
        .fontSize(11)
        .fontColor(this.model.coreReady ?
        $r('app.color.obs_meter_ok') : $r('app.color.obs_meter_warn'))
      Blank()
      Text($r('app.string.app_subtitle'))
        .fontSize(11)
        .fontColor($r('app.color.obs_text_secondary'))
    }
    .width('100%')
    .height(44)
    .padding({ left: 12, right: 12 })
  }

  @Builder
  SideDocks() {
    Column() {
      Column() {
        SceneList({ model: this.model })
      }
      .layoutWeight(1)
      .width('100%')
      .backgroundColor($r('app.color.obs_panel'))
      .borderRadius(6)

      Column() {
        SourceList({ model: this.model })
        FilterPanel({ model: this.model })
      }
      .layoutWeight(1)
      .width('100%')
      .margin({ top: 8 })
      .backgroundColor($r('app.color.obs_panel'))
      .borderRadius(6)
    }
    .width(this.isLargeScreen ? 320 : '100%')
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
    Column() {
      this.TopBar()
      this.NoticeBanner()

      if (this.isLargeScreen) {
        Row({ space: 8 }) {
          Column() {
            PreviewCanvas({ xcomponentId: 'obs-preview-canvas' })
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
              PreviewCanvas({ xcomponentId: 'obs-preview-canvas' })
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
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.obs_background'))
  }
}
