import { ObsAppState, ObsController } from '../model/ObsModel';

/**
 * SettingsPanel — profile-level settings sheet (W2).
 *
 * Shown through the main page's bindSheet: video canvas geometry (applied
 * via nativeResetVideo, refused while an output is live), encoder bitrates
 * for recording and streaming, and the RTMP target. Closing the sheet
 * persists the whole bag through SettingsStore; canvas geometry is also
 * re-applied at the next core start from the persisted copy.
 */
@ComponentV2
export struct SettingsPanel {
  @Param @Require model: ObsAppState;
  @Event onVisibleChange: (v: boolean) => void = (v: boolean) => {};

  private resolutions: string[] = ['1280x720', '1920x1080', '2560x1440', '3840x2160'];
  private fpsOptions: number[] = [30, 60];
  private codecOptions: string[] = ['H.264', 'HEVC'];

  private codecIndex(): number {
    return this.model.setVideoCodec === 'hevc' ? 1 : 0;
  }

  private codecOptionList(): SelectOption[] {
    return this.codecOptions.map((c: string): SelectOption => {
      const opt: SelectOption = { value: c };
      return opt;
    });
  }

  private resolutionLabel(): string {
    return `${this.model.setVideoWidth}x${this.model.setVideoHeight}`;
  }

  private pickResolution(index: number): void {
    const parts = this.resolutions[index].split('x');
    this.model.setVideoWidth = Number.parseInt(parts[0], 10);
    this.model.setVideoHeight = Number.parseInt(parts[1], 10);
  }

  private resolutionIndex(): number {
    const want = `${this.model.setVideoWidth}x${this.model.setVideoHeight}`;
    const i = this.resolutions.indexOf(want);
    return i >= 0 ? i : 1;
  }

  private resolutionOptions(): SelectOption[] {
    return this.resolutions.map((r: string): SelectOption => {
      const opt: SelectOption = { value: r };
      return opt;
    });
  }

  build() {
    Column({ space: 8 }) {
      Text($r('app.string.settings_video'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.obs_text_primary'))
        .margin({ top: 14 })
        .width('100%')

      Row({ space: 8 }) {
        Text($r('app.string.settings_resolution'))
          .fontSize(13)
          .fontColor($r('app.color.obs_text_secondary'))
          .width(110)
        Select(this.resolutionOptions())
          .selected(this.resolutionIndex())
          .value(this.resolutionLabel())
          .font({ size: 13 })
          .fontColor($r('app.color.obs_text_primary'))
          .selectedOptionFont({ size: 13 })
          .optionFont({ size: 13 })
          .layoutWeight(1)
          .onSelect((index: number) => {
            this.pickResolution(index);
          })
      }
      .width('100%')

      Row({ space: 8 }) {
        Text($r('app.string.settings_fps'))
          .fontSize(13)
          .fontColor($r('app.color.obs_text_secondary'))
          .width(110)
        Row({ space: 8 }) {
          ForEach(this.fpsOptions, (fps: number) => {
            Button(`${fps}`)
              .type(ButtonType.Normal)
              .fontSize(12)
              .height(28)
              .fontColor($r('app.color.obs_text_primary'))
              .backgroundColor(this.model.setVideoFps === fps ?
              $r('app.color.obs_accent') : $r('app.color.obs_panel_border'))
              .borderRadius(4)
              .onClick(() => {
                this.model.setVideoFps = fps;
              })
          }, (fps: number) => `${fps}`)
        }
        .layoutWeight(1)
      }
      .width('100%')

      Row({ space: 8 }) {
        Text($r('app.string.settings_codec'))
          .fontSize(13)
          .fontColor($r('app.color.obs_text_secondary'))
          .width(110)
        Select(this.codecOptionList())
          .selected(this.codecIndex())
          .value(this.codecOptions[this.codecIndex()])
          .font({ size: 13 })
          .fontColor($r('app.color.obs_text_primary'))
          .selectedOptionFont({ size: 13 })
          .optionFont({ size: 13 })
          .layoutWeight(1)
          .onSelect((index: number) => {
            this.model.setVideoCodec = index === 1 ? 'hevc' : 'h264';
            ObsController.saveSettings();
          })
      }
      .width('100%')

      Button($r('app.string.settings_apply_video'))
        .type(ButtonType.Normal)
        .fontSize(13)
        .height(32)
        .width('100%')
        .fontColor($r('app.color.obs_text_primary'))
        .backgroundColor($r('app.color.obs_accent'))
        .borderRadius(4)
        .enabled(!this.model.stats.recording && !this.model.stats.streaming)
        .onClick(() => {
          ObsController.applyVideoSettings();
        })
      if (this.model.stats.recording || this.model.stats.streaming) {
        Text($r('app.string.settings_output_busy'))
          .fontSize(11)
          .fontColor($r('app.color.obs_meter_warn'))
          .width('100%')
      }

      Text($r('app.string.settings_record'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.obs_text_primary'))
        .margin({ top: 14 })
        .width('100%')

      Row({ space: 8 }) {
        Text($r('app.string.settings_video_bitrate'))
          .fontSize(13)
          .fontColor($r('app.color.obs_text_secondary'))
          .width(110)
        TextInput({ text: this.model.setRecordVideoKbps.toString() })
          .type(InputType.Number)
          .fontSize(13)
          .layoutWeight(1)
          .backgroundColor($r('app.color.obs_panel_border'))
          .fontColor($r('app.color.obs_text_primary'))
          .onSubmit((enterKey: EnterKeyType, event: SubmitEvent) => {
            const parsed = Number.parseInt(event.text, 10);
            if (!Number.isNaN(parsed) && parsed > 0) {
              this.model.setRecordVideoKbps = parsed;
            }
          })
      }
      .width('100%')

      Row({ space: 8 }) {
        Text($r('app.string.settings_audio_bitrate'))
          .fontSize(13)
          .fontColor($r('app.color.obs_text_secondary'))
          .width(110)
        TextInput({ text: this.model.setRecordAudioKbps.toString() })
          .type(InputType.Number)
          .fontSize(13)
          .layoutWeight(1)
          .backgroundColor($r('app.color.obs_panel_border'))
          .fontColor($r('app.color.obs_text_primary'))
          .onSubmit((enterKey: EnterKeyType, event: SubmitEvent) => {
            const parsed = Number.parseInt(event.text, 10);
            if (!Number.isNaN(parsed) && parsed > 0) {
              this.model.setRecordAudioKbps = parsed;
            }
          })
      }
      .width('100%')

      Text($r('app.string.settings_stream'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.obs_text_primary'))
        .margin({ top: 14 })
        .width('100%')

      Row({ space: 8 }) {
        Text($r('app.string.settings_server'))
          .fontSize(13)
          .fontColor($r('app.color.obs_text_secondary'))
          .width(110)
        TextInput({ text: this.model.streamingServer })
          .fontSize(13)
          .layoutWeight(1)
          .backgroundColor($r('app.color.obs_panel_border'))
          .fontColor($r('app.color.obs_text_primary'))
          .onSubmit((enterKey: EnterKeyType, event: SubmitEvent) => {
            this.model.streamingServer = event.text;
          })
      }
      .width('100%')

      Row({ space: 8 }) {
        Text($r('app.string.settings_key'))
          .fontSize(13)
          .fontColor($r('app.color.obs_text_secondary'))
          .width(110)
        TextInput({ text: this.model.streamingKey })
          .fontSize(13)
          .layoutWeight(1)
          .backgroundColor($r('app.color.obs_panel_border'))
          .fontColor($r('app.color.obs_text_primary'))
          .onSubmit((enterKey: EnterKeyType, event: SubmitEvent) => {
            this.model.streamingKey = event.text;
          })
      }
      .width('100%')

      Row({ space: 8 }) {
        Text($r('app.string.settings_video_bitrate'))
          .fontSize(13)
          .fontColor($r('app.color.obs_text_secondary'))
          .width(110)
        TextInput({ text: this.model.setStreamVideoKbps.toString() })
          .type(InputType.Number)
          .fontSize(13)
          .layoutWeight(1)
          .backgroundColor($r('app.color.obs_panel_border'))
          .fontColor($r('app.color.obs_text_primary'))
          .onSubmit((enterKey: EnterKeyType, event: SubmitEvent) => {
            const parsed = Number.parseInt(event.text, 10);
            if (!Number.isNaN(parsed) && parsed > 0) {
              this.model.setStreamVideoKbps = parsed;
            }
          })
      }
      .width('100%')

      Row({ space: 8 }) {
        Text($r('app.string.settings_audio_bitrate'))
          .fontSize(13)
          .fontColor($r('app.color.obs_text_secondary'))
          .width(110)
        TextInput({ text: this.model.setStreamAudioKbps.toString() })
          .type(InputType.Number)
          .fontSize(13)
          .layoutWeight(1)
          .backgroundColor($r('app.color.obs_panel_border'))
          .fontColor($r('app.color.obs_text_primary'))
          .onSubmit((enterKey: EnterKeyType, event: SubmitEvent) => {
            const parsed = Number.parseInt(event.text, 10);
            if (!Number.isNaN(parsed) && parsed > 0) {
              this.model.setStreamAudioKbps = parsed;
            }
          })
      }
      .width('100%')

      Button($r('app.string.settings_close'))
        .type(ButtonType.Normal)
        .fontSize(13)
        .height(32)
        .width('100%')
        .fontColor($r('app.color.obs_text_primary'))
        .backgroundColor($r('app.color.obs_panel_border'))
        .borderRadius(4)
        .margin({ top: 16, bottom: 12 })
        .onClick(() => {
          ObsController.saveSettings();
          this.onVisibleChange(false);
        })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.obs_background'))
  }
}
