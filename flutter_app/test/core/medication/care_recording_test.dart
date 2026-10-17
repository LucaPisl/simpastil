import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_day.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/medication/medication_command.dart';
import 'package:simpastil/core/medication/medication_repository.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/core/medication/routine_repository.dart';
import 'package:simpastil/core/medication/reviewed_stock.dart';
import 'package:simpastil/core/medication/occurrence_detail_repository.dart';
import 'package:simpastil/core/projections/projection_command_id.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../../helpers/care_recording_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);
  test(
    'prepared Taken now, durable retry and Undo retain actual facts',
    () async {
      final f = await CareRecordingFixture.create();
      addTearDown(f.db.close);
      final now = DateTime.utc(2026, 9, 30, 11, 17);
      final service = CareRecordingService(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
        clock: () => now,
        afterCareSave: () async => throw StateError('platform unavailable'),
      );
      final intent = await service.prepareTakenNow(
        personId: f.person.id,
        occurrenceId: f.occurrence.id,
        expectedStateVersion: 0,
        amount: MedicationAmount.known('1/2', 'tablet'),
      );
      final saved = await service.commit(intent);
      final replay = await service.commit(intent);
      expect(saved.event.id, replay.event.id);
      expect(saved.event.actualAt!.isAtSameMomentAs(now), isTrue);
      expect(saved.projection, CareProjectionOutcome.unavailable);
      expect(saved.sharing, CareSharingOutcome.localOnly);
      final reopened = CareRecordingService(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
      );
      final undo = await reopened.prepareUndoForEntry(
        personId: f.person.id,
        occurrenceId: saved.current.id,
        expectedStateVersion: saved.current.stateVersion,
        headEventId: saved.event.id,
      );
      final undone = await reopened.commit(undo);
      await reopened.commit(undo);
      expect(undone.current.state, 'pending');
      final history = await service.historyForPerson(f.person.id);
      expect(history, hasLength(2));
      expect(history.first.event.id, saved.event.id);
      expect(history.first.amount.quantityText, '1/2');
      expect(history.first.authorId, f.workspace.context.authorId);
      expect(history.last.localReversalEventId, saved.event.id);
      expect(await f.db.select(f.db.pendingOperations).get(), isEmpty);
    },
  );

  test(
    'receipt distinguishes verified server review from uncertainty',
    () async {
      final f = await CareRecordingFixture.create(connected: true);
      addTearDown(f.db.close);
      final service = CareRecordingService(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
      );
      final intent = await service.prepareTakenNow(
        personId: f.person.id,
        occurrenceId: f.occurrence.id,
        expectedStateVersion: 0,
      );
      await service.commit(intent);
      final operation = (await f.db.pendingOperationsDao.getByMutationId(
        f.workspace.context.ownerUserId,
        intent.commandId,
      ))!;
      final effect = (await f.db.pendingOperationsDao.getEffects(
        operation.id,
      )).single;
      final issueId = projectionCommandIdForKey(
        'legacy-split-issue-v1:${intent.commandId}:${effect.ordinal}',
      );
      final now = DateTime.utc(2026, 10, 8, 12);
      await f.db.transaction(() async {
        await (f.db.update(f.db.pendingOperations)
              ..where((row) => row.id.equals(operation.id)))
            .write(const PendingOperationsCompanion(state: Value('blocked')));
        await (f.db.update(
          f.db.pendingOperationEffects,
        )..where((row) => row.id.equals(effect.id))).write(
          PendingOperationEffectsCompanion(
            state: const Value('uncertain'),
            attemptedAt: Value(now),
            safeResultFingerprint: Value('reconciliation-recorded:$issueId'),
          ),
        );
        await f.db.migrationIssuesDao.record(
          MigrationIssuesCompanion.insert(
            id: issueId,
            userId: f.workspace.context.ownerUserId,
            entityType: 'medication_split',
            entityId: projectionCommandIdForKey(
              'legacy-split-command-v1:${intent.commandId}:${effect.ordinal}',
            ),
            issueCode: 'legacy_split_checkpoint',
            snapshotJson: '{"fictional":"server review evidence"}',
            serverId: Value(issueId),
            revision: const Value(1),
            resolutionState: const Value('unresolved'),
            createdAt: now,
            updatedAt: now,
          ),
        );
      });

      final replay = await service.commit(intent);
      expect(replay.sharing, CareSharingOutcome.needsReview);
      final day = await CareDayRepository(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
        clock: () => now,
      ).load(localDate: '2026-09-30', personId: f.person.id);
      expect(day.entries.single.sharing, CareSharingOutcome.needsReview);
      final detail = await OccurrenceDetailRepository(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
      ).load(f.occurrence.id);
      expect(detail.sharing, CareSharingOutcome.needsReview);
      expect(
        (await f.db.pendingOperationsDao.getEffects(operation.id)).single.state,
        'uncertain',
        reason:
            'the receipt reports review without rewriting delivery evidence',
      );
    },
  );

  test('retrospective Unknown never invents planned time', () async {
    final f = await CareRecordingFixture.create();
    addTearDown(f.db.close);
    final service = CareRecordingService(
      database: f.db,
      access: f.workspace.access,
      context: f.workspace.context,
    );
    final intent = await service.prepare(
      personId: f.person.id,
      occurrenceId: f.occurrence.id,
      expectedStateVersion: 0,
      action: MedicationAction.take,
      amount: const MedicationAmount.unknown(),
      actualAt: null,
      actualTimeKnown: false,
    );
    final saved = await service.commit(intent);
    expect(saved.event.actualTimeKnown, isFalse);
    expect(saved.event.actualAt, isNull);
    expect(saved.amount.isUnknown, isTrue);
  });

  test(
    'each deliberate PRN entry is separate and its retries are stable',
    () async {
      final f = await CareRecordingFixture.create();
      addTearDown(f.db.close);
      final repo = RoutineRepository(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
        clock: () => DateTime.utc(2026, 9, 30, 10),
      );
      final existing = (await repo.loadForPill(f.pill.id)).single;
      final preview = await repo.preview(
        pillId: f.pill.id,
        routineId: existing.routineId,
        expectedRevision: 1,
        definition: RoutineDefinition(
          kind: RoutineKind.prn,
          timeZone: 'UTC',
          times: [],
        ),
        effectiveFrom: DateTime.utc(2026, 9, 30, 10),
        fromLocalDate: '2026-09-30',
        throughLocalDate: '2026-09-30',
      );
      await repo.saveReviewed(preview);
      final service = CareRecordingService(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
        clock: () => DateTime.utc(2026, 9, 30, 11),
      );
      Future<PreparedCareIntent> prepare() => service.preparePrn(
        personId: f.person.id,
        pillId: f.pill.id,
        expectedRoutineRevision: 2,
        reviewedLocalDate: '2026-09-30',
        amount: const MedicationAmount.unknown(),
        actualAt: null,
        actualTimeKnown: false,
      );
      final first = await prepare();
      final a = await service.commit(first);
      expect((await service.commit(first)).event.id, a.event.id);
      final second = await prepare();
      final b = await service.commit(second);
      expect(a.current.id, isNot(b.current.id));
      expect(a.current.expected, isFalse);
      expect(a.current.plannedAt, isNull);
      expect(a.event.actualAt, isNull);
      expect(await service.historyForPerson(f.person.id), hasLength(2));
    },
  );

  test('prepared record refuses a changed head or removed person', () async {
    final f = await CareRecordingFixture.create();
    addTearDown(f.db.close);
    final service = CareRecordingService(
      database: f.db,
      access: f.workspace.access,
      context: f.workspace.context,
    );
    final intent = await service.prepareTakenNow(
      personId: f.person.id,
      occurrenceId: f.occurrence.id,
      expectedStateVersion: 0,
    );
    await (f.db.update(f.db.medicationOccurrences)
          ..where((r) => r.id.equals(f.occurrence.id)))
        .write(const MedicationOccurrencesCompanion(stateVersion: Value(1)));
    await expectLater(
      service.commit(intent),
      throwsA(isA<MedicationCommandBlocked>()),
    );
    expect(await f.db.select(f.db.occurrenceEvents).get(), isEmpty);
  });

  test(
    'correction contribution survives repeated corrections and exact Undo',
    () async {
      final f = await CareRecordingFixture.create();
      addTearDown(f.db.close);
      final stocks = ReviewedStockRepository(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
      );
      await stocks.review(
        f.pill.id,
        StockQuantity.parse('10', 'tablet'),
        expectedRevision: 0,
      );
      final service = CareRecordingService(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
      );
      Future<CareRecordingReceipt> take(int version, String amount) async =>
          service.commit(
            await service.prepare(
              personId: f.person.id,
              occurrenceId: f.occurrence.id,
              expectedStateVersion: version,
              action: version == 0
                  ? MedicationAction.take
                  : MedicationAction.correct,
              targetState: version == 0 ? null : MedicationState.taken,
              amount: MedicationAmount.known(amount, 'tablet'),
              actualAt: null,
              actualTimeKnown: false,
            ),
          );
      Future<StockQuantity> balance() async => StockQuantity.fromJson(
        jsonDecode((await stocks.load(f.pill.id))!.quantityJson),
      );
      await take(0, '1/2');
      await take(1, '1/2');
      final skipped = await service.commit(
        await service.prepare(
          personId: f.person.id,
          occurrenceId: f.occurrence.id,
          expectedStateVersion: 2,
          action: MedicationAction.correct,
          targetState: MedicationState.skipped,
          amount: const MedicationAmount.unknown(),
          actualAt: null,
          actualTimeKnown: false,
        ),
      );
      expect((await balance()).numerator, BigInt.from(10));
      final undone = await service.commit(await service.prepareUndo(skipped));
      expect(undone.current.state, 'taken');
      expect(undone.amount.quantityText, '1/2');
      expect((await balance()).numerator, BigInt.from(19));
      await take(4, '1');
      await take(5, '2');
      expect((await balance()).numerator, BigInt.from(8));
    },
  );

  test(
    'deleted and moved medication retains history under its recorded person',
    () async {
      final f = await CareRecordingFixture.create();
      addTearDown(f.db.close);
      final service = CareRecordingService(
        database: f.db,
        access: f.workspace.access,
        context: f.workspace.context,
      );
      final recorded = await service.commit(
        await service.prepareTakenNow(
          personId: f.person.id,
          occurrenceId: f.occurrence.id,
          expectedStateVersion: 0,
        ),
      );
      await (f.db.update(f.db.pills)..where((p) => p.id.equals(f.pill.id)))
          .write(const PillsCompanion(isDeleted: Value(true)));
      expect(
        (await service.historyForPerson(f.person.id)).single.event.id,
        recorded.event.id,
      );
      const other = 'other-fictional-person';
      await f.db.profilesDao.upsert(
        ProfilesCompanion.insert(
          id: other,
          userId: f.workspace.context.ownerUserId,
          name: 'Other fictional person',
          createdAt: DateTime.utc(2026, 9, 30),
          updatedAt: DateTime.utc(2026, 9, 30),
        ),
      );
      await (f.db.update(
        f.db.pills,
      )..where((p) => p.id.equals(f.pill.id))).write(
        const PillsCompanion(isDeleted: Value(false), profileId: Value(other)),
      );
      expect(
        (await service.historyForPerson(f.person.id)).single.event.id,
        recorded.event.id,
      );
      expect(await service.historyForPerson(other), isEmpty);
    },
  );
}
