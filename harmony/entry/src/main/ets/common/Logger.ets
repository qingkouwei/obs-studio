import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * Thin wrapper over @ohos.hilog so every layer (ability, UI, bridge wrapper)
 * logs through one domain/tag pair. Domain 0x0B50 == "OBS".
 *
 * Native side logs under the same domain/tag (see LOG_DOMAIN in the cpp).
 */
const DOMAIN: number = 0x0b50;
const TAG: string = 'ObsHarmony';

export class Logger {
  static debug(message: string): void {
    hilog.debug(DOMAIN, TAG, '%{public}s', message);
  }

  static info(message: string): void {
    hilog.info(DOMAIN, TAG, '%{public}s', message);
  }

  static warn(message: string): void {
    hilog.warn(DOMAIN, TAG, '%{public}s', message);
  }

  /**
   * Log an error. `err` is optional because ArkTS catch clauses are untyped:
   * callers pass the caught value through asError() below.
   */
  static error(message: string, err?: BusinessError): void {
    if (err !== undefined && err !== null) {
      hilog.error(DOMAIN, TAG, '%{public}s | code=%{public}d message=%{public}s', message,
        err.code ?? -1, err.message ?? String(err));
    } else {
      hilog.error(DOMAIN, TAG, '%{public}s', message);
    }
  }

  /**
   * Normalize a caught value into a BusinessError-shaped object for error().
   * Never throws — defensive by design, a logging path must not take down the
   * UI.
   */
  static asError(caught: Object): BusinessError {
    const err = caught as BusinessError;
    if (err === null || err === undefined) {
      return { code: -1, message: 'unknown error', name: 'Error' } as BusinessError;
    }
    return err;
  }
}
