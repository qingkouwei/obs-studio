import { ObsBridge } from '../napi/obsBridge';
import { Logger } from '../common/Logger';
import { ObsAppState } from '../model/ObsModel';
import { PreviewInteractor } from './PreviewInteractor';

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
  /** When provided, the canvas gesture overlay (select/move/pinch-scale)
   * is mounted above the surface (W4). */
  @Param model: ObsAppState | null = null;
  /** Studio mode: this canvas is the SECOND display, rendering the private
   * preview canvas (attach routes to nativeAttachStudioPreviewSurface). */
  @Param studioPreview: boolean = false;
  private xcomponentController: XComponentController = new XComponentController();
  @Local surfaceAttached: boolean = false;
  @Local areaW: number = 0;
  @Local areaH: number = 0;

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      XComponent({
        id: this.xcomponentId,
        type: XComponentType.SURFACE,
        libraryname: 'obs_bridge',
        controller: this.xcomponentController
      })
        // ArkUI identity for componentSnapshot.get() (the W3-C4 program
        // monitor grabs this canvas by id). The XComponent CONSTRUCTOR id
        // above is the native surface-registration key — a different
        // namespace; the snapshot API only sees .id() attributes.
        .id(this.xcomponentId)
        .onLoad(() => {
          // The native module registered its OnSurfaceCreated callback when
          // the XComponent loaded the library; by onLoad time the NativeWindow
          // is in the registry.
          this.surfaceAttached = this.studioPreview ?
            ObsBridge.attachStudioPreviewSurface(this.xcomponentId) :
            ObsBridge.attachPreviewSurface(this.xcomponentId);
          if (!this.surfaceAttached) {
            Logger.warn(`preview surface '${this.xcomponentId}' not attached ` +
              '(surface not created yet, or graphics backend unavailable)');
          } else {
            Logger.info(`preview surface '${this.xcomponentId}' attached`);
          }
        })
        .onDestroy(() => {
          if (this.surfaceAttached) {
            if (this.studioPreview) {
              ObsBridge.detachStudioPreviewSurface();
            } else {
              ObsBridge.detachPreviewSurface();
            }
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

      // W4 canvas gesture overlay (tap-select / drag-move / pinch-scale).
      // Only mounted when a model was handed in — shell-only builds and the
      // program monitor keep the plain surface.
      if (this.model !== null) {
        PreviewInteractor({ model: this.model, viewWidth: this.areaW, viewHeight: this.areaH })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#101216')
    .borderRadius(6)
    .clip(true)
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      this.areaW = Number(newValue.width);
      this.areaH = Number(newValue.height);
    })
  }
}
