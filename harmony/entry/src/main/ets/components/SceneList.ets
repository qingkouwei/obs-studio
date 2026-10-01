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

  build() {
    Column({ space: 6 }) {
      Row() {
        Text($r('app.string.scenes'))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.obs_text_secondary'))
        Blank()
        Button('+')
          .type(ButtonType.Normal)
          .fontSize(14)
          .fontColor($r('app.color.obs_text_primary'))
          .backgroundColor($r('app.color.obs_panel_border'))
          .borderRadius(4)
          .width(28)
          .height(24)
          .enabled(this.model.coreReady)
          .onClick(() => {
            ObsController.createScene(`Scene ${this.model.sceneNameCounter}`);
          })
        Button('-')
          .type(ButtonType.Normal)
          .fontSize(14)
          .fontColor($r('app.color.obs_text_primary'))
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
            $r('app.color.obs_accent') : Color.Transparent)
            .onClick(() => {
              ObsController.selectScene(scene.id);
            })
          }
        }, (scene: SceneItemModel) => scene.id)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)

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
  }
}
