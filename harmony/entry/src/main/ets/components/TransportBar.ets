import { ConnectionState, ObsAppState, ObsController } from '../model/ObsModel';

/**
 * TransportBar — Start/Stop Streaming + Start/Stop Recording with the live
 * readout (bitrate, dropped/total frames, uptime) fed by the push-mode stats
 * callback from the native output thread (no UI polling for stats).
 *
 * The RTMP target (server + key) is NOT edited here: like the desktop OBS
 * main window, the transport bar only carries status + the two output
 * buttons, and the stream target lives in Settings ▸ 直播 (which also owns
 * the history picker and the masked key field). The old always-visible
 * server/key input row ate a full line of vertical space for a value that
 * rarely changes (user report 10-17).
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

  private connectionLabel(): Resource {
    switch (this.model.connectionState) {
      case ConnectionState.Live:
        return $r('app.string.st_live');
      case ConnectionState.Starting:
        return $r('app.string.st_connecting');
      case ConnectionState.Stopping:
        return $r('app.string.st_stopping');
      case ConnectionState.Recording:
        return $r('app.string.st_recording');
      case ConnectionState.Error:
        return $r('app.string.st_error');
      default:
        return $r('app.string.st_idle');
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

  /** Desktop 输出 confirmation parity: when the matching 确认 checkbox is
   * on, the transport button asks before acting. Remote director commands
   * (DirectorLink) bypass this by design — confirmations guard local
   * mis-taps, not deliberate remote control. */
  private confirmThen(message: Resource, action: () => void): void {
    this.getUIContext().getPromptAction().showDialog({
      title: $r('app.string.confirm_title'),
      message: message,
      buttons: [
        { text: $r('app.string.confirm_cancel'), color: '#9aa0a6' },
        { text: $r('app.string.confirm_ok'), color: '#4a9eff' }
      ]
    }).then((result) => {
      if (result.index === 1) {
        action();
      }
    }).catch(() => {
      /* dialog unavailable: act without confirmation rather than blocking
       * the transport entirely. */
      action();
    });
  }

  private onStreamToggle(): void {
    const starting = !this.model.stats.streaming;
    const need = starting ? this.model.confirmStartStream : this.model.confirmStopStream;
    if (need) {
      this.confirmThen(starting ? $r('app.string.confirm_start_stream') : $r('app.string.confirm_stop_stream'),
        () => {
          ObsController.toggleStreaming();
        });
    } else {
      ObsController.toggleStreaming();
    }
  }

  private onRecordToggle(): void {
    const starting = !this.model.stats.recording;
    const need = starting ? this.model.confirmStartRecord : this.model.confirmStopRecord;
    if (need) {
      this.confirmThen(starting ? $r('app.string.confirm_start_record') : $r('app.string.confirm_stop_record'),
        () => {
          ObsController.toggleRecording();
        });
    } else {
      ObsController.toggleRecording();
    }
  }

  build() {
    Column({ space: 6 }) {
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

        Button(this.model.stats.streaming ? $r('app.string.stream_stop') : $r('app.string.stream_start'))
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
            this.onStreamToggle();
          })

        Button(this.model.stats.recording ? $r('app.string.record_stop') : $r('app.string.record_start'))
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
            this.onRecordToggle();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(8)
  }
}
