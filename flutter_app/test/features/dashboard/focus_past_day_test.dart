import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/storage/layout_family_preference.dart';
import 'package:simpastil/core/utils/app_clock.dart';
import 'package:simpastil/features/dashboard/focus_deck.dart';
import 'package:simpastil/features/dashboard/selected_date_provider.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../helpers/care_recording_fixture.dart';

/// The Focus deck opened on the fixture's day (09:00 UTC on September 30)
/// two days after it, on a phone.
Future<CareRecordingFixture> _mountTwoDaysLater(WidgetTester tester) async {
  final f = await CareRecordingFixture.create();
  final container = await f.workspace.createContainer(
    extraOverrides: [
      appClockProvider.overrideWithValue(() => DateTime(2026, 10, 2, 12)),
    ],
  );
  await container
      .read(layoutFamilyProvider.notifier)
      .apply(LayoutFamily.focusDeck);
  container
      .read(selectedDateProvider.notifier)
      .select(CareRecordingFixture.planned);
  await tester.binding.setSurfaceSize(const Size(412, 914));
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
  return f;
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  testWidgets('a day already gone names itself and records at the planned '
      'time', (tester) async {
    final f = await _mountTwoDaysLater(tester);
    expect(find.text('Wednesday'), findsOneWidget);
    expect(find.text('September 30 · 2 days ago'), findsOneWidget);
    expect(find.text('Taken at 9:00 AM'), findsOneWidget);
    expect(find.text('Taken now'), findsNothing);
    expect(find.text('Records it on Wednesday, September 30'), findsOneWidget);

    await _tap(tester, find.byKey(const ValueKey('focus-taken')));
    final events = await tester.runAsync(
      () => f.db.select(f.db.occurrenceEvents).get(),
    );
    expect(events, hasLength(1));
    expect(events!.single.action, 'take');
    expect(events.single.actualTimeKnown, isTrue);
    expect(events.single.actualAt!.toUtc(), CareRecordingFixture.planned);
    expect(find.byKey(const ValueKey('focus-undo')), findsOneWidget);
  });

  testWidgets('Skip on a phone records at once and can be undone', (
    tester,
  ) async {
    final f = await _mountTwoDaysLater(tester);
    await _tap(tester, find.byKey(const ValueKey('focus-skip')));
    var events = await tester.runAsync(
      () => f.db.select(f.db.occurrenceEvents).get(),
    );
    expect(events!.map((e) => e.action), ['skip']);
    await _tap(tester, find.byKey(const ValueKey('focus-undo')));
    events = await tester.runAsync(
      () => f.db.select(f.db.occurrenceEvents).get(),
    );
    expect(events!.map((e) => e.action), ['skip', 'undo']);
    expect(find.byKey(const ValueKey('focus-taken')), findsOneWidget);
  });
}
