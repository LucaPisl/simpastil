import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/medication_detail_provider.dart';
import 'package:simpastil/features/pills/presentation/medication_edit.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../../helpers/care_recording_fixture.dart';
import '../../../helpers/held_provider_read.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  testWidgets('the edit form can retire the original dosage reminder', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(412, 915)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final f = await CareRecordingFixture.create();
    // A dosage no parser should guess, so the switch is the only way out.
    await (f.db.update(f.db.pills)..where((p) => p.id.equals(f.pill.id))).write(
      const PillsCompanion(dosage: Value('1-2 tablets')),
    );
    final container = await f.workspace.createContainer();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await f.db.close();
      container.dispose();
      await tester.pumpAndSettle();
    });
    final repository = await container.readHeld(
      medicationDetailRepositoryProvider,
    );
    final detail = await repository.load(f.pill.id);
    expect(detail.review.legacyDosageReviewed, isFalse);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: AppTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    showMedicationReview(context, detail, repository),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final reviewed = find.byKey(
      const ValueKey('edit-medication-dosage-reviewed'),
    );
    await tester.ensureVisible(reviewed);
    await tester.pumpAndSettle();
    expect(find.text('Original dosage text · Not reviewed'), findsOneWidget);

    await tester.tap(reviewed);
    await tester.pumpAndSettle();
    expect(find.text('Original dosage text · Reviewed'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('save-medication-review')));
    await tester.pumpAndSettle();

    final saved = await repository.load(f.pill.id);
    expect(saved.review.legacyDosageReviewed, isTrue);
    // Clearing the reminder never rewrites the wording or invents an amount.
    expect(saved.review.originalDosage, '1-2 tablets');
    expect(saved.review.amount.isUnknown, isTrue);
  });
}
