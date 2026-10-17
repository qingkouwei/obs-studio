import { promptAction } from '@kit.ArkUI';
import { media } from '@kit.MediaKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../common/Logger';
import { ObsAppState, ObsController, RecordingEntry } from '../model/ObsModel';

/**
 * WorksPanel — the recordings browser (user request 10-15).
 *
 * Lists every finished recording (recording-<ts>.mp4) in the app sandbox
 * with size + date, newest first, three actions per row:
 *   预览  → sheet flips into an inline player (XComponent + AVPlayer)
 *   导出  → system album via the photoAccessHelper consent dialog
 *   删除  → confirm dialog, then unlink
 *
 * The file a LIVE recording is writing never appears; the list refreshes
 * on open and after every mutation.
 */
@ComponentV2
export struct WorksPanel {
  @Param @Require model: ObsAppState;
  @Event onVisibleChange: (v: boolean) => void = (v: boolean) => {};
  @Local entries: RecordingEntry[] = [];
  /** Sandbox path of the row currently playing ('' = list mode). */
  @Local playingPath: string = '';
  @Local playerError: string = '';

  aboutToAppear(): void {
    this.refresh();
  }

  private refresh(): void {
    this.entries = ObsController.listRecordings();
  }

  private formatSize(bytes: number): string {
    if (bytes >= 1024 * 1024) {
      return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
    }
    return `${(bytes / 1024).toFixed(0)} KB`;
  }

  private formatDate(ms: number): string {
    const d = new Date(ms);
    const pad = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ` +
      `${pad(d.getHours())}:${pad(d.getMinutes())}`;
  }

  /** recording-<ms>.mp4 → 录制 <date>; legacy names pass through. */
  private titleOf(e: RecordingEntry): string {
    const m = /recording-(\d+)\.mp4$/.exec(e.name);
    if (m === null) {
      return e.name;
    }
    return `录制 ${this.formatDate(Number.parseInt(m[1], 10))}`;
  }

  private async exportOne(e: RecordingEntry): Promise<void> {
    await ObsController.exportRecordingToAlbum(e.path);
  }

  private async deleteOne(e: RecordingEntry): Promise<void> {
    const result = await promptAction.showDialog({
      title: '删除录制',
      message: `确定删除「${this.titleOf(e)}」？此操作不可恢复。`,
      buttons: [
        { text: '取消', color: '#9AA0A6' },
        { text: '删除', color: '#E5484D' }
      ]
    } as promptAction.ShowDialogOptions);
    if (result.index === 1) {
      if (this.playingPath === e.path) {
        this.playingPath = '';
      }
      ObsController.deleteRecording(e.path);
      this.refresh();
    }
  }

  @Builder
  ActionButton(label: Resource, color: string, bg: ResourceColor, handler: () => void) {
    Button(label)
      .type(ButtonType.Normal)
      .fontSize(12)
      .height(26)
      .fontColor(color)
      .backgroundColor(bg)
      .borderRadius(4)
      .onClick(() => {
        handler();
      })
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Text($r('app.string.works_title'))
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.obs_text_primary'))
        Blank()
        if (this.playingPath !== '') {
          this.ActionButton($r('app.string.works_back'), '#FFFFFF', $r('app.color.obs_panel_border'), (): void => {
            this.playingPath = '';
            this.playerError = '';
          })
        }
        Button($r('app.string.works_close'))
          .type(ButtonType.Normal)
          .fontSize(12)
          .height(28)
          .fontColor($r('app.color.obs_text_primary'))
          .backgroundColor($r('app.color.obs_accent'))
          .borderRadius(4)
          .onClick(() => {
            this.onVisibleChange(false);
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 10 })

      if (this.playingPath !== '') {
        Stack({ alignContent: Alignment.Center }) {
          VideoSurface({
            path: this.playingPath,
            onError: (msg: string) => {
              this.playerError = msg;
            }
          })
            .width('100%')
            .height('100%')
          if (this.playerError !== '') {
            Text(this.playerError)
              .fontSize(13)
              .fontColor('#E5484D')
              .padding(12)
          }
        }
        .layoutWeight(1)
        .width('100%')
        .backgroundColor(Color.Black)
        .margin({ left: 16, right: 16, bottom: 16 })
        .borderRadius(6)
        .clip(true)
      } else if (this.entries.length === 0) {
        Column() {
          Text($r('app.string.works_empty'))
            .fontSize(13)
            .fontColor($r('app.color.obs_text_secondary'))
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 8 }) {
          ForEach(this.entries, (e: RecordingEntry) => {
            ListItem() {
              Row({ space: 8 }) {
                Column({ space: 2 }) {
                  Text(this.titleOf(e))
                    .fontSize(13)
                    .fontColor($r('app.color.obs_text_primary'))
                  Text(`${this.formatDate(e.mtimeMs)} · ${this.formatSize(e.size)}`)
                    .fontSize(11)
                    .fontColor($r('app.color.obs_text_secondary'))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                this.ActionButton($r('app.string.works_play'), '#FFFFFF', $r('app.color.obs_panel_border'),
                  (): void => {
                    this.playerError = '';
                    this.playingPath = e.path;
                  })
                this.ActionButton($r('app.string.works_export'), '#FFFFFF', $r('app.color.obs_panel_border'),
                  (): void => {
                    this.exportOne(e);
                  })
                this.ActionButton($r('app.string.works_delete'), '#E5484D', $r('app.color.obs_panel_border'),
                  (): void => {
                    this.deleteOne(e);
                  })
              }
              .width('100%')
              .padding(10)
              .backgroundColor($r('app.color.obs_panel'))
              .borderRadius(6)
            }
          }, (e: RecordingEntry) => e.path)
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 16 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.obs_background'))
  }
}

/**
 * VideoSurface — XComponent surface + AVPlayer for one sandbox file.
 * The player is created after the surface exists (onLoad) and driven by
 * the state machine: url set → initialized → prepare → prepared → play
 * (autoPlay); completed loops back to 0. Teardown on disappear.
 */
@ComponentV2
struct VideoSurface {
  @Param @Require path: string;
  @Event onError: (msg: string) => void = (msg: string) => {};
  private xController: XComponentController = new XComponentController();
  private player: media.AVPlayer | null = null;
  private fd: number = -1;
  private released: boolean = false;

  aboutToDisappear(): void {
    this.teardown();
  }

  private teardown(): void {
    this.released = true;
    if (this.player !== null) {
      const p = this.player;
      this.player = null;
      p.release().catch((err: Error) => {
        Logger.warn(`AVPlayer release: ${err.message}`);
      });
    }
    if (this.fd >= 0) {
      try {
        fileIo.closeSync(this.fd);
      } catch (err) {
        // already closed
      }
      this.fd = -1;
    }
  }

  private async start(surfaceId: string): Promise<void> {
    try {
      const f = fileIo.openSync(this.path, fileIo.OpenMode.READ_ONLY);
      this.fd = f.fd;
      const stat = fileIo.statSync(this.path);
      const p = await media.createAVPlayer();
      if (this.released) {
        p.release().catch((err: Error) => Logger.warn(`release race: ${err.message}`));
        return;
      }
      this.player = p;
      p.on('stateChange', (state: string) => {
        if (state === 'initialized') {
          p.surfaceId = surfaceId;
          p.prepare().catch((err: Error) => this.onError(err.message));
        } else if (state === 'prepared') {
          p.play().catch((err: Error) => this.onError(err.message));
        } else if (state === 'completed') {
          // seek() is void on this SDK; play() restarts from the head.
          p.seek(0);
          p.play().catch((err: Error) => this.onError(err.message));
        }
      });
      p.on('error', (err: BusinessError) => {
        Logger.error(`AVPlayer error ${err.code} ${err.message}`);
        this.onError(`播放错误 ${err.code}`);
      });
      p.url = `fd://${this.fd}?offset=0&size=${stat.size}`;
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(`video open failed: ${e.code} ${e.message}`);
      this.onError(`打开失败 ${e.code}`);
    }
  }

  build() {
    XComponent({ id: 'works-video-surface', type: XComponentType.SURFACE, controller: this.xController })
      .onLoad(() => {
        this.start(this.xController.getXComponentSurfaceId());
      })
      .width('100%')
      .height('100%')
  }
}
