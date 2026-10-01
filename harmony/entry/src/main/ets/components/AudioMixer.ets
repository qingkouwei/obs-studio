import { AudioTrackModel, CaptureState, ObsAppState, ObsController } from '../model/ObsModel';

/**
 * AudioMixer — per-track level meters (peak + RMS), volume faders and mute
 * toggles for the desktop-loopback and microphone tracks.
 *
 * Levels come from REAL captured PCM: the native bridge computes peak/RMS in
 * the OH_AudioCapturer read callback, and the page polls
 * nativeGetOutputLevels() on a 200 ms timer — this works even in shell-only
 * builds (no libobs required).
 *
 * The desktop track surfaces the loopback probe/authorization state honestly:
 * Requesting (async privacy dialog pending), NotAuthorized (user denied),
 * Unsupported (PC/2in1 syscap probe failed) — never pretended to be Running.
 */
@ComponentV2
export struct AudioMixer {
  @Param @Require model: ObsAppState;

  /** Linear amplitude (0..1) -> meter width percent with a perceptual taper. */
  private meterPercent(level: number): number {
    if (level <= 0) {
      return 0;
    }
    const clamped = Math.min(1, Math.max(0, level));
    // ~dB-scaled fill: -60 dB..0 dB mapped onto 0%..100%
    const db = 20 * Math.log10(clamped);
    const percent = ((db + 60) / 60) * 100;
    return Math.min(100, Math.max(2, percent));
  }

  private meterColor(level: number): ResourceColor {
    if (level >= 0.98) {
      return $r('app.color.obs_meter_clip');
    }
    if (level >= 0.7) {
      return $r('app.color.obs_meter_warn');
    }
    return $r('app.color.obs_meter_ok');
  }

  /** Human-readable state chip for non-running tracks. */
  private stateLabel(track: AudioTrackModel): string | Resource {
    switch (track.state) {
      case CaptureState.Unsupported:
        return $r('app.string.st_unsupported');
      case CaptureState.Requesting:
        return $r('app.string.st_requesting');
      case CaptureState.NotAuthorized:
        return $r('app.string.st_notauthorized');
      case CaptureState.Failed:
        return track.id === 'mic-audio' ? $r('app.string.st_micdenied') : $r('app.string.st_capture_failed');
      case CaptureState.Idle:
        return $r('app.string.st_idle');
      default:
        return '';
    }
  }

  build() {
    Column({ space: 4 }) {
      Row() {
        Text($r('app.string.audio_mixer'))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.obs_text_secondary'))
        Blank()
        if (this.model.systemAudio.probed && !this.model.systemAudio.supported) {
          // The honest probe result: docs list Phone/Tablet/TV for the
          // PlaybackCapture syscap; on this PC/2in1 device it was not
          // confirmed, so say exactly that.
          Text(`${this.getUIContext().getHostContext()!.resourceManager.getStringSync($r('app.string.loopback_probe').id)}: ` +
            `syscap=${this.model.systemAudio.syscapReported ? 'yes' : 'no'} ` +
            `native=${this.model.systemAudio.nativeProbeOk ? 'yes' : 'no'}`)
            .fontSize(10)
            .fontColor($r('app.color.obs_meter_warn'))
        }
      }
      .width('100%')

      Row({ space: 12 }) {
        ForEach(this.model.audioTracks, (track: AudioTrackModel) => {
          Column({ space: 4 }) {
            Row({ space: 6 }) {
              Text(track.id === 'desktop-audio' ? $r('app.string.track_desktop') :
                (track.id === 'mic-audio' ? $r('app.string.track_mic') : track.name))
                .fontSize(12)
                .fontColor($r('app.color.obs_text_primary'))
              if (track.state !== CaptureState.Running) {
                Text(this.stateLabel(track))
                  .fontSize(10)
                  .fontColor($r('app.color.obs_meter_warn'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
            }
            .width('100%')

            // Peak meter (top) + RMS meter (bottom)
            Stack({ alignContent: Alignment.Start }) {
              Row()
                .width('100%')
                .height(8)
                .backgroundColor('#101216')
                .borderRadius(4)
              Row()
                .width(`${this.meterPercent(track.rms)}%`)
                .height(8)
                .backgroundColor(this.meterColor(track.rms))
                .opacity(0.55)
                .borderRadius(4)
              Row()
                .width(`${this.meterPercent(track.peak)}%`)
                .height(3)
                .backgroundColor(this.meterColor(track.peak))
                .borderRadius(2)
            }
            .width('100%')
            .height(8)

            Row({ space: 8 }) {
              Button(track.muted ? $r('app.string.unmute') : $r('app.string.mute'))
                .type(ButtonType.Normal)
                .fontSize(11)
                .fontColor(track.muted ? $r('app.color.obs_live') : $r('app.color.obs_text_primary'))
                .backgroundColor($r('app.color.obs_panel_border'))
                .borderRadius(4)
                .height(24)
                .width(58)
                .onClick(() => {
                  ObsController.setTrackMute(track.id, !track.muted);
                })
              Slider({
                value: track.volume * 100,
                min: 0,
                max: 100,
                step: 1,
                style: SliderStyle.OutSet
              })
                .layoutWeight(1)
                .blockColor($r('app.color.obs_text_primary'))
                .trackColor($r('app.color.obs_panel_border'))
                .selectedColor($r('app.color.obs_accent'))
                .onChange((value: number) => {
                  ObsController.setTrackVolume(track.id, value / 100);
                })
              Text(`${Math.round(track.volume * 100)}`)
                .fontSize(10)
                .fontColor($r('app.color.obs_text_secondary'))
                .width(28)
                .textAlign(TextAlign.End)
            }
            .width('100%')
          }
          .layoutWeight(1)
          .padding(8)
          .borderRadius(6)
          .backgroundColor('#1B1E23')
          .alignItems(HorizontalAlign.Start)
        }, (track: AudioTrackModel) => track.id)
      }
      .width('100%')
      .layoutWeight(1)
      .alignItems(VerticalAlign.Top)
    }
    .width('100%')
    .height('100%')
    .padding(8)
    .alignItems(HorizontalAlign.Start)
  }
}
