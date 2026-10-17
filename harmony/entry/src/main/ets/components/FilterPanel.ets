import { FilterItemModel, ObsAppState, ObsController } from '../model/ObsModel';
import { PropertyPanel } from './PropertyPanel';

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
  /** Generic property sheet for one filter (desktop filter-settings parity). */
  @Local propSheetOpen: boolean = false;
  @Local propFilterName: string = '';

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
      case 'gain_filter':
        return $r('app.string.filter_gain');
      case 'noise_gate_filter':
        return $r('app.string.filter_noise_gate');
      case 'noise_suppress_filter':
        return $r('app.string.filter_noise_suppress');
      case 'late_delay_filter':
        return $r('app.string.filter_late_delay');
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
              Button() {
                /* literal-string Button labels render as grey blocks on this
                 * device (10-04) — Text child instead. */
                Text('⚙').fontSize(13).fontColor($r('app.color.obs_text_secondary'))
              }
                .type(ButtonType.Normal)
                .backgroundColor(Color.Transparent)
                .borderRadius(4)
                .width(24)
                .height(22)
                .onClick(() => {
                  this.propFilterName = filter.name;
                  this.propSheetOpen = true;
                })
              Button() {
                /* literal-string Button labels render as grey blocks on this
                 * device (10-04) — Text child instead. */
                Text('×').fontSize(14).fontColor($r('app.color.obs_text_primary'))
              }
                .type(ButtonType.Normal)
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
                  /* Native names the filter after its type id, so on success
                   * we can open its property sheet right away — the user
                   * complaint "滤镜面板没有看到 Gamma 等" was really "I added
                   * a filter and still can't see its parameters": the panel
                   * only ever showed add-buttons, the sliders lived one
                   * hidden ⚙ tap away (10-13). */
                  if (ObsController.addFilterToSelectedSource(typeId)) {
                    this.propFilterName = typeId;
                    this.propSheetOpen = true;
                  }
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
    /* Generic property sheet for the selected filter. Bound here (not on a
     * per-row node) — one sheet instance, the filter name travels in state. */
    .bindSheet($$this.propSheetOpen,
      this.PropSheet(),
      {
        /* PC dialog size (10-12): MEDIUM clipped long property lists and the
         * content collided with the system ✕. ✕ OFF (10-13 #3): the dim grey
         * close glyph was unreadable and overlapped header content; the
         * sheet has a full-width blue 关闭 button plus drag-bar/tap-outside. */
        height: '80%',
        width: 560,
        dragBar: true,
        showClose: false,
        backgroundColor: $r('app.color.obs_background')
      })
  }

  @Builder
  PropSheet() {
    PropertyPanel({
      itemId: this.model.selectedSourceId,
      filterName: this.propFilterName,
      title: this.propFilterName,
      onClose: () => {
        this.propSheetOpen = false;
      }
    })
  }
}
