import { SourceBounds, ObsBridge } from '../napi/obsBridge';
import { ObsAppState, ObsController } from '../model/ObsModel';

/**
 * PreviewInteractor — the canvas gesture layer (W4), an ArkUI overlay on
 * top of the preview XComponent. Desktop OBS lets you click a source in
 * the preview to select it, drag to move, and pull handles to resize;
 * this is the touch equivalent:
 *
 *   tap     → hit-test items (top-most first) → select (syncs the Sources
 *             list selection and the filter panel); empty tap deselects
 *   drag    → move the selected item
 *   pinch   → uniform scale the selected item
 *
 * Coordinates: the native display stretches the base canvas onto the
 * surface (obs_render_main_texture draws into the full viewport — no
 * letterbox), so canvas→view is a plain per-axis scale. Item geometry
 * comes from nativeGetSourceBounds so the outline always matches what the
 * core draws. The outline refreshes on a ~15 Hz poll: cheap (one napi
 * string call) and immune to missing change events from self-animating
 * sources.
 *
 * Device quirk respected here: every visible label on this build uses
 * $r() or a Text child, never a literal Button string (10-04).
 */

interface CanvasTransform {
  scaleX: number;
  scaleY: number;
}

/** One border-scaling guide box, in view px. */
interface GuideBox {
  ratio: string;
  x: number;
  y: number;
  w: number;
  h: number;
}

@ComponentV2
export struct PreviewInteractor {
  @Param @Require model: ObsAppState;
  /** Preview area size, reported by the parent via onAreaChange. */
  @Param viewWidth: number = 0;
  @Param viewHeight: number = 0;

  @Local selBounds: SourceBounds | null = null;
  /** Live drag offset (view px), applied to the outline during a drag. */
  @Local dragDX: number = 0;
  @Local dragDY: number = 0;
  /** Canvas-px position when the current drag began — the live-commit base
   * (selBounds moves under us once a live commit lands, so re-anchoring on
   * it mid-drag would double the offset). */
  private dragStartX: number = 0;
  private dragStartY: number = 0;
  private pollTimer: number = -1;
  private canvasW: number = 1920;
  private canvasH: number = 1080;
  private lastPinchScale: number = 1;
  /** Corner-handle resize state (user request 10-14 #2): the Pan gesture
   * enters resize mode when it began within reach of a selection corner.
   * 0=TL 1=TR 2=BL 3=BR (matches the render ForEach), -1 = not resizing. */
  private resizeCorner: number = -1;
  /** The OPPOSITE corner in canvas px — stays anchored while dragging. */
  private resizeAnchorX: number = 0;
  private resizeAnchorY: number = 0;
  /** The grabbed corner's canvas-px position at gesture start (the live
   * corner = start + drag delta / scale; selBounds churns under live
   * commits so the start corner must be frozen separately). */
  private resizeStartCX: number = 0;
  private resizeStartCY: number = 0;

  aboutToAppear(): void {
    const vi = ObsBridge.getVideoInfo();
    this.canvasW = vi.width;
    this.canvasH = vi.height;
    this.pollTimer = setInterval(() => {
      this.refreshSelection();
    }, 66);
  }

  aboutToDisappear(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private refreshSelection(): void {
    const id = this.model.selectedSourceId;
    if (id === '') {
      if (this.selBounds !== null) {
        this.selBounds = null;
      }
      return;
    }
    const b = ObsBridge.getSourceBounds(id);
    if (b === null) {
      if (this.selBounds !== null) {
        this.selBounds = null;
      }
      return;
    }
    const prev = this.selBounds;
    if (prev === null || prev.x !== b.x || prev.y !== b.y || prev.w !== b.w || prev.h !== b.h) {
      this.selBounds = b;
    }
  }

  private canvasTransform(): CanvasTransform {
    if (this.viewWidth <= 0 || this.viewHeight <= 0) {
      return { scaleX: 1, scaleY: 1 };
    }
    /* UNIFORM aspect-fit scale — must match the native ObsDisplayDrawCallback
     * exactly (s = min(cx/base_w, cy/base_h), canvas centred in the surface).
     * The old per-axis STRETCH model assumed the canvas filled the view, but
     * libobs blits the render_texture at native base size into a (0,0,cx,cy)
     * ortho, so a non-matching surface letterboxes it. Per-axis mapping put
     * the selection box far off the picture (user report 10-14: box much
     * larger than the camera). Both axes now share one scale + an offset. */
    const s = Math.min(this.viewWidth / this.canvasW, this.viewHeight / this.canvasH);
    return { scaleX: s, scaleY: s };
  }

  /** The rendered canvas rect in view px (the letterboxed, centred box the
   * native display draws into). Doubles as the recording-area indicator. */
  private canvasRect(): GuideBox {
    const s = this.canvasTransform().scaleX;
    const w = this.canvasW * s;
    const h = this.canvasH * s;
    return { ratio: 'canvas', x: (this.viewWidth - w) / 2, y: (this.viewHeight - h) / 2, w: w, h: h };
  }

  private scaleBoxes(): GuideBox[] {
    const ratios: string[] = ['4:3', '1:1', '4:5'];
    const boxes: GuideBox[] = [];
    const cr = this.canvasRect();
    if (cr.w <= 0 || cr.h <= 0) {
      return boxes;
    }
    for (const r of ratios) {
      const parts = r.split(':');
      const rw = Number.parseInt(parts[0], 10);
      const rh = Number.parseInt(parts[1], 10);
      if (!(rw > 0 && rh > 0)) {
        continue;
      }
      let w = cr.w;
      let h = w * rh / rw;
      if (h > cr.h) {
        h = cr.h;
        w = h * rw / rh;
      }
      const box: GuideBox = { ratio: r, x: cr.x + (cr.w - w) / 2, y: cr.y + (cr.h - h) / 2, w: w, h: h };
      boxes.push(box);
    }
    return boxes;
  }

  private toCanvasPx(viewX: number, viewY: number): number[] {
    const t = this.canvasTransform();
    const cr = this.canvasRect();
    return [(viewX - cr.x) / t.scaleX, (viewY - cr.y) / t.scaleY];
  }

  /** Top-most first: the Sources list is z-ordered top→bottom, so the
   * first visible box containing the point wins. */
  private hitTest(canvasX: number, canvasY: number): string {
    for (const src of this.model.sources) {
      if (!src.visible) {
        continue;
      }
      const b = ObsBridge.getSourceBounds(src.id);
      if (b !== null && canvasX >= b.x && canvasX <= b.x + b.w &&
        canvasY >= b.y && canvasY <= b.y + b.h) {
        return src.id;
      }
    }
    return '';
  }

  /** Locked items (desktop lock icon) ignore drag/pinch: selection still
   * works (so the settings sheet stays reachable) but geometry does not. */
  private isSelectedLocked(): boolean {
    const id = this.model.selectedSourceId;
    if (id === '') {
      return false;
    }
    const src = this.model.sources.find((candidate): boolean => candidate.id === id);
    return src !== undefined && src.locked;
  }

  /** Corner index (0=TL 1=TR 2=BL 3=BR) if the view-px point is within
   * reach of a handle of the CURRENT selection, else -1. Checked before
   * the regular hit-test so grabbing a handle never re-selects whatever
   * source happens to sit under it (user request 10-14 #2). */
  private cornerAt(viewX: number, viewY: number): number {
    if (this.model.selectedSourceId === '' || this.selBounds === null || this.isSelectedLocked()) {
      return -1;
    }
    const reach = 26; // vp — generous touch target around the 10vp dot
    const ox = this.outlineX();
    const oy = this.outlineY();
    const ow = this.outlineW();
    const oh = this.outlineH();
    const corners: number[][] = [
      [ox, oy], [ox + ow, oy], [ox, oy + oh], [ox + ow, oy + oh]
    ];
    for (let i = 0; i < 4; i++) {
      if (Math.abs(viewX - corners[i][0]) <= reach && Math.abs(viewY - corners[i][1]) <= reach) {
        return i;
      }
    }
    return -1;
  }

  /* ---- Source snapping (desktop 源对齐 parity) ----
   * On drag commit, snap the moved box's edges/centres onto the canvas
   * edges/centre (when snapToEdges) and onto every other visible source's
   * edges/centres, within model.snapThreshold canvas px. Commit-time (not
   * live) snapping keeps the outline honest during the drag and makes the
   * effect predictable on a touch surface. */
  private snapPosition(targetX: number, targetY: number, w: number, h: number): number[] {
    let sx = targetX;
    let sy = targetY;
    const thr = this.model.snapThreshold;

    // Vertical guide lines (x positions) and horizontal ones (y positions).
    const xLines: number[] = [];
    const yLines: number[] = [];
    if (this.model.snapToEdges) {
      xLines.push(0, this.canvasW / 2, this.canvasW);
      yLines.push(0, this.canvasH / 2, this.canvasH);
    }
    const draggedId = this.model.selectedSourceId;
    for (const src of this.model.sources) {
      if (!src.visible || src.id === draggedId) {
        continue;
      }
      const b = ObsBridge.getSourceBounds(src.id);
      if (b === null) {
        continue;
      }
      xLines.push(b.x, b.x + b.w / 2, b.x + b.w);
      yLines.push(b.y, b.y + b.h / 2, b.y + b.h);
    }

    const boxXs: number[] = [targetX, targetX + w / 2, targetX + w];
    const boxYs: number[] = [targetY, targetY + h / 2, targetY + h];

    let bestDX = Infinity;
    for (const line of xLines) {
      for (const bx of boxXs) {
        const d = line - bx;
        if (Math.abs(d) <= thr && Math.abs(d) < Math.abs(bestDX)) {
          bestDX = d;
        }
      }
    }
    let bestDY = Infinity;
    for (const line of yLines) {
      for (const by of boxYs) {
        const d = line - by;
        if (Math.abs(d) <= thr && Math.abs(d) < Math.abs(bestDY)) {
          bestDY = d;
        }
      }
    }
    if (bestDX !== Infinity) {
      sx += bestDX;
    }
    if (bestDY !== Infinity) {
      sy += bestDY;
    }
    return [sx, sy];
  }

  /** Outline geometry (view px) for the current selection.
   * Rendered from the POLLED TRUE BOUNDS only (no drag-offset addition):
   * with live position commits the poll is the single source of truth, so
   * the box can never desync from the pixels (user report 10-13 #3). The
   * ≤66 ms poll lag is imperceptible and always self-correcting. */
  private outlineX(): number {
    return this.selBounds === null ? 0 :
      this.canvasRect().x + this.selBounds.x * this.canvasTransform().scaleX;
  }

  private outlineY(): number {
    return this.selBounds === null ? 0 :
      this.canvasRect().y + this.selBounds.y * this.canvasTransform().scaleY;
  }

  private outlineW(): number {
    return this.selBounds === null ? 0 : this.selBounds.w * this.canvasTransform().scaleX;
  }

  private outlineH(): number {
    return this.selBounds === null ? 0 : this.selBounds.h * this.canvasTransform().scaleY;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      /* Persistent recording-area frame (user report 10-14: "录制的画布区域
       * 标识不明显"). The canvas is now letterboxed inside the panel, so a
       * thin always-on accent border marks exactly what gets recorded /
       * streamed — the black bars outside it are NOT part of the output. */
      Text()
        .width(this.canvasRect().w)
        .height(this.canvasRect().h)
        .position({ x: this.canvasRect().x, y: this.canvasRect().y })
        .border({ width: 1.5, color: '#804DA6FF' })
      /* Preview guides (desktop 参考线 parity): safe-area rectangles, centre
       * cross, and border-ratio boxes — ALL measured off the canvas rect
       * (the view can be letterboxed; guides over black bars are useless).
       * Pure decoration — the Stack is hit-test-transparent. */
      if (this.model.guideSafeAreas) {
        Text()
          .width(this.canvasRect().w * 0.9)
          .height(this.canvasRect().h * 0.9)
          .position({ x: this.canvasRect().x + this.canvasRect().w * 0.05, y: this.canvasRect().y + this.canvasRect().h * 0.05 })
          .border({ width: 2, color: '#CCFFD600', style: BorderStyle.Dashed })
        Text()
          .width(this.canvasRect().w * 0.8)
          .height(this.canvasRect().h * 0.8)
          .position({ x: this.canvasRect().x + this.canvasRect().w * 0.1, y: this.canvasRect().y + this.canvasRect().h * 0.1 })
          .border({ width: 2, color: '#CC4CAF50', style: BorderStyle.Dashed })
      }
      if (this.model.guideCenter) {
        Text()
          .width(2)
          .height(this.canvasRect().h)
          .position({ x: this.canvasRect().x + this.canvasRect().w / 2, y: this.canvasRect().y })
          .backgroundColor('#AAFFFFFF')
        Text()
          .width(this.canvasRect().w)
          .height(2)
          .position({ x: this.canvasRect().x, y: this.canvasRect().y + this.canvasRect().h / 2 })
          .backgroundColor('#AAFFFFFF')
      }
      if (this.model.guideScale) {
        /* Inner-ratio boxes for the canvas aspect: 4:3 / 1:1 / 4:5, centred
         * horizontally and vertically (desktop "border scaling" guides). */
        ForEach(this.scaleBoxes(), (box: GuideBox) => {
          Text()
            .width(box.w)
            .height(box.h)
            .position({ x: box.x, y: box.y })
            .border({ width: 2, color: '#AA00E5FF', style: BorderStyle.Solid })
        }, (box: GuideBox) => `${box.ratio}`)
      }

      if (this.selBounds !== null) {
        // Selection rectangle.
        Text()
          .width(this.outlineW())
          .height(this.outlineH())
          .position({ x: this.outlineX(), y: this.outlineY() })
          .border({ width: 2, color: '#FF3B30' })
        // Four corner handles.
        ForEach([0, 1, 2, 3], (corner: number) => {
          Circle({ width: 10, height: 10 })
            .fill(Color.White)
            .stroke('#FF3B30')
            .strokeWidth(1.5)
            .position({
              x: this.outlineX() + (corner % 2 === 0 ? 0 : this.outlineW()) - 5,
              y: this.outlineY() + (corner < 2 ? 0 : this.outlineH()) - 5
            })
        }, (corner: number) => `${corner}`)
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down && event.touches.length === 1) {
        /* Corner grab takes precedence over (re)selection: a handle sits
         * over the outline edge, and the plain hit-test below would happily
         * select whatever source is under the finger mid-resize. */
        this.resizeCorner = this.cornerAt(event.touches[0].x, event.touches[0].y);
        if (this.resizeCorner < 0) {
          const p = this.toCanvasPx(event.touches[0].x, event.touches[0].y);
          const hit = this.hitTest(p[0], p[1]);
          if (hit !== '') {
            if (this.model.selectedSourceId !== hit) {
              this.model.selectedSourceId = hit;
              ObsController.refreshFilters();
              this.refreshSelection();
            }
          } else {
            this.model.selectedSourceId = '';
            this.selBounds = null;
          }
        }
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.resizeCorner = -1;
      }
      if (event.touches.length >= 2) {
        // A second finger means the user is pinching, not resizing a
        // corner — drop resize mode so the two gestures never fight.
        this.resizeCorner = -1;
      }
    })
    .gesture(
      PanGesture({ distance: 6 })
        .onActionStart((event: GestureEvent) => {
          this.dragDX = 0;
          this.dragDY = 0;
          // Snapshot the drag origin in canvas px for live commits.
          this.dragStartX = this.selBounds === null ? 0 : this.selBounds.x;
          this.dragStartY = this.selBounds === null ? 0 : this.selBounds.y;
          /* Resize mode: the touch-down already classified a corner grab
           * (resizeCorner >= 0). Anchor = the OPPOSITE corner, frozen in
           * canvas px; the grabbed corner's live position = its frozen
           * start + the drag delta. Both are needed because selBounds
           * churns under the live commits. */
          if (this.resizeCorner >= 0 && this.selBounds !== null) {
            const b = this.selBounds;
            const grabRight = (this.resizeCorner % 2 === 1);
            const grabBottom = (this.resizeCorner >= 2);
            const ax = grabRight ? b.x : b.x + b.w;
            const ay = grabBottom ? b.y : b.y + b.h;
            this.resizeAnchorX = ax;
            this.resizeAnchorY = ay;
            this.resizeStartCX = grabRight ? b.x + b.w : b.x;
            this.resizeStartCY = grabBottom ? b.y + b.h : b.y;
          }
        })
        .onActionUpdate((event: GestureEvent) => {
          if (this.model.selectedSourceId !== '' && this.selBounds !== null && !this.isSelectedLocked()) {
            this.dragDX = event.offsetX;
            this.dragDY = event.offsetY;
            const t = this.canvasTransform();
            if (this.resizeCorner >= 0) {
              /* Corner drag: the grabbed corner follows the finger, the
               * opposite corner holds. min/max normalise a flip past the
               * anchor; a 20px floor keeps the rect invertible. */
              const cx = this.resizeStartCX + this.dragDX / t.scaleX;
              const cy = this.resizeStartCY + this.dragDY / t.scaleY;
              const x0 = Math.min(cx, this.resizeAnchorX);
              const y0 = Math.min(cy, this.resizeAnchorY);
              const w = Math.max(Math.abs(cx - this.resizeAnchorX), 20);
              const h = Math.max(Math.abs(cy - this.resizeAnchorY), 20);
              ObsBridge.setSourceRect(this.model.selectedSourceId, x0, y0, w, h);
              return;
            }
            /* Live commit (user report 10-13 #5: the red outline moved but
             * the source lagged until release): push the position to the
             * core on every update. The 66 ms poll below would otherwise
             * re-anchor selBounds to the stale position mid-drag, so the
             * outline keeps its own offset AND the pixels follow.
             * Snapping stays a commit-time affair (predictable on touch). */
            ObsBridge.setSourcePosition(this.model.selectedSourceId,
              this.dragStartX + this.dragDX / t.scaleX,
              this.dragStartY + this.dragDY / t.scaleY);
          }
        })
        .onActionEnd(() => {
          const id = this.model.selectedSourceId;
          const b = this.selBounds;
          const wasResize = this.resizeCorner >= 0;
          this.resizeCorner = -1;
          if (wasResize) {
            // The rect live-commits already landed the final geometry;
            // move-snapping does not apply to a resize gesture.
            this.dragDX = 0;
            this.dragDY = 0;
            this.refreshSelection();
            return;
          }
          if (id !== '' && b !== null && !this.isSelectedLocked() &&
            (this.dragDX !== 0 || this.dragDY !== 0)) {
            const t = this.canvasTransform();
            // The live commits already wrote the un-snapped position;
            // re-derive it from the DRAG ORIGIN (b may already be the moved
            // position after a live commit) so snapping has a clean base.
            let nx = this.dragStartX + this.dragDX / t.scaleX;
            let ny = this.dragStartY + this.dragDY / t.scaleY;
            if (this.model.snapEnabled) {
              const snapped = this.snapPosition(nx, ny, b.w, b.h);
              nx = snapped[0];
              ny = snapped[1];
            }
            ObsBridge.setSourcePosition(id, nx, ny);
          }
          this.dragDX = 0;
          this.dragDY = 0;
          this.refreshSelection();
        })
        .onActionCancel(() => {
          // A cancelled gesture never reaches onActionEnd; reset the deltas
          // so a stale offset cannot leak into the next gesture.
          this.dragDX = 0;
          this.dragDY = 0;
          this.refreshSelection();
        })
    )
    .gesture(
      PinchGesture({ fingers: 2 })
        .onActionStart(() => {
          this.lastPinchScale = 1;
        })
        .onActionUpdate((event: GestureEvent) => {
          const id = this.model.selectedSourceId;
          if (id === '' || this.selBounds === null || this.isSelectedLocked()) {
            return;
          }
          // Incremental ratio since the previous callback — the native
          // scale is multiplicative, so compounding event.scale would
          // square the gesture.
          const step = event.scale / this.lastPinchScale;
          this.lastPinchScale = event.scale;
          ObsBridge.scaleSourceBy(id, step);
          this.refreshSelection();
        })
    )
    /* Desktop canvas right-click parity: long-press a source on the canvas
     * opens the same context menu the source-row long-press shows. The
     * request travels through the model (SourceList owns the sheet). */
    .gesture(
      LongPressGesture({ repeat: false })
        .onAction((event: GestureEvent) => {
          if (event.fingerList.length === 0) {
            return;
          }
          const finger = event.fingerList[0];
          const p = this.toCanvasPx(finger.localX, finger.localY);
          const hit = this.hitTest(p[0], p[1]);
          if (hit !== '') {
            this.model.selectedSourceId = hit;
            this.model.contextMenuSourceId = hit;
            this.model.contextMenuSeq += 1;
          }
        })
    )
  }
}
