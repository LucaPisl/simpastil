import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:simpastil/core/medication/medication_photo_processor.dart';

/// A noisy picture with a GPS position and camera in its Exif, the kind a
/// phone camera produces.
Uint8List _phonePhoto({int width = 3200, int height = 2400, int orient = 1}) {
  final random = math.Random(7);
  final image = img.Image(width: width, height: height);
  for (final pixel in image) {
    pixel
      ..r = random.nextInt(256)
      ..g = random.nextInt(256)
      ..b = random.nextInt(256);
  }
  image.exif.imageIfd['Make'] = 'Fictional Camera Co';
  image.exif.imageIfd.orientation = orient;
  image.exif.gpsIfd[0x0001] = img.IfdValueAscii('N');
  image.exif.gpsIfd[0x0003] = img.IfdValueAscii('E');
  return Uint8List.fromList(img.encodeJpg(image, quality: 95));
}

bool _hasApp1(Uint8List bytes) {
  for (var i = 2; i + 3 < bytes.length; i++) {
    if (bytes[i] == 0xFF && bytes[i + 1] == 0xE1) return true;
  }
  return false;
}

void main() {
  test('the fixture really carries a GPS position', () {
    final source = _phonePhoto(width: 400, height: 300);
    expect(_hasApp1(source), isTrue);
    expect(img.decodeJpg(source)!.exif.gpsIfd.isEmpty, isFalse);
  });

  test('a large phone photo comes out small, bounded and clean', () {
    final out = cleanMedicationPhoto(_phonePhoto());
    expect(out.bytes.length, lessThanOrEqualTo(medicationPhotoTargetBytes));
    expect(
      math.max(out.width, out.height),
      lessThanOrEqualTo(medicationPhotoMaxSide),
    );
    expect(_hasApp1(out.bytes), isFalse);
    expect(jpegCarriesMetadata(out.bytes), isFalse);
    expect(isAcceptableMedicationPhoto(out.bytes), isTrue);
    final back = img.decodeJpg(out.bytes)!;
    expect(back.exif.gpsIfd.isEmpty, isTrue);
    expect(back.exif.imageIfd.hasOrientation, isFalse);
    expect(out.sha256, hasLength(64));
  });

  test('the orientation is applied to the pixels, then dropped', () {
    // Stored sideways (orientation 6 = rotate 90 degrees clockwise).
    final out = cleanMedicationPhoto(
      _phonePhoto(width: 600, height: 300, orient: 6),
    );
    expect(out.width, 300);
    expect(out.height, 600);
  });

  test('the same picture gives the same hash', () {
    final source = _phonePhoto(width: 800, height: 600);
    expect(
      cleanMedicationPhoto(source).sha256,
      cleanMedicationPhoto(source).sha256,
    );
  });

  test('bytes that are not a picture are refused', () {
    expect(
      () => cleanMedicationPhoto(Uint8List.fromList([1, 2, 3, 4])),
      throwsA(
        isA<MedicationPhotoException>().having(
          (e) => e.failure,
          'failure',
          MedicationPhotoFailure.unreadable,
        ),
      ),
    );
  });

  test('it runs off the calling isolate', () async {
    final out = await processMedicationPhoto(
      _phonePhoto(width: 800, height: 600),
    );
    expect(jpegCarriesMetadata(out.bytes), isFalse);
  });
}
