import { unifiedDataChannel, uniformTypeDescriptor as utd } from '@kit.ArkData';
import { Logger } from './Logger';
import { ObsController } from '../model/ObsModel';

const TAG = 'DragDrop';

const IMAGE_EXT = /\.(png|jpe?g|webp|bmp|gif)$/i;

/**
 * DragDropReceiver — the second half of W3 C6 (continuation was the first,
 * 50e8c5c8d). An ArkUI component drop (from the file manager, gallery, or —
 * per the official cross-device story — dragged off a phone's screen bezel
 * onto this window, the system handles the transport) lands images as
 * image sources.
 *
 * Intake policy:
 * - unifiedDataChannel.Image records (gallery/albums) and File records whose
 *   uri names an image extension (file manager hands over a plain File
 *   record with general.file-uri, not an Image) are both accepted; the
 *   same suffix set the image picker filters on.
 * - Everything else declined. The .allowDrop() predicate lets the system
 *   paint "no drop" feedback for unsupported payloads before the gesture
 *   lands, so this class is the second (semantic) gate, not the only one.
 * - Accepted uris are copied into the sandbox — media URIs are not
 *   open()able by native libobs — through the picker's copyUriToSandbox,
 *   one code path, one bug surface.
 */
export class DragDropReceiver {
  /** Types we accept — passed to .allowDrop() so the system gives correct
   * drag feedback for unsupported payloads at dragover time. file-uri is
   * what the file manager drags (any file type); the suffix gate below
   * narrows it to images. */
  static allowedTypes(): string[] {
    return [utd.UniformDataType.IMAGE, 'general.file-uri'];
  }

  /** onDrop handler. Returns the number of sources actually created. */
  static handleDrop(data: unifiedDataChannel.UnifiedData): number {
    const types: string[] = data.getTypes();
    Logger.info(`${TAG}: payload types=[${types.join(',')}]`);
    let added = 0;
    for (const rec of data.getRecords()) {
      // Only file-shaped records carry a uri (Image extends File).
      if (!(rec instanceof unifiedDataChannel.Image) && !(rec instanceof unifiedDataChannel.File)) {
        Logger.info(`${TAG}: record ${rec.getType()} is not file-shaped, skipping`);
        continue;
      }
      const fileRec = rec as unifiedDataChannel.File;
      const uri: string = fileRec.uri ?? '';
      if (uri === '') {
        Logger.warn(`${TAG}: file record without uri, skipping`);
        continue;
      }
      // A plain File record must name an image suffix; Image records trust
      // the UDMF classification (uri may be a media-library handle without
      // a readable extension).
      const isImage = rec instanceof unifiedDataChannel.Image || IMAGE_EXT.test(uri);
      if (!isImage) {
        Logger.info(`${TAG}: non-image file ${uri}, skipping`);
        continue;
      }
      const copied = ObsController.copyUriToSandbox(uri);
      if (copied === '') {
        Logger.warn(`${TAG}: copy failed for ${uri}`);
        continue;
      }
      ObsController.addSource('image_source', JSON.stringify({ file: copied }));
      added += 1;
    }
    Logger.info(`${TAG}: ${added} source(s) created`);
    return added;
  }
}
