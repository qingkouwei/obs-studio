import { Logger } from './Logger';

/**
 * Desktop Extension Kit stub (status bar / quickbar dock integration).
 *
 * STATUS: intentionally NOT implemented.
 *
 * The Desktop Extension Kit is available from HarmonyOS 6.0.2(22)+ and is
 * CHINA-MAINLAND ONLY. Until (a) the extension API set is confirmed on the
 * target PC/2in1 image and (b) a region gate is in place, OBS must not
 * depend on it. Everything here is a guarded no-op so call sites can exist
 * without behavior.
 *
 * When implemented, this is where the app would:
 *  - pin a quickbar/status-bar entry with live stream state (bitrate, LIVE),
 *  - expose start/stop streaming controls without raising the main window,
 *  - deep-link back into the main window's transport bar.
 */
export class DesktopExtensionStub {
  /** True only when the kit could be usable on this device/region/build. */
  static isAvailable(): boolean {
    // Guarded probe: the kit is 6.0.2(22)+ and CN-only. We do not even probe
    // the syscap strings here because the kit's syscaps are not present in
    // the international SDK this scaffold builds against; the answer today is
    // unconditionally false. Keep this the single source of truth so the
    // feature flag flips in exactly one place when that changes.
    return false;
  }

  /** Request the status-bar/quickbar entry. No-op until isAvailable() is true. */
  static installDockEntry(): void {
    if (!DesktopExtensionStub.isAvailable()) {
      Logger.debug('Desktop Extension Kit unavailable on this device/region — skipping dock entry');
      return;
    }
    Logger.info('Desktop Extension Kit dock entry installed');
  }

  /** Remove the dock entry on shutdown. No-op until implemented. */
  static removeDockEntry(): void {
    if (!DesktopExtensionStub.isAvailable()) {
      return;
    }
    Logger.info('Desktop Extension Kit dock entry removed');
  }
}
