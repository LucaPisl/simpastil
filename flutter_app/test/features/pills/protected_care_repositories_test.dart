import 'dart:async';

import 'package:dio/dio.dart';
import 'dart:ui';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:simpastil/core/api/api_client.dart';
import 'package:simpastil/core/projections/projection_identity.dart';
import 'package:simpastil/core/medication/occurrence_materializer.dart';
import 'package:simpastil/core/projections/projection_reconciler.dart';
import 'package:simpastil/core/session/session_generation_repository.dart';
import 'package:simpastil/core/workspace/workspace_provider.dart';
import 'package:simpastil/features/pills/pill_provider.dart';
import 'package:simpastil/features/pills/schedule_provider.dart';
import 'package:simpastil/features/profiles/profile_provider.dart';
import 'package:drift/drift.dart' show Variable;
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
}
