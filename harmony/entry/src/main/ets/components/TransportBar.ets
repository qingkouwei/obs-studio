import { ConnectionState, ObsAppState, ObsController } from '../model/ObsModel';

/**
 * TransportBar — Start/Stop Streaming + Start/Stop Recording with the live
 * readout (bitrate, dropped/total frames, uptime) fed by the push-mode stats
 * callback from the native output thread (no UI polling for stats).
 *
 * Also hosts the minimal RTMP target inputs (server + key) that feed
 * nativeStartStreaming(configJson). A full settings dialog replaces this row
 * once the profile/settings system lands.
 */
@ComponentV2
export struct TransportBar {
  @Param @Require model: ObsAppState;

  private formatUptime(totalSeconds: number): string {
    const seconds = Math.max(0, Math.floor(totalSeconds));
    const hh = Math.floor(seconds / 3600);
    const mm = Math.floor((seconds % 3600) / 60);
    const ss = seconds % 60;
    const pad = (value: number): string => (value < 10 ? `0${value}` : `${value}`);
    return `${pad(hh)}:${pad(mm)}:${pad(ss)}`;
  }

  private connectionLabel(): string {
    switch (this.model.connectionState) {
      case ConnectionState.Live:
        return 'LIVE';
      case ConnectionState.Starting:
        return 'CONNECTING…';
      case ConnectionState.Stopping:
        return 'STOPPING…';
      case ConnectionState.Recording:
        return 'RECORDING';
      case ConnectionState.Error:
        return 'ERROR';
      default:
        return 'IDLE';
    }
  }

  private connectionColor(): ResourceColor {
    switch (this.model.connectionState) {
      case ConnectionState.Live:
        return $r('app.color.obs_live');
      case ConnectionState.Recording:
        return $r('app.color.obs_live');
      case ConnectionState.Error:
        return $r('app.color.obs_meter_warn');
      default:
        return $r('app.color.obs_text_secondary');
    }
  }

  build() {
    Column({ space: 6 }) {
      // RTMP target row -----------------------------------------------------
      Row({ space: 8 }) {
        Text('Server')
          .fontSize(11)
          .fontColor($r('app.color.obs_text_secondary'))
          .width(48)
        TextInput({ text: this.model.streamingServer, placeholder: 'rtmp://…' })
          .fontSize(12)
          .fontColor($r('app.color.obs_text_primary'))
          .placeholderColor($r('app.color.obs_text_secondary'))
          .backgroundColor('#101216')
          .borderRadius(4)
          .height(28)
          .layoutWeight(2)
          .enabled(!this.model.stats.streaming)
          .onChange((value: string) => {
            this.model.streamingServer = value;
          })
        Text('Key')
          .fontSize(11)
          .fontColor($r('app.color.obs_text_secondary'))
          .width(28)
        TextInput({ text: this.model.streamingKey, placeholder: 'stream key' })
          .fontSize(12)
          .fontColor($r('app.color.obs_text_primary'))
          .placeholderColor($r('app.color.obs_text_secondary'))
          .backgroundColor('#101216')
          .borderRadius(4)
          .height(28)
          .layoutWeight(1)
          .enabled(!this.model.stats.streaming)
          .onChange((value: string) => {
            this.model.streamingKey = value;
          })
      }
      .width('100%')

      // Transport row ---------------------------------------------------------
      Row({ space: 10 }) {
        // Status indicator + readout
        Circle({ width: 10, height: 10 })
          .fill(this.connectionColor())
        Text(this.connectionLabel())
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.connectionColor())
          .width(104)

        Text(`${(this.model.stats.bitrateKbps / 1000).toFixed(2)} Mbps`)
          .fontSize(12)
          .fontColor($r('app.color.obs_text_primary'))
          .width(90)
          .textAlign(TextAlign.End)
        Text(`drop ${this.model.stats.droppedFrames}/${this.model.stats.totalFrames}`)
          .fontSize(12)
          .fontColor(this.model.stats.droppedFrames > 0 ?
          $r('app.color.obs_meter_warn') : $r('app.color.obs_text_secondary'))
          .width(110)
          .textAlign(TextAlign.End)
        Text(this.formatUptime(this.model.stats.uptimeSeconds))
          .fontSize(12)
          .fontColor($r('app.color.obs_text_primary'))
          .width(76)
          .textAlign(TextAlign.End)

        Blank()

        Button(this.model.stats.streaming ? 'Stop Streaming' : 'Start Streaming')
          .type(ButtonType.Normal)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .backgroundColor(this.model.stats.streaming ?
          $r('app.color.obs_live') : $r('app.color.obs_accent'))
          .borderRadius(4)
          .height(32)
          .width(150)
          .enabled(this.model.coreReady)
          .onClick(() => {
            ObsController.toggleStreaming();
          })

        Button(this.model.stats.recording ? 'Stop Recording' : 'Start Recording')
          .type(ButtonType.Normal)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .backgroundColor(this.model.stats.recording ?
          $r('app.color.obs_live') : $r('app.color.obs_panel_border'))
          .borderRadius(4)
          .height(32)
          .width(150)
          .enabled(this.model.coreReady)
          .onClick(() => {
            ObsController.toggleRecording();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(8)
  }
}
