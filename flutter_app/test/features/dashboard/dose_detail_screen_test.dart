import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/care_day.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/features/dashboard/dose_detail_screen.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/router/app_router.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/storage/recorded_by_preference.dart';
import '../../helpers/care_recording_fixture.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  _missedDetailTests();
  testWidgets('detail and audit retain an unnamed but known author', (
    tester,
  ) async {
    final f = await CareRecordingFixture.create();
    // A custom source with no typed name leaves the author unnamed.
    SharedPreferences.setMockInitialValues({
      recordedByModePreferenceKey(f.workspace.context.ownerUserId): 'custom',
    });
    final service = CareRecordingService(
      database: f.db,
      access: f.workspace.access,
      context: f.workspace.context,
      clock: () => DateTime.utc(2026, 9, 30, 9, 15),
    );
    final receipt = await service.commit(
      await service.prepareTakenNow(
        personId: f.person.id,
        occurrenceId: f.occurrence.id,
        expectedStateVersion: 0,
        amount: const MedicationAmount.unknown(),
      ),
    );
    expect(receipt.authorId, f.workspace.context.authorId);
    expect(receipt.authorName, isNull);
    final container = await f.workspace.createContainer();
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await f.db.close();
      container.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      await tester.pumpAndSettle();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DoseDetailScreen(occurrenceId: f.occurrence.id),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Author name not recorded'), findsNWidgets(2));
    expect(find.text('Author unknown'), findsNothing);
    expect(
      (await _read(
        tester,
        f.db.select(f.db.careEventDetails).get(),
      )).single.authorId,
      receipt.authorId,
    );
  });
  testWidgets(
    'exact incoming dose opens despite current date and records Unknown then Undo',
    (tester) async {
      final f = await CareRecordingFixture.create();
      final container = await f.workspace.createContainer();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await f.db.close();
        container.dispose();
        await tester.pumpAndSettle();
      });
      final router = container.read(routerProvider)
        ..go('/home?dose=${f.occurrence.id}');
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: router,
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(f.pill.name), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('2026-09-30 · 9:00 AM'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('2026-09-30 · 9:00 AM'), findsOneWidget);
      await _tap(tester, 'Taken at another time');
      await _tap(tester, 'Review this record');
      expect(
        await _read(tester, f.db.select(f.db.occurrenceEvents).get()),
        isEmpty,
      );
      await _tap(tester, 'Save record');
      var events = await _read(
        tester,
        f.db.select(f.db.occurrenceEvents).get(),
      );
      expect(events, hasLength(1));
      expect(events.single.actualAt, isNull);
      expect(events.single.actualTimeKnown, isFalse);
      await _tap(tester, 'Undo');
      await _tap(tester, 'Done');
      events = await _read(tester, f.db.select(f.db.occurrenceEvents).get());
      expect(events, hasLength(2));
      final row = await _read(
        tester,
        f.db.medicationLedgerDao.getOccurrenceById(f.occurrence.id),
      );
      expect(row!.state, 'pending');
      await tester.scrollUntilVisible(
        find.text('Undo recorded'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Undo recorded'), findsOneWidget);
      expect(find.text('Missed'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'future exact detail clamps actual-time picker without changing planned date',
    (tester) async {
      final f = await CareRecordingFixture.create();
      final now = DateTime.now();
      final tomorrow = DateTime(now.year, now.month, now.day + 1);
      final day = await CareDayRepository(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
      ).load(localDate: routineDateKey(tomorrow));
      final exact = day.entries.single.occurrence;
      final container = await f.workspace.createContainer();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await f.db.close();
        container.dispose();
        await tester.pumpAndSettle();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: DoseDetailScreen(occurrenceId: exact.id),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _tap(tester, 'Taken at another time');
      await tester.scrollUntilVisible(
        find.text('Choose a time'),
        120,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Choose a time'));
      await tester.pumpAndSettle();
      await _tap(tester, 'Choose a time');
      final picker = tester.widget<DatePickerDialog>(
        find.byType(DatePickerDialog),
      );
      expect(picker.initialDate, DateUtils.dateOnly(now));
      expect(picker.lastDate, DateUtils.dateOnly(now));
      expect(tester.takeException(), isNull);
      expect(
        (await _read(
          tester,
          f.db.medicationLedgerDao.getOccurrenceById(exact.id),
        ))!.plannedLocalDate,
        routineDateKey(tomorrow),
      );
      expect(
        await _read(tester, f.db.select(f.db.occurrenceEvents).get()),
        isEmpty,
      );
    },
  );
  testWidgets(
    'amount correction retains known time and Undo restores exact earlier facts',
    (tester) async {
      final f = await CareRecordingFixture.create(
        routineAmount: MedicationAmount.known('1/2', 'tablet'),
      );
      final actual = DateTime.utc(2026, 9, 30, 9, 15);
      final writer = CareRecordingService(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
        clock: () => actual,
      );
      await writer.commit(
        await writer.prepareTakenNow(
          personId: f.person.id,
          occurrenceId: f.occurrence.id,
          expectedStateVersion: 0,
          amount: MedicationAmount.known('1/2', 'tablet'),
          note: 'Retained factual note',
        ),
      );
      final container = await f.workspace.createContainer();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await f.db.close();
        container.dispose();
        await tester.pumpAndSettle();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: DoseDetailScreen(occurrenceId: f.occurrence.id),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _tap(tester, 'Correct this record');
      final quantity = find.byWidgetPredicate(
        (w) => w is TextField && w.controller?.text == '1/2',
      );
      await tester.scrollUntilVisible(
        quantity,
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(quantity, '0.75');
      await _tap(tester, 'Review this record');
      await _tap(tester, 'Save record');
      var events = await _read(
        tester,
        f.db.medicationLedgerDao.getEventsForOccurrence(f.occurrence.id),
      );
      final corrected = events.singleWhere((e) => e.action == 'correct');
      expect(corrected.actualAt?.toUtc(), actual);
      expect(corrected.note, 'Retained factual note');
      await _tap(tester, 'Undo');
      final row = await _read(
        tester,
        f.db.medicationLedgerDao.getOccurrenceById(f.occurrence.id),
      );
      expect(row!.state, 'taken');
      events = await _read(
        tester,
        f.db.medicationLedgerDao.getEventsForOccurrence(f.occurrence.id),
      );
      final undo = events.singleWhere((e) => e.action == 'undo');
      expect(undo.actualAt?.toUtc(), actual);
      expect(events, hasLength(3));
      final details = await _read(
        tester,
        f.db.select(f.db.careEventDetails).get(),
      );
      expect(
        details.singleWhere((d) => d.eventId == undo.id).amountJson,
        contains('1/2'),
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'retained medication history remains readable and cannot mutate after deletion',
    (tester) async {
      final f = await CareRecordingFixture.create(
        routineAmount: MedicationAmount.known('1/2', 'tablet'),
      );
      final service = CareRecordingService(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
        clock: () => DateTime.utc(2026, 9, 30, 9, 15),
      );
      await service.commit(
        await service.prepareTakenNow(
          personId: f.person.id,
          occurrenceId: f.occurrence.id,
          expectedStateVersion: 0,
          amount: MedicationAmount.known('1/2', 'tablet'),
        ),
      );
      await (f.db.update(f.db.pills)..where((p) => p.id.equals(f.pill.id)))
          .write(const PillsCompanion(isDeleted: Value(true)));
      final container = await f.workspace.createContainer();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await f.db.close();
        container.dispose();
        await tester.pumpAndSettle();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.dark(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: DoseDetailScreen(occurrenceId: f.occurrence.id),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(f.pill.name), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text(
          'This retained record can be read, but cannot be changed here.',
        ),
        220,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Correct this record'), findsNothing);
      expect(find.text('Undo'), findsNothing);
      expect(
        await _read(tester, f.db.select(f.db.occurrenceEvents).get()),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'an open connected recording form loses authority after sign-out',
    (tester) async {
      final f = await CareRecordingFixture.create(connected: true);
      final container = await f.workspace.createContainer();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await f.db.close();
        container.dispose();
        await tester.pumpAndSettle();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: DoseDetailScreen(occurrenceId: f.occurrence.id),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _tap(tester, 'Taken at another time');
      await _read(tester, f.workspace.access.revokeNetwork());
      await tester.pumpAndSettle();
      expect(find.text(f.pill.name), findsNothing);
      expect(find.text('Review this record'), findsNothing);
      expect(
        await _read(tester, f.db.select(f.db.occurrenceEvents).get()),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('pending as-needed detail offers no record or skip actions', (
    tester,
  ) async {
    final f = await CareRecordingFixture.create(
      connected: true,
      legacyStock: 4,
    );
    final scheduleId = f.occurrence.scheduleId!;
    await (f.db.delete(
      f.db.medicationOccurrences,
    )..where((o) => o.id.equals(f.occurrence.id))).go();
    await (f.db.update(
      f.db.profiles,
    )..where((p) => p.id.equals(f.person.id))).write(
      ProfilesCompanion(
        serverId: Value(f.person.id),
        syncStatus: const Value('synced'),
      ),
    );
    await (f.db.update(f.db.pills)..where((p) => p.id.equals(f.pill.id))).write(
      PillsCompanion(
        serverId: Value(f.pill.id),
        isPrn: const Value(true),
        syncStatus: const Value('synced'),
      ),
    );
    await (f.db.update(
      f.db.schedules,
    )..where((s) => s.id.equals(scheduleId))).write(
      SchedulesCompanion(
        serverId: Value(scheduleId),
        frequency: const Value('prn'),
        timeZone: const Value('Europe/Bucharest'),
        timeZoneStatus: const Value('known'),
        syncStatus: const Value('synced'),
      ),
    );
    final service = CareRecordingService(
      database: f.db,
      access: f.workspace.access,
      context: f.workspace.context,
    );
    final taken = await service.commit(
      await service.prepareConnectedPrn(
        personId: f.person.id,
        pillId: f.pill.id,
        sentinelId: scheduleId,
        reviewedLocalDate: '2026-09-30',
        amount: MedicationAmount.known('1', 'tablet'),
        actualAt: null,
        actualTimeKnown: false,
        note: null,
      ),
    );
    final occurrenceId = taken.current.id;
    await service.commit(
      await service.prepareUndoForEntry(
        personId: f.person.id,
        occurrenceId: occurrenceId,
        expectedStateVersion: taken.current.stateVersion,
        headEventId: taken.event.id,
      ),
    );
    final container = await f.workspace.createContainer();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await f.db.close();
      container.dispose();
      await tester.pumpAndSettle();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DoseDetailScreen(occurrenceId: occurrenceId),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('This as-needed dose was undone.'), findsOneWidget);
    expect(find.text('Record a dose'), findsNothing);
    expect(find.text('Record as skipped'), findsNothing);
    expect(find.text('Taken now'), findsNothing);
    expect(find.text('Skipped'), findsNothing);
  });
}

Future<ProviderContainer> _openDetail(
  WidgetTester tester,
  CareRecordingFixture f,
) async {
  final container = await f.workspace.createContainer();
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await f.db.close();
    container.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await tester.pumpAndSettle();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: DoseDetailScreen(occurrenceId: f.occurrence.id),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void _missedDetailTests() {
  group('a dose recorded as missed', () {
    testWidgets('explains the miss and can still be taken late, then undone', (
      tester,
    ) async {
      final f = await CareRecordingFixture.create();
      await f.recordMiss();
      await _openDetail(tester, f);
      expect(find.text('Missed'), findsWidgets);
      expect(find.textContaining('marked missed'), findsOneWidget);
      // The miss is told as a story station and as an audit entry, with the
      // entry time only: nobody took or typed anything.
      expect(find.text('Marked missed automatically'), findsWidgets);
      expect(find.text('Actual time'), findsNothing);
      expect(find.text('Recorded in Simpastil'), findsWidgets);
      expect(find.text('Taken now (late)'), findsOneWidget);
      expect(find.text('Taken at another time'), findsOneWidget);
      expect(find.text('Correct this record'), findsNothing);

      await _tap(tester, 'Taken at another time');
      await _tap(tester, 'Review this record');
      await _tap(tester, 'Save record');
      await _tap(tester, 'Done');
      final events = await _read(
        tester,
        f.db.medicationLedgerDao.getEventsForOccurrence(f.occurrence.id),
      );
      expect(events.map((e) => e.action), ['miss', 'correct']);
      expect(events.last.fromState, 'missed');
      expect(events.last.toState, 'taken');
      // Taken after the miss reads as late, and the story keeps the miss.
      expect(find.text('Taken (late)'), findsWidgets);
      expect(find.text('Marked missed automatically'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('goes back to missed when the late take is undone', (
      tester,
    ) async {
      final f = await CareRecordingFixture.create();
      await f.recordMiss();
      await _openDetail(tester, f);
      await _tap(tester, 'Taken at another time');
      await _tap(tester, 'Review this record');
      await _tap(tester, 'Save record');
      await _tap(tester, 'Undo');
      await _tap(tester, 'Done');
      final row = await _read(
        tester,
        f.db.medicationLedgerDao.getOccurrenceById(f.occurrence.id),
      );
      expect(row!.state, 'missed');
      final events = await _read(
        tester,
        f.db.medicationLedgerDao.getEventsForOccurrence(f.occurrence.id),
      );
      expect(events.map((e) => e.action), ['miss', 'correct', 'undo']);
      expect(find.text('Missed'), findsWidgets);
      expect(find.text('Taken now (late)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('can be taken late in one tap, as a correction of the miss', (
      tester,
    ) async {
      final f = await CareRecordingFixture.create();
      await f.recordMiss();
      await _openDetail(tester, f);
      await _tap(tester, 'Taken now (late)');
      final events = await _read(
        tester,
        f.db.medicationLedgerDao.getEventsForOccurrence(f.occurrence.id),
      );
      expect(events.map((e) => e.action), ['miss', 'correct']);
      expect(events.last.fromState, 'missed');
      expect(events.last.toState, 'taken');
      expect(find.text('Taken (late)'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('can be recorded as skipped', (tester) async {
      final f = await CareRecordingFixture.create();
      await f.recordMiss();
      await _openDetail(tester, f);
      await _tap(tester, 'Skipped');
      await _tap(tester, 'Review this record');
      await _tap(tester, 'Save record');
      final events = await _read(
        tester,
        f.db.medicationLedgerDao.getEventsForOccurrence(f.occurrence.id),
      );
      expect(events.map((e) => e.action), ['miss', 'correct']);
      expect(events.last.toState, 'skipped');
      final row = await _read(
        tester,
        f.db.medicationLedgerDao.getOccurrenceById(f.occurrence.id),
      );
      expect(row!.state, 'skipped');
      expect(find.text('Taken (late)'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}

Future<void> _tap(WidgetTester tester, String text) async {
  final finder = find.ancestor(
    of: find.text(text),
    matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
  );
  await tester.scrollUntilVisible(
    finder,
    180,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<T> _read<T>(WidgetTester tester, Future<T> future) async {
  var done = false;
  T? value;
  Object? error;
  future.then(
    (v) {
      value = v;
      done = true;
    },
    onError: (Object e) {
      error = e;
      done = true;
    },
  );
  for (var i = 0; i < 200 && !done; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  if (!done) throw StateError('Query did not settle');
  if (error != null) throw error!;
  return value as T;
}
