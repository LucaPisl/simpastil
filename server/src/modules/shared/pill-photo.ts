import { ApiError } from './api-error.js';
import { ErrorCode } from './errors.js';

// The one photo of a medication (capability contracts.medicationPhoto 1).
// The app shrinks and re-encodes the picture, which drops every piece of
// metadata (camera, location). The server does not trust that: it checks the
// file again and refuses anything that still carries an Exif or XMP segment.
// Photo bytes are personal data and never appear in a log or an error.

export const PILL_PHOTO_MAX_BYTES = 524288;
export const PILL_PHOTO_MAX_SIDE = 1600;
/** Route body limit: the photo plus a little slack for the HTTP framing. */
export const PILL_PHOTO_BODY_LIMIT = 614400;

export interface JpegInfo {
  width: number;
  height: number;
}

function reject(message: string): never {
  throw new ApiError(422, ErrorCode.VALIDATION_ERROR, message, { retryable: false });
}

const SOF_MARKERS = new Set([0xc0, 0xc1, 0xc2]);
// Markers that stand alone, without a length.
const bare = (marker: number) => marker === 0x01 || (marker >= 0xd0 && marker <= 0xd8);

/**
 * Checks the bytes are a JPEG, reads its size and refuses metadata segments.
 * Throws a 422 ApiError that says what is wrong, never the content.
 */
export function inspectJpeg(bytes: Buffer): JpegInfo {
  if (bytes.length === 0) reject('The photo is empty');
  if (bytes.length > PILL_PHOTO_MAX_BYTES) {
    throw new ApiError(413, ErrorCode.VALIDATION_ERROR, 'The photo is larger than 512 KiB', { retryable: false });
  }
  if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8 || bytes[2] !== 0xff) {
    reject('The photo is not a JPEG');
  }
  if (bytes[bytes.length - 2] !== 0xff || bytes[bytes.length - 1] !== 0xd9) {
    reject('The photo is incomplete');
  }
  let size: JpegInfo | undefined;
  let offset = 2;
  while (offset < bytes.length) {
    if (bytes[offset] !== 0xff) reject('The photo is not a valid JPEG');
    while (bytes[offset] === 0xff) offset += 1;
    const marker = bytes[offset];
    offset += 1;
    if (marker === undefined || marker === 0x00) reject('The photo is not a valid JPEG');
    if (bare(marker)) continue;
    if (marker === 0xd9) reject('The photo has no image data');
    if (offset + 2 > bytes.length) reject('The photo is not a valid JPEG');
    const length = bytes.readUInt16BE(offset);
    if (length < 2 || offset + length > bytes.length) reject('The photo is not a valid JPEG');
    if (marker === 0xe1 || marker === 0xed) {
      reject('The photo carries metadata (Exif, XMP); send it without');
    }
    if (SOF_MARKERS.has(marker)) {
      if (length < 8) reject('The photo is not a valid JPEG');
      const height = bytes.readUInt16BE(offset + 3);
      const width = bytes.readUInt16BE(offset + 5);
      size = { width, height };
    }
    if (marker === 0xda) break; // image data follows; the header is complete
    offset += length;
  }
  if (!size) reject('The photo is not a baseline or progressive JPEG');
  if (size.width < 1 || size.height < 1
      || size.width > PILL_PHOTO_MAX_SIDE || size.height > PILL_PHOTO_MAX_SIDE) {
    reject('The photo is larger than 1600 px on a side');
  }
  return size;
}
