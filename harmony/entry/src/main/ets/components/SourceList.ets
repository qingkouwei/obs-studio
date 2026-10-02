import { ObsAppState, ObsController, SourceItemModel } from '../model/ObsModel';

/**
 * SourceList — the sources dock for the currently selected scene.
 * Per-row visibility toggle maps to obs_sceneitem_set_visible; add/remove map
 * to obs_source_create + obs_scene_add / obs_sceneitem_remove through the
 * bridge. In shell-only builds the add buttons are disabled (core not linked).
 */
/**
 * Every source the HarmonyOS build can actually create. The ids must match the
 * strings each plugin passes to obs_register_source() exactly — a mismatch is
 * invisible at compile time and surfaces only as "source type not found" when
 * the button is tapped on a device.
 */
interface SourceTypeEntry {
  label: Resource;
  id: string;
}

const SOURCE_TYPES: SourceTypeEntry[] = [
  { label: $r('app.string.src_display'), id: 'harmony_display_capture' },
  { label: $r('app.string.src_window'), id: 'harmony_window_capture' },
  { label: $r('app.string.src_camera'), id: 'harmony_camera_capture' },
  { label: $r('app.string.src_mic'), id: 'harmony_mic_capture' },
  { label: $r('app.string.src_desktop'), id: 'harmony_desktop_audio' },
  { label: $r('app.string.src_image'), id: '@picker:image_source' },
  { label: $r('app.string.src_text'), id: '@dialog:text_ft2_source' },
];

@ComponentV2
export struct SourceList {
  @Param @Require model: ObsAppState;
  /** Text-source input sheet (add flow). */
  @Local textSheetOpen: boolean = false;
  @Local textDraft: string = '';

  @Builder
  TextSourceSheet() {
    Column({ space: 10 }) {
      Text($r('app.string.text_source_title'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.obs_text_primary'))
        .width('100%')
        .margin({ top: 14 })
      TextArea({ text: this.textDraft, placeholder: $r('app.string.text_source_hint') })
        .fontSize(13)
        .height(120)
        .width('100%')
        .backgroundColor($r('app.color.obs_panel_border'))
        .fontColor($r('app.color.obs_text_primary'))
        .onChange((v: string) => {
          this.textDraft = v;
        })
      Button($r('app.string.text_source_add'))
        .type(ButtonType.Normal)
        .fontSize(13)
        .height(32)
        .width('100%')
        .fontColor($r('app.color.obs_text_primary'))
        .backgroundColor($r('app.color.obs_accent'))
        .borderRadius(4)
        .enabled(this.textDraft.trim().length > 0)
        .onClick(() => {
          ObsController.addTextSource(this.textDraft);
          this.textSheetOpen = false;
        })
      Button($r('app.string.text_source_cancel'))
        .type(ButtonType.Normal)
        .fontSize(13)
        .height(32)
        .width('100%')
        .fontColor($r('app.color.obs_text_secondary'))
        .backgroundColor($r('app.color.obs_panel_border'))
        .borderRadius(4)
        .onClick(() => {
          this.textSheetOpen = false;
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 12 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.obs_background'))
  }

  build() {
    Column({ space: 6 }) {
      Row() {
        Text($r('app.string.sources'))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.obs_text_secondary'))
        Blank()
        Button('-')
          .type(ButtonType.Normal)
          .fontSize(14)
          .fontColor($r('app.color.obs_text_primary'))
          .backgroundColor($r('app.color.obs_panel_border'))
          .borderRadius(4)
          .width(28)
          .height(24)
          .enabled(this.model.coreReady && this.model.selectedSourceId !== '')
          .onClick(() => {
            ObsController.removeSelectedSource();
          })
      }

      // Wrapping rather than a single Row: six source types do not fit the dock
      // width, and on a narrow floating window or split view they would be
      // clipped off the edge with no way to reach them.
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(SOURCE_TYPES, (entry: SourceTypeEntry) => {
          Button(entry.label)
            .type(ButtonType.Normal)
            .fontSize(11)
            .fontColor($r('app.color.obs_text_primary'))
            .backgroundColor($r('app.color.obs_panel_border'))
            .borderRadius(4)
            .height(24)
            .margin({ right: 6, bottom: 6 })
            .enabled(this.model.coreReady && this.model.selectedSceneId !== '')
            .onClick(() => {
              if (entry.id === '@picker:image_source') {
                ObsController.addImageSourcePicked();
              } else if (entry.id === '@dialog:text_ft2_source') {
                this.textDraft = '';
                this.textSheetOpen = true;
              } else {
                ObsController.addSource(entry.id);
              }
            })
        }, (entry: SourceTypeEntry) => entry.id)
      }
      .width('100%')

      List({ space: 2 }) {
        ForEach(this.model.sources, (source: SourceItemModel) => {
          ListItem() {
            Row({ space: 6 }) {
              // Eye toggle: obs_sceneitem_set_visible
              Toggle({ type: ToggleType.Switch, isOn: source.visible })
                .selectedColor($r('app.color.obs_accent'))
                .width(34)
                .height(20)
                .onChange((isOn: boolean) => {
                  ObsController.setSourceVisible(source.id, isOn);
                })
              Column() {
                Text(source.name)
                  .fontSize(13)
                  .fontColor($r('app.color.obs_text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(source.typeId)
                  .fontSize(10)
                  .fontColor($r('app.color.obs_text_secondary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width('100%')
            .height(42)
            .padding({ left: 6, right: 8 })
            .borderRadius(4)
            .backgroundColor(source.id === this.model.selectedSourceId ?
            $r('app.color.obs_panel_border') : Color.Transparent)
            .onClick(() => {
              this.model.selectedSourceId = source.id;
              ObsController.refreshFilters();
            })
          }
        }, (source: SourceItemModel) => source.id)
      }
      .width('100%')
      .layoutWeight(1)
      .constraintSize({ minHeight: 46 })
      .scrollBar(BarState.Auto)

      if (this.model.selectedSceneId === '') {
        Text($r('app.string.select_scene_first'))
          .fontSize(11)
          .fontColor($r('app.color.obs_text_secondary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ bottom: 4 })
      }
    }
    .width('100%')
    .layoutWeight(1)
    .padding(8)
    .alignItems(HorizontalAlign.Start)
    .bindSheet($$this.textSheetOpen,
      this.TextSourceSheet(),
      {
        height: SheetSize.MEDIUM,
        dragBar: true,
        showClose: true,
        backgroundColor: $r('app.color.obs_background')
      })
  }
}
