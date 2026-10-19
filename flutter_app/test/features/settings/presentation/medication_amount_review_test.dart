import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_sharing_provider.dart';
import 'package:simpastil/core/medication/care_sharing_status.dart';
import 'package:simpastil/core/medication/medication_detail_provider.dart';
import 'package:simpastil/features/settings/migration_issue_provider.dart';
import 'package:simpastil/features/settings/presentation/medication_amount_review_screen.dart';
import 'package:simpastil/features/settings/presentation/sync_recovery_screen.dart';
import 'package:simpastil/features/settings/presentation/sync_settings_section.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../../helpers/care_recording_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  testWidgets('readable original text is previewed and accepted in one pass', (
    tester,
  ) async {
    final f = await CareRecordingFixture.create();
    await _setDosage(f, '1 pastila');
    await f.workspace.access.viewPerson(
      f.workspace.context,
      null,
      everyone: true,
    );
    final container = await f.workspace.createContainer();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await f.db.close();
      container.dispose();
      await tester.pumpAndSettle();
    });
    await _open(tester, container);

    // The person sees the exact amount before accepting, not just a count.
    expect(find.text('Original text: 1 pastila'), findsOneWidget);
    expect(find.text('Sets 1 pastila per use'), findsOneWidget);
    expect(container.read(medicationAmountReviewCountProvider), 1);

    await tester.tap(find.byKey(const ValueKey('amount-review-accept')));
    await tester.pumpAndSettle();

    expect(find.text('1 amount saved'), findsOneWidget);
    final detail = await container.read(
      medicationDetailProvider(f.pill.id).future,
    );
    expect(detail.review.amount.quantityText, '1');
    expect(detail.review.amount.unit, 'pastila');
    expect(detail.review.legacyDosageReviewed, isTrue);
    // The wording itself is evidence and is never rewritten.
    expect(detail.review.originalDosage, '1 pastila');
    expect(container.read(medicationAmountReviewCountProvider), 0);
  });

  testWidgets('text carrying a second number is left for the person', (
    tester,
  ) async {
    final f = await CareRecordingFixture.create();
    await _setDosage(f, '1-2 tablets');
    await f.workspace.access.viewPerson(
      f.workspace.context,
      null,
      everyone: true,
    );
    final container = await f.workspace.createContainer();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await f.db.close();
      container.dispose();
      await tester.pumpAndSettle();
    });
    await _open(tester, container);

    expect(find.text('Set these yourself'), findsOneWidget);
    expect(find.text('Original text: 1-2 tablets'), findsOneWidget);
    // Nothing is offered in bulk, so no amount can be guessed wrong.
    expect(find.byKey(const ValueKey('amount-review-accept')), findsNothing);
    final detail = await container.read(
      medicationDetailProvider(f.pill.id).future,
    );
    expect(detail.review.amount.isUnknown, isTrue);
    expect(detail.review.legacyDosageReviewed, isFalse);
  });

  testWidgets('a reviewed medicine leaves the list', (tester) async {
    final f = await CareRecordingFixture.create();
    await _setDosage(f, '1 pastila');
    await f.workspace.access.viewPerson(
      f.workspace.context,
      null,
      everyone: true,
    );
    await f.db
        .into(f.db.medicationDetails)
        .insertOnConflictUpdate(
          MedicationDetailsCompanion.insert(
            pillId: f.pill.id,
            amountJson: '{"version":1,"state":"unknown"}',
            legacyDosageReviewed: const Value(true),
          ),
        );
    final container = await f.workspace.createContainer();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await f.db.close();
      container.dispose();
      await tester.pumpAndSettle();
    });
    await _open(tester, container);

    expect(find.byKey(const ValueKey('amount-review-empty')), findsOneWidget);
    expect(container.read(medicationAmountReviewCountProvider), 0);
  });

  testWidgets('the Data screen offers the review with its count', (
    tester,
  ) async {
    final f = await CareRecordingFixture.create();
    await _setDosage(f, '1 pastila');
    await f.workspace.access.viewPerson(
      f.workspace.context,
      null,
      everyone: true,
    );
    final container = await f.workspace.createContainer(
      extraOverrides: [
        careSharingStatusProvider.overrideWith(
          (_) => Stream.value(
            const CareSharingStatus(
              isLocalOnly: false,
              lastCarePullAt: null,
              pendingCount: 0,
              needsReviewCount: 0,
              uncertainCount: 0,
            ),
          ),
        ),
        keptNotesCountProvider.overrideWith((_) async => 0),
        migrationIssuesProvider.overrideWith((_) => Stream.value(const [])),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await f.db.close();
      container.dispose();
      await tester.pumpAndSettle();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SyncSettingsSection(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final entry = find.byKey(const ValueKey('medication-amount-review-entry'));
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    expect(
      find.text('1 medicine still shows its original dosage text'),
      findsOneWidget,
    );
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.byType(MedicationAmountReviewScreen), findsOneWidget);
  });

  testWidgets('viewing one person says the list is partial', (tester) async {
    final f = await CareRecordingFixture.create();
    await _setDosage(f, '1 pastila');
    await f.workspace.access.viewPerson(f.workspace.context, f.person.id);
    final container = await f.workspace.createContainer();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await f.db.close();
      container.dispose();
      await tester.pumpAndSettle();
    });
    await _open(tester, container);

    expect(find.textContaining('Switch to Everyone'), findsOneWidget);
  });
}

/// Saves the medicine the way the older client did: dosage as plain text,
/// with no structured amount beside it.
Future<void> _setDosage(CareRecordingFixture f, String dosage) =>
    (f.db.update(f.db.pills)..where((p) => p.id.equals(f.pill.id))).write(
      PillsCompanion(dosage: Value(dosage)),
    );

Future<void> _open(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: AppTheme.light(),
        home: const MedicationAmountReviewScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
