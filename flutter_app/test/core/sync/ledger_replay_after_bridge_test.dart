import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/account_settlement_merger.dart';
import 'package:simpastil/core/medication/medication_command.dart';
import 'package:simpastil/core/medication/medication_repository.dart';
import 'package:simpastil/core/sync/component_sync_merger.dart';
import 'package:simpastil/core/sync/sync_models.dart';

const _u = 'user-1';
const _prof = '00000000-0000-4000-8000-000000000001';
const _pillA = '00000000-0000-4000-8000-00000000000a';
const _pillB = '00000000-0000-4000-8000-00000000000b';
const _schA = '00000000-0000-4000-8000-0000000000a1';
const _schB = '00000000-0000-4000-8000-0000000000b1';
const _locA = '00000000-0000-4000-8000-0000000000a4';
const _locB = '00000000-0000-4000-8000-0000000000b4';
const _srvA = '00000000-0000-4000-8000-0000000005a4';
const _srvB = '00000000-0000-4000-8000-0000000005b4';
const _keyA = 'scheduled:v1:a';
const _keyB = 'scheduled:v1:b';

Map<String, dynamic> _snapshot(String name) => {
  'version': 1,
  'frequency': 'daily',
  'dosage': null,
  'frequencyDays': null,
  'hour': 8,
  'minute': 0,
  'profileId': _prof,
  'profileName': 'Ada',
  'pillName': name,
  'timeZone': 'Europe/Bucharest',
};

Map<String, dynamic> _occ(
  String id,
  String pill,
  String sch,
  String key,
  String version,
) => {
  'kind': 'medicationOccurrence',
  'id': id,
  'pillId': pill,
  'scheduleId': sch,
  'occurrenceKey': key,
  'source': 'scheduled',
  'scheduleRevision': '1',
  'plannedLocalDate': '2026-10-13',
  'plannedLocalTime': '08:00',
  'timeZone': 'Europe/Bucharest',
  'plannedAt': '2026-10-13T05:00:00.000Z',
  'expected': true,
  'snapshotVersion': 1,
  'scheduleSnapshot': _snapshot('x'),
  'provenance': 'exact',
  'supersededAt': null,
  'supersededByOccurrenceId': null,
  'stateVersion': version,
};

Map<String, dynamic> _change(
  String entityType,
  String id,
  Map<String, dynamic> p,
) => {
  'schemaVersion': 2,
  'component': 'medication',
  'entityType': entityType,
  'entityId': id,
  'operation': 'upsert',
  'payload': p,
};

void main() {
  late AppDatabase db;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    final now = DateTime.utc(2026, 10, 13, 5);
    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: _u,
            email: 'u@test.com',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await db.profilesDao.upsert(
      ProfilesCompanion.insert(
        id: _prof,
        userId: _u,
        name: 'Ada',
        createdAt: now,
        updatedAt: now,
        serverId: const Value(_prof),
        syncStatus: const Value('synced'),
      ),
    );
    for (final (id, sid, name) in [
      (_pillA, _schA, 'Alpha'),
      (_pillB, _schB, 'Beta'),
    ]) {
      await db.pillsDao.upsert(
        PillsCompanion.insert(
          id: id,
          profileId: _prof,
          name: name,
          currentStock: const Value(7),
          serverId: Value(id),
          syncStatus: const Value('synced'),
          createdAt: now,
          updatedAt: now,
        ),
      );
      await db.schedulesDao.upsert(
        SchedulesCompanion.insert(
          id: sid,
          pillId: id,
          hour: 8,
          minute: 0,
          frequency: 'daily',
          serverId: Value(sid),
          syncStatus: const Value('synced'),
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
    for (final (id, pill, sch, key, name) in [
      (_locA, _pillA, _schA, _keyA, 'Alpha'),
      (_locB, _pillB, _schB, _keyB, 'Beta'),
    ]) {
      await db.medicationLedgerDao.upsertOccurrence(
        MedicationOccurrencesCompanion.insert(
          id: id,
          userId: _u,
          pillId: Value(pill),
          scheduleId: Value(sch),
          occurrenceKey: key,
          source: 'scheduled',
          scheduleRevision: const Value(1),
          plannedLocalDate: '2026-10-13',
          plannedLocalTime: const Value('08:00'),
          timeZone: 'Europe/Bucharest',
          plannedAt: Value(now),
          expected: const Value(true),
          scheduleSnapshotJson: jsonEncode(_snapshot(name)),
          provenance: 'exact',
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
  });
  tearDown(() => db.close());

  Future<void> replay(List<Map<String, dynamic>> changes) => db.transaction(
    () => ComponentSyncMerger(db).merge(_u, SyncComponent.medication, changes),
  );

  test('replay over bridge-era history', () async {
    final repo = MedicationRepository(db);
    await repo.apply(
      userId: _u,
      occurrenceId: _locA,
      action: MedicationAction.take,
      actualAt: DateTime.utc(2026, 10, 13, 5, 1),
      actualTimeKnown: true,
    );
    final ev = (await db.medicationLedgerDao.getEventsForOccurrence(
      _locA,
    )).single;
    await repo.apply(
      userId: _u,
      occurrenceId: _locA,
      action: MedicationAction.undo,
      actualTimeKnown: false,
      intendedState: MedicationState.pending,
      reversesEventId: ev.id,
    );
    await repo.apply(
      userId: _u,
      occurrenceId: _locA,
      action: MedicationAction.take,
      actualAt: DateTime.utc(2026, 10, 13, 5, 2),
      actualTimeKnown: true,
    );
    const bundle = '00000000-0000-4000-8000-0000000000c1';
    await replay([
      _change(
        'medication_occurrence',
        _srvA,
        _occ(_srvA, _pillA, _schA, _keyA, '0'),
      ),
      _change(
        'medication_occurrence',
        _srvB,
        _occ(_srvB, _pillB, _schB, _keyB, '0'),
      ),
      _change('inventory_event', 'i1', {
        'kind': 'inventoryEvent',
        'id': '00000000-0000-4000-8000-0000000000d1',
        'pillId': _pillA,
        'commandId': bundle,
        'eventKind': 'opening',
        'delta': 10,
        'occurrenceEventId': null,
        'reversesInventoryEventId': null,
        'provenance': 'legacy_handoff',
        'note': null,
        'serverSequence': '5',
        'recordedAt': '2026-10-13T05:00:00.000Z',
      }),
    ]);
    // replay again (checkpoint reset)
    await replay([
      _change(
        'medication_occurrence',
        _srvA,
        _occ(_srvA, _pillA, _schA, _keyA, '0'),
      ),
    ]);
  });

  Map<String, dynamic> evt(
    String id,
    String occ,
    String cmd,
    String action,
    String from,
    String to,
    String base,
    String result,
    String seq, {
    String? reverses,
  }) => _change('occurrence_event', id, {
    'kind': 'occurrenceEvent',
    'id': id,
    'occurrenceId': occ,
    'commandId': cmd,
    'action': action,
    'fromState': from,
    'toState': to,
    'reversesEventId': reverses,
    'rebasesCommandId': null,
    'actualAt': '2026-10-13T05:03:00.000Z',
    'actualTimeKnown': true,
    'note': null,
    'origin': 'native',
    'baseVersion': base,
    'resultVersion': result,
    'serverSequence': seq,
    'recordedAt': '2026-10-13T05:03:00.000Z',
  });

  test('local take beside server event with different versions', () async {
    final repo = MedicationRepository(db);
    await repo.apply(
      userId: _u,
      occurrenceId: _locA,
      action: MedicationAction.take,
      actualAt: DateTime.utc(2026, 10, 13, 5, 1),
      actualTimeKnown: true,
    );
    final e1 = (await db.medicationLedgerDao.getEventsForOccurrence(
      _locA,
    )).single;
    await repo.apply(
      userId: _u,
      occurrenceId: _locA,
      action: MedicationAction.undo,
      actualTimeKnown: false,
      intendedState: MedicationState.pending,
      reversesEventId: e1.id,
    );
    final c3 = await repo.apply(
      userId: _u,
      occurrenceId: _locA,
      action: MedicationAction.take,
      actualAt: DateTime.utc(2026, 10, 13, 5, 3),
      actualTimeKnown: true,
    );
    await replay([
      _change(
        'medication_occurrence',
        _srvA,
        _occ(_srvA, _pillA, _schA, _keyA, '1'),
      ),
      evt(
        '00000000-0000-4000-8000-0000000000e1',
        _srvA,
        c3.commandId,
        'take',
        'pending',
        'taken',
        '0',
        '1',
        '7',
      ),
      _change('inventory_event', 'i2', {
        'kind': 'inventoryEvent',
        'id': '00000000-0000-4000-8000-0000000000d2',
        'pillId': _pillA,
        'commandId': c3.commandId,
        'eventKind': 'dose',
        'delta': -1,
        'occurrenceEventId': '00000000-0000-4000-8000-0000000000e1',
        'reversesInventoryEventId': null,
        'provenance': 'native',
        'note': null,
        'serverSequence': '8',
        'recordedAt': '2026-10-13T05:03:00.000Z',
      }),
    ]);
  });

  test('replayed identity mapping over a dismissed review note', () async {
    final change = {
      'schemaVersion': 2,
      'component': 'medication',
      'entityType': 'identity_mapping',
      'entityId': '00000000-0000-4000-8000-0000000000d1',
      'operation': 'mapping',
      'payload': {
        'kind': 'identityMapping',
        'mappingRevision': '3',
        'legacySourceKind': 'pill_stock',
        'legacySourceId': _pillA,
        'historyId': '00000000-0000-4000-8000-0000000000f1',
        'bridgeCommandId': null,
        'targetEntityType': 'inventory_event',
        'targetEntityId': '00000000-0000-4000-8000-0000000000d1',
        'targetRevision': '5',
      },
    };
    // An older build wrote a note for this mapping; it is dismissed already.
    await AccountSettlementMerger(
      db,
    ).recordReviewIssue(_u, change, change['payload']! as Map<String, dynamic>);
    final note = (await db.select(db.migrationIssues).get()).single;
    await db.migrationIssuesDao.markResolved(
      [note.id],
      resolvedByUserId: _u,
      at: DateTime.utc(2026, 10, 14),
    );
    await replay([change]);
    final after = (await db.select(db.migrationIssues).get()).single;
    expect(after.id, note.id);
    expect(after.resolutionState, 'resolved');
    expect(after.resolvedAt, isNotNull);
  });

  test('a replayed identity mapping for a known pill writes no note', () async {
    final change = {
      'schemaVersion': 2,
      'component': 'medication',
      'entityType': 'identity_mapping',
      'entityId': '00000000-0000-4000-8000-0000000000d2',
      'operation': 'mapping',
      'payload': {
        'kind': 'identityMapping',
        'mappingRevision': '3',
        'legacySourceKind': 'pill_stock',
        'legacySourceId': _pillA,
        'historyId': '00000000-0000-4000-8000-0000000000f2',
        'bridgeCommandId': null,
        'targetEntityType': 'inventory_event',
        'targetEntityId': '00000000-0000-4000-8000-0000000000d2',
        'targetRevision': '5',
      },
    };
    await replay([change]);
    await replay([change]);
    expect(await db.select(db.migrationIssues).get(), isEmpty);
  });

  test('bridge-era local care survives a replay that includes a dismissed '
      'note and the take recorded just before it', () async {
    final repo = MedicationRepository(db);
    await repo.apply(
      userId: _u,
      occurrenceId: _locA,
      action: MedicationAction.take,
      actualAt: DateTime.utc(2026, 10, 13, 5, 1),
      actualTimeKnown: true,
    );
    final first = (await db.medicationLedgerDao.getEventsForOccurrence(
      _locA,
    )).single;
    final mapping = {
      'schemaVersion': 2,
      'component': 'medication',
      'entityType': 'identity_mapping',
      'entityId': first.id,
      'operation': 'mapping',
      'payload': {
        'kind': 'identityMapping',
        'mappingRevision': '3',
        'legacySourceKind': 'dose_log',
        'legacySourceId': _locA,
        'historyId': '00000000-0000-4000-8000-0000000000f3',
        'bridgeCommandId': first.commandId,
        'targetEntityType': 'legacy_medication_history',
        'targetEntityId': '00000000-0000-4000-8000-0000000000f3',
        'targetRevision': '1',
      },
    };
    final page = [
      _change(
        'medication_occurrence',
        _srvA,
        _occ(_srvA, _pillA, _schA, _keyA, '0'),
      ),
      _change(
        'medication_occurrence',
        _srvB,
        _occ(_srvB, _pillB, _schB, _keyB, '0'),
      ),
      mapping,
    ];
    await replay(page);
    final note = (await db.select(db.migrationIssues).get()).single;
    await db.migrationIssuesDao.markResolved(
      [note.id],
      resolvedByUserId: _u,
      at: DateTime.utc(2026, 10, 14),
    );
    await repo.apply(
      userId: _u,
      occurrenceId: _locB,
      action: MedicationAction.take,
      actualAt: DateTime.utc(2026, 10, 13, 5, 2),
      actualTimeKnown: true,
    );
    await replay(page);
    expect(
      (await db.medicationLedgerDao.getEventsForOccurrence(_locA)).single.id,
      first.id,
    );
    expect(
      await db.medicationLedgerDao.getEventsForOccurrence(_locB),
      hasLength(1),
    );
  });
}
