import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_day.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/medication/medication_repository.dart';
import 'package:simpastil/core/medication/occurrence_detail_repository.dart';
import 'package:simpastil/core/medication/occurrence_materializer.dart';
import 'package:simpastil/core/sync/adapters/bridge_medication_sync_adapter.dart';
import 'package:simpastil/core/sync/adapters/medication_sync_adapter.dart';
import 'package:simpastil/core/sync/component_sync_merger.dart';
import 'package:simpastil/core/sync/sync_models.dart';
import 'package:simpastil/core/sync/sync_write_scope.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;

import '../../helpers/care_recording_fixture.dart';

class _Dio extends Mock implements Dio {}

const _personId = '20000000-0000-4000-8000-000000000001';
const _pillId = '20000000-0000-4000-8000-000000000002';
const _scheduleId = '20000000-0000-4000-8000-000000000003';
const _serverOccurrenceId = '20000000-0000-4000-8000-000000000004';
const _serverEventId = '20000000-0000-4000-8000-000000000005';
const _recordedAt = '2026-09-30T09:06:00.000Z';

/// A phone that took a dose while the server was still in bridge mode: the
/// take reached the server through the bridge, and the device now pulls the
/// ledger after the server was activated.
Future<
  ({
    CareRecordingFixture care,
    SyncWriteScope scope,
    PendingOperation operation,
    OccurrenceEvent localEvent,
    Map<String, dynamic> occurrence,
  })
>
_bridgeRecordedDose() async {
  final care = await CareRecordingFixture.create(
    connected: true,
    legacyStock: 4,
  );
  final db = care.db;
  addTearDown(db.close);
  await (db.update(db.profiles)..where((r) => r.id.equals(care.person.id)))
      .write(const ProfilesCompanion(serverId: Value(_personId)));
  await (db.update(db.pills)..where((r) => r.id.equals(care.pill.id))).write(
    const PillsCompanion(serverId: Value(_pillId)),
  );
  await (db.update(db.schedules)
        ..where((r) => r.id.equals(care.occurrence.scheduleId!)))
      .write(const SchedulesCompanion(serverId: Value(_scheduleId)));
  final plan = OccurrenceMaterializer()
      .materialize(
        source: ScheduledOccurrenceSource(
          userId: care.workspace.context.ownerUserId,
          id: _scheduleId,
          scheduleRevision: '1',
          pillId: care.pill.id,
          pillName: care.pill.name,
          dosage: care.pill.dosage,
          frequency: 'daily',
          frequencyDays: null,
          hour: 9,
          minute: 0,
          timeZone: 'UTC',
          profileId: care.person.id,
          profileName: care.person.name,
        ),
        fromLocalDate: '2026-09-30',
        throughLocalDate: '2026-09-30',
      )
      .single;
  await (db.update(
    db.medicationOccurrences,
  )..where((r) => r.id.equals(care.occurrence.id))).write(
    MedicationOccurrencesCompanion(
      occurrenceKey: Value(plan.occurrenceKey),
      plannedLocalTime: Value(plan.plannedLocalTime),
      scheduleSnapshotJson: Value(jsonEncode(plan.scheduleSnapshot.toJson())),
    ),
  );
  final context = care.workspace.context;
  final writer = CareRecordingService(
    database: db,
    access: care.workspace.access,
    context: context,
    clock: () => DateTime.utc(2026, 9, 30, 9, 5),
  );
  final receipt = await writer.commit(
    await writer.prepareTakenNow(
      personId: care.person.id,
      occurrenceId: care.occurrence.id,
      expectedStateVersion: 0,
      amount: const MedicationAmount.unknown(),
    ),
  );
  final scope = SyncWriteScope(
    access: care.workspace.access,
    capability: NetworkCapability(
      ownerId: context.ownerUserId,
      endpoint: context.endpoint!,
      epoch: context.networkEpoch!,
      generation: context.sessionGeneration!,
    ),
  );
  // The bridge accepted the command: the operation is committed.
  final operation = (await db.pendingOperationsDao.getByMutationId(
    context.ownerUserId,
    receipt.event.commandId,
  ))!;
  final dio = _Dio();
  when(
    () => dio.post<dynamic>(
      '/medication/bridge/commands',
      data: any(named: 'data'),
    ),
  ).thenAnswer((i) async {
    final request = Map<String, dynamic>.from(i.namedArguments[#data] as Map);
    return Response<dynamic>(
      requestOptions: RequestOptions(path: '/fictional'),
      data: {'commandId': request['commandId']},
    );
  });
  expect(
    (await BridgeMedicationSyncAdapter(
      db: db,
      dio: dio,
      writeScope: scope,
    ).send(operation)).status,
    MedicationMutationStatus.acknowledged,
  );
  expect(
    (await db.pendingOperationsDao.getById(operation.id))!.state,
    'committed',
  );
  return (
    care: care,
    scope: scope,
    operation: operation,
    localEvent: (await db.medicationLedgerDao.getEventsForOccurrence(
      care.occurrence.id,
    )).single,
    occurrence: {
      'kind': 'medicationOccurrence',
      'id': _serverOccurrenceId,
      'pillId': _pillId,
      'scheduleId': _scheduleId,
      'occurrenceKey': plan.occurrenceKey,
      'source': 'scheduled',
      'scheduleRevision': '1',
      'plannedLocalDate': plan.plannedLocalDate,
      'plannedLocalTime': plan.plannedLocalTime,
      'timeZone': plan.timeZone,
      'plannedAt': plan.plannedAt.toIso8601String(),
      'expected': true,
      'snapshotVersion': 1,
      'scheduleSnapshot': plan.scheduleSnapshot.toJson(),
      'provenance': 'exact',
      'stateVersion': '0',
      'supersededAt': null,
      'supersededByOccurrenceId': null,
    },
  );
}

Map<String, dynamic> _change(String type, String id, Map<String, dynamic> p) =>
    {
      'schemaVersion': 2,
      'component': 'medication',
      'entityType': type,
      'entityId': id,
      'operation': 'upsert',
      'payload': p,
    };

Map<String, dynamic> _backfilledEvent(String commandId) => {
  'kind': 'occurrenceEvent',
  'id': _serverEventId,
  'occurrenceId': _serverOccurrenceId,
  'commandId': commandId,
  'action': 'take',
  'fromState': 'pending',
  'toState': 'taken',
  'reversesEventId': null,
  'rebasesCommandId': null,
  'actualAt': '2026-09-30T09:05:00.000Z',
  'actualTimeKnown': true,
  'note': null,
  'origin': 'legacy_handoff',
  'baseVersion': '0',
  'resultVersion': '1',
  'serverSequence': '9',
  'recordedAt': _recordedAt,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    tz_data.initializeTimeZones();
    registerFallbackValue(<String, Object?>{});
  });

  Future<void> pull(
    ({
      CareRecordingFixture care,
      SyncWriteScope scope,
      PendingOperation operation,
      OccurrenceEvent localEvent,
      Map<String, dynamic> occurrence,
    })
    x,
    List<Map<String, dynamic>> changes,
  ) => x.care.db.transaction(
    () => ComponentSyncMerger(x.care.db, writeScope: x.scope).merge(
      x.care.workspace.context.ownerUserId,
      SyncComponent.medication,
      changes,
      contractVersion: 2,
    ),
  );

  CareDayRepository dayOf(CareRecordingFixture f) => CareDayRepository(
    database: f.db,
    access: f.workspace.access,
    context: f.workspace.context,
    clock: () => DateTime.utc(2026, 9, 30, 12),
  );

  test('a ledger without the event leaves the local take waiting to share '
      '(the behaviour before the activation backfill)', () async {
    final x = await _bridgeRecordedDose();
    await pull(x, [
      _change('medication_occurrence', _serverOccurrenceId, x.occurrence),
    ]);
    final entry = (await dayOf(
      x.care,
    ).load(localDate: '2026-09-30', personId: x.care.person.id)).entries.single;
    expect(entry.head, isNull);
    expect(
      (await x.care.db.medicationLedgerDao.getEventsForOccurrence(
        x.care.occurrence.id,
      )).single.serverId,
      isNull,
    );
  });

  test('the activation backfill gives the phone event its server identity, '
      'a shared label and no Undo', () async {
    final x = await _bridgeRecordedDose();
    final commandId = x.localEvent.commandId;
    expect(x.localEvent.serverId, isNull);
    await pull(x, [
      _change('medication_occurrence', _serverOccurrenceId, {
        ...x.occurrence,
        'stateVersion': '1',
      }),
      _change('occurrence_event', _serverEventId, _backfilledEvent(commandId)),
    ]);
    final db = x.care.db;
    final events = await db.medicationLedgerDao.getEventsForOccurrence(
      x.care.occurrence.id,
    );
    expect(events, hasLength(1));
    expect(events.single.id, x.localEvent.id);
    expect(events.single.serverId, _serverEventId);
    expect(events.single.origin, 'legacy_handoff');
    expect(events.single.resultVersion, 1);
    final occurrence = (await db.medicationLedgerDao.getOccurrenceById(
      x.care.occurrence.id,
    ))!;
    expect(occurrence.state, 'taken');
    expect(occurrence.stateVersion, 1);

    final entry = (await dayOf(
      x.care,
    ).load(localDate: '2026-09-30', personId: x.care.person.id)).entries.single;
    expect(entry.head!.id, x.localEvent.id);
    expect(entry.sharing, CareSharingOutcome.acknowledged);

    final detail = await OccurrenceDetailRepository(
      database: db,
      access: x.care.workspace.access,
      context: x.care.workspace.context,
    ).load(x.care.occurrence.id);
    expect(detail.sharing, CareSharingOutcome.acknowledged);
    expect(detail.canUndo, isFalse);

    final writer = CareRecordingService(
      database: db,
      access: x.care.workspace.access,
      context: x.care.workspace.context,
    );
    await expectLater(
      writer.prepareUndoForEntry(
        personId: x.care.person.id,
        occurrenceId: x.care.occurrence.id,
        expectedStateVersion: 1,
        headEventId: events.single.id,
      ),
      throwsA(isA<MedicationCommandBlocked>()),
    );
  });
}
