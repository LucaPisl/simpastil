import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/care_day.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/core/medication/routine_repository.dart';
import 'package:simpastil/features/dashboard/selected_doses_review.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/features/setup/setup_state.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import '../../helpers/care_recording_fixture.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  testWidgets(
    'counted review stays reachable and removing one dose preserves the others',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final f = await CareRecordingFixture.create();
      await _add(f, 'Second exact dose');
      await _add(f, 'Third exact dose');
      final day = await CareDayRepository(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
      ).load(localDate: '2026-09-30');
      final container = await f.workspace.createContainer();
      addTearDown(() async {
        await f.db.close();
        container.dispose();
        await tester.pumpAndSettle();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: AppTheme.light(),
            home: SelectedDosesReview(
              day: day,
              service: CareRecordingService(
                database: f.db,
                access: f.workspace.access,
                context: f.workspace.context,
              ),
              personId: f.person.id,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final row in day.entries) {
        final target = find.byKey(ValueKey('select-${row.occurrence.id}'));
        await tester.ensureVisible(target);
        await tester.tap(target);
        await tester.pumpAndSettle();
      }
      expect(find.text('Review 3 doses').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Review 3 doses'));
      await tester.pumpAndSettle();
      expect(find.text('Record 3 as taken').hitTestable(), findsOneWidget);
      expect(find.text('2026-09-30'), findsNothing);
      final removed = day.entries.last;
      final remove = find.byKey(ValueKey('remove-${removed.occurrence.id}'));
      await tester.ensureVisible(remove);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      expect(find.text('Record 2 as taken').hitTestable(), findsOneWidget);
      expect(
        await _read(tester, f.db.select(f.db.occurrenceEvents).get()),
        isEmpty,
      );
      await tester.tap(find.text('Record 2 as taken'));
      await tester.pumpAndSettle();
      final events = await _read(
        tester,
        f.db.select(f.db.occurrenceEvents).get(),
      );
      expect(
        events.map((event) => event.occurrenceId).toSet(),
        day.entries
            .where((row) => row != removed)
            .map((row) => row.occurrence.id)
            .toSet(),
      );
      expect(events.every((event) => !event.actualTimeKnown), isTrue);
      expect(
        await _read(tester, f.db.select(f.db.pendingOperations).get()),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'Romanian large text keeps long care and review controls reachable',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final f = await CareRecordingFixture.create();
      const personName = 'FictionalRowanExampleWithALongName';
      const medicationName = 'FictionalMedicationWithALongUnbrokenName';
      await f.db.customStatement('UPDATE profiles SET name = ? WHERE id = ?', [
        personName,
        f.person.id,
      ]);
      await _add(f, medicationName);
      final day = await CareDayRepository(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
      ).load(localDate: '2026-09-30');
      final target = day.entries.singleWhere(
        (row) => row.snapshot.pillName == medicationName,
      );
      final container = await f.workspace.createContainer();
      addTearDown(() async {
        await f.db.close();
        container.dispose();
        await tester.pumpAndSettle();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('ro'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: AppTheme.dark(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: SelectedDosesReview(
              day: day,
              service: CareRecordingService(
                database: f.db,
                access: f.workspace.access,
                context: f.workspace.context,
              ),
              personId: f.person.id,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final row = find.byKey(ValueKey('select-${target.occurrence.id}'));
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Golește selecția'));
      await tester.tap(find.text('Golește selecția'));
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(row).value, isFalse);
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();
      final review = find.byKey(const ValueKey('selection-review'));
      await tester.ensureVisible(review);
      expect(review.hitTestable(), findsOneWidget);
      await tester.tap(review);
      await tester.pumpAndSettle();
      expect(find.text(personName), findsOneWidget);
      expect(find.text(medicationName), findsOneWidget);
      expect(find.text('1 doză selectată'), findsOneWidget);
      final record = find.byKey(const ValueKey('selection-record'));
      await tester.ensureVisible(record);
      expect(record.hitTestable(), findsOneWidget);
      expect(find.text('Înregistrează 1 ca luată'), findsOneWidget);
      expect(
        await _read(tester, f.db.select(f.db.occurrenceEvents).get()),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'exact selection retains partial outcomes and retries only the unsaved intent',
    (tester) async {
      final f = await CareRecordingFixture.create();
      await _add(f, 'Second exact dose');
      final setup = SetupRepository(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
      );
      var personDraft = await setup.resumeOrCreateDraft(
        purpose: SetupPurpose.person,
      );
      personDraft = (await setup.savePerson(
        personDraft.id,
        personDraft.revision,
        name: 'Other person',
        avatar: 'B',
      )).draft;
      await setup.advanceOrSkip(
        personDraft.id,
        personDraft.revision,
        SetupStep.complete,
      );
      await _add(f, 'Other person dose', personId: personDraft.personId);

      final repo = CareDayRepository(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
      );
      final day = await repo.load(localDate: '2026-09-30');
      expect(day.entries, hasLength(3));
      final own = day.entries.where((e) => e.person.id == f.person.id).toList();
      final blocked = own.last;
      final live = ValueNotifier(day);
      addTearDown(live.dispose);
      await f.db.customStatement(
        "CREATE TRIGGER fictional_failure BEFORE INSERT ON occurrence_events WHEN NEW.occurrence_id = '${blocked.occurrence.id}' BEGIN SELECT RAISE(ABORT, 'fictional write failure'); END",
      );
      final service = CareRecordingService(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
      );
      final container = await f.workspace.createContainer();
      addTearDown(() async {
        await f.db.close();
        container.dispose();
        await tester.pumpAndSettle();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: AppTheme.light(),
            home: ValueListenableBuilder<CareDay>(
              valueListenable: live,
              builder: (_, value, _) => SelectedDosesReview(
                day: value,
                service: service,
                personId: f.person.id,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final row in own) {
        final box = find.byKey(ValueKey('select-${row.occurrence.id}'));
        await tester.ensureVisible(box);
        await tester.tap(box);
        await tester.pumpAndSettle();
      }
      // A new exact arrival while reviewing never joins the frozen two-dose set.
      await _read(tester, _add(f, 'New arrival remains unselected'));
      final updated = await _read(tester, repo.load(localDate: '2026-09-30'));
      live.value = CareDay(
        localDate: updated.localDate,
        state: updated.state,
        people: updated.people,
        entries: updated.entries.reversed.toList(),
        prn: updated.prn,
      );
      await tester.pumpAndSettle();
      expect(find.text('Other person dose'), findsNothing);
      expect(find.text('New arrival remains unselected'), findsNothing);
      for (final row in own) {
        expect(
          tester
              .widget<CheckboxListTile>(
                find.byKey(ValueKey('select-${row.occurrence.id}')),
              )
              .value,
          isTrue,
        );
      }

      await tester.scrollUntilVisible(find.text('Review 2 doses'), 200);
      await tester.tap(find.text('Review 2 doses'));
      await tester.pumpAndSettle();
      expect(find.text('New arrival remains unselected'), findsNothing);
      expect(
        await _read(tester, f.db.select(f.db.occurrenceEvents).get()),
        isEmpty,
      );
      await tester.scrollUntilVisible(find.text('Record 2 as taken'), 200);
      await tester.tap(find.text('Record 2 as taken'));
      await tester.pumpAndSettle();
      expect(
        find.text('Some doses were saved. Review each result below.'),
        findsOneWidget,
      );
      var events = await _read(
        tester,
        f.db.select(f.db.occurrenceEvents).get(),
      );
      expect(events, hasLength(1));
      final firstId = events.single.id;
      await _read(
        tester,
        f.db.customStatement('DROP TRIGGER fictional_failure'),
      );
      await tester.scrollUntilVisible(find.text('Retry unsaved doses'), 200);
      await tester.tap(find.text('Retry unsaved doses'));
      await tester.pumpAndSettle();
      expect(find.text('Every selected dose was saved.'), findsOneWidget);
      events = await _read(tester, f.db.select(f.db.occurrenceEvents).get());
      expect(events, hasLength(2));
      expect(
        events.map((e) => e.occurrenceId).toSet(),
        own.map((e) => e.occurrence.id).toSet(),
      );
      expect(events.where((e) => e.id == firstId), hasLength(1));
      expect(
        events.every((e) => !e.actualTimeKnown && e.actualAt == null),
        isTrue,
      );
      expect(
        await _read(tester, f.db.select(f.db.pendingOperations).get()),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}

Future<void> _add(
  CareRecordingFixture f,
  String name, {
  String? personId,
}) async {
  final setup = SetupRepository(
    database: f.db,
    access: f.workspace.access,
    context: f.workspace.context,
  );
  var draft = await setup.resumeOrCreateDraft(
    purpose: SetupPurpose.medication,
    fixedPersonId: personId ?? f.person.id,
  );
  draft = (await setup.saveMedication(
    draft.id,
    draft.revision,
    MedicationReview(name: name),
  )).draft;
  draft = await setup.advanceOrSkip(draft.id, draft.revision, SetupStep.ready);
  draft = await setup.advanceOrSkip(
    draft.id,
    draft.revision,
    SetupStep.complete,
  );
  final routine = RoutineRepository(
    database: f.db,
    access: f.workspace.access,
    context: f.workspace.context,
    clock: () => DateTime.utc(2026, 9, 30, 8),
  );
  await routine.saveReviewed(
    await routine.preview(
      pillId: draft.medicationId!,
      expectedRevision: 0,
      definition: RoutineDefinition(
        kind: RoutineKind.daily,
        timeZone: 'UTC',
        times: [const RoutineTime(slotId: 'morning', hour: 9, minute: 0)],
      ),
      effectiveFrom: DateTime.utc(2026, 9, 30, 8),
      fromLocalDate: '2026-09-30',
      throughLocalDate: '2026-09-30',
    ),
  );
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
