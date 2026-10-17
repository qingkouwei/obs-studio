import { ObsAppState, ObsController, SceneItemModel } from '../model/ObsModel';

/**
 * SceneList — the scenes dock (bottom-left panel in the desktop OBS layout).
 * Selection drives which scene's items SourceList shows; mutations go
 * through ObsController -> native bridge -> libobs and are re-read afterwards
 * so the UI always reflects the core's state.
 */
@ComponentV2
export struct SceneList {
  @Param @Require model: ObsAppState;
  /** Long-press context menu (desktop right-click parity): rename / delete. */
  @Local menuOpen: boolean = false;
  @Local menuScene: SceneItemModel | null = null;
  @Local renameOpen: boolean = false;
  @Local renameDraft: string = '';

  private openRename(): void {
    const scene = this.menuScene;
    if (scene !== null) {
      this.renameDraft = scene.name;
      this.renameOpen = true;
    }
    this.menuOpen = false;
  }

  private applyRename(): void {
    const scene = this.menuScene;
    if (scene !== null && this.renameDraft.trim() !== '') {
      ObsController.renameSceneById(scene.id, this.renameDraft);
    }
    this.renameOpen = false;
  }

  private delScene(): void {
    const scene = this.menuScene;
    if (scene !== null) {
      ObsController.removeSceneById(scene.id);
    }
    this.menuOpen = false;
  }

  @Builder
  MenuRow(label: string, action: () => void) {
    Text(label)
      .fontSize(13)
      .fontColor($r('app.color.obs_text_primary'))
      .width('100%')
      .padding({ top: 9, bottom: 9, left: 4 })
      .onClick(action)
  }

  @Builder
  SceneMenuSheet() {
    Column() {
      Text(this.menuScene !== null ? this.menuScene.name : '')
        .fontSize(12)
        .fontColor($r('app.color.obs_text_secondary'))
        .width('100%')
        .margin({ top: 12, bottom: 4 })
      this.MenuRow('重命名', () => {
        this.openRename();
      })
      this.MenuRow('删除', () => {
        this.delScene();
      })
      Button() {
        Text('取消').fontSize(13).fontColor($r('app.color.obs_text_secondary'))
      }
        .type(ButtonType.Normal)
        .height(32)
        .width('100%')
        .margin({ top: 6 })
        .backgroundColor($r('app.color.obs_panel_border'))
        .borderRadius(4)
        .onClick(() => {
          this.menuOpen = false;
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 12 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.obs_background'))
  }

  @Builder
  SceneRenameSheet() {
    Column({ space: 10 }) {
      Text('重命名场景')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.obs_text_primary'))
        .width('100%')
        .margin({ top: 14 })
      TextInput({ text: this.renameDraft })
        .fontSize(13)
        .height(36)
        .width('100%')
        .backgroundColor($r('app.color.obs_panel_border'))
        .fontColor($r('app.color.obs_text_primary'))
        .onChange((v: string) => {
          this.renameDraft = v;
        })
      Button('确定')
        .type(ButtonType.Normal)
        .fontSize(13)
        .height(32)
        .width('100%')
        .fontColor($r('app.color.obs_text_primary'))
        .backgroundColor($r('app.color.obs_accent'))
        .borderRadius(4)
        .onClick(() => {
          this.applyRename();
        })
      Button('取消')
        .type(ButtonType.Normal)
        .fontSize(13)
        .height(32)
        .width('100%')
        .fontColor($r('app.color.obs_text_secondary'))
        .backgroundColor($r('app.color.obs_panel_border'))
        .borderRadius(4)
        .onClick(() => {
          this.renameOpen = false;
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
        Text($r('app.string.scenes'))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.obs_text_secondary'))
        Blank()
        /* Device quirk 10-04 (API 26 / this ROM): Button(label: string) with
         * literal glyphs renders a textless grey block (the accessibility
         * tree still carries the label, but no pixels). Resource-string
         * buttons render fine; the child-Text form below renders fine too,
         * so never pass a literal string as a Button label. */
        Button() {
          Text('+').fontSize(14).fontColor($r('app.color.obs_text_primary'))
        }
          .type(ButtonType.Normal)
          .backgroundColor($r('app.color.obs_panel_border'))
          .borderRadius(4)
          .width(28)
          .height(24)
          .enabled(this.model.coreReady)
          .onClick(() => {
            ObsController.createScene(
              this.getUIContext().getHostContext()!.resourceManager.getStringSync(
                $r('app.string.scene_named').id, `${this.model.sceneNameCounter + 1}`));
          })
        Button() {
          Text('-').fontSize(14).fontColor($r('app.color.obs_text_primary'))
        }
          .type(ButtonType.Normal)
          .backgroundColor($r('app.color.obs_panel_border'))
          .borderRadius(4)
          .width(28)
          .height(24)
          .margin({ left: 6 })
          .enabled(this.model.coreReady && this.model.selectedSceneId !== '')
          .onClick(() => {
            ObsController.removeSelectedScene();
          })
      }
      .width('100%')

      List({ space: 2 }) {
        ForEach(this.model.scenes, (scene: SceneItemModel) => {
          ListItem() {
            Row() {
              Text(scene.name)
                .fontSize(13)
                .fontColor($r('app.color.obs_text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .height(30)
            .padding({ left: 8, right: 8 })
            .borderRadius(4)
            .backgroundColor(scene.id === this.model.selectedSceneId ?
            $r('app.color.obs_accent') :
              (scene.id === this.model.previewSceneId && this.model.studioMode ? '#3a4a63' : Color.Transparent))
            .onClick(() => {
              // Studio mode stages the click on the preview (accent-blue
              // highlight); otherwise it cuts the program directly.
              ObsController.pickScene(scene.id);
            })
            .gesture(LongPressGesture().onAction(() => {
              this.menuScene = scene;
              this.menuOpen = true;
            }))
          }
        }, (scene: SceneItemModel) => scene.id)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      /* Context menu on its own node (two bindSheets on one node silently
       * drop the earlier one, 10-06 lesson). */
      .bindSheet($$this.menuOpen,
        this.SceneMenuSheet(),
        {
          height: SheetSize.FIT_CONTENT,
          dragBar: true,
          showClose: false,
          backgroundColor: $r('app.color.obs_background')
        })

      if (!this.model.coreReady && this.model.scenes.length === 0) {
        Text($r('app.string.scene_edit_unavailable'))
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
    /* Rename dialog: separate node from the menu sheet. */
    .bindSheet($$this.renameOpen,
      this.SceneRenameSheet(),
      {
        height: SheetSize.FIT_CONTENT,
        dragBar: true,
        showClose: false,
        backgroundColor: $r('app.color.obs_background')
      })
  }
}
