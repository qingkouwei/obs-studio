import { resourceManager } from '@kit.LocalizationKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from './Logger';

/**
 * Extracts the HAP's rawfile assets into a writable directory.
 *
 * This is not an optimisation — it is mandatory. Files under resources/rawfile
 * live inside the HAP and are only reachable through ResourceManager; they have
 * no filesystem path. libobs resolves its data files with access()/fopen()
 * (find_libobs_data_file in libobs/obs-harmony.c), and obs_reset_video() loads
 * six .effect shaders that way. Without extraction the video subsystem fails to
 * initialise and nothing renders.
 *
 * The layout written here is what obs_harmony_set_paths() expects for dataDir:
 *   <dataDir>/libobs/*.effect                 libobs shaders
 *   <dataDir>/obs-plugins/<module>/locale/*   plugin translations
 *
 * Extraction is idempotent and version-stamped: a marker file records the
 * bundle versionCode, and a matching stamp skips the copy entirely so normal
 * launches do not pay for it.
 */

const STAMP_FILE = '.extracted-version';
const TAG = 'RawFileExtractor';

/**
 * getRawFileListSync returns folders and files in a single undifferentiated
 * list, so the only reliable way to tell them apart is to attempt a read: a
 * folder makes getRawFileContentSync throw.
 */
function isRawFileDirectory(rm: resourceManager.ResourceManager, relativePath: string): boolean {
  try {
    rm.getRawFileContentSync(relativePath);
    return false;
  } catch (err) {
    const e = err as BusinessError;
    Logger.debug(`${TAG}: '${relativePath}' is a directory (${e.code})`);
    return true;
  }
}

function writeRawFile(rm: resourceManager.ResourceManager, relativePath: string, destPath: string): boolean {
  let content: Uint8Array;
  try {
    content = rm.getRawFileContentSync(relativePath);
  } catch (err) {
    const e = err as BusinessError;
    Logger.error(`${TAG}: cannot read rawfile '${relativePath}'`, Logger.asError(err as Object));
    return false;
  }

  try {
    const file = fs.openSync(destPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      // Uint8Array is a view; writeSync wants the underlying ArrayBuffer.
      const buffer = content.buffer.slice(content.byteOffset, content.byteOffset + content.byteLength);
      fs.writeSync(file.fd, buffer);
    } finally {
      fs.closeSync(file);
    }
  } catch (err) {
    Logger.error(`${TAG}: cannot write '${destPath}'`, Logger.asError(err as Object));
    return false;
  }
  return true;
}

/**
 * Recursively copies rawfileDir into destDir, mirroring the relative structure.
 * Returns the number of files written.
 */
function extractRecursive(rm: resourceManager.ResourceManager, rawfileDir: string, destDir: string): number {
  let entries: string[];
  try {
    entries = rm.getRawFileListSync(rawfileDir);
  } catch (err) {
    // An empty directory throws rather than returning []. Nothing to extract.
    Logger.debug(`${TAG}: '${rawfileDir}' is empty or absent`);
    return 0;
  }

  if (!fs.accessSync(destDir)) {
    fs.mkdirSync(destDir, true);
  }

  let written = 0;
  for (const entry of entries) {
    const childRaw = rawfileDir.length === 0 ? entry : `${rawfileDir}/${entry}`;
    const childDest = `${destDir}/${entry}`;

    if (isRawFileDirectory(rm, childRaw)) {
      written += extractRecursive(rm, childRaw, childDest);
    } else if (writeRawFile(rm, childRaw, childDest)) {
      written++;
    }
  }
  return written;
}

function readStamp(dataDir: string): string {
  const stampPath = `${dataDir}/${STAMP_FILE}`;
  try {
    if (!fs.accessSync(stampPath)) {
      return '';
    }
    const file = fs.openSync(stampPath, fs.OpenMode.READ_ONLY);
    try {
      const buf = new ArrayBuffer(64);
      const n = fs.readSync(file.fd, buf);
      const bytes = new Uint8Array(buf, 0, n);
      let s = '';
      for (let i = 0; i < bytes.length; i++) {
        s += String.fromCharCode(bytes[i]);
      }
      return s.trim();
    } finally {
      fs.closeSync(file);
    }
  } catch (err) {
    Logger.warn(`${TAG}: cannot read stamp: ${Logger.asError(err as Object).message}`);
    return '';
  }
}

function writeStamp(dataDir: string, version: string): void {
  const stampPath = `${dataDir}/${STAMP_FILE}`;
  try {
    const file = fs.openSync(stampPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, version);
    } finally {
      fs.closeSync(file);
    }
  } catch (err) {
    Logger.warn(`${TAG}: cannot write stamp: ${Logger.asError(err as Object).message}`);
  }
}

export class RawFileExtractor {
  /**
   * Ensures <dataDir> holds the rawfile tree. `version` should be the bundle's
   * versionCode so that an app upgrade invalidates the cached copy.
   *
   * @returns the number of files written, or -1 if the cache was already valid.
   */
  static extract(rm: resourceManager.ResourceManager, dataDir: string, version: string): number {
    if (!fs.accessSync(dataDir)) {
      fs.mkdirSync(dataDir, true);
    }

    if (readStamp(dataDir) === version && version.length > 0) {
      Logger.info(`${TAG}: rawfile assets already extracted (version ${version})`);
      return -1;
    }

    Logger.info(`${TAG}: extracting rawfile assets to ${dataDir} (version ${version})`);
    const written = extractRecursive(rm, '', dataDir);
    writeStamp(dataDir, version);
    Logger.info(`${TAG}: extracted ${written} file(s)`);

    // Fail loudly rather than letting obs_reset_video() fail mysteriously: the
    // libobs shaders are the difference between a rendering app and a black one.
    if (!fs.accessSync(`${dataDir}/libobs/default.effect`)) {
      Logger.error(`${TAG}: libobs/default.effect is missing after extraction — ` +
        'obs_reset_video() will fail and nothing will render. Was install_obs_data ' +
        'wired for the libobs target?');
    }
    return written;
  }
}
