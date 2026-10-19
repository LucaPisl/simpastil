import 'dart:convert';
import 'dart:async';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_day.dart';
import 'package:simpastil/core/medication/care_provider.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/core/medication/routine_repository.dart';
import 'package:simpastil/core/medication/local_occurrence_snapshot.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/widget/widget_snapshot.dart';
import 'package:simpastil/core/storage/preference_keys.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/features/setup/setup_state.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import '../../helpers/protected_workspace_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);
  late ProtectedWorkspaceFixture f;
  late RoutineRepository repo;
  late String pillId;
  late String personId;
  final now = DateTime.utc(2026, 9, 30, 8);
  setUp(() async {
    f = await ProtectedWorkspaceFixture.create();
    final setup = SetupRepository(
      database: f.db,
      access: f.access,
      context: f.context,
    );
    var draft = await setup.resumeOrCreateDraft();
    draft = (await setup.savePerson(
      draft.id,
      draft.revision,
      name: 'Fictional Alex',
      avatar: 'A',
    )).draft;
    draft = (await setup.saveMedication(
      draft.id,
      draft.revision,
      const MedicationReview(name: 'Fictional medication'),
    )).draft;
    personId = draft.personId!;
    pillId = draft.medicationId!;
    repo = RoutineRepository(
      database: f.db,
      access: f.access,
      context: f.context,
      clock: () => now,
    );
  });
  tearDown(() async => f.db.close());
  RoutineDefinition daily([int hour = 9, bool evening = false]) =>
      RoutineDefinition(
        kind: RoutineKind.daily,
        timeZone: 'UTC',
        amount: MedicationAmount.known('1/2', 'tablet'),
        times: [
          RoutineTime(slotId: 'morning', hour: hour, minute: 0),
          if (evening)
            const RoutineTime(slotId: 'evening', hour: 20, minute: 0),
        ],
      );
  Future<ReviewedRoutinePreview> preview(
    RoutineDefinition d, {
    LocalRoutine? prior,
    DateTime? boundary,
    String through = '2026-10-02',
  }) => repo.preview(
    pillId: pillId,
    routineId: prior?.routineId,
    expectedRevision: prior?.revision ?? 0,
    definition: d,
    effectiveFrom: boundary ?? now,
    fromLocalDate: '2026-09-30',
    throughLocalDate: through,
  );
  Future<List<MedicationOccurrence>> rows() =>
      f.db.medicationLedgerDao.getOccurrencesForUser(f.context.ownerUserId);
  Future<void> record(MedicationOccurrence r, {bool undone = false}) async {
    await (f.db.update(
      f.db.medicationOccurrences,
    )..where((o) => o.id.equals(r.id))).write(
      MedicationOccurrencesCompanion(
        state: Value(undone ? 'pending' : 'taken'),
        stateVersion: const Value(2),
      ),
    );
    await f.db
        .into(f.db.occurrenceEvents)
        .insert(
          OccurrenceEventsCompanion.insert(
            id: 'fictional-event-${r.id}',
            userId: r.userId,
            occurrenceId: r.id,
            commandId: 'fictional-command-${r.id}',
            action: undone ? 'undo' : 'take',
            fromState: 'pending',
            toState: undone ? 'pending' : 'taken',
            origin: 'native',
            baseVersion: 1,
            resultVersion: 2,
            recordedAt: now,
          ),
        );
  }

  test(
    'preview and stored local entries agree; repeated reads write nothing and never queue',
    () async {
      final review = await preview(daily(9, true));
      await repo.saveReviewed(review);
      final stored = await rows();
      expect(
        stored.map((r) => r.plannedAt!.toUtc()),
        review.upcoming.map((r) => r.plannedAt),
      );
      final snap =
          decodeScheduleSnapshot(jsonDecode(stored.first.scheduleSnapshotJson))
              as LocalOccurrenceSnapshot;
      expect(snap.ownerUserId, f.context.ownerUserId);
      expect(snap.amount.quantityText, '1/2');
      expect(await f.db.select(f.db.pendingOperations).get(), isEmpty);
      await f.db.customStatement(
        "CREATE TRIGGER refuse_repeat BEFORE INSERT ON medication_occurrences BEGIN SELECT RAISE(FAIL, 'Unexpected duplicate write'); END",
      );
      await repo.ensureMaterialized(
        fromLocalDate: '2026-09-30',
        throughLocalDate: '2026-10-02',
      );
      expect((await rows()).map((r) => r.id), stored.map((r) => r.id));
    },
  );
  test(
    'clock move preserves recorded and undone future slots and snapshots',
    () async {
      final original = await repo.saveReviewed(await preview(daily()));
      final before = await rows();
      await record(before[1]);
      await record(before[2], undone: true);
      final review = await preview(daily(10), prior: original);
      expect(review.preservedRecords.map((r) => r.id).toSet(), {
        before[1].id,
        before[2].id,
      });
      await repo.saveReviewed(review);
      final after = await rows();
      for (final r in before.skip(1)) {
        final retained = after.singleWhere((o) => o.id == r.id);
        expect(retained.supersededAt, isNull);
        expect(retained.scheduleSnapshotJson, r.scheduleSnapshotJson);
        expect(
          after
              .where(
                (o) =>
                    o.plannedLocalDate == r.plannedLocalDate &&
                    o.supersededAt == null,
              )
              .length,
          1,
        );
      }
      final replacement = after.singleWhere(
        (o) => o.plannedLocalDate == '2026-09-30' && o.supersededAt == null,
      );
      expect(replacement.scheduleId, before.first.scheduleId);
      expect(replacement.plannedLocalTime, '10:00:00');
    },
  );
  test(
    'future boundary beyond current horizon keeps both immutable definitions',
    () async {
      final original = await repo.saveReviewed(
        await preview(daily(), through: '2026-09-30'),
      );
      await repo.saveReviewed(
        await preview(
          daily(10),
          prior: original,
          boundary: DateTime.utc(2026, 10, 20),
          through: '2026-09-30',
        ),
      );
      await repo.ensureMaterialized(
        fromLocalDate: '2026-10-19',
        throughLocalDate: '2026-10-20',
      );
      final future = (await rows())
          .where((r) => r.plannedLocalDate.compareTo('2026-10-19') >= 0)
          .toList();
      expect(future.map((r) => r.plannedLocalTime), ['09:00:00', '10:00:00']);
      expect((await repo.loadForPill(pillId)).length, 2);
    },
  );
  test('removed slot retains recorded History and readable bridge', () async {
    final original = await repo.saveReviewed(await preview(daily(9, true)));
    final evening = (await rows())
        .where((r) => r.plannedLocalTime == '20:00:00')
        .toList();
    await record(evening.last);
    await repo.saveReviewed(await preview(daily(), prior: original));
    expect(
      (await f.db.schedulesDao.getById(evening.last.scheduleId!))!.isDeleted,
      isFalse,
    );
    final after = await rows();
    expect(
      after.singleWhere((r) => r.id == evening.last.id).supersededAt,
      isNull,
    );
    expect(
      after.singleWhere((r) => r.id == evening.first.id).supersededAt,
      isNotNull,
    );
  });
  test(
    'PRN has no quota and a future switch does not change current care',
    () async {
      final original = await repo.saveReviewed(await preview(daily()));
      final prn = RoutineDefinition(
        kind: RoutineKind.prn,
        timeZone: 'UTC',
        times: [],
      );
      await repo.saveReviewed(
        await preview(
          prn,
          prior: original,
          boundary: DateTime.utc(2026, 10, 20),
        ),
      );
      expect((await f.db.pillsDao.getById(pillId))!.isPrn, isFalse);
      final later = RoutineRepository(
        database: f.db,
        access: f.access,
        context: f.context,
        clock: () => DateTime.utc(2026, 10, 20, 8),
      );
      await later.ensureMaterialized(
        fromLocalDate: '2026-10-20',
        throughLocalDate: '2026-10-22',
      );
      expect((await f.db.pillsDao.getById(pillId))!.isPrn, isTrue);
      expect(
        (await rows()).where(
          (r) =>
              r.plannedLocalDate.compareTo('2026-10-20') >= 0 &&
              r.supersededAt == null,
        ),
        isEmpty,
      );
    },
  );
  test(
    'review replay with a precise instant returns the same saved routine',
    () async {
      final review = await preview(
        daily(),
        boundary: now.add(const Duration(microseconds: 350001)),
      );
      final saved = await repo.saveReviewed(review);
      expect((await repo.saveReviewed(review)).revision, saved.revision);
      expect((await repo.loadForPill(pillId)).length, 1);
    },
  );
  test(
    'the actual Today provider receives a routine saved after its empty view',
    () async {
      final container = await f.createContainer();
      final request = CareDayRequest(
        localDate: routineDateKey(now),
        personId: personId,
      );
      final provider = careDayProvider(request);
      final subscription = container.listen(provider, (_, _) {});
      addTearDown(() {
        subscription.close();
        container.dispose();
      });
      expect((await container.read(provider.future)).entries, isEmpty);
      final arrived = Completer<CareDay>();
      final changes = container.listen(provider, (_, next) {
        final day = next.asData?.value;
        if (day != null && day.entries.isNotEmpty && !arrived.isCompleted) {
          arrived.complete(day);
        }
      });
      addTearDown(changes.close);
      await repo.saveReviewed(await preview(daily()));
      final day = await arrived.future.timeout(const Duration(seconds: 5));
      expect(day.entries, hasLength(1));
      expect(day.entries.single.pill.id, pillId);
      expect(day.entries.single.occurrence.plannedLocalTime, '09:00:00');
      expect(day.entries.single.occurrence.timeZone, 'UTC');
    },
  );

  test('saved local PRN appears in the actual Today PRN provider', () async {
    await repo.saveReviewed(
      await preview(
        RoutineDefinition(kind: RoutineKind.prn, timeZone: 'UTC', times: []),
      ),
    );
    final container = await f.createContainer();
    addTearDown(container.dispose);
    final day = await container.read(
      careDayProvider(
        CareDayRequest(localDate: routineDateKey(now), personId: personId),
      ).future,
    );
    expect(day.prn.single.pill.id, pillId);
    expect(day.prn.single.definition.kind, RoutineKind.prn);
    expect(day.entries, isEmpty);
    expect(await rows(), isEmpty);
  });
  test(
    'short edit preview immediately reconciles all persisted affected future rows',
    () async {
      final original = await repo.saveReviewed(
        await preview(daily(9, true), through: '2026-10-30'),
      );
      final before = await rows();
      final recorded = before.singleWhere(
        (r) =>
            r.plannedLocalDate == '2026-10-20' &&
            r.plannedLocalTime == '20:00:00',
      );
      await record(recorded);
      await repo.saveReviewed(
        await preview(daily(10), prior: original, through: '2026-10-02'),
      );
      final after = await rows();
      expect(
        after.singleWhere((r) => r.id == recorded.id).supersededAt,
        isNull,
      );
      final day20 = after
          .where(
            (r) => r.plannedLocalDate == '2026-10-20' && r.supersededAt == null,
          )
          .toList();
      expect(day20.map((r) => r.plannedLocalTime).toSet(), {
        '10:00:00',
        '20:00:00',
      });
      final unrecordedEvening = before.singleWhere(
        (r) =>
            r.plannedLocalDate == '2026-10-21' &&
            r.plannedLocalTime == '20:00:00',
      );
      expect(
        after.singleWhere((r) => r.id == unrecordedEvening.id).supersededAt,
        isNotNull,
      );
    },
  );
  for (final toPrn in [false, true]) {
    test(
      'first widget snapshot after a boundary reads current mode: PRN=$toPrn',
      () async {
        final prn = RoutineDefinition(
          kind: RoutineKind.prn,
          timeZone: 'UTC',
          times: [],
        );
        final original = await repo.saveReviewed(
          await preview(toPrn ? daily() : prn),
        );
        await repo.saveReviewed(
          await preview(
            toPrn ? prn : daily(),
            prior: original,
            boundary: DateTime.utc(2026, 10, 20),
            through: '2026-09-30',
          ),
        );
        final pill = (await f.db.pillsDao.getById(pillId))!;
        await f.db
            .into(f.db.devicePersonReminders)
            .insertOnConflictUpdate(
              DevicePersonRemindersCompanion.insert(
                profileId: pill.profileId,
                enabled: const Value(true),
              ),
            );
        await f.preferences.setBool(
          prnInWidgetPreferenceKey(f.context.ownerUserId),
          true,
        );
        final snapshot = await computeWidgetSnapshot(
          db: f.db,
          prefs: f.preferences,
          access: f.access,
          context: f.context,
          now: DateTime.utc(2026, 10, 20, 8),
        );
        final doses = (snapshot['doses'] as List).cast<Map>();
        expect(doses.length, 1);
        expect(doses.single['isPrn'] == true, toPrn);
        expect(snapshot['total'], toPrn ? 0 : 1);
      },
    );
  }
  test(
    'clock crossing a reviewed slot requires another review without changing care',
    () async {
      var clock = DateTime.utc(2026, 9, 30, 8, 59);
      final changing = RoutineRepository(
        database: f.db,
        access: f.access,
        context: f.context,
        clock: () => clock,
      );
      final original = await changing.saveReviewed(
        await changing.preview(
          pillId: pillId,
          expectedRevision: 0,
          definition: daily(),
          effectiveFrom: now,
          fromLocalDate: '2026-09-30',
          throughLocalDate: '2026-10-02',
        ),
      );
      final review = await changing.preview(
        pillId: pillId,
        routineId: original.routineId,
        expectedRevision: 1,
        definition: daily(10),
        effectiveFrom: clock,
        fromLocalDate: '2026-09-30',
        throughLocalDate: '2026-10-02',
      );
      clock = DateTime.utc(2026, 9, 30, 9, 1);
      await expectLater(
        changing.saveReviewed(review),
        throwsA(isA<RoutineConflict>()),
      );
      expect((await changing.loadForPill(pillId)).length, 1);
      expect(
        (await rows())
            .where((r) => r.plannedLocalDate == '2026-09-30')
            .single
            .plannedLocalTime,
        '09:00:00',
      );
    },
  );
  test(
    'PRN start and end dates use the reviewed zone inclusively during travel',
    () async {
      final prn = RoutineDefinition(
        kind: RoutineKind.prn,
        timeZone: 'Europe/Bucharest',
        times: [],
        startDate: '2026-10-01',
        endDate: '2026-10-01',
      );
      await repo.saveReviewed(await preview(prn));
      expect((await f.db.pillsDao.getById(pillId))!.isPrn, isFalse);
      Future<void> at(DateTime instant) =>
          RoutineRepository(
            database: f.db,
            access: f.access,
            context: f.context,
            clock: () => instant,
          ).ensureMaterialized(
            fromLocalDate: '2026-10-01',
            throughLocalDate: '2026-10-02',
          );
      await at(DateTime.utc(2026, 9, 30, 21, 30));
      expect((await f.db.pillsDao.getById(pillId))!.isPrn, isTrue);
      await at(DateTime.utc(2026, 10, 1, 21, 30));
      expect((await f.db.pillsDao.getById(pillId))!.isPrn, isFalse);
    },
  );

  test('changed parent or revoked context refuses the reviewed save', () async {
    final review = await preview(daily());
    await (f.db.update(f.db.pills)..where((p) => p.id.equals(pillId))).write(
      const PillsCompanion(name: Value('Changed reviewed name')),
    );
    await expectLater(
      repo.saveReviewed(review),
      throwsA(isA<RoutineConflict>()),
    );
    await f.db.customStatement(
      'UPDATE workspace_grants SET epoch=epoch+1 WHERE workspace_id=?',
      [f.context.workspaceId],
    );
    await expectLater(
      repo.ensureMaterialized(
        fromLocalDate: '2026-09-30',
        throughLocalDate: '2026-09-30',
      ),
      throwsA(isA<WorkspaceAccessFailure>()),
    );
    expect(await rows(), isEmpty);
  });
}
