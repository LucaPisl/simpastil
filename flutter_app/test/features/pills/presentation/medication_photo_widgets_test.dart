import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:simpastil/core/medication/medication_photo_processor.dart';
import 'package:simpastil/features/pills/medication_photo_repository.dart';
import 'package:simpastil/features/pills/presentation/medication_photo_card.dart';
import 'package:simpastil/features/pills/presentation/medication_photo_field.dart';
import 'package:simpastil/l10n/app_localizations.dart';

const _pillId = 'pill-1';

Uint8List _photo() {
  final random = math.Random(3);
  final image = img.Image(width: 120, height: 80);
  for (final pixel in image) {
    pixel
      ..r = random.nextInt(256)
      ..g = random.nextInt(256)
      ..b = random.nextInt(256);
  }
  return Uint8List.fromList(img.encodeJpg(image));
}

Widget _app(
  Widget child, {
  List<Override> overrides = const [],
  Brightness brightness = Brightness.light,
  double textScale = 1.0,
  Locale locale = const Locale('en'),
}) => ProviderScope(
  overrides: overrides,
  child: MaterialApp(
    locale: locale,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.teal,
        brightness: brightness,
      ),
    ),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, app) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: app!,
    ),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

void main() {
  final bytes = _photo();
  final view = MedicationPhotoView(bytes: bytes, sha256: 'x' * 64);

  Override stored(MedicationPhotoView? value) => medicationPhotoProvider(
    _pillId,
  ).overrideWith((ref) => Stream.value(value));

  for (final width in [390.0, 1000.0]) {
    for (final dark in [false, true]) {
      for (final scale in [1.0, 1.3]) {
        testWidgets('the card fits at width ${width.toInt()}, '
            '${dark ? 'dark' : 'light'}, text x$scale', (tester) async {
          tester.view.physicalSize = Size(width, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            _app(
              const MedicationPhotoCard(pillId: _pillId, name: 'Fakeolol'),
              overrides: [stored(view)],
              brightness: dark ? Brightness.dark : Brightness.light,
              textScale: scale,
            ),
          );
          await tester.pump();
          expect(find.byType(Image), findsOneWidget);
          expect(tester.takeException(), isNull);
          final size = tester.getSize(
            find
                .descendant(
                  of: find.byType(MedicationPhotoFrame),
                  matching: find.byType(DecoratedBox),
                )
                .first,
          );
          expect(size.width, lessThanOrEqualTo(math.min(width, 420)));
          // The picture has a label for a screen reader.
          expect(find.bySemanticsLabel('Photo of Fakeolol'), findsOneWidget);
        });
      }
    }
  }

  testWidgets('the card shows nothing without a photo', (tester) async {
    await tester.pumpWidget(
      _app(
        const MedicationPhotoCard(pillId: _pillId, name: 'Fakeolol'),
        overrides: [stored(null)],
      ),
    );
    await tester.pump();
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('the Romanian label is used', (tester) async {
    await tester.pumpWidget(
      _app(
        const MedicationPhotoCard(pillId: _pillId, name: 'Fakeolol'),
        overrides: [stored(view)],
        locale: const Locale('ro'),
      ),
    );
    await tester.pump();
    expect(find.bySemanticsLabel('Fotografie cu Fakeolol'), findsOneWidget);
  });

  group('the edit field', () {
    Widget field({
      Uint8List? storedBytes,
      MedicationPhotoDraft draft = const MedicationPhotoDraft(),
      required ValueChanged<MedicationPhotoDraft> onChanged,
      List<Override> overrides = const [],
      double textScale = 1.0,
    }) => _app(
      MedicationPhotoField(
        name: 'Fakeolol',
        stored: storedBytes,
        draft: draft,
        onChanged: onChanged,
      ),
      overrides: overrides,
      textScale: textScale,
    );

    for (final width in [390.0, 1000.0]) {
      testWidgets('offers add and, once there is a photo, replace and remove '
          'at width ${width.toInt()}, text x1.3', (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(field(onChanged: (_) {}, textScale: 1.3));
        expect(find.text('Add a photo'), findsOneWidget);
        expect(find.byKey(const ValueKey('photo-remove')), findsNothing);
        await tester.pumpWidget(
          field(storedBytes: bytes, onChanged: (_) {}, textScale: 1.3),
        );
        expect(find.text('Replace photo'), findsOneWidget);
        expect(find.byKey(const ValueKey('photo-remove')), findsOneWidget);
        expect(tester.takeException(), isNull);
        // Targets are at least 48 logical pixels tall.
        for (final key in ['photo-pick', 'photo-remove']) {
          expect(
            tester.getSize(find.byKey(ValueKey(key))).height,
            greaterThanOrEqualTo(48),
          );
        }
      });
    }

    testWidgets('picking cleans the photo and reports the change', (
      tester,
    ) async {
      MedicationPhotoDraft? reported;
      await tester.pumpWidget(
        field(
          onChanged: (d) => reported = d,
          overrides: [
            medicationPhotoPickerProvider.overrideWithValue(
              (ImageSource source) async => bytes,
            ),
          ],
        ),
      );
      await tester.tap(find.byKey(const ValueKey('photo-pick')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('photo-source-gallery')));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 2)),
      );
      await tester.pump();
      expect(reported?.staged, isNotNull);
      expect(jpegCarriesMetadata(reported!.staged!.bytes), isFalse);
    });

    testWidgets('a file that is not a picture shows a message', (tester) async {
      MedicationPhotoDraft? reported;
      await tester.pumpWidget(
        field(
          onChanged: (d) => reported = d,
          overrides: [
            medicationPhotoPickerProvider.overrideWithValue(
              (ImageSource source) async => Uint8List.fromList([1, 2, 3]),
            ),
          ],
        ),
      );
      await tester.tap(find.byKey(const ValueKey('photo-pick')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('photo-source-gallery')));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 2)),
      );
      await tester.pump();
      expect(reported, isNull);
      expect(find.textContaining('could not be used'), findsOneWidget);
    });

    testWidgets('remove reports a removal', (tester) async {
      MedicationPhotoDraft? reported;
      await tester.pumpWidget(
        field(storedBytes: bytes, onChanged: (d) => reported = d),
      );
      await tester.tap(find.byKey(const ValueKey('photo-remove')));
      expect(reported?.removed, isTrue);
    });

    testWidgets('a removed photo shows as empty until saved', (tester) async {
      await tester.pumpWidget(
        field(
          storedBytes: bytes,
          draft: const MedicationPhotoDraft(removed: true),
          onChanged: (_) {},
        ),
      );
      expect(find.byKey(const ValueKey('photo-preview')), findsNothing);
      expect(find.text('Add a photo'), findsOneWidget);
    });
  });
}
