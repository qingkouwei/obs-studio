import { FilterItemModel, ObsAppState, ObsController } from '../model/ObsModel';

/**
 * FilterPanel — per-source filter management for the selected source.
 *
 * Surfaces the filters obs-filters registered on the current source and lets
 * the user add/remove/toggle them through the bridge. Only a curated,
 * GPU-cheap subset is exposed (colour correction / flip / scale / crop); the
 * candidate list is whatever nativeGetFilterTypes() reports as actually
 * registered, so a plugin that failed to load simply yields fewer buttons.
 *
 * Renders nothing until a source is selected — filters attach to a source, not
 * to a scene.
 */
@ComponentV2
export struct FilterPanel {
  @Param @Require model: ObsAppState;

  private typeLabel(typeId: string): string | Resource {
    switch (typeId) {
      case 'color_filter':
        return $r('app.string.filter_color');
      case 'scale_filter':
        return $r('app.string.filter_scale');
      case 'crop_filter':
        return $r('app.string.filter_crop');
      case 'sharpness_filter':
        return $r('app.string.filter_sharpness');
      default:
        return typeId;
    }
  }

  build() {
    Column() {
      if (this.model.selectedSourceId !== '') {
        Column({ space: 6 }) {
          Row() {
            Text($r('app.string.filters'))
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.obs_text_secondary'))
          }
          .width('100%')

          // Existing filters on the selected source.
          ForEach(this.model.filters, (filter: FilterItemModel) => {
            Row({ space: 6 }) {
              Toggle({ type: ToggleType.Switch, isOn: filter.enabled })
                .selectedColor($r('app.color.obs_accent'))
                .width(34)
                .height(20)
                .onChange((isOn: boolean) => {
                  ObsController.setFilterEnabled(filter.name, isOn);
                })
              Text(this.typeLabel(filter.typeId))
                .fontSize(13)
                .fontColor($r('app.color.obs_text_primary'))
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Button('×')
                .type(ButtonType.Normal)
                .fontSize(14)
                .fontColor($r('app.color.obs_text_primary'))
                .backgroundColor($r('app.color.obs_panel_border'))
                .borderRadius(4)
                .width(24)
                .height(22)
                .onClick(() => {
                  ObsController.removeFilterFromSelectedSource(filter.name);
                })
            }
            .width('100%')
          }, (filter: FilterItemModel) => filter.name)

          // Add-filter buttons for the registered candidate types.
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.model.filterTypes, (typeId: string) => {
              Button(this.typeLabel(typeId))
                .type(ButtonType.Normal)
                .fontSize(11)
                .fontColor($r('app.color.obs_text_primary'))
                .backgroundColor($r('app.color.obs_panel_border'))
                .borderRadius(4)
                .height(24)
                .margin({ right: 6, bottom: 6 })
                .onClick(() => {
                  ObsController.addFilterToSelectedSource(typeId);
                })
            }, (typeId: string) => typeId)
          }
          .width('100%')
        }
        .width('100%')
        .padding(8)
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
  }
}
