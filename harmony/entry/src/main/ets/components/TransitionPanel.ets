import { ObsAppState, ObsController, TransitionOptionModel } from '../model/ObsModel';

/**
 * TransitionPanel — the 转场动画 dock (desktop parity: the panel between the
 * mixer and the control buttons on OBS desktop).
 *
 * Two controls:
 *  - a Select of the transition TYPES the staged obs-transitions plugin
 *    actually registered (fade/slide/swipe/fade-to-color/wipe), so a build
 *    missing a plugin simply offers fewer rows;
 *  - the duration in ms (0 = hard cut, matching nativeSelectScene's
 *    duration<=0 path).
 *
 * The type change rebuilds the program-channel transition shell around the
 * currently visible source (nativeSetTransitionType), preserving the
 * channel-0 ownership invariant; the duration is applied on the next switch.
 */
@ComponentV2
export struct TransitionPanel {
  @Param @Require model: ObsAppState;
  /** Local mirror of the duration TextInput so typing does not fight the
   * persisted value until the user commits (onSubmit / blur). */
  @Local durationDraft: string = '';

  aboutToAppear(): void {
    this.durationDraft = String(this.model.sceneTransitionMs);
  }

  private options(): SelectOption[] {
    return this.model.transitionOptions.map((o: TransitionOptionModel): SelectOption => {
      const opt: SelectOption = { value: o.name };
      return opt;
    });
  }

  private selectedIndex(): number {
    for (let i = 0; i < this.model.transitionOptions.length; i++) {
      if (this.model.transitionOptions[i].id === this.model.sceneTransitionId) {
        return i;
      }
    }
    return 0;
  }

  private commitDuration(): void {
    const parsed = parseInt(this.durationDraft, 10);
    if (isNaN(parsed)) {
      this.durationDraft = String(this.model.sceneTransitionMs);
      return;
    }
    ObsController.setTransitionMs(parsed);
    this.durationDraft = String(this.model.sceneTransitionMs);
  }

  build() {
    Column({ space: 6 }) {
      Text($r('app.string.transition_title'))
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.obs_text_secondary'))
        .width('100%')

      if (this.model.transitionOptions.length > 0) {
        Select(this.options())
          .selected(this.selectedIndex())
          .value(this.model.transitionOptions[this.selectedIndex()].name)
          .font({ size: 12 })
          .fontColor($r('app.color.obs_text_primary'))
          .backgroundColor($r('app.color.obs_panel_border'))
          .selectedOptionFont({ size: 12 })
          .width('100%')
          .onSelect((index: number) => {
            const opt: TransitionOptionModel = this.model.transitionOptions[index];
            ObsController.setTransitionId(opt.id);
          })

        Row({ space: 6 }) {
          Text($r('app.string.transition_duration'))
            .fontSize(12)
            .fontColor($r('app.color.obs_text_secondary'))
          TextInput({ text: this.durationDraft })
            .type(InputType.Number)
            .fontSize(12)
            .height(30)
            .layoutWeight(1)
            .backgroundColor($r('app.color.obs_panel_border'))
            .fontColor($r('app.color.obs_text_primary'))
            .onChange((v: string) => {
              this.durationDraft = v;
            })
            .onSubmit(() => {
              this.commitDuration();
            })
            .onBlur(() => {
              this.commitDuration();
            })
          Text('ms')
            .fontSize(12)
            .fontColor($r('app.color.obs_text_secondary'))
        }
        .width('100%')
      } else {
        Text($r('app.string.transition_unavailable'))
          .fontSize(11)
          .fontColor($r('app.color.obs_text_secondary'))
          .width('100%')
      }
    }
    .width('100%')
    .padding(8)
    .alignItems(HorizontalAlign.Start)
  }
}
