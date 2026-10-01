import { ObsBridge } from '../napi/obsBridge';
import { Logger } from '../common/Logger';

/**
 * PreviewCanvas — wraps XComponent(type: SURFACE) and hands its
 * NativeWindow to the native bridge so libobs's graphics subsystem can
 * create its EGL surface on it.
 *
 * Wiring:
 *  - `libraryname: "obs_bridge"` makes the ArkUI runtime load
 *    libobs_bridge.so for this XComponent and inject the OH_NativeXComponent
 *    into the napi module exports; napi_init.cpp registers the native
 *    surface lifecycle callbacks (created/changed/destroyed) at that point,
 *    BEFORE this component's onLoad fires.
 *  - onLoad: the surface exists natively; we tell the bridge that THIS
 *    XComponent id is the program/preview canvas
 *    (nativeAttachPreviewSurface), which creates the obs_display / EGL
 *    window surface (shell-only builds create a plain EGL surface and clear
 *    it once, exercising the whole seam).
 *  - Surface changed/destroyed are handled natively (xcomponent_surface.cpp
 *    recreates/tears down the graphics surface); onDestroy detaches.
 */
@ComponentV2
export struct PreviewCanvas {
  @Param xcomponentId: string = 'obs-preview-canvas';
  private xcomponentController: XComponentController = new XComponentController();
  @Local surfaceAttached: boolean = false;

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      XComponent({
        id: this.xcomponentId,
        type: XComponentType.SURFACE,
        libraryname: 'obs_bridge',
        controller: this.xcomponentController
      })
        .onLoad(() => {
          // The native module registered its OnSurfaceCreated callback when
          // the XComponent loaded the library; by onLoad time the NativeWindow
          // is in the registry.
          this.surfaceAttached = ObsBridge.attachPreviewSurface(this.xcomponentId);
          if (!this.surfaceAttached) {
            Logger.warn(`preview surface '${this.xcomponentId}' not attached ` +
              '(surface not created yet, or graphics backend unavailable)');
          } else {
            Logger.info(`preview surface '${this.xcomponentId}' attached`);
          }
        })
        .onDestroy(() => {
          if (this.surfaceAttached) {
            ObsBridge.detachPreviewSurface();
            this.surfaceAttached = false;
            Logger.info(`preview surface '${this.xcomponentId}' detached`);
          }
        })
        .width('100%')
        .height('100%')

      if (!this.surfaceAttached) {
        // Honest placeholder: the canvas exists (the EGL seam clears it dark
        // gray in shell-only builds), but no libobs frame producer is bound.
        Text($r('app.string.preview_unavailable'))
          .fontSize(12)
          .fontColor($r('app.color.obs_text_secondary'))
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding(6)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#101216')
    .borderRadius(6)
    .clip(true)
  }
}
