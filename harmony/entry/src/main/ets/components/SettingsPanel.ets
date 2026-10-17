import { ObsAppState, ObsController } from '../model/ObsModel';
import { StreamTargetEntry } from '../common/SettingsStore';

/**
 * SettingsPanel — profile-level settings sheet (W2), restructured to the
 * desktop OBS settings dialog shape (10-12): a tab row across the top
 * (常规 / 视频 / 录制 / 直播) with one section per tab, instead of one long
 * scroll. The 常规 tab carries the desktop "General" group we now support:
 * source snapping (源对齐) and output confirmations (输出).
 *
 * Persistence is unchanged: closing the sheet writes the whole bag through
 * SettingsStore; canvas geometry is re-applied at the next core start.
 */
@ComponentV2
export struct SettingsPanel {
  @Param @Require model: ObsAppState;
  @Event onVisibleChange: (v: boolean) => void = (v: boolean) => {};
  @Local tab: string = 'general';

  private resolutions: string[] = ['1280x720', '1920x1080', '2560x1440', '3840x2160'];
  private fpsOptions: number[] = [30, 60];
  private codecOptions: string[] = ['H.264', 'HEVC'];
  private transitionOptions: number[] = [0, 300, 600, 1000];

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

  @Builder
  SectionTitle(label: Resource) {
    Text(label)
      .fontSize(14)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.obs_text_primary'))
      .margin({ top: 10 })
      .width('100%')
  }

  @Builder
  LabelRow(label: Resource) {
    Text(label)
      .fontSize(13)
      .fontColor($r('app.color.obs_text_secondary'))
      .width(110)
  }

  @Builder
  CheckRow(label: Resource, isOn: boolean, onChange: (v: boolean) => void) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor($r('app.color.obs_text_primary'))
        .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .selectedColor($r('app.color.obs_accent'))
        .onChange(onChange)
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
  }

  @Builder
  GeneralTab() {
    Column({ space: 4 }) {
      this.SectionTitle($r('app.string.set_snap_group'))
      this.CheckRow($r('app.string.set_snap_enable'), this.model.snapEnabled, (v: boolean) => {
        this.model.snapEnabled = v;
        ObsController.saveSettings();
      })
      Row({ space: 8 }) {
        this.LabelRow($r('app.string.set_snap_threshold'))
        Slider({ value: this.model.snapThreshold, min: 2, max: 60, step: 2 })
          .layoutWeight(1)
          .onChange((v: number) => {
            this.model.snapThreshold = Math.round(v);
          })
        Text(`${this.model.snapThreshold}`)
          .fontSize(12)
          .fontColor($r('app.color.obs_text_secondary'))
          .width(28)
      }
      .width('100%')
      this.CheckRow($r('app.string.set_snap_edges'), this.model.snapToEdges, (v: boolean) => {
        this.model.snapToEdges = v;
        ObsController.saveSettings();
      })

      this.SectionTitle($r('app.string.set_confirm_group'))
      this.CheckRow($r('app.string.set_confirm_start_record'), this.model.confirmStartRecord, (v: boolean) => {
        this.model.confirmStartRecord = v;
        ObsController.saveSettings();
      })
      this.CheckRow($r('app.string.set_confirm_stop_record'), this.model.confirmStopRecord, (v: boolean) => {
        this.model.confirmStopRecord = v;
        ObsController.saveSettings();
      })
      this.CheckRow($r('app.string.set_confirm_start_stream'), this.model.confirmStartStream, (v: boolean) => {
        this.model.confirmStartStream = v;
        ObsController.saveSettings();
      })
      this.CheckRow($r('app.string.set_confirm_stop_stream'), this.model.confirmStopStream, (v: boolean) => {
        this.model.confirmStopStream = v;
        ObsController.saveSettings();
      })
      this.CheckRow($r('app.string.set_auto_record'), this.model.autoRecordOnStream, (v: boolean) => {
        this.model.autoRecordOnStream = v;
        ObsController.saveSettings();
      })
      this.CheckRow($r('app.string.set_auto_stop_record'), this.model.autoStopRecordOnStreamStop, (v: boolean) => {
        this.model.autoStopRecordOnStreamStop = v;
        ObsController.saveSettings();
      })

      this.SectionTitle($r('app.string.set_guides_group'))
      this.CheckRow($r('app.string.set_guide_safe'), this.model.guideSafeAreas, (v: boolean) => {
        this.model.guideSafeAreas = v;
        ObsController.saveSettings();
      })
      this.CheckRow($r('app.string.set_guide_center'), this.model.guideCenter, (v: boolean) => {
        this.model.guideCenter = v;
        ObsController.saveSettings();
      })
      this.CheckRow($r('app.string.set_guide_scale'), this.model.guideScale, (v: boolean) => {
        this.model.guideScale = v;
        ObsController.saveSettings();
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  VideoTab() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        this.LabelRow($r('app.string.settings_resolution'))
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
        this.LabelRow($r('app.string.settings_fps'))
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
        this.LabelRow($r('app.string.settings_codec'))
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

      Row({ space: 8 }) {
        this.LabelRow($r('app.string.settings_transition'))
        Row({ space: 8 }) {
          ForEach(this.transitionOptions, (ms: number) => {
            Button(ms === 0 ? $r('app.string.settings_transition_cut') : `${ms}ms`)
              .type(ButtonType.Normal)
              .fontSize(12)
              .height(28)
              .fontColor($r('app.color.obs_text_primary'))
              .backgroundColor(this.model.sceneTransitionMs === ms ?
              $r('app.color.obs_accent') : $r('app.color.obs_panel_border'))
              .borderRadius(4)
              .onClick(() => {
                this.model.sceneTransitionMs = ms;
                ObsController.saveSettings();
              })
          }, (ms: number) => `${ms}`)
        }
        .layoutWeight(1)
      }
      .width('100%')
      if (this.model.stats.recording || this.model.stats.streaming) {
        Text($r('app.string.settings_output_busy'))
          .fontSize(11)
          .fontColor($r('app.color.obs_meter_warn'))
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  BitrateRow(label: Resource, value: number, onCommit: (v: number) => void) {
    Row({ space: 8 }) {
      this.LabelRow(label)
      TextInput({ text: value.toString() })
        .type(InputType.Number)
        .fontSize(13)
        .layoutWeight(1)
        .backgroundColor($r('app.color.obs_panel_border'))
        .fontColor($r('app.color.obs_text_primary'))
        .onSubmit((enterKey: EnterKeyType, event: SubmitEvent) => {
          const parsed = Number.parseInt(event.text, 10);
          if (!Number.isNaN(parsed) && parsed > 0) {
            onCommit(parsed);
          }
        })
    }
    .width('100%')
  }

  @Builder
  RecordTab() {
    Column({ space: 8 }) {
      this.BitrateRow($r('app.string.settings_video_bitrate'), this.model.setRecordVideoKbps, (v: number) => {
        this.model.setRecordVideoKbps = v;
      })
      this.BitrateRow($r('app.string.settings_audio_bitrate'), this.model.setRecordAudioKbps, (v: number) => {
        this.model.setRecordAudioKbps = v;
      })
      /* Album export (user request 10-14): the sandbox recording is
       * invisible to Gallery; this hands the finished file to the media
       * library through the system consent dialog. Disabled while a
       * recording is live (the file is still being written). */
      Button($r('app.string.settings_export_album'))
        .type(ButtonType.Normal)
        .fontSize(13)
        .height(32)
        .width('100%')
        .fontColor($r('app.color.obs_text_primary'))
        .backgroundColor($r('app.color.obs_panel_border'))
        .borderRadius(4)
        .margin({ top: 8 })
        .enabled(!this.model.stats.recording)
        .onClick(() => {
          ObsController.exportLastRecordingToAlbum();
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** Picker label for one remembered target: server + masked key (the
   * full secret never renders in the dropdown — reveal happens only in
   * the field via the password eye icon, user request 10-17). */
  private targetLabel(e: StreamTargetEntry): string {
    const k = e.key;
    const masked = k.length <= 4 ? '*'.repeat(k.length) :
      `${k.substring(0, 2)}${'*'.repeat(Math.min(k.length - 4, 8))}${k.substring(k.length - 2)}`;
    return `${e.server} / ${masked}`;
  }

  private streamTargetOptions(): SelectOption[] {
    return this.model.streamTargets.map((e: StreamTargetEntry): SelectOption => {
      const opt: SelectOption = { value: this.targetLabel(e) };
      return opt;
    });
  }

  @Builder
  StreamTab() {
    Column({ space: 8 }) {
      /* History picker (user request 10-17): every target that actually
       * started a stream is remembered; choosing one fills both fields. */
      if (this.model.streamTargets.length > 0) {
        Row({ space: 8 }) {
          this.LabelRow($r('app.string.stream_history'))
          Select(this.streamTargetOptions())
            .value($r('app.string.stream_history'))
            .font({ size: 12 })
            .selectedOptionFont({ size: 12 })
            .optionFont({ size: 12 })
            .layoutWeight(1)
            .backgroundColor($r('app.color.obs_panel_border'))
            .fontColor($r('app.color.obs_text_primary'))
            .onSelect((index: number) => {
              if (index >= 0 && index < this.model.streamTargets.length) {
                ObsController.applyStreamTarget(this.model.streamTargets[index]);
              }
            })
        }
        .width('100%')
      }
      Row({ space: 8 }) {
        this.LabelRow($r('app.string.settings_server'))
        TextInput({ text: this.model.streamingServer })
          .fontSize(13)
          .layoutWeight(1)
          .backgroundColor($r('app.color.obs_panel_border'))
          .fontColor($r('app.color.obs_text_primary'))
          .onChange((v: string) => {
            this.model.streamingServer = v;
          })
          .onSubmit((enterKey: EnterKeyType, event: SubmitEvent) => {
            this.model.streamingServer = event.text;
          })
      }
      .width('100%')
      Row({ space: 8 }) {
        this.LabelRow($r('app.string.settings_key'))
        /* Password input with the system eye icon: dots by default, one
         * tap reveals the raw key, typing keeps working normally. */
        TextInput({ text: this.model.streamingKey, placeholder: $r('app.string.stream_key_hint') })
          .type(InputType.Password)
          .showPasswordIcon(true)
          .fontSize(13)
          .layoutWeight(1)
          .backgroundColor($r('app.color.obs_panel_border'))
          .fontColor($r('app.color.obs_text_primary'))
          .onChange((v: string) => {
            this.model.streamingKey = v;
          })
          .onSubmit((enterKey: EnterKeyType, event: SubmitEvent) => {
            this.model.streamingKey = event.text;
          })
      }
      .width('100%')
      this.BitrateRow($r('app.string.settings_video_bitrate'), this.model.setStreamVideoKbps, (v: number) => {
        this.model.setStreamVideoKbps = v;
      })
      this.BitrateRow($r('app.string.settings_audio_bitrate'), this.model.setStreamAudioKbps, (v: number) => {
        this.model.setStreamAudioKbps = v;
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  KeysTab() {
    Column({ space: 6 }) {
      this.SectionTitle($r('app.string.set_keys'))
      Text($r('app.string.key_scene_n'))
        .fontSize(13)
        .fontColor($r('app.color.obs_text_primary'))
        .width('100%')
      Text($r('app.string.key_ctrl_r'))
        .fontSize(13)
        .fontColor($r('app.color.obs_text_primary'))
        .width('100%')
      Text($r('app.string.key_ctrl_f'))
        .fontSize(13)
        .fontColor($r('app.color.obs_text_primary'))
        .width('100%')
      Text($r('app.string.key_arrows'))
        .fontSize(13)
        .fontColor($r('app.color.obs_text_primary'))
        .width('100%')
      Text($r('app.string.key_del'))
        .fontSize(13)
        .fontColor($r('app.color.obs_text_primary'))
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column({ space: 8 }) {
      // Header with a prominent top-right close (user report 10-13 #1/#3:
      // the system ✕ was removed for being dim & overlapping the tabs, but
      // that left the only close at the very bottom near the system nav
      // bar — users could not find it. A filled top-right button is the
      // conventional, always-visible affordance).
      Row() {
        Text($r('app.string.settings_title'))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.obs_text_primary'))
          .layoutWeight(1)
        Button() {
          /* '✕' (U+2715) is missing from the device font and rendered as an
           * invisible circle (user report 10-13, 2nd round). Chinese label +
           * accent background always renders. */
          Text('关闭').fontSize(13).fontWeight(FontWeight.Medium).fontColor(Color.White)
        }
          .type(ButtonType.Normal)
          .height(32)
          .padding({ left: 14, right: 14 })
          .backgroundColor($r('app.color.obs_accent'))
          .borderRadius(6)
          .onClick(() => {
            ObsController.saveSettings();
            this.onVisibleChange(false);
          })
      }
      .width('100%')
      .margin({ top: 12 })

      // Tab row (desktop settings sidebar, flattened to tabs for the sheet).
      Row({ space: 6 }) {
        ForEach(['general', 'video', 'record', 'stream', 'keys'], (t: string) => {
          Button(t === 'general' ? $r('app.string.set_general') :
            t === 'video' ? $r('app.string.set_video') :
              t === 'record' ? $r('app.string.set_record') :
                t === 'stream' ? $r('app.string.set_stream') : $r('app.string.set_keys'))
            .type(ButtonType.Normal)
            .fontSize(12)
            .height(30)
            .layoutWeight(1)
            .fontColor($r('app.color.obs_text_primary'))
            .backgroundColor(this.tab === t ?
            $r('app.color.obs_accent') : $r('app.color.obs_panel_border'))
            .borderRadius(4)
            .onClick(() => {
              this.tab = t;
            })
        }, (t: string) => t)
      }
      .width('100%')
      .margin({ top: 8 })

      Scroll() {
        Column() {
          if (this.tab === 'general') {
            this.GeneralTab()
          } else if (this.tab === 'video') {
            this.VideoTab()
          } else if (this.tab === 'record') {
            this.RecordTab()
          } else if (this.tab === 'stream') {
            this.StreamTab()
          } else {
            this.KeysTab()
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Auto)
      .align(Alignment.Top)

      Button($r('app.string.settings_close'))
        .type(ButtonType.Normal)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .height(40)
        .width('100%')
        .fontColor(Color.White)
        .backgroundColor($r('app.color.obs_accent'))
        .borderRadius(6)
        .margin({ top: 8, bottom: 12 })
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
