import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;

/// The longest side a stored medication photo may have, in pixels.
const medicationPhotoMaxSide = 1600;

/// The size the cleaned JPEG is brought under, in bytes. The server accepts up
/// to 512 KiB; staying near 300 KB keeps a full backup within its limit.
const medicationPhotoTargetBytes = 300 * 1000;

/// What the server accepts, mirrored here so a downloaded file is checked too.
const medicationPhotoServerMaxBytes = 512 * 1024;

/// Why a picked file could not be turned into a medication photo.
enum MedicationPhotoFailure {
  /// The bytes are not an image this build can read.
  unreadable,

  /// The image could not be brought under the size limit.
  tooLarge,
}

class MedicationPhotoException implements Exception {
  const MedicationPhotoException(this.failure);
  final MedicationPhotoFailure failure;
  @override
  String toString() => 'MedicationPhotoException(${failure.name})';
}

/// A cleaned photo, ready to store: a baseline JPEG with no metadata at all.
class ProcessedMedicationPhoto {
  const ProcessedMedicationPhoto({
    required this.bytes,
    required this.sha256,
    required this.width,
    required this.height,
  });
  final Uint8List bytes;
  final String sha256;
  final int width;
  final int height;
}

/// Decodes [source], applies its orientation, shrinks it to at most
/// [medicationPhotoMaxSide] pixels a side and re-encodes it as a JPEG whose
/// quality is lowered until it is about [medicationPhotoTargetBytes] or less.
///
/// Re-encoding from pixels is what removes the metadata: no Exif (so no GPS
/// position or camera), no XMP and no embedded colour profile survive. The work
/// runs in a separate isolate so the screen never waits on it.
Future<ProcessedMedicationPhoto> processMedicationPhoto(Uint8List source) =>
    Isolate.run(() => cleanMedicationPhoto(source));

/// The synchronous core of [processMedicationPhoto], for tests and isolates.
ProcessedMedicationPhoto cleanMedicationPhoto(Uint8List source) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(source);
  } on Object {
    decoded = null;
  }
  if (decoded == null || decoded.width < 1 || decoded.height < 1) {
    throw const MedicationPhotoException(MedicationPhotoFailure.unreadable);
  }
  var working = img.bakeOrientation(decoded);
  final longest = working.width > working.height
      ? working.width
      : working.height;
  if (longest > medicationPhotoMaxSide) {
    final scale = medicationPhotoMaxSide / longest;
    working = img.copyResize(
      working,
      width: (working.width * scale).round().clamp(1, medicationPhotoMaxSide),
      height: (working.height * scale).round().clamp(1, medicationPhotoMaxSide),
      interpolation: img.Interpolation.average,
    );
  }
  for (var round = 0; round < 6; round++) {
    for (final quality in const [85, 75, 65, 55, 45, 35]) {
      // A fresh image each time: nothing the decoder read can be written back.
      final clean = img.Image.from(working)
        ..exif = img.ExifData()
        ..iccProfile = null;
      final bytes = Uint8List.fromList(img.encodeJpg(clean, quality: quality));
      if (bytes.length <= medicationPhotoTargetBytes) {
        return _result(bytes, clean.width, clean.height);
      }
    }
    // Even the lowest quality is too big: shrink the picture and try again.
    working = img.copyResize(
      working,
      width: (working.width * 0.8).round().clamp(1, medicationPhotoMaxSide),
      height: (working.height * 0.8).round().clamp(1, medicationPhotoMaxSide),
      interpolation: img.Interpolation.average,
    );
  }
  throw const MedicationPhotoException(MedicationPhotoFailure.tooLarge);
}

ProcessedMedicationPhoto _result(Uint8List bytes, int width, int height) {
  if (jpegCarriesMetadata(bytes)) {
    throw const MedicationPhotoException(MedicationPhotoFailure.unreadable);
  }
  return ProcessedMedicationPhoto(
    bytes: bytes,
    sha256: sha256.convert(bytes).toString(),
    width: width,
    height: height,
  );
}

/// Whether [bytes] hold an Exif/XMP (APP1), colour profile (APP2) or Photoshop
/// (APP13) segment, or a comment, before the image data starts.
bool jpegCarriesMetadata(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return true;
  var at = 2;
  while (at + 4 <= bytes.length) {
    if (bytes[at] != 0xFF) return true;
    final marker = bytes[at + 1];
    if (marker == 0xFF) {
      at++;
      continue;
    }
    if (marker == 0xDA || marker == 0xD9) return false;
    if (marker == 0xE1 || marker == 0xE2 || marker == 0xED || marker == 0xFE) {
      return true;
    }
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8)) {
      at += 2;
      continue;
    }
    at += 2 + ((bytes[at + 2] << 8) | bytes[at + 3]);
  }
  return false;
}

/// Whether [bytes] are a JPEG the server would accept: well formed from start
/// to end, no metadata, within the size limit. A downloaded photo is checked
/// with this before it is stored.
bool isAcceptableMedicationPhoto(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > medicationPhotoServerMaxBytes) {
    return false;
  }
  if (bytes.length < 4 ||
      bytes[bytes.length - 2] != 0xFF ||
      bytes[bytes.length - 1] != 0xD9) {
    return false;
  }
  return !jpegCarriesMetadata(bytes);
}
