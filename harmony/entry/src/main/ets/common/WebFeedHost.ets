import { webview } from '@kit.ArkWeb';
import { Logger } from './Logger';
import { WebFeedEntry, WebFeedPump, WebFeedRegistry } from './WebFeed';

/**
 * WebFeedHost — the off-screen Web nodes behind every browser source.
 *
 * Mounted exactly once inside Index's producer layout, sized 0x0 and clipped:
 * the Web children carry the real viewport but sit at x=-2000, far outside
 * the window. They are still "mounted in the component tree" (the SDK rule
 * that unmounted/cached nodes cannot be snapshotted — see WebFeed.ets), and
 * componentSnapshot works on out-of-window positioned nodes as long as the
 * window itself is shown; the on-device pass of this feature will confirm
 * blank-vs-content and, if blank, flip the position to a visible 1vp clipped
 * corner without touching anything else.
 *
 * Each entry gets: one Web (id `obsweb-<itemId>`, the snapshot target) and
 * one WebFeedPump timer bound to it. The list is reactive: adding a browser
 * source upserts an entry, removing/scene-reloading drops it, and the host
 * re-renders on its own (the ForEach key includes url and viewport so any
 * change rebuilds that node cleanly).
 */
@ComponentV2
export struct WebFeedHost {
  build() {
    Stack() {
      ForEach(WebFeedRegistry.entries, (entry: WebFeedEntry) => {
        Column() {
          Web({ src: entry.url, controller: new webview.WebviewController() })
            .id(`obsweb-${entry.itemId}`)
            .width(entry.width)
            .height(entry.height)
            .domStorageAccess(true)
            .javaScriptAccess(true)
            .fileAccess(false)
            .mixedMode(MixedMode.None)
            .backgroundColor(Color.Black)
            .onErrorReceive((ev) => {
              Logger.warn(`webfeed ${entry.itemId}: load error ${ev.request?.getRequestUrl()} ` +
                `${ev.error.getErrorCode()} ${ev.error.getErrorInfo()}`);
            })
            .onPageEnd((ev) => {
              Logger.info(`webfeed ${entry.itemId}: page end ${ev.url}`);
            })
          WebFeedPump({ entry: entry })
        }
        .width(entry.width)
        .height(entry.height)
        .position({ x: -2000, y: 0 })
        .clip(true)
      }, (entry: WebFeedEntry): string => `${entry.itemId}|${entry.url}|${entry.width}x${entry.height}`)
    }
    .width(0)
    .height(0)
    .clip(true)
    .hitTestBehavior(HitTestMode.Transparent)
  }
}
