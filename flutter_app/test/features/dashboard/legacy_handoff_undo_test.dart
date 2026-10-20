import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart' show OccurrenceEventsCompanion;
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/storage/layout_family_preference.dart';
import 'package:simpastil/features/dashboard/focus_deck.dart';
import 'package:simpastil/features/dashboard/selected_date_provider.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../helpers/care_recording_fixture.dart';
import '../../helpers/window_view.dart';

/// Every Today layout offers Undo for a dose the app recorded, and none offers
/// it (neither enabled nor disabled) for the event activation backfilled from
/// a dose recorded through the bridge: that dose's stock lives in the handoff.
Finder _undo() => find.byWidgetPredicate((w) {
  final key = w.key;
  return key is ValueKey<String> &&
      (key.value == 'focus-undo' || key.value.contains('-undo-'));
});

Future<void> _mount(
  WidgetTester tester,
  LayoutFamily family, {
  required String origin,
}) async {
  final f = await CareRecordingFixture.create();
  final writer = CareRecordingService(
    database: f.db,
    access: f.workspace.access,
    context: f.workspace.context,
    clock: () => DateTime.utc(2026, 9, 30, 11, 17),
  );
  final receipt = await writer.commit(
    await writer.prepareTakenNow(
      personId: f.person.id,
      occurrenceId: f.occurrence.id,
      expectedStateVersion: 0,
      amount: const MedicationAmount.unknown(),
    ),
  );
  await f.db.medicationLedgerDao.updateOccurrenceEvent(
    receipt.event.id,
    OccurrenceEventsCompanion(origin: Value(origin)),
  );
  final container = await f.workspace.createContainer();
  await container.read(layoutFamilyProvider.notifier).apply(family);
  container
      .read(selectedDateProvider.notifier)
      .select(CareRecordingFixture.planned);
  useWindow(tester, const Size(412, 914));
  addTearDown(() async {
    await tester.binding.setSurfaceSize(null);
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.pump(const Duration(milliseconds: 1));
    await f.db.close();
    await tester.pumpAndSettle();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: AppTheme.light(),
        home: const FocusTodayScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  for (final family in LayoutFamily.values) {
    testWidgets('${family.name}: a native dose offers Undo', (tester) async {
      await _mount(tester, family, origin: 'native');
      expect(_undo(), findsOneWidget);
    });
    testWidgets('${family.name}: a backfilled bridge dose offers no Undo', (
      tester,
    ) async {
      await _mount(tester, family, origin: 'legacy_handoff');
      expect(_undo(), findsNothing);
      expect(
        find.textContaining('Fictional recorded medication'),
        findsWidgets,
      );
    });
  }
}
