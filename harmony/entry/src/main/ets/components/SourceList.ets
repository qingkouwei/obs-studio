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
  label: string;
  id: string;
}

const SOURCE_TYPES: SourceTypeEntry[] = [
  { label: 'Display', id: 'harmony_display_capture' },
  { label: 'Window', id: 'harmony_window_capture' },
  { label: 'Camera', id: 'harmony_camera_capture' },
  { label: 'Mic', id: 'harmony_mic_capture' },
  { label: 'Desktop', id: 'harmony_desktop_audio' },
  { label: 'Image', id: 'image_source' },
];

@ComponentV2
export struct SourceList {
  @Param @Require model: ObsAppState;

  build() {
    Column({ space: 6 }) {
      Row() {
        Text('Sources')
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
              ObsController.addSource(entry.id);
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
            })
          }
        }, (source: SourceItemModel) => source.id)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)

      if (this.model.selectedSceneId === '') {
        Text('Select a scene first')
          .fontSize(11)
          .fontColor($r('app.color.obs_text_secondary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ bottom: 4 })
      }
    }
    .width('100%')
    .height('100%')
    .padding(8)
    .alignItems(HorizontalAlign.Start)
  }
}
