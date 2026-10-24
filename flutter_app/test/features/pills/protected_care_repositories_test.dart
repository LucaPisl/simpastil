import 'package:simpastil/core/sync/ledger_mode_hint.dart';
import 'package:simpastil/core/sync/adapters/legacy_medication_sync_adapter.dart';
import 'package:simpastil/core/sync/adapters/medication_sync_adapter.dart';
import 'package:simpastil/core/sync/capabilities_client.dart';
import 'package:simpastil/core/inventory/exact_stock.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:async';

import 'package:dio/dio.dart';
import 'dart:ui';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:simpastil/core/api/api_client.dart';
import 'package:simpastil/core/projections/projection_command_id.dart';
import 'package:simpastil/core/projections/projection_identity.dart';
import 'package:simpastil/core/medication/occurrence_materializer.dart';
import 'package:simpastil/core/projections/projection_reconciler.dart';
import 'package:simpastil/core/session/session_generation_repository.dart';
import 'package:simpastil/core/workspace/workspace_provider.dart';
import 'package:simpastil/features/pills/pill_provider.dart';
import 'package:simpastil/features/pills/schedule_provider.dart';
import 'package:simpastil/features/profiles/profile_provider.dart';
import 'package:drift/drift.dart' show Value, Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/errors/app_error.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import 'package:simpastil/features/pills/pill_repository.dart';
import 'package:simpastil/features/pills/schedule_repository.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import '../../helpers/held_provider_read.dart';

const _owner = '00000000-0000-4000-8000-000000000001';
const _foreign = '00000000-0000-4000-8000-000000000002';
const _person = '00000000-0000-4000-8000-000000000003';
const _medication = '00000000-0000-4000-8000-000000000004';
const _routine = '00000000-0000-4000-8000-000000000005';

class _Client extends Mock implements ApiClient {
  _Client(this.dio);
  @override
  final Dio dio;
}

class _ReconcileProbe extends Mock implements ProjectionReconciler {
  final identities = <ProjectionIdentity?>[];
  @override
  Future<ProjectionReconciliationReport?> reconcile({
    SessionIdentity? identity,
    Locale? locale,
    ProjectionIdentity? projectionIdentity,
  }) async {
    identities.add(projectionIdentity);
    return null;
  }
}

class _BeforeRecord extends PendingOperationRepository {
  _BeforeRecord(super.db, {required super.access, required super.context});
  Future<void> Function()? beforeRecord;

  @override
  Future<List<RecordedPendingOperation>> recordAtomically({
    required List<PendingOperationDraft> operations,
    required Future<void> Function() applyProjection,
  }) async {
    await beforeRecord?.call();
    return super.recordAtomically(
      operations: operations,
      applyProjection: applyProjection,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tz_data.initializeTimeZones);
  late AppDatabase db;
  late WorkspaceAccessRepository access;
  late _BeforeRecord pending;
  late PillRepositoryImpl pills;
  late ScheduleRepositoryImpl schedules;
  late Dio dio;

  setUp(() async {
    db = AppDatabase.forTesting();
    addTearDown(db.close);
    final now = DateTime.now().toUtc();
    for (final owner in [_owner, _foreign]) {
      await db.usersDao.upsert(
        UsersCompanion.insert(
          id: owner,
          email: '$owner@fictional.invalid',
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
    await db.profilesDao.upsert(
      ProfilesCompanion.insert(
        id: _person,
        userId: _owner,
        name: 'Fictional person',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await db.pillsDao.upsert(
      PillsCompanion.insert(
        id: _medication,
        profileId: _person,
        name: 'Fictional medication',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await db.schedulesDao.upsert(
      SchedulesCompanion.insert(
        id: _routine,
        pillId: _medication,
        hour: 8,
        minute: 0,
        frequency: 'daily',
        createdAt: now,
        updatedAt: now,
      ),
    );
    access = WorkspaceAccessRepository(db);
    const endpoint = 'https://fictional-repository.test/care';
    final epoch = await access.configureEndpoint(endpoint);
    await db
        .into(db.credentialSlots)
        .insert(
          CredentialSlotsCompanion.insert(
            id: 'fictional-slot',
            ownerId: _owner,
            endpoint: endpoint,
            state: 'staged',
            createdAt: now,
          ),
        );
    final active = await access.authenticate(
      ownerId: _owner,
      endpoint: endpoint,
      expectedNetworkEpoch: epoch,
      sessionGeneration: 1,
      credentialId: 'fictional-slot',
    );
    final context = await access.confirmOriginalServer(
      workspaceId: active.workspace.id,
      reviewedOriginalEndpoint: endpoint,
      expectedNetworkEpoch: active.network.epoch,
    );
    pending = _BeforeRecord(db, access: access, context: context);
    pills = PillRepositoryImpl(
      db: db,
      dao: db.pillsDao,
      profilesDao: db.profilesDao,
      schedulesDao: db.schedulesDao,
      pendingOperations: pending,
      reconcileProjections: () async {},
    );
    dio = Dio();
    addTearDown(() => dio.close(force: true));
    schedules = ScheduleRepositoryImpl(
      schedulesDao: db.schedulesDao,
      pillsDao: db.pillsDao,
      profilesDao: db.profilesDao,
      ledgerDao: db.medicationLedgerDao,
      migrationIssuesDao: db.migrationIssuesDao,
      pendingOperations: pending,
      dio: dio,
      reconcileProjections: () async {},
    );
  });

  for (final kind in ['medication', 'routine', 'person']) {
    test(
      '$kind repository callback retains its originating full grant',
      () async {
        final context = pending.context!;
        final projections = _ReconcileProbe();
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(db),
            workspaceAccessRepositoryProvider.overrideWithValue(access),
            workspaceContextProvider.overrideWith(
              (ref) => Stream.value(context),
            ),
            pendingOperationRepositoryProvider.overrideWithValue(pending),
            projectionReconcilerProvider.overrideWithValue(projections),
            apiClientProvider.overrideWithValue(_Client(dio)),
          ],
        );
        addTearDown(container.dispose);
        await container.readHeld(workspaceContextProvider);
        final local = await access.workspaces.ensureLocal();
        final localContext = (await access.contextForOwner(local.ownerUserId))!;
        pending.beforeRecord = () => access.viewWorkspace(localContext);
        switch (kind) {
          case 'medication':
            await container.read(pillRepositoryProvider).delete(_medication);
          case 'routine':
            await container.read(scheduleRepositoryProvider).delete(_routine);
          case 'person':
            await container.read(profileRepositoryProvider).delete(_person);
        }
        expect(
          (await access.currentContext()).workspaceId,
          localContext.workspaceId,
        );
        expect(projections.identities, [
          ProjectionIdentity.fromContext(context),
        ]);
      },
    );
  }

  for (final mapped in [false, true]) {
    test(
      'routine projections hash ${mapped ? 'canonical' : 'local'} identity and retain local foreign key',
      () async {
        const canonicalRoutine = '00000000-0000-4000-8000-000000000015';
        if (mapped) {
          await db.customUpdate(
            'UPDATE schedules SET server_id=? WHERE id=?',
            variables: const [
              Variable<String>(canonicalRoutine),
              Variable<String>(_routine),
            ],
            updates: {db.schedules},
          );
        }
        await schedules.update(
          _routine,
          hour: 9,
          minute: 15,
          frequency: 'daily',
          isActive: true,
        );
        final projected = await db.medicationLedgerDao
            .getOccurrencesForSchedule(_routine);
        expect(projected, isNotEmpty);
        final pill = (await db.pillsDao.getById(_medication))!;
        for (final row in projected) {
          final expected = OccurrenceMaterializer()
              .materialize(
                source: ScheduledOccurrenceSource(
                  userId: _owner,
                  id: mapped ? canonicalRoutine : _routine,
                  scheduleRevision: '2',
                  pillId: _medication,
                  pillName: pill.name,
                  dosage: pill.dosage,
                  frequency: 'daily',
                  frequencyDays: null,
                  hour: 9,
                  minute: 15,
                  timeZone: row.timeZone,
                  profileId: _person,
                  profileName: 'Fictional person',
                ),
                fromLocalDate: row.plannedLocalDate,
                throughLocalDate: row.plannedLocalDate,
              )
              .single;
          expect(row.scheduleId, _routine);
          expect(row.occurrenceKey, expected.occurrenceKey);
        }
      },
    );
  }

  for (final schedule in [false, true]) {
    test(
      '${schedule ? 'routine' : 'medication'} cannot save under a person deleted during publication',
      () async {
        pending.beforeRecord = () => db.profilesDao.softDelete(_person);
        await expectLater(
          schedule
              ? schedules.create(
                  pillId: _medication,
                  hour: 9,
                  minute: 0,
                  frequency: 'daily',
                )
              : pills.create(profileId: _person, name: 'New medication'),
          throwsA(isA<WorkspaceAccessFailure>()),
        );
        expect(await db.pendingOperationsDao.getForUser(_owner), isEmpty);
        expect(await db.pillsDao.getByProfileId(_person), hasLength(1));
        expect(await db.schedulesDao.getByPillId(_medication), hasLength(1));
      },
    );
    test(
      '${schedule ? 'routine' : 'medication'} stale grant cannot report an unguarded missing row',
      () async {
        await access.revokeNetwork();
        await expectLater(
          schedule ? schedules.delete('missing') : pills.delete('missing'),
          throwsA(isA<WorkspaceAccessFailure>()),
        );
      },
    );
    test(
      '${schedule ? 'routine' : 'medication'} revalidates actual parents inside publication',
      () async {
        pending.beforeRecord = () async {
          await db.customUpdate(
            'UPDATE profiles SET user_id=? WHERE id=?',
            variables: const [
              Variable<String>(_foreign),
              Variable<String>(_person),
            ],
            updates: {db.profiles},
          );
        };
        await expectLater(
          schedule
              ? schedules.update(
                  _routine,
                  hour: 9,
                  minute: 0,
                  frequency: 'daily',
                  isActive: true,
                )
              : pills.update(_medication, name: 'Changed medication'),
          throwsA(isA<WorkspaceAccessFailure>()),
        );
        expect(
          (await db.pillsDao.getById(_medication))?.name,
          'Fictional medication',
        );
        expect((await db.schedulesDao.getById(_routine))?.hour, 8);
        expect(await db.pendingOperationsDao.getForUser(_owner), isEmpty);
      },
    );
  }
  for (final changed in ['person', 'medication name', 'person name']) {
    test('routine publication refuses a changed same-owner $changed', () async {
      final now = DateTime.now().toUtc();
      const otherPerson = '00000000-0000-4000-8000-000000000006';
      await db.profilesDao.upsert(
        ProfilesCompanion.insert(
          id: otherPerson,
          userId: _owner,
          name: 'Other fictional person',
          createdAt: now,
          updatedAt: now,
        ),
      );
      pending.beforeRecord = () async {
        if (changed == 'person') {
          await db.customUpdate(
            'UPDATE pills SET profile_id=? WHERE id=?',
            variables: const [
              Variable<String>(otherPerson),
              Variable<String>(_medication),
            ],
            updates: {db.pills},
          );
        } else if (changed == 'medication name') {
          await db.customUpdate(
            'UPDATE pills SET name=? WHERE id=?',
            variables: const [
              Variable<String>('New fictional name'),
              Variable<String>(_medication),
            ],
            updates: {db.pills},
          );
        } else {
          await db.customUpdate(
            'UPDATE profiles SET name=? WHERE id=?',
            variables: const [
              Variable<String>('New fictional person name'),
              Variable<String>(_person),
            ],
            updates: {db.profiles},
          );
        }
      };
      await expectLater(
        schedules.update(
          _routine,
          hour: 9,
          minute: 0,
          frequency: 'daily',
          isActive: true,
        ),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
      expect((await db.schedulesDao.getById(_routine))?.hour, 8);
      expect(await db.pendingOperationsDao.getForUser(_owner), isEmpty);
      expect(await db.select(db.medicationOccurrences).get(), isEmpty);
    });
  }
  test('routine creation refuses an already deleted medication', () async {
    await db.pillsDao.softDelete(_medication);
    await expectLater(
      schedules.create(
        pillId: _medication,
        hour: 9,
        minute: 0,
        frequency: 'daily',
      ),
      throwsA(isA<WorkspaceAccessFailure>()),
    );
    expect(await db.schedulesDao.getByPillId(_medication), hasLength(1));
    expect(await db.pendingOperationsDao.getForUser(_owner), isEmpty);
  });

  test(
    'repeating the same stock edit offline records distinct inventory intents',
    () async {
      Future<void> save(int stock) async {
        final result = await pills.update(
          _medication,
          name: 'Fictional medication',
          currentStock: stock,
        );
        expect(result, isA<Ok<Pill>>());
      }

      await save(10); // start
      await save(8); // correct
      await save(10); // correct, back to the start value
      await save(8); // correct, same (revision, action, target) as before
      final ops = await db.pendingOperationsDao.getForUser(_owner);
      final inventory = ops
          .where((op) => op.operationType.startsWith('inventory.'))
          .toList();
      expect(inventory, hasLength(4));
      expect(inventory.map((op) => op.mutationId).toSet(), hasLength(4));
      expect(
        ops.where((op) => op.operationType == 'pill.update'),
        hasLength(4),
      );
      expect(
        await db.medicationLedgerDao.getInventoryEventsForPill(_medication),
        hasLength(4),
      );
    },
  );

  group('exact stock against the server', () {
    Future<Map<String, Object?>> startCommand() async {
      final ops = await db.pendingOperationsDao.getForUser(_owner);
      final op = ops.lastWhere((o) => o.operationType == 'inventory.start');
      return Map<String, Object?>.from(
        (jsonDecode(op.payloadJson) as Map)['inventoryCommand'] as Map,
      );
    }

    test('a server with exact stock gets the quantity and its unit', () async {
      SharedPreferences.setMockInitialValues({
        LedgerModeHint.fractionalStockKey: true,
      });
      final result = await pills.update(
        _medication,
        name: 'Fictional medication',
        stockQuantity: ExactStock.tryParseWire('7.5'),
        stockUnit: 'tablet',
      );
      expect(result, isA<Ok<Pill>>());
      final command = await startCommand();
      expect(command['initialQuantity'], '7.5');
      expect(command['stockUnit'], 'tablet');
      expect(command.containsKey('initialStock'), isFalse);
    });

    test('an older server gets the plain whole count it always did', () async {
      SharedPreferences.setMockInitialValues({});
      final result = await pills.update(
        _medication,
        name: 'Fictional medication',
        stockQuantity: ExactStock.fromInt(8),
        stockUnit: 'tablet',
      );
      expect(result, isA<Ok<Pill>>());
      final command = await startCommand();
      expect(command['initialStock'], 8);
      expect(command.containsKey('initialQuantity'), isFalse);
      expect(command.containsKey('stockUnit'), isFalse);
      final pill = (await db.pillsDao.getById(_medication))!;
      expect(pill.currentStock, 8);
      expect(pill.stockUnit, isNull);
    });

    test('an older server refuses a part count', () async {
      SharedPreferences.setMockInitialValues({});
      final result = await pills.update(
        _medication,
        name: 'Fictional medication',
        stockQuantity: ExactStock.tryParseWire('7.5'),
        stockUnit: 'tablet',
      );
      expect(result, isA<Err<Pill>>());
      expect(
        (await db.pendingOperationsDao.getForUser(
          _owner,
        )).where((o) => o.operationType.startsWith('inventory.')),
        isEmpty,
      );
    });
  });

  group('a recount', () {
    Future<void> markForRecount() =>
        (db.update(db.pills)..where((p) => p.id.equals(_medication))).write(
          const PillsCompanion(stockNeedsRecount: Value(true)),
        );

    Future<int> countOps() async => (await db.pendingOperationsDao.getForUser(
      _owner,
    )).where((o) => o.operationType == 'inventory.correct').length;

    test(
      'saving the same count still sends a count and clears the mark',
      () async {
        await pills.update(
          _medication,
          name: 'Fictional medication',
          currentStock: 10,
        );
        final ledgerBefore =
            (await db.medicationLedgerDao.getInventoryEventsForPill(
              _medication,
            )).length;
        await markForRecount();
        final result = await pills.update(
          _medication,
          name: 'Fictional medication',
          currentStock: 10,
          stockCounted: true,
        );
        expect(result, isA<Ok<Pill>>());
        expect(await countOps(), 1);
        expect(
          (await db.pillsDao.getById(_medication))!.stockNeedsRecount,
          isFalse,
        );
        // Nothing changed, so there is nothing to append to the ledger.
        expect(
          await db.medicationLedgerDao.getInventoryEventsForPill(_medication),
          hasLength(ledgerBefore),
        );
      },
    );

    test(
      'saving the same count without a pending recount sends nothing',
      () async {
        await pills.update(
          _medication,
          name: 'Fictional medication',
          currentStock: 10,
        );
        await pills.update(
          _medication,
          name: 'Fictional medication',
          currentStock: 10,
        );
        expect(await countOps(), 0);
      },
    );

    test('saving other fields with the same count keeps the mark', () async {
      await pills.update(
        _medication,
        name: 'Fictional medication',
        currentStock: 10,
      );
      await markForRecount();
      final result = await pills.update(
        _medication,
        name: 'Fictional medication',
        dosage: '2 tablets',
        currentStock: 10,
      );
      expect(result, isA<Ok<Pill>>());
      expect(await countOps(), 0);
      expect(
        (await db.pillsDao.getById(_medication))!.stockNeedsRecount,
        isTrue,
      );
    });

    test('a changed count clears the mark too', () async {
      await pills.update(
        _medication,
        name: 'Fictional medication',
        currentStock: 10,
      );
      await markForRecount();
      await pills.update(
        _medication,
        name: 'Fictional medication',
        currentStock: 7,
      );
      expect(
        (await db.pillsDao.getById(_medication))!.stockNeedsRecount,
        isFalse,
      );
      expect(await countOps(), 1);
    });
  });

  test('an unexpected failure during update becomes an Err', () async {
    pending.beforeRecord = () async => throw StateError('boom');
    final result = await pills.update(_medication, name: 'Renamed');
    expect(result, isA<Err<Pill>>());
  });

  test(
    'a projection effect that never completes does not hold a save',
    () async {
      final hung = PillRepositoryImpl(
        db: db,
        dao: db.pillsDao,
        profilesDao: db.profilesDao,
        schedulesDao: db.schedulesDao,
        pendingOperations: pending,
        reconcileProjections: () => Completer<void>().future,
        effectsTimeout: const Duration(milliseconds: 50),
      );
      final result = await hung
          .update(_medication, name: 'Renamed')
          .timeout(const Duration(seconds: 5));
      expect(result, isA<Ok<Pill>>());
      expect((await db.pillsDao.getById(_medication))?.name, 'Renamed');
    },
  );
  group('pill shape', () {
    Future<Map<String, Object?>> lastPayload(String type) async {
      final operations = await db.pendingOperationsDao.getForUser(_owner);
      final operation = operations.lastWhere((o) => o.operationType == type);
      return (jsonDecode(operation.payloadJson) as Map)['data']
          as Map<String, Object?>;
    }

    test('a created pill stores and sends the picked shape', () async {
      final result = await pills.create(
        profileId: _person,
        name: 'Shaped',
        shape: 'diamond',
      );
      final created = (result as Ok<Pill>).value;
      expect(created.shape, 'diamond');
      expect((await lastPayload('pill.create'))['shape'], 'diamond');
    });

    test('a pill created without one sends no shape key', () async {
      await pills.create(profileId: _person, name: 'Plain');
      expect((await lastPayload('pill.create')).containsKey('shape'), isFalse);
    });

    test('an update changes the shape and sends it', () async {
      await pills.update(
        _medication,
        name: 'Fictional medication',
        shape: 'oval',
      );
      expect((await db.pillsDao.getById(_medication))?.shape, 'oval');
      expect((await lastPayload('pill.update'))['shape'], 'oval');
    });

    test('an update without a shape keeps the stored one', () async {
      await pills.update(
        _medication,
        name: 'Fictional medication',
        shape: 'oval',
      );
      await pills.update(_medication, name: 'Renamed');
      expect((await db.pillsDao.getById(_medication))?.shape, 'oval');
      expect((await lastPayload('pill.update')).containsKey('shape'), isFalse);
    });
  });
  group('a refill', () {
    Future<List<PendingOperation>> inventoryOps() async =>
        (await db.pendingOperationsDao.getForUser(
          _owner,
        )).where((o) => o.operationType.startsWith('inventory.')).toList();

    Map<String, Object?> commandOf(PendingOperation op) =>
        Map<String, Object?>.from(
          (jsonDecode(op.payloadJson) as Map)['inventoryCommand'] as Map,
        );

    Future<void> track(int stock) async {
      SharedPreferences.setMockInitialValues({
        LedgerModeHint.fractionalStockKey: true,
        LedgerModeHint.key: true,
      });
      final result = await pills.update(
        _medication,
        name: 'Fictional medication',
        currentStock: stock,
      );
      expect(result, isA<Ok<Pill>>());
    }

    test('a refill is refused, and stock stays, on a server known to lack '
        'the ledger', () async {
      await track(10);
      for (final hint in <Map<String, Object>>[
        {LedgerModeHint.key: false},
        {LedgerModeHint.legacyServerKey: ''},
      ]) {
        SharedPreferences.setMockInitialValues({
          LedgerModeHint.fractionalStockKey: true,
          ...hint,
        });
        final before = (await inventoryOps()).length;
        final result = await pills.refill(_medication, ExactStock.fromInt(5));
        expect(result, isA<Err<Pill>>());
        expect((await inventoryOps()).length, before);
        expect((await db.pillsDao.getById(_medication))!.currentStock, 10);
      }
    });

    test('a refill is queued while the server is still unknown', () async {
      await track(10);
      SharedPreferences.setMockInitialValues({});
      final result = await pills.refill(_medication, ExactStock.fromInt(5));
      expect(result, isA<Ok<Pill>>());
      expect((await inventoryOps()).last.operationType, 'inventory.refill');
      expect((await db.pillsDao.getById(_medication))!.currentStock, 15);
    });

    test('a refill queued while the server is unknown is refused once an '
        'older server answers, and the next one is refused at once', () async {
      await track(10);
      SharedPreferences.setMockInitialValues({});
      expect(
        await pills.refill(_medication, ExactStock.fromInt(5)),
        isA<Ok<Pill>>(),
      );
      final queued = (await inventoryOps()).last;
      expect(queued.state, 'queued');

      // The server turns out to be an older one.
      await LedgerModeHint.record(
        const CapabilitySnapshot.absent(),
        server: await LedgerModeHint.configuredServer(),
      );
      var requests = 0;
      final legacyDio = Dio();
      addTearDown(() => legacyDio.close(force: true));
      legacyDio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests++;
            handler.reject(DioException(requestOptions: request));
          },
        ),
      );
      final result = await LegacyMedicationSyncAdapter(
        db: db,
        dio: legacyDio,
      ).flush(queued);
      expect(result.status, MedicationMutationStatus.blocked);
      expect(result.safeErrorCode, refillNeedsLedgerCode);
      expect(requests, 0);

      final before = (await inventoryOps()).length;
      expect(
        await pills.refill(_medication, ExactStock.fromInt(5)),
        isA<Err<Pill>>(),
      );
      expect((await inventoryOps()).length, before);
      expect((await db.pillsDao.getById(_medication))!.currentStock, 15);
    });

    test('a whole amount is a refill command with amount', () async {
      await track(10);
      final result = await pills.refill(_medication, ExactStock.fromInt(5));
      expect(result, isA<Ok<Pill>>());
      final op = (await inventoryOps()).last;
      expect(op.operationType, 'inventory.refill');
      final command = commandOf(op);
      expect(command['action'], 'refill');
      expect(command['amount'], 5);
      expect(command.containsKey('refillQuantity'), isFalse);
      expect(command.containsKey('stockUnit'), isFalse);
      expect(command.containsKey('targetStock'), isFalse);
      expect(command['commandId'], op.mutationId);
    });

    test('the stock moves by the delta and history gets a refill', () async {
      await track(10);
      await pills.refill(_medication, ExactStock.fromInt(5));
      final pill = (await db.pillsDao.getById(_medication))!;
      expect(pill.currentStock, 15);
      final events = await db.medicationLedgerDao.getInventoryEventsForPill(
        _medication,
      );
      final refill = events.last;
      expect(refill.kind, 'refill');
      expect(refill.delta, '5');
      expect(refill.commandId, (await inventoryOps()).last.mutationId);
      // The earlier opening is untouched: history only grew.
      expect(events.first.kind, 'opening');
      expect(events, hasLength(2));
    });

    test('a part is a refill quantity on stock counted in a unit', () async {
      SharedPreferences.setMockInitialValues({
        LedgerModeHint.fractionalStockKey: true,
        LedgerModeHint.key: true,
      });
      await pills.update(
        _medication,
        name: 'Fictional medication',
        stockQuantity: ExactStock.tryParseWire('7.5'),
        stockUnit: 'tablet',
      );
      final result = await pills.refill(
        _medication,
        ExactStock.tryParseWire('2.5')!,
      );
      expect(result, isA<Ok<Pill>>());
      final command = commandOf((await inventoryOps()).last);
      expect(command['action'], 'refill');
      expect(command['refillQuantity'], '2.5');
      expect(command.containsKey('amount'), isFalse);
      expect(command.containsKey('stockUnit'), isFalse);
      final pill = (await db.pillsDao.getById(_medication))!;
      expect(pill.stockQuantity, '10');
      expect(pill.currentStock, 10);
      expect(pill.stockUnit, 'tablet');
      final events = await db.medicationLedgerDao.getInventoryEventsForPill(
        _medication,
      );
      expect(events.last.kind, 'refill');
      expect(events.last.delta, '2.5');
    });

    test('a whole amount on counted stock stays a whole amount', () async {
      SharedPreferences.setMockInitialValues({
        LedgerModeHint.fractionalStockKey: true,
        LedgerModeHint.key: true,
      });
      await pills.update(
        _medication,
        name: 'Fictional medication',
        stockQuantity: ExactStock.tryParseWire('7.5'),
        stockUnit: 'tablet',
      );
      await pills.refill(_medication, ExactStock.fromInt(3));
      final command = commandOf((await inventoryOps()).last);
      expect(command['amount'], 3);
      expect(command.containsKey('refillQuantity'), isFalse);
      expect((await db.pillsDao.getById(_medication))!.stockQuantity, '10.5');
    });

    test('a refill does not settle a pending recount', () async {
      await track(10);
      await (db.update(db.pills)..where((p) => p.id.equals(_medication))).write(
        const PillsCompanion(stockNeedsRecount: Value(true)),
      );
      await pills.refill(_medication, ExactStock.fromInt(2));
      expect(
        (await db.pillsDao.getById(_medication))!.stockNeedsRecount,
        isTrue,
      );
    });

    test(
      'the command id is per intent: stable id, new id per refill',
      () async {
        await track(10);
        final pill = (await db.pillsDao.getById(_medication))!;
        final ordinal = (await db.medicationLedgerDao.getInventoryEventsForPill(
          _medication,
        )).length;
        await pills.refill(_medication, ExactStock.fromInt(5));
        await pills.refill(_medication, ExactStock.fromInt(5));
        final ops = (await inventoryOps()).where(
          (o) => o.operationType == 'inventory.refill',
        );
        expect(ops, hasLength(2));
        expect(ops.map((o) => o.mutationId).toSet(), hasLength(2));
        expect(
          ops.first.mutationId,
          projectionCommandIdForKey(
            'inventory-command-v1:$_medication:${pill.revision}:refill:5:'
            '$ordinal',
          ),
        );
      },
    );

    test('a refill that rolled back replays under the same id', () async {
      await track(10);
      final base = (await db.pillsDao.getById(_medication))!;
      pending.beforeRecord = () async => throw StateError('rolled back');
      final failed = await pills.refill(_medication, ExactStock.fromInt(5));
      expect(failed, isA<Err<Pill>>());
      expect((await db.pillsDao.getById(_medication))!.currentStock, 10);
      pending.beforeRecord = null;
      await pills.refill(_medication, ExactStock.fromInt(5));
      expect(
        (await inventoryOps()).last.mutationId,
        projectionCommandIdForKey(
          'inventory-command-v1:$_medication:${base.revision}:refill:5:1',
        ),
      );
    });

    test(
      'untracked stock, zero and a part without a unit are refused',
      () async {
        expect(
          await pills.refill(_medication, ExactStock.fromInt(1)),
          isA<Err<Pill>>(),
        );
        await track(10);
        expect(
          await pills.refill(_medication, ExactStock.zero),
          isA<Err<Pill>>(),
        );
        expect(
          await pills.refill(_medication, ExactStock.tryParseWire('0.5')!),
          isA<Err<Pill>>(),
        );
        expect(
          (await inventoryOps()).where(
            (o) => o.operationType == 'inventory.refill',
          ),
          isEmpty,
        );
        expect((await db.pillsDao.getById(_medication))!.currentStock, 10);
      },
    );

    test('start and correct command ids are unchanged', () async {
      SharedPreferences.setMockInitialValues({});
      await pills.update(
        _medication,
        name: 'Fictional medication',
        currentStock: 10,
      );
      final startRevision = (await db.pillsDao.getById(_medication))!.revision;
      expect(
        (await inventoryOps()).last.mutationId,
        projectionCommandIdForKey(
          'inventory-command-v1:$_medication:$startRevision:start:10:0',
        ),
      );
      final pill = (await db.pillsDao.getById(_medication))!;
      await pills.update(
        _medication,
        name: 'Fictional medication',
        currentStock: 8,
      );
      final correct = (await inventoryOps()).last;
      expect(correct.operationType, 'inventory.correct');
      expect(
        correct.mutationId,
        projectionCommandIdForKey(
          'inventory-command-v1:$_medication:${pill.revision}:correct:8:1',
        ),
      );
      expect(commandOf(correct), {
        'commandId': correct.mutationId,
        'action': 'correct',
        'pillId': _medication,
        'targetStock': 8,
        'note': null,
      });
    });
  });
}
