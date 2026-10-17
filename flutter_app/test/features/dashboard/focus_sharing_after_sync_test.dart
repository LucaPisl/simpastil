import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/care_day.dart';
import 'package:simpastil/core/medication/care_provider.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/features/dashboard/focus_deck.dart';
import 'package:simpastil/features/dashboard/selected_date_provider.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../../helpers/care_recording_fixture.dart';
import '../../helpers/review_rendering.dart';
import '../../helpers/window_view.dart';

CareDay _withSharing(CareDay day, CareSharingOutcome sharing) => CareDay(
  localDate: day.localDate,
  state: day.state,
  people: day.people,
  prn: day.prn,
  entries: [
    for (final entry in day.entries)
      CareDayEntry(
        occurrence: entry.occurrence,
        person: entry.person,
        pill: entry.pill,
        snapshot: entry.snapshot,
        plannedAmount: entry.plannedAmount,
        head: entry.head,
        sharing: sharing,
      ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await loadReviewFonts();
  });

  // Seen on a real server: the card kept "waiting to share" after a pull to
  // refresh had sent the dose, because the save receipt outranked the day.
  testWidgets(
    'a dose sent by a later sync stops waiting to share on its card',
    (tester) async {
      useWindow(tester, const Size(412, 914));
      final f = await CareRecordingFixture.create(connected: true);
      final days = CareDayRepository(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
      );
      final before = await days.load(localDate: '2026-09-30');
      final stream = StreamController<CareDay>.broadcast();
      final container = await f.workspace.createContainer(
        extraOverrides: [
          careDayProvider.overrideWith((ref, request) async* {
            yield before;
            yield* stream.stream;
          }),
        ],
      );
      container
          .read(selectedDateProvider.notifier)
          .select(DateTime(2026, 9, 30));
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        await stream.close();
        await tester.pumpAndSettle();
        await tester.runAsync(f.db.close);
        await tester.binding.setSurfaceSize(null);
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: reviewRenderingTheme(AppTheme.light()),
            home: const FocusTodayScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final take = find.text('Taken now');
      await tester.ensureVisible(take);
      await tester.pumpAndSettle();
      await tester.tap(take);
      await tester.pumpAndSettle();
      const waiting = 'Saved here · waiting to share';
      const accepted = 'Accepted by shared care';
      expect(find.text(waiting), findsOneWidget);

      // The day reads the same save back: still waiting, nothing changes.
      final after = (await tester.runAsync(
        () => days.load(localDate: '2026-09-30'),
      ))!;
      expect(
        after.entries.single.occurrence.stateVersion,
        greaterThan(before.entries.single.occurrence.stateVersion),
      );
      stream.add(_withSharing(after, CareSharingOutcome.pending));
      await tester.pumpAndSettle();
      expect(find.text(waiting), findsOneWidget);

      // A sync sends it; the state is unchanged, only the sharing moves on.
      stream.add(_withSharing(after, CareSharingOutcome.acknowledged));
      await tester.pumpAndSettle();
      expect(find.text(waiting), findsNothing);
      expect(find.text(accepted), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
