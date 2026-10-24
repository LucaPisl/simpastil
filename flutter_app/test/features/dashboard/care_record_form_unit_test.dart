import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/features/dashboard/care_record_form.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';

import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../helpers/care_recording_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  for (final (code, shown) in [('ro', 'comprimat'), ('en', 'tablet')]) {
    testWidgets(
      'the care record form shows the unit in the app language ($code) and '
      'hands back the stored unit',
      (tester) async {
        final f = await CareRecordingFixture.create();
        final container = await f.workspace.createContainer();
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          container.dispose();
          await f.db.close();
          await tester.pumpAndSettle();
        });
        CareRecordValues? values;
        final service = CareRecordingService(
          database: f.db,
          access: f.workspace.access,
          context: f.workspace.context,
        );
        await tester.binding.setSurfaceSize(const Size(412, 1400));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.light(),
              locale: Locale(code),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: CareRecordForm(
                service: service,
                personName: 'Fictional Alex',
                medicationName: 'Fictional medication',
                localDate: '2026-09-30',
                amount: MedicationAmount.known('1', 'tablet'),
                prepare: (v) async {
                  values = v;
                  throw StateError('stop after the values are captured');
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final field = find.widgetWithText(TextField, shown);
        expect(field, findsOneWidget);
        // Review without touching the unit: the stored English unit goes on.
        final review = find.text(
          AppLocalizations.of(
            tester.element(find.byType(CareRecordForm)),
          ).t10_reviewRecord,
        );
        await tester.ensureVisible(review);
        await tester.pumpAndSettle();
        await tester.tap(review);
        await tester.pumpAndSettle();
        expect(values?.amount.unit, 'tablet');
        expect(values?.amount.quantityText, '1');
      },
    );
  }
}
