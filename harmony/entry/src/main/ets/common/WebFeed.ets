import { image } from '@kit.ImageKit';
import { ObsBridge } from '../napi/obsBridge';
import { Logger } from '../common/Logger';

/**
 * WebFeed — ArkTS side of the harmony-web (ArkWeb browser) source.
 *
 * ArkWeb is ets-only, so the pixel pipeline starts here: a `Web` component
 * per browser source is rasterised by the system, snapshotted through the
 * UIContext's ComponentSnapshot (BGRA_8888 PixelMap), and the raw buffer is
 * handed to libobs through ObsBridge.webSourceFeed — the same async-video
 * door harmony-remotecam uses, fed from the UI thread at a timer's pace
 * instead of from a codec callback.
 *
 * Mounting rule (SDK doc, verified against @ohos.arkui.UIContext.d.ts):
 * "Off-screen or cached components not mounted in the component tree are not
 * supported" — mounted + positioned outside the visible edge passes (it IS
 * in the tree), unmounted does not. The host (WebFeedHost) renders the list
 * inside the Index layout and shifts each Web node off-canvas with
 * .position({ x: -2000 }); that is the arrangement to verify on device: if
 * the snapshot comes back blank for fully-out-of-window nodes, the host
 * switches to a visible 1vp clipped corner slot — feed plumbing unchanged.
 *
 * Timestamps: 0 is passed to the bridge on purpose — the bridge stamps
 * os_gettime_ns() (its CLOCK_MONOTONIC) on arrival, which keeps audio/video
 * in one clock domain and avoids the epoch-vs-monotonic pitfall found while
 * wiring remotecam audio (task #36).
 */

export class WebFeedEntry {
  itemId: string = '';
  url: string = '';
  width: number = 800;
  height: number = 600;
  refreshMs: number = 100;
  /** Consecutive failures; entries retire after WEB_FEED_MAX_FAILS. */
  fails: number = 0;

  constructor(itemId: string, url: string, width: number, height: number, refreshMs: number) {
    this.itemId = itemId;
    this.url = url;
    this.width = width;
    this.height = height;
    this.refreshMs = refreshMs;
  }
}

/** Single shared registry the off-screen host list renders from. */
@ObservedV2
export class WebFeedRegistry {
  /** Entries the host must keep mounted (one Web node each). */
  @Trace static entries: WebFeedEntry[] = [];

  static upsert(entry: WebFeedEntry): void {
    for (let i = 0; i < WebFeedRegistry.entries.length; i++) {
      if (WebFeedRegistry.entries[i].itemId === entry.itemId) {
        // Replace, not mutate: the host's ForEach key includes url/size so a
        // changed viewport rebuilds the Web node instead of scaling one.
        WebFeedRegistry.entries[i] = entry;
        return;
      }
    }
    WebFeedRegistry.entries.push(entry);
  }

  static get(itemId: string): WebFeedEntry | undefined {
    return WebFeedRegistry.entries.find((e: WebFeedEntry): boolean => e.itemId === itemId);
  }

  static drop(itemId: string): void {
    WebFeedRegistry.entries = WebFeedRegistry.entries.filter(
      (e: WebFeedEntry): boolean => e.itemId !== itemId);
  }
}

const WEB_FEED_MAX_FAILS: number = 10;

/**
 * One pump per mounted Web node. Started from the node's own component
 * aboutToAppear (which is where the live UIContext is available); tick uses
 * an inFlight flag because ComponentSnapshot.get is async and a slow page
 * must not stack snapshots.
 */
@ComponentV2
export struct WebFeedPump {
  @Param @Require entry: WebFeedEntry;
  private timer: number = -1;
  private inFlight: boolean = false;

  aboutToAppear(): void {
    this.timer = setInterval((): void => {
      this.tick();
    }, Math.max(33, this.entry.refreshMs));
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private tick(): void {
    if (this.inFlight) {
      return;
    }
    this.inFlight = true;
    const snap = this.getUIContext().getComponentSnapshot();
    // id of the Web node we are mounted on (see WebFeedHost: `obsweb-${itemId}`)
    snap.get(`obsweb-${this.entry.itemId}`)
      .then((pm: image.PixelMap): void => {
        try {
          this.feedFrame(pm);
        } finally {
          pm.release();
          this.inFlight = false;
        }
      })
      .catch((err: Object): void => {
        this.inFlight = false;
        this.fail(Logger.asError(err).message);
      });
  }

  private fedCount: number = 0;

  private feedFrame(pm: image.PixelMap): void {
    const info: image.ImageInfo = pm.getImageInfoSync();
    const w: number = info.size.width;
    const h: number = info.size.height;
    if (w <= 0 || h <= 0 || w > 8192 || h > 8192) {
      this.fail(`bad snapshot geometry ${w}x${h}`);
      return;
    }
    const buf: ArrayBuffer = new ArrayBuffer(w * h * 4);
    pm.readPixelsToBufferSync(buf);
    // Energy probe (task #36 lesson: count events, but verify DATA): sample
    // the first + every 50th frame's byte sum to tell "snapshot blank" from
    // "feed lost downstream" without burning the UI thread on full scans.
    this.fedCount++;
    if (this.fedCount === 1 || this.fedCount % 500 === 0) {
      const v = new Uint8Array(buf);
      let sum = 0;
      for (let i = 0; i < v.length; i += 401) {
        sum += v[i];
      }
      Logger.info(`webfeed ${this.entry.itemId}: frame#${this.fedCount} ${w}x${h} bytes=${buf.byteLength} sum~${sum}`);
    }
    // ts 0 → bridge stamps os_gettime_ns() on arrival (single clock domain).
    const ok: boolean = ObsBridge.webSourceFeed(this.entry.itemId, w, h, buf, 0);
    if (ok) {
      this.entry.fails = 0;
    } else {
      // false = the libobs item is gone (scene reload / source removed):
      // retire; the next refreshSources() diff will rebuild it if back.
      this.fail('feed rejected (source gone?)');
      WebFeedRegistry.drop(this.entry.itemId);
    }
  }

  private fail(reason: string): void {
    this.entry.fails++;
    if (this.entry.fails === 1 || this.entry.fails % 5 === 0) {
      Logger.warn(`webfeed ${this.entry.itemId}: ${reason} (x${this.entry.fails})`);
    }
    if (this.entry.fails >= WEB_FEED_MAX_FAILS) {
      WebFeedRegistry.drop(this.entry.itemId);
    }
  }

  build() {
    // Renders nothing itself — the pump is an invisible timer wrapper; the
    // actual Web node lives in WebFeedHost next to it.
    Row().width(0).height(0)
  }
}
