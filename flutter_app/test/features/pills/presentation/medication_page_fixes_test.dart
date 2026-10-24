import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/features/pills/medication_photo_repository.dart';
import 'package:simpastil/features/pills/presentation/medication_detail_sections.dart';
import 'package:simpastil/features/pills/presentation/medication_photo_card.dart';
import 'package:simpastil/features/setup/setup_state.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';

final _png = Uint8List.fromList(const [
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0xF8,
  0xFF,
  0xFF,
  0x3F,
  0x00,
  0x05,
  0xFE,
  0x02,
  0xFE,
  0xA7,
  0x35,
  0x81,
  0x84,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
]);

Widget _app(
  Widget child, {
  Locale locale = const Locale('en'),
  bool dark = false,
  double scale = 1,
}) => ProviderScope(
  overrides: [
    medicationPhotoProvider('p').overrideWith(
      (ref) => Stream.value(MedicationPhotoView(bytes: _png, sha256: 'x' * 64)),
    ),
  ],
  child: MaterialApp(
    locale: locale,
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    themeMode: dark ? ThemeMode.dark : ThemeMode.light,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, c) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: c!,
    ),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

void main() {
  test('only details that still wait for a review ask for one', () {
    final unreviewed = MedicationReview(
      name: 'A',
      amount: MedicationAmount.known('1', 'tablet'),
      originalDosage: '1 tablet',
    );
    expect(detailsNeedReview(unreviewed), isTrue);
    expect(detailsNeedReview(const MedicationReview(name: 'A')), isTrue);
    final reviewed = MedicationReview(
      name: 'A',
      amount: MedicationAmount.known('1', 'tablet'),
      originalDosage: '1 tablet',
      legacyDosageReviewed: true,
    );
    expect(detailsNeedReview(reviewed), isFalse);
    final noDosage = MedicationReview(
      name: 'A',
      amount: MedicationAmount.known('1', 'tablet'),
    );
    expect(detailsNeedReview(noDosage), isFalse);
  });

  testWidgets('a fact is one screen-reader item with its label', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(const MedicationFact(label: 'Form', value: 'Tablet')),
    );
    expect(
      find.bySemanticsLabel(RegExp('Form.*Tablet', dotAll: true)),
      findsOne,
    );
    handle.dispose();
  });

  testWidgets('the read-only labels have no "(optional)"', (tester) async {
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (c) {
            final l = AppLocalizations.of(c);
            return Text('${l.rvm_form}|${l.rvm_strength}|${l.rvm_notes}');
          },
        ),
      ),
    );
    expect(find.text('Form|Package strength|Notes'), findsOneWidget);
  });

  for (final ro in [false, true]) {
    for (final dark in [false, true]) {
      for (final scale in [1.0, 1.3]) {
        testWidgets('photo card and viewer ro=$ro dark=$dark x$scale', (
          tester,
        ) async {
          final handle = tester.ensureSemantics();
          tester.view.physicalSize = const Size(412, 915);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            _app(
              const MedicationPhotoCard(
                pillId: 'p',
                name: 'Fakeolol',
                maxWidth: double.infinity,
                fill: true,
              ),
              locale: Locale(ro ? 'ro' : 'en'),
              dark: dark,
              scale: scale,
            ),
          );
          await tester.pump();
          expect(
            find.bySemanticsLabel(
              ro
                  ? 'Deschide fotografia cu Fakeolol pe tot ecranul'
                  : 'Open the photo of Fakeolol full screen',
            ),
            findsOneWidget,
          );
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          await tester.tap(find.byKey(const ValueKey('medication-photo-open')));
          await tester.pumpAndSettle();
          expect(
            find.byTooltip(ro ? 'Închide fotografia' : 'Close the photo'),
            findsOneWidget,
          );
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          await expectLater(tester, meetsGuideline(textContrastGuideline));
          handle.dispose();
        });
      }
    }
  }
}
