import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value, Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/auto_miss_discard.dart';
import 'package:simpastil/core/medication/medication_command.dart';
import 'package:simpastil/core/medication/medication_repository.dart';
import 'package:simpastil/core/projections/projection_command_id.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';

const _userId = 'user-1';
const _profileId = '00000000-0000-4000-8000-000000000001';
const _pillId = '00000000-0000-4000-8000-000000000002';
const _scheduleId = '00000000-0000-4000-8000-000000000003';
const _occurrenceId = '00000000-0000-4000-8000-000000000004';

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    final now = DateTime.utc(2026, 9, 24, 5, 0);
    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: _userId,
            email: 'user@test.com',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await db.profilesDao.upsert(
      ProfilesCompanion.insert(
        id: _profileId,
        userId: _userId,
        name: 'Ada',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await db.pillsDao.upsert(
      PillsCompanion.insert(
        id: _pillId,
        profileId: _profileId,
        name: 'Medication',
        currentStock: const Value(3),
        createdAt: now,
        updatedAt: now,
      ),
    );
    await db.schedulesDao.upsert(
      SchedulesCompanion.insert(
        id: _scheduleId,
        pillId: _pillId,
        hour: 8,
        minute: 0,
        frequency: 'daily',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await db.medicationLedgerDao.upsertOccurrence(
      MedicationOccurrencesCompanion.insert(
        id: _occurrenceId,
        userId: _userId,
        pillId: const Value(_pillId),
        scheduleId: const Value(_scheduleId),
        occurrenceKey: 'scheduled:v1:fixture',
        source: 'scheduled',
        scheduleRevision: const Value(1),
        plannedLocalDate: '2026-09-24',
        plannedLocalTime: const Value('08:00'),
        timeZone: 'Europe/Bucharest',
        plannedAt: Value(now),
        expected: const Value(true),
        scheduleSnapshotJson: jsonEncode({
          'version': 1,
          'frequency': 'daily',
          'dosage': null,
          'frequencyDays': null,
          'hour': 8,
          'minute': 0,
          'profileId': _profileId,
          'profileName': 'Ada',
          'pillName': 'Medication',
          'timeZone': 'Europe/Bucharest',
        }),
        provenance: 'exact',
        createdAt: now,
        updatedAt: now,
      ),
    );
  });

  tearDown(() => db.close());

  Future<({WorkspaceAccessRepository access, WorkspaceContext context})>
  protectedContext() async {
    final access = WorkspaceAccessRepository(db);
    const endpoint = 'https://fictional.test/care';
    final transition = await access.configureEndpoint(endpoint);
    await db
        .into(db.credentialSlots)
        .insert(
          CredentialSlotsCompanion.insert(
            id: 'fictional-staged',
            ownerId: _userId,
            endpoint: endpoint,
            state: 'staged',
            createdAt: DateTime.now(),
          ),
        );
    final authenticated = await access.authenticate(
      ownerId: _userId,
      endpoint: endpoint,
      expectedNetworkEpoch: transition,
      sessionGeneration: 1,
      credentialId: 'fictional-staged',
    );
    final context = await access.confirmOriginalServer(
      workspaceId: authenticated.workspace.id,
      reviewedOriginalEndpoint: endpoint,
      expectedNetworkEpoch: authenticated.network.epoch,
    );
    return (access: access, context: context);
  }

  test(
    'a retained medication repository refuses care reads and writes after revocation',
    () async {
      final fixture = await protectedContext();
      final repository = MedicationRepository(
        db,
        access: fixture.access,
        context: fixture.context,
      );
      await fixture.access.revokeNetwork();
      await expectLater(
        repository.occurrenceForScheduleSlot(
          userId: _userId,
          scheduleId: _scheduleId,
          scheduledAt: DateTime.utc(2026, 9, 24, 5),
        ),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
      await expectLater(
        repository.apply(
          userId: _userId,
          occurrenceId: _occurrenceId,
          action: MedicationAction.take,
          actualAt: DateTime.utc(2026, 9, 24, 5, 17),
          actualTimeKnown: true,
        ),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
      expect(
        (await db.medicationLedgerDao.getOccurrenceById(_occurrenceId))!.state,
        'pending',
      );
      expect(
        await db.medicationLedgerDao.getEventsForOccurrence(_occurrenceId),
        isEmpty,
      );
      expect(await db.pendingOperationsDao.getForUser(_userId), isEmpty);
      expect((await db.pillsDao.getById(_pillId))!.currentStock, 3);
    },
  );

  test(
    'review validator accepts only current enabled reminder projections',
    () async {
      final fixture = await protectedContext();
      await db
          .into(db.devicePersonReminders)
          .insert(
            DevicePersonRemindersCompanion.insert(
              profileId: _profileId,
              enabled: const Value(true),
            ),
          );
      await db
          .into(db.deviceScheduleReminders)
          .insert(
            DeviceScheduleRemindersCompanion.insert(
              workspaceId: fixture.context.workspaceId,
              scheduleId: _scheduleId,
              followUpMinutesJson: const Value('[10]'),
            ),
          );
      final repository = MedicationRepository(
        db,
        access: fixture.access,
        context: fixture.context,
      );
      String projection(String kind, int version) => reminderProjectionId(
        userId: _userId,
        sessionGeneration: fixture.context.accessEpoch,
        occurrenceId: _occurrenceId,
        kind: kind,
        workspaceId: fixture.context.workspaceId,
        grantEpoch: fixture.context.accessEpoch,
        stateVersion: version,
      );

      final occurrenceBefore = await db.medicationLedgerDao.getOccurrenceById(
        _occurrenceId,
      );
      final stockBefore = (await db.pillsDao.getById(_pillId))!.currentStock;
      final eventsBefore = await db.medicationLedgerDao.getEventsForOccurrence(
        _occurrenceId,
      );
      final receiptsBefore = await db.select(db.careEventDetails).get();
      final operationsBefore = await db.pendingOperationsDao.getForUser(
        _userId,
      );

      expect(
        await repository.isCurrentReminderActionForReview(
          occurrenceId: _occurrenceId,
          projectionId: projection('reminder', 0),
          kind: 'reminder',
          deliveredStateVersion: 0,
        ),
        isTrue,
      );
      expect(
        await repository.isCurrentReminderActionForReview(
          occurrenceId: _occurrenceId,
          projectionId: projection('snooze', 0),
          kind: 'snooze',
          deliveredStateVersion: 0,
        ),
        isTrue,
      );
      final followUp = followUpReminderKind(10);
      expect(
        await repository.isCurrentReminderActionForReview(
          occurrenceId: _occurrenceId,
          projectionId: projection(followUp, 0),
          kind: followUp,
          deliveredStateVersion: 0,
        ),
        isTrue,
      );
      expect(
        await repository.isCurrentReminderActionForReview(
          occurrenceId: _occurrenceId,
          projectionId: projection('reminder', 1),
          kind: 'reminder',
          deliveredStateVersion: 1,
        ),
        isFalse,
      );
      expect(
        await repository.isCurrentReminderActionForReview(
          occurrenceId: _occurrenceId,
          projectionId: 'wrong-projection',
          kind: 'reminder',
          deliveredStateVersion: 0,
        ),
        isFalse,
      );

      await (db.update(db.devicePersonReminders)
            ..where((row) => row.profileId.equals(_profileId)))
          .write(const DevicePersonRemindersCompanion(enabled: Value(false)));
      expect(
        await repository.isCurrentReminderActionForReview(
          occurrenceId: _occurrenceId,
          projectionId: projection('reminder', 0),
          kind: 'reminder',
          deliveredStateVersion: 0,
        ),
        isFalse,
      );
      expect(
        await db.medicationLedgerDao.getOccurrenceById(_occurrenceId),
        occurrenceBefore,
      );
      expect((await db.pillsDao.getById(_pillId))!.currentStock, stockBefore);
      expect(
        await db.medicationLedgerDao.getEventsForOccurrence(_occurrenceId),
        eventsBefore,
      );
      expect(await db.select(db.careEventDetails).get(), receiptsBefore);
      expect(
        await db.pendingOperationsDao.getForUser(_userId),
        operationsBefore,
      );
    },
  );

  test('review validator refuses a revoked workspace grant', () async {
    final fixture = await protectedContext();
    await db
        .into(db.devicePersonReminders)
        .insert(
          DevicePersonRemindersCompanion.insert(
            profileId: _profileId,
            enabled: const Value(true),
          ),
        );
    final repository = MedicationRepository(
      db,
      access: fixture.access,
      context: fixture.context,
    );
    final projectionId = reminderProjectionId(
      userId: _userId,
      sessionGeneration: fixture.context.accessEpoch,
      occurrenceId: _occurrenceId,
      kind: 'reminder',
      workspaceId: fixture.context.workspaceId,
      grantEpoch: fixture.context.accessEpoch,
      stateVersion: 0,
    );
    await fixture.access.revokeNetwork();
    await expectLater(
      repository.isCurrentReminderActionForReview(
        occurrenceId: _occurrenceId,
        projectionId: projectionId,
        kind: 'reminder',
        deliveredStateVersion: 0,
      ),
      throwsA(isA<WorkspaceAccessFailure>()),
    );
    expect(
      (await db.medicationLedgerDao.getOccurrenceById(_occurrenceId))!.state,
      'pending',
    );
    expect(
      await db.medicationLedgerDao.getEventsForOccurrence(_occurrenceId),
      isEmpty,
    );
    expect(await db.pendingOperationsDao.getForUser(_userId), isEmpty);
    expect((await db.pillsDao.getById(_pillId))!.currentStock, 3);
  });

  test(
    'widget review accepts its exact protected action without notification settings',
    () async {
      final fixture = await protectedContext();
      await db
          .into(db.devicePersonReminders)
          .insert(
            DevicePersonRemindersCompanion.insert(
              profileId: _profileId,
              enabled: const Value(true),
            ),
          );
      await db
          .into(db.deviceScheduleReminders)
          .insert(
            DeviceScheduleRemindersCompanion.insert(
              workspaceId: fixture.context.workspaceId,
              scheduleId: _scheduleId,
              enabled: const Value(false),
            ),
          );
      final repository = MedicationRepository(
        db,
        access: fixture.access,
        context: fixture.context,
      );
      final projectionId = widgetProjectionId(
        userId: _userId,
        sessionGeneration: fixture.context.accessEpoch,
        occurrenceId: _occurrenceId,
        workspaceId: fixture.context.workspaceId,
        grantEpoch: fixture.context.accessEpoch,
        stateVersion: 0,
      );
      final occurrenceBefore = await db.medicationLedgerDao.getOccurrenceById(
        _occurrenceId,
      );
      final eventsBefore = await db.medicationLedgerDao.getEventsForOccurrence(
        _occurrenceId,
      );
      final stockBefore = (await db.pillsDao.getById(_pillId))!.currentStock;
      final receiptsBefore = await db.select(db.careEventDetails).get();
      final operationsBefore = await db.pendingOperationsDao.getForUser(
        _userId,
      );

      expect(
        await repository.isCurrentWidgetActionForReview(
          occurrenceId: _occurrenceId,
          projectionId: projectionId,
          deliveredStateVersion: 0,
        ),
        isTrue,
      );
      expect(
        await repository.isCurrentWidgetActionForReview(
          occurrenceId: _occurrenceId,
          projectionId: projectionId,
          deliveredStateVersion: 1,
        ),
        isFalse,
      );
      expect(
        await db.medicationLedgerDao.getOccurrenceById(_occurrenceId),
        occurrenceBefore,
      );
      expect(
        await db.medicationLedgerDao.getEventsForOccurrence(_occurrenceId),
        eventsBefore,
      );
      expect((await db.pillsDao.getById(_pillId))!.currentStock, stockBefore);
      expect(await db.select(db.careEventDetails).get(), receiptsBefore);
      expect(
        await db.pendingOperationsDao.getForUser(_userId),
        operationsBefore,
      );
    },
  );

  test(
    'protected medication replay retains exact command and rejects another owner',
    () async {
      final fixture = await protectedContext();
      final repository = MedicationRepository(
        db,
        access: fixture.access,
        context: fixture.context,
      );
      final time = DateTime.utc(2026, 9, 24, 5, 17);
      final first = await repository.apply(
        userId: _userId,
        occurrenceId: _occurrenceId,
        action: MedicationAction.take,
        actualAt: time,
        actualTimeKnown: true,
      );
      final replay = await repository.apply(
        userId: _userId,
        occurrenceId: _occurrenceId,
        action: MedicationAction.take,
        actualAt: time,
        actualTimeKnown: true,
      );
      expect(replay.commandId, first.commandId);
      expect(
        await db.medicationLedgerDao.getEventsForOccurrence(_occurrenceId),
        hasLength(1),
      );
      await expectLater(
        repository.apply(
          userId: 'fictional-other-owner',
          occurrenceId: _occurrenceId,
          action: MedicationAction.take,
          actualAt: time,
          actualTimeKnown: true,
        ),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
    },
  );

  test(
    'a captured medication grant cannot change stock through foreign parent references',
    () async {
      final fixture = await protectedContext();
      final now = DateTime.now();
      await db.usersDao.upsert(
        UsersCompanion.insert(
          id: 'fictional-other-owner',
          email: 'fictional-other@example.invalid',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await db.profilesDao.upsert(
        ProfilesCompanion.insert(
          id: 'fictional-other-person',
          userId: 'fictional-other-owner',
          name: 'Retained person',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await db.pillsDao.upsert(
        PillsCompanion.insert(
          id: 'fictional-other-pill',
          profileId: 'fictional-other-person',
          name: 'Retained medication',
          currentStock: const Value(9),
          createdAt: now,
          updatedAt: now,
        ),
      );
      await db.schedulesDao.upsert(
        SchedulesCompanion.insert(
          id: 'fictional-other-schedule',
          pillId: 'fictional-other-pill',
          hour: 8,
          minute: 0,
          frequency: 'daily',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await db.customUpdate(
        "UPDATE medication_occurrences SET schedule_id='fictional-other-schedule', pill_id='fictional-other-pill' WHERE id='$_occurrenceId'",
        updates: {db.medicationOccurrences},
      );
      final repository = MedicationRepository(
        db,
        access: fixture.access,
        context: fixture.context,
      );
      await expectLater(
        repository.apply(
          userId: _userId,
          occurrenceId: _occurrenceId,
          action: MedicationAction.take,
          actualAt: now,
          actualTimeKnown: true,
        ),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
      expect(
        (await db.pillsDao.getById('fictional-other-pill'))!.currentStock,
        9,
      );
      expect(await db.pendingOperationsDao.getForUser(_userId), isEmpty);
      expect(
        await db.medicationLedgerDao.getEventsForOccurrence(_occurrenceId),
        isEmpty,
      );
    },
  );

  test('same-workspace snapshot cannot name a different person', () async {
    final fixture = await protectedContext();
    final now = DateTime.now();
    await db.profilesDao.upsert(
      ProfilesCompanion.insert(
        id: 'fictional-person-b',
        userId: _userId,
        name: 'B',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await db.customUpdate(
      'UPDATE medication_occurrences SET schedule_snapshot_json=? WHERE id=?',
      variables: [
        Variable<String>(
          jsonEncode({
            'version': 1,
            'frequency': 'daily',
            'dosage': null,
            'frequencyDays': null,
            'hour': 8,
            'minute': 0,
            'profileId': 'fictional-person-b',
            'profileName': 'B',
            'pillName': 'Medication',
            'timeZone': 'Europe/Bucharest',
          }),
        ),
        const Variable<String>(_occurrenceId),
      ],
      updates: {db.medicationOccurrences},
    );
    final repository = MedicationRepository(
      db,
      access: fixture.access,
      context: fixture.context,
    );
    await expectLater(
      repository.apply(
        userId: _userId,
        occurrenceId: _occurrenceId,
        action: MedicationAction.take,
        actualAt: now,
        actualTimeKnown: true,
      ),
      throwsA(isA<MedicationCommandBlocked>()),
    );
    expect((await db.pillsDao.getById(_pillId))!.currentStock, 3);
    expect(
      await db.medicationLedgerDao.getEventsForOccurrence(_occurrenceId),
      isEmpty,
    );
    expect(await db.pendingOperationsDao.getForUser(_userId), isEmpty);
  });

  test(
    'stock callback runs after care commits without blocking revocation',
    () async {
      final fixture = await protectedContext();
      final started = Completer<void>();
      final release = Completer<void>();
      final repository = MedicationRepository(
        db,
        access: fixture.access,
        context: fixture.context,
        onStockChanged: (_) async {
          started.complete();
          await release.future;
        },
      );
      final command = repository.apply(
        userId: _userId,
        occurrenceId: _occurrenceId,
        action: MedicationAction.take,
        actualAt: DateTime.now(),
        actualTimeKnown: true,
      );
      await started.future;
      expect(
        (await db.medicationLedgerDao.getOccurrenceById(_occurrenceId))!.state,
        'taken',
      );
      expect((await db.pillsDao.getById(_pillId))!.currentStock, 2);
      await fixture.access.revokeNetwork();
      expect(await fixture.access.currentNetworkCapability(), isNull);
      release.complete();
      await command;
      expect(
        await db.medicationLedgerDao.getEventsForOccurrence(_occurrenceId),
        hasLength(1),
      );
    },
  );

  test(
    'take atomically journals command, split effects, event and stock',
    () async {
      final repository = MedicationRepository(db);

      final command = await repository.apply(
        userId: _userId,
        occurrenceId: _occurrenceId,
        action: MedicationAction.take,
        actualAt: DateTime.utc(2026, 9, 24, 5, 17),
        actualTimeKnown: true,
      );

      final occurrence = await db.medicationLedgerDao.getOccurrenceById(
        _occurrenceId,
      );
      final events = await db.medicationLedgerDao.getEventsForOccurrence(
        _occurrenceId,
      );
      final operations = await db.pendingOperationsDao.getForUser(_userId);
      final effects = await db.pendingOperationsDao.getEffects(
        operations.single.id,
      );
      expect(occurrence?.state, 'taken');
      expect(occurrence?.stateVersion, 1);
      expect(events.single.commandId, command.commandId);
      expect((await db.pillsDao.getById(_pillId))?.currentStock, 2);
      expect(operations.single.component, 'medication');
      expect(effects.map((effect) => effect.kind), ['dose', 'inventory']);
      expect(effects.every((effect) => effect.state == 'queued'), isTrue);
    },
  );

  test(
    'replayed take intent reuses its command without applying twice',
    () async {
      final repository = MedicationRepository(db);
      final actualAt = DateTime.utc(2026, 9, 24, 5, 17);

      final first = await repository.apply(
        userId: _userId,
        occurrenceId: _occurrenceId,
        action: MedicationAction.take,
        actualAt: actualAt,
        actualTimeKnown: true,
      );
      final replay = await repository.apply(
        userId: _userId,
        occurrenceId: _occurrenceId,
        action: MedicationAction.take,
        actualAt: actualAt,
        actualTimeKnown: true,
      );

      expect(replay.commandId, first.commandId);
      expect(
        (await db.medicationLedgerDao.getEventsForOccurrence(
          _occurrenceId,
        )).length,
        1,
      );
      expect((await db.pillsDao.getById(_pillId))?.currentStock, 2);
      expect((await db.pendingOperationsDao.getForUser(_userId)).length, 1);
    },
  );

  test(
    'conflicted take rebases as a linked correction against server head',
    () async {
      final repository = MedicationRepository(db);
      final original = await repository.apply(
        userId: _userId,
        occurrenceId: _occurrenceId,
        action: MedicationAction.take,
        actualAt: DateTime.utc(2026, 9, 24, 5, 17),
        actualTimeKnown: true,
      );
      final pending = await db.pendingOperationsDao.getByMutationId(
        _userId,
        original.commandId,
      );
      expect(pending, isNotNull);
      await db.pendingOperationsDao.transitionState(
        operationId: pending!.id,
        from: 'queued',
        to: 'sending',
      );
      await db.pendingOperationsDao.transitionState(
        operationId: pending.id,
        from: 'sending',
        to: 'conflict',
      );

      final now = DateTime.utc(2026, 9, 24, 6);
      await (db.update(
        db.medicationOccurrences,
      )..where((row) => row.id.equals(_occurrenceId))).write(
        const MedicationOccurrencesCompanion(
          serverId: Value('server-occurrence'),
          state: Value('skipped'),
          stateVersion: Value(2),
        ),
      );
      await (db.update(db.pills)..where((row) => row.id.equals(_pillId))).write(
        const PillsCompanion(currentStock: Value(3)),
      );
      await db.medicationLedgerDao.appendOccurrenceEvent(
        OccurrenceEventsCompanion.insert(
          id: 'server-event-local',
          serverId: const Value('server-event-head'),
          userId: _userId,
          occurrenceId: _occurrenceId,
          commandId: 'server-command-head',
          action: 'skip',
          fromState: 'pending',
          toState: 'skipped',
          actualTimeKnown: const Value(false),
          origin: 'native',
          baseVersion: 1,
          resultVersion: 2,
          recordedAt: now,
        ),
      );

      final rebased = await repository.rebaseConflict(pending.id);

      expect(rebased?.action, MedicationAction.correct);
      expect(rebased?.targetState, MedicationState.taken);
      expect(rebased?.rebasesCommandId, original.commandId);
      expect((await db.pillsDao.getById(_pillId))?.currentStock, 2);
      final originalAfterRebase = await db.pendingOperationsDao.getById(
        pending.id,
      );
      final operations = await db.pendingOperationsDao.getForUser(_userId);
      final linked = operations.singleWhere(
        (operation) => operation.id != pending.id,
      );
      expect(operations, hasLength(2));
      expect(originalAfterRebase?.state, 'committed');
      expect(linked.dependsOnOperationId, pending.id);
    },
  );

  test(
    'rebase keeps the stock count negative instead of clamping it to zero',
    () async {
      final repository = MedicationRepository(db);
      final original = await repository.apply(
        userId: _userId,
        occurrenceId: _occurrenceId,
        action: MedicationAction.take,
        actualAt: DateTime.utc(2026, 9, 24, 5, 17),
        actualTimeKnown: true,
      );
      final pending = await db.pendingOperationsDao.getByMutationId(
        _userId,
        original.commandId,
      );
      expect(pending, isNotNull);
      await db.pendingOperationsDao.transitionState(
        operationId: pending!.id,
        from: 'queued',
        to: 'sending',
      );
      await db.pendingOperationsDao.transitionState(
        operationId: pending.id,
        from: 'sending',
        to: 'conflict',
      );

      final now = DateTime.utc(2026, 9, 24, 6);
      await (db.update(
        db.medicationOccurrences,
      )..where((row) => row.id.equals(_occurrenceId))).write(
        const MedicationOccurrencesCompanion(
          serverId: Value('server-occurrence'),
          state: Value('skipped'),
          stateVersion: Value(2),
        ),
      );
      await (db.update(db.pills)..where((row) => row.id.equals(_pillId))).write(
        const PillsCompanion(currentStock: Value(0)),
      );
      await db.medicationLedgerDao.appendOccurrenceEvent(
        OccurrenceEventsCompanion.insert(
          id: 'server-event-local',
          serverId: const Value('server-event-head'),
          userId: _userId,
          occurrenceId: _occurrenceId,
          commandId: 'server-command-head',
          action: 'skip',
          fromState: 'pending',
          toState: 'skipped',
          actualTimeKnown: const Value(false),
          origin: 'native',
          baseVersion: 1,
          resultVersion: 2,
          recordedAt: now,
        ),
      );

      final rebased = await repository.rebaseConflict(pending.id);

      expect(rebased?.action, MedicationAction.correct);
      expect((await db.pillsDao.getById(_pillId))?.currentStock, -1);
    },
  );

  test(
    'rebase of an as-needed occurrence leaves tracked stock and inventory untouched',
    () async {
      await (db.update(
        db.medicationOccurrences,
      )..where((row) => row.id.equals(_occurrenceId))).write(
        const MedicationOccurrencesCompanion(
          source: Value('prn'),
          expected: Value(false),
        ),
      );
      final repository = MedicationRepository(db);
      final original = await repository.apply(
        userId: _userId,
        occurrenceId: _occurrenceId,
        action: MedicationAction.take,
        actualAt: DateTime.utc(2026, 9, 24, 5, 17),
        actualTimeKnown: true,
      );
      final pending = await db.pendingOperationsDao.getByMutationId(
        _userId,
        original.commandId,
      );
      expect(pending, isNotNull);
      await db.pendingOperationsDao.transitionState(
        operationId: pending!.id,
        from: 'queued',
        to: 'sending',
      );
      await db.pendingOperationsDao.transitionState(
        operationId: pending.id,
        from: 'sending',
        to: 'conflict',
      );

      final now = DateTime.utc(2026, 9, 24, 6);
      await (db.update(
        db.medicationOccurrences,
      )..where((row) => row.id.equals(_occurrenceId))).write(
        const MedicationOccurrencesCompanion(
          serverId: Value('server-occurrence'),
          state: Value('skipped'),
          stateVersion: Value(2),
        ),
      );
      await (db.update(db.pills)..where((row) => row.id.equals(_pillId))).write(
        const PillsCompanion(currentStock: Value(3)),
      );
      await db.medicationLedgerDao.appendOccurrenceEvent(
        OccurrenceEventsCompanion.insert(
          id: 'server-event-local',
          serverId: const Value('server-event-head'),
          userId: _userId,
          occurrenceId: _occurrenceId,
          commandId: 'server-command-head',
          action: 'skip',
          fromState: 'pending',
          toState: 'skipped',
          actualTimeKnown: const Value(false),
          origin: 'native',
          baseVersion: 1,
          resultVersion: 2,
          recordedAt: now,
        ),
      );

      final rebased = await repository.rebaseConflict(pending.id);

      expect(rebased?.action, MedicationAction.correct);
      expect((await db.pillsDao.getById(_pillId))?.currentStock, 3);
      expect(
        await db.medicationLedgerDao.getInventoryEventsForPill(_pillId),
        isEmpty,
      );
      final operations = await db.pendingOperationsDao.getForUser(_userId);
      for (final operation in operations) {
        final effects = await db.pendingOperationsDao.getEffects(operation.id);
        expect(
          effects.map((effect) => effect.kind),
          isNot(contains('inventory')),
        );
      }
    },
  );

  group('automatic miss', () {
    final missId = autoMissCommandId(
      ownerUserId: _userId,
      occurrenceKey: 'scheduled:v1:fixture',
    );

    Future<MedicationCommand> recordMiss(MedicationRepository repository) =>
        repository.apply(
          userId: _userId,
          occurrenceId: _occurrenceId,
          action: MedicationAction.miss,
          actualTimeKnown: false,
          commandIdOverride: missId,
        );

    test('records a miss without touching stock or the wire note', () async {
      final repository = MedicationRepository(db);

      final command = await recordMiss(repository);

      final occurrence = await db.medicationLedgerDao.getOccurrenceById(
        _occurrenceId,
      );
      final operation = (await db.pendingOperationsDao.getForUser(
        _userId,
      )).single;
      final payload = jsonDecode(operation.payloadJson) as Map;
      expect(command.commandId, missId);
      expect(command.action, MedicationAction.miss);
      expect(command.baseVersion, 0);
      expect(command.actualAt, isNull);
      expect(occurrence?.state, 'missed');
      expect(occurrence?.stateVersion, 1);
      expect((await db.pillsDao.getById(_pillId))?.currentStock, 3);
      expect((payload['intent'] as Map)['origin'], 'auto');
      expect((payload['command'] as Map).containsKey('origin'), isFalse);
      expect(isAutoMissOperation(operation), isTrue);
      expect(
        (await db.doseLogsDao.getByScheduledSlot(
          _scheduleId,
          DateTime.utc(2026, 9, 24, 5),
        ))?.status,
        'missed',
      );
    });

    test('is idempotent for the same deterministic command', () async {
      final repository = MedicationRepository(db);

      await recordMiss(repository);
      final replay = await recordMiss(repository);

      expect(replay.commandId, missId);
      expect(
        await db.medicationLedgerDao.getEventsForOccurrence(_occurrenceId),
        hasLength(1),
      );
      expect(await db.pendingOperationsDao.getForUser(_userId), hasLength(1));
    });

    test('refuses a dose that has not come due yet', () async {
      await (db.update(
        db.medicationOccurrences,
      )..where((row) => row.id.equals(_occurrenceId))).write(
        MedicationOccurrencesCompanion(
          plannedAt: Value(
            DateTime.now().toUtc().add(const Duration(hours: 1)),
          ),
        ),
      );
      final repository = MedicationRepository(db);

      await expectLater(
        recordMiss(repository),
        throwsA(
          isA<MedicationCommandBlocked>().having(
            (e) => e.code,
            'code',
            'miss_not_allowed',
          ),
        ),
      );
      expect(await db.pendingOperationsDao.getForUser(_userId), isEmpty);
    });

    test('a take before the miss was sent withdraws the miss', () async {
      final repository = MedicationRepository(db);
      await recordMiss(repository);

      final taken = await repository.apply(
        userId: _userId,
        occurrenceId: _occurrenceId,
        action: MedicationAction.take,
        actualAt: DateTime.utc(2026, 9, 24, 7),
        actualTimeKnown: true,
      );

      final occurrence = await db.medicationLedgerDao.getOccurrenceById(
        _occurrenceId,
      );
      final operations = await db.pendingOperationsDao.getForUser(_userId);
      final miss = operations.singleWhere((op) => op.mutationId == missId);
      final take = operations.singleWhere(
        (op) => op.mutationId == taken.commandId,
      );
      expect(taken.action, MedicationAction.take);
      expect(taken.baseVersion, 0);
      expect(occurrence?.state, 'taken');
      expect(occurrence?.stateVersion, 1);
      expect((await db.pillsDao.getById(_pillId))?.currentStock, 2);
      expect(miss.state, 'discarded');
      expect(miss.safeErrorCode, 'AUTO_MISS_WITHDRAWN');
      expect(take.state, 'queued');
      expect(take.dependsOnOperationId, isNull);
      expect(
        (await db.doseLogsDao.getByScheduledSlot(
          _scheduleId,
          DateTime.utc(2026, 9, 24, 5),
        ))?.status,
        'taken',
      );
    });

    test('a skip before the miss was sent withdraws the miss', () async {
      final repository = MedicationRepository(db);
      await recordMiss(repository);

      final skipped = await repository.apply(
        userId: _userId,
        occurrenceId: _occurrenceId,
        action: MedicationAction.skip,
        actualTimeKnown: false,
      );

      final occurrence = await db.medicationLedgerDao.getOccurrenceById(
        _occurrenceId,
      );
      expect(skipped.action, MedicationAction.skip);
      expect(skipped.baseVersion, 0);
      expect(occurrence?.state, 'skipped');
      expect(occurrence?.stateVersion, 1);
      expect((await db.pillsDao.getById(_pillId))?.currentStock, 3);
    });

    test('a take after the miss was tried is a late correction', () async {
      final repository = MedicationRepository(db);
      await recordMiss(repository);
      final miss = (await db.pendingOperationsDao.getForUser(_userId)).single;
      await db.pendingOperationsDao.transitionState(
        operationId: miss.id,
        from: 'queued',
        to: 'sending',
      );
      await db.pendingOperationsDao.transitionState(
        operationId: miss.id,
        from: 'sending',
        to: 'failedRetryable',
      );

      final taken = await repository.apply(
        userId: _userId,
        occurrenceId: _occurrenceId,
        action: MedicationAction.take,
        actualAt: DateTime.utc(2026, 9, 24, 7),
        actualTimeKnown: true,
      );

      final occurrence = await db.medicationLedgerDao.getOccurrenceById(
        _occurrenceId,
      );
      final after = await db.pendingOperationsDao.getById(miss.id);
      expect(taken.action, MedicationAction.correct);
      expect(taken.targetState, MedicationState.taken);
      expect(taken.baseVersion, 1);
      expect(occurrence?.state, 'taken');
      expect(occurrence?.stateVersion, 2);
      expect((await db.pillsDao.getById(_pillId))?.currentStock, 2);
      expect(after?.state, 'failedRetryable');
    });
  });
}
