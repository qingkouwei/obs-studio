import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { ObsBridge } from '../napi/obsBridge';
import { SettingsStore } from '../common/SettingsStore';
import { DirectorPanel } from '../components/DirectorPanel';
import { ProgramFeedClient, FeedState } from '../common/ProgramFeedClient';
import { JPGM_DEFAULT_PORT } from '../common/JpgmProtocol';
import { MobileTheme as MT } from '../common/MobileTheme';
import { Logger } from '../common/Logger';

/**
 * CameraRolePage — the phone-side director console for W3-C1/C4.
 *
 * The phone is the producer's lens and remote (user-approved 10-04; layout
 * reworked 10-17 after the user pointed out the old form-stack read like a
 * demo rather than an extension of the PC app). Three layers, top to bottom,
 * mirroring a real monitor-and-switch desk:
 *   1. PROGRAM MONITOR — the producer's live picture, streamed back over the
 *      JPGM socket (ProgramFeedClient). This is what makes the console
 *      "see what you cut": no more blind button tapping.
 *   2. DIRECTOR — connect to the producer over the collaboration channel,
 *      then cut scenes and toggle record/stream (DirectorPanel).
 *   3. WIRELESS CAMERA — a collapsible card: this device's own camera can be
 *      pushed into the producer as a source (native camera_sender).
 *
 * Visual language (contrast rework 10-17): every colour comes from
 * MobileTheme — text ≥7:1 on its surface, saturated action fills under
 * white labels, three surface steps so cards read without hairlines.
 *
 * The monitor and the camera both point at the producer's LAN IP (typed once
 * here, persisted for one-tap re-arming). libobs is never started on the
 * phone: it is a thin peripheral, so the process stays light.
 */

/** Defaults match the receiver plugin (RCTM_DEFAULT_PORT). */
const DEFAULT_PORT: string = '25890';
const DEFAULT_BITRATE: number = 3000;

@ComponentV2
export struct CameraRolePage {
  // Producer address (shared by monitor + camera).
  @Local host: string = '';
  @Local port: string = DEFAULT_PORT;
  // Wireless-camera sender state.
  @Local camStatusText: string = '待机';
  @Local camStreaming: boolean = false;
  @Local camExpanded: boolean = false;
  // Program monitor state.
  @Local monitorPm: image.PixelMap | undefined = undefined;
  @Local monitorState: FeedState = 'idle';
  @Local monitorInfo: string = '';
  @Local monitorSize: string = '';
  private pollTimerId: number = -1;

  aboutToAppear(): void {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      // Pre-fill the last used producer address so re-arming is one tap.
      SettingsStore.loadCamfeedHost(ctx).then((saved: string) => {
        if (saved.length > 0) {
          this.host = saved;
        }
      });
    } catch (err) {
      Logger.error('CameraRolePage init failed', Logger.asError(err as Object));
    }

    // Monitor callbacks. Each frame hands over a fresh PixelMap; release the
    // previous one so decodes do not accumulate GPU buffers.
    ProgramFeedClient.onFrame = (pm: image.PixelMap | undefined, info: string): void => {
      const old = this.monitorPm;
      this.monitorPm = pm;
      if (old !== undefined) {
        old.release();
      }
      this.monitorSize = info;
    };
    ProgramFeedClient.onState = (state: FeedState, message: string): void => {
      this.monitorState = state;
      this.monitorInfo = message;
      if (state === 'idle' || state === 'error') {
        const old = this.monitorPm;
        this.monitorPm = undefined;
        if (old !== undefined) {
          old.release();
        }
      }
    };

    this.pollTimerId = setInterval(() => {
      const st = ObsBridge.cameraSenderStatus();
      if (st === undefined) return;
      this.camStreaming = st.running === 1;
      if (st.running === 1 && st.connected === 1) {
        this.camStatusText = `正在向 ${st.host} 推流`;
      } else if (st.running === 1 && st.reconnecting === 1) {
        this.camStatusText = `连接中断，自动重连中（第 ${st.retry} 次）…`;
      } else if (st.running === 1) {
        this.camStatusText = '连接中…';
      } else if (st.failed === 1) {
        this.camStatusText = '连接失败：请确认制作端「无线机位」源仍在监听';
      } else {
        this.camStatusText = '待机';
      }
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.pollTimerId >= 0) {
      clearInterval(this.pollTimerId);
      this.pollTimerId = -1;
    }
    if (this.camStreaming) {
      ObsBridge.stopCameraSender();
    }
    ProgramFeedClient.onFrame = null;
    ProgramFeedClient.onState = null;
    ProgramFeedClient.disconnect('page hide');
    const pm = this.monitorPm;
    if (pm !== undefined) {
      pm.release();
    }
    this.monitorPm = undefined;
  }

  private trimmedHost(): string {
    return this.host.trim();
  }

  private startMonitor(): void {
    const host = this.trimmedHost();
    if (host.length === 0) {
      this.monitorState = 'error';
      this.monitorInfo = '请先填写制作端 IP';
      return;
    }
    this.saveHost(host);
    ProgramFeedClient.connect(host, JPGM_DEFAULT_PORT);
  }

  private stopMonitor(): void {
    ProgramFeedClient.disconnect('user stop');
  }

  private startFeed(): void {
    const host = this.trimmedHost();
    if (host.length === 0) {
      this.camStatusText = '请先填写制作端 IP';
      return;
    }
    const port = parseInt(this.port, 10);
    if (isNaN(port) || port <= 0 || port >= 65536) {
      this.camStatusText = '端口无效';
      return;
    }
    const error = ObsBridge.startCameraSender(host, port, DEFAULT_BITRATE);
    if (error !== undefined) {
      this.camStatusText = `启动失败：${error}`;
      return;
    }
    this.saveHost(host);
    this.camStatusText = `正在向 ${host}:${port} 推流`;
    this.camStreaming = true;
  }

  private stopFeed(): void {
    ObsBridge.stopCameraSender();
    this.camStreaming = false;
    this.camStatusText = '待机';
  }

  private saveHost(host: string): void {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      SettingsStore.saveCamfeedHost(ctx, host);
    } catch (err) {
      Logger.warn('saveHost failed');
    }
  }

  private monitorDotColor(): string {
    switch (this.monitorState) {
      case 'connected':
        return MT.ok;
      case 'connecting':
        return MT.warn;
      case 'error':
        return MT.live;
      default:
        return MT.textDim;
    }
  }

  private monitorLabel(): string {
    switch (this.monitorState) {
      case 'connected':
        return `监看中 ${this.monitorSize}`;
      case 'connecting':
        return '连接中…';
      case 'error':
        return '连接失败';
      default:
        return '未连接';
    }
  }

  /** Section header: state light + bold title, the card's visual anchor.
   * NOT width('100%') — the camera card places an 展开 toggle after it via
   * a Blank, which a full-width header would push off-screen. */
  @Builder
  SectionHeader(title: string, dotColor: string) {
    Row({ space: 8 }) {
      Circle({ width: 9, height: 9 }).fill(dotColor)
      Text(title)
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(MT.textStrong)
    }
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        // Title bar ----------------------------------------------------------
        Row({ space: 8 }) {
          Text('轻录')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(MT.textStrong)
          Text('手机导播台')
            .fontSize(12)
            .fontColor(MT.textDim)
          Blank()
          Text(this.monitorLabel())
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.monitorDotColor())
        }
        .width('100%')

        // Producer address ---------------------------------------------------
        Row({ space: 10 }) {
          Text('制作端 IP')
            .fontSize(14)
            .fontColor(MT.text)
          TextInput({ placeholder: '例如 192.168.31.75', text: this.host })
            .fontSize(15)
            .fontColor(MT.textStrong)
            .placeholderColor(MT.textDim)
            .caretColor(MT.blue)
            .backgroundColor(MT.inset)
            .borderRadius(8)
            .border({ width: 1, color: MT.cardBorder })
            .height(44)
            .layoutWeight(1)
            .enabled(this.monitorState !== 'connected' && !this.camStreaming)
            .onChange((v: string) => {
              this.host = v;
            })
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .backgroundColor(MT.card)
        .borderRadius(10)
        .border({ width: 1, color: MT.cardBorder })

        // 1) PROGRAM MONITOR --------------------------------------------------
        Column({ space: 10 }) {
          this.SectionHeader('节目监视', this.monitorDotColor())
          Stack({ alignContent: Alignment.TopStart }) {
            if (this.monitorPm !== undefined) {
              Image(this.monitorPm)
                .objectFit(ImageFit.Contain)
                .width('100%')
                .height('100%')
            } else {
              Column({ space: 8 }) {
                Text(this.monitorState === 'connecting' ? '正在连接制作端…' :
                  (this.monitorState === 'error' ? this.monitorInfo : '等待监看'))
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(MT.text)
                  .textAlign(TextAlign.Center)
                Text(this.monitorState === 'error' ? '' : '点击下方「开始监看」查看制作端画面')
                  .fontSize(12)
                  .fontColor(MT.textDim)
                  .textAlign(TextAlign.Center)
              }
              .width('100%')
              .height('100%')
              .justifyContent(FlexAlign.Center)
            }
            // PGM badge while live
            if (this.monitorState === 'connected') {
              Row({ space: 5 }) {
                Circle({ width: 7, height: 7 }).fill(MT.live)
                Text('PGM')
                  .fontSize(11)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#FFFFFF')
              }
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .backgroundColor(MT.badgeBg)
              .borderRadius(4)
              .margin(8)
            }
          }
          .width('100%')
          .aspectRatio(16 / 9)
          .backgroundColor(MT.inset)
          .borderRadius(8)
          .border({ width: 1, color: MT.cardBorder })
          .clip(true)

          Button(this.monitorState === 'connected' ? '停止监看' : '开始监看')
            .type(ButtonType.Normal)
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .width('100%')
            .height(44)
            .borderRadius(8)
            .backgroundColor(this.monitorState === 'connected' ? MT.red : MT.blue)
            .onClick(() => {
              if (this.monitorState === 'connected') {
                this.stopMonitor();
              } else {
                this.startMonitor();
              }
            })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .backgroundColor(MT.card)
        .borderRadius(10)
        .border({ width: 1, color: MT.cardBorder })

        // 2) DIRECTOR (scene cuts + record/stream) ----------------------------
        DirectorPanel()

        // 3) WIRELESS CAMERA (collapsible) ------------------------------------
        Column({ space: 10 }) {
          Row({ space: 8 }) {
            this.SectionHeader('本机作为无线机位', this.camStreaming ? MT.ok : MT.textDim)
            Blank()
            Text(this.camExpanded ? '收起 ▲' : '展开 ▼')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(MT.blue)
              .padding({ left: 8, top: 4, bottom: 4 })
              .onClick(() => {
                this.camExpanded = !this.camExpanded;
              })
          }
          .width('100%')

          if (this.camExpanded) {
            Text('把本机摄像头实时推入制作端画布（制作端需先添加「无线机位」来源）')
              .fontSize(12)
              .fontColor(MT.textDim)
            Row({ space: 10 }) {
              Text('机位端口')
                .fontSize(14)
                .fontColor(MT.text)
              TextInput({ placeholder: DEFAULT_PORT, text: this.port })
                .type(InputType.Number)
                .fontSize(15)
                .fontColor(MT.textStrong)
                .placeholderColor(MT.textDim)
                .caretColor(MT.blue)
                .backgroundColor(MT.inset)
                .borderRadius(8)
                .border({ width: 1, color: MT.cardBorder })
                .height(44)
                .layoutWeight(1)
                .enabled(!this.camStreaming)
                .onChange((v: string) => {
                  this.port = v;
                })
            }
            .width('100%')

            Button(this.camStreaming ? '停止推流' : '开始推流')
              .type(ButtonType.Normal)
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
              .width('100%')
              .height(44)
              .borderRadius(8)
              .backgroundColor(this.camStreaming ? MT.red : MT.green)
              .onClick(() => {
                if (this.camStreaming) {
                  this.stopFeed();
                } else {
                  this.startFeed();
                }
              })
          }
          Text(this.camStatusText)
            .fontSize(13)
            .fontColor(MT.text)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .backgroundColor(MT.card)
        .borderRadius(10)
        .border({ width: 1, color: MT.cardBorder })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
    .backgroundColor(MT.bg)
  }
}
