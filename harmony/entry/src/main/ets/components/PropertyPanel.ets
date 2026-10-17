import { ObsController } from '../model/ObsModel';
import { Logger } from '../common/Logger';

/**
 * PropertyPanel — the generic obs_properties renderer (desktop parity: the
 * auto-generated half of every source/filter settings dialog).
 *
 * The bridge walks obs_source_properties() into a JSON schema (see
 * CollectPropertySchema in obs_bridge.cpp: key/label/type + ranges/options/
 * current value); this component turns each descriptor into the matching
 * touch control and writes patches back through setSourceSettings or
 * setFilterSettings. A plugin that adds a property gets UI for free.
 *
 * Rendered inside a bindSheet from FilterPanel (per-filter gear) — one
 * instance per open sheet.
 */

/** One schema row, mirroring the C++ descriptor shape. */
@ObservedV2
class PropRow {
  @Trace key: string = '';
  @Trace label: string = '';
  @Trace type: string = '';
  @Trace format: string = 'string';
  @Trace boolValue: boolean = false;
  @Trace numValue: number = 0;
  @Trace textValue: string = '';
  @Trace min: number = 0;
  @Trace max: number = 100;
  @Trace step: number = 1;
  @Trace suffix: string = '';
  @Trace optionNames: string[] = [];
  @Trace optionValues: (string | number)[] = [];
  @Trace selectedIndex: number = 0;
}

/** Local draft map: key -> current widget value (number for bool/int/float/
 * color/list-int/list-float, string for text/list-string). Commits go
 * per-control (toggle/slider release/field submit) so the plugin's update()
 * sees the same granularity as the desktop dialog's live apply. */
@ComponentV2
export struct PropertyPanel {
  @Param @Require itemId: string;
  /** '' renders the source's own properties; otherwise the named filter's. */
  @Param filterName: string = '';
  @Param title: string = '';
  @Event onClose: () => void = () => {};

  @Local rows: PropRow[] = [];
  @Local loading: boolean = true;

  aboutToAppear(): void {
    this.reload();
  }

  private reload(): void {
    const json = ObsController.getPropertySchema(this.itemId, this.filterName);
    const rows: PropRow[] = [];
    try {
      const arr = JSON.parse(json) as Record<string, Object>[];
      for (const entry of arr) {
        const row = new PropRow();
        row.key = String(entry['key'] ?? '');
        row.label = String(entry['label'] ?? row.key);
        row.type = String(entry['type'] ?? '');
        row.suffix = String(entry['suffix'] ?? '');
        if (row.type === 'bool') {
          row.boolValue = entry['value'] === true;
        } else if (row.type === 'list') {
          row.format = String(entry['format'] ?? 'string');
          const opts = (entry['options'] ?? []) as Record<string, Object>[];
          for (const o of opts) {
            row.optionNames.push(String(o['name'] ?? ''));
            const v: Object = o['value'];
            row.optionValues.push(typeof v === 'number' ? v : String(v ?? ''));
          }
          const cur: Object = entry['value'] ?? '';
          const want: string = typeof cur === 'number' ? String(cur) : String(cur);
          let idx = row.optionNames.length > 0 ? 0 : -1;
          for (let i = 0; i < row.optionValues.length; i++) {
            if (String(row.optionValues[i]) === want) {
              idx = i;
              break;
            }
          }
          row.selectedIndex = idx < 0 ? 0 : idx;
          if (typeof cur === 'number') {
            row.numValue = cur;
          }
        } else if (row.type === 'text') {
          row.textValue = String(entry['value'] ?? '');
        } else {
          // int / float / color — numeric draft.
          row.min = Number(entry['min'] ?? 0);
          row.max = Number(entry['max'] ?? 100);
          row.step = Number(entry['step'] ?? 1);
          row.numValue = Number(entry['value'] ?? 0);
          if (row.type === 'int' && !Number.isFinite(row.step)) {
            row.step = 1;
          }
        }
        if (row.key !== '' && row.type !== '') {
          rows.push(row);
        }
      }
    } catch (err) {
      Logger.error('PropertyPanel schema parse failed', Logger.asError(err as Object));
    }
    this.rows = rows;
    this.loading = false;
  }

  /** Route a patch to the right write-back (source vs filter settings). */
  private commit(patch: Record<string, Object>): void {
    const json = JSON.stringify(patch);
    if (this.filterName === '') {
      ObsController.setSourceSettings(this.itemId, patch);
    } else {
      ObsController.setFilterSettings(this.itemId, this.filterName, json);
    }
  }

  private listOptionLabels(row: PropRow): SelectOption[] {
    return row.optionNames.map((n: string): SelectOption => {
      const opt: SelectOption = { value: n };
      return opt;
    });
  }

  private onListSelect(row: PropRow, index: number): void {
    row.selectedIndex = index;
    const v = row.optionValues[index];
    const patch: Record<string, Object> = {};
    patch[row.key] = v;
    this.commit(patch);
  }

  @Builder
  RowWidget(row: PropRow) {
    if (row.type === 'bool') {
      Row() {
        Text(row.label)
          .fontSize(13)
          .fontColor($r('app.color.obs_text_primary'))
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: row.boolValue })
          .selectedColor($r('app.color.obs_accent'))
          .onChange((isOn: boolean) => {
            row.boolValue = isOn;
            const patch: Record<string, Object> = {};
            patch[row.key] = isOn;
            this.commit(patch);
          })
      }
      .width('100%')
      .padding({ top: 5, bottom: 5 })
    } else if (row.type === 'int' || row.type === 'float' || row.type === 'color') {
      Column({ space: 2 }) {
        Text(`${row.label}  ${row.type === 'color' ? `0x${Math.round(row.numValue).toString(16)}` :
        `${row.numValue}${row.suffix}`}`)
          .fontSize(12)
          .fontColor($r('app.color.obs_text_secondary'))
          .width('100%')
        Slider({
          value: row.numValue,
          min: row.min,
          max: row.max,
          step: row.step > 0 ? row.step : 1
        })
          .width('100%')
          .onChange((v: number, mode: SliderChangeMode) => {
            const snapped = row.type === 'int' || row.type === 'color' ? Math.round(v) : v;
            row.numValue = snapped;
            // Live-apply on release only: sliders on filters (sharpness,
            // delay) are cheap, but update() per frame would spam logs.
            if (mode === SliderChangeMode.End) {
              const patch: Record<string, Object> = {};
              patch[row.key] = snapped;
              this.commit(patch);
            }
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ top: 4, bottom: 4 })
    } else if (row.type === 'list') {
      Row({ space: 8 }) {
        Text(row.label)
          .fontSize(13)
          .fontColor($r('app.color.obs_text_primary'))
          .width(110)
          .maxLines(2)
        Select(this.listOptionLabels(row))
          .selected(row.selectedIndex)
          .value(row.optionNames.length > 0 ? row.optionNames[row.selectedIndex] : '')
          .font({ size: 12 })
          .fontColor($r('app.color.obs_text_primary'))
          .selectedOptionFont({ size: 12 })
          .optionFont({ size: 12 })
          .layoutWeight(1)
          .onSelect((index: number) => {
            this.onListSelect(row, index);
          })
      }
      .width('100%')
      .padding({ top: 5, bottom: 5 })
    } else {
      Column({ space: 2 }) {
        Text(row.label)
          .fontSize(12)
          .fontColor($r('app.color.obs_text_secondary'))
          .width('100%')
        TextInput({ text: row.textValue })
          .fontSize(13)
          .height(34)
          .backgroundColor($r('app.color.obs_panel_border'))
          .fontColor($r('app.color.obs_text_primary'))
          .onChange((v: string) => {
            row.textValue = v;
          })
          .onSubmit(() => {
            const patch: Record<string, Object> = {};
            patch[row.key] = row.textValue;
            this.commit(patch);
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ top: 4, bottom: 4 })
    }
  }

  build() {
    Column({ space: 4 }) {
      Row() {
        Text(this.title !== '' ? this.title : (this.filterName === '' ? '属性' : this.filterName))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.obs_text_primary'))
          .layoutWeight(1)
        Button() {
          /* literal-string Button labels render as grey blocks on this
           * device (10-04) — Text child instead. */
          Text('刷新').fontSize(12).fontColor($r('app.color.obs_text_secondary'))
        }
          .type(ButtonType.Normal)
          .height(30)
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            this.reload();
          })
        Button() {
          /* '✕' (U+2715) is NOT in the device font and rendered as an empty
           * circle — the "invisible close button" (user report 10-13, 2nd
           * round). Chinese label + accent background always renders and
           * is unmistakable. */
          Text('关闭').fontSize(13).fontWeight(FontWeight.Medium).fontColor(Color.White)
        }
          .type(ButtonType.Normal)
          .height(32)
          .padding({ left: 14, right: 14 })
          .margin({ left: 8 })
          .backgroundColor($r('app.color.obs_accent'))
          .borderRadius(6)
          .onClick(() => {
            this.onClose();
          })
      }
      .width('100%')
      .margin({ top: 12 })

      if (!this.loading && this.rows.length === 0) {
        Text('该对象没有可显示的属性')
          .fontSize(12)
          .fontColor($r('app.color.obs_text_secondary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 20, bottom: 20 })
      }

      Scroll() {
        Column({ space: 2 }) {
          ForEach(this.rows, (row: PropRow) => {
            this.RowWidget(row)
          }, (row: PropRow) => row.key)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Auto)
      .align(Alignment.Top)

      Button() {
        Text('关闭').fontSize(14).fontWeight(FontWeight.Medium).fontColor(Color.White)
      }
        .type(ButtonType.Normal)
        .height(40)
        .width('100%')
        .backgroundColor($r('app.color.obs_accent'))
        .borderRadius(6)
        .margin({ top: 6, bottom: 12 })
        .onClick(() => {
          this.onClose();
        })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.obs_background'))
  }
}
