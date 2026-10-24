import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/adapters/v2_stable_adapter.dart';
import 'package:simpastil/core/sync/ledger_mode_hint.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';
import 'package:simpastil/core/sync/sync_write_scope.dart';

import '../../helpers/protected_workspace_fixture.dart';

const _owner = '10000000-0000-4000-8000-000000000401';
const _profile = '10000000-0000-4000-8000-000000000402';
const _pill = '10000000-0000-4000-8000-000000000403';
final _at = DateTime.utc(2026, 10, 12, 8);

/// A pull leaves a pill holding unsent work alone, so a review made on another
/// device can only reach this one through the server's answer to the stale
/// update. That answer must carry the reviewed details with the record.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a server-wins conflict adopts the reviewed details too', () async {
    final w = await ProtectedWorkspaceFixture.create(ownerId: _owner);
    addTearDown(w.db.close);
    await w.db.profilesDao.upsert(
      ProfilesCompanion.insert(
        id: _profile,
        userId: _owner,
        name: 'Fictional person',
        createdAt: _at,
        updatedAt: _at,
        serverId: const Value(_profile),
        revision: const Value(2),
        syncStatus: const Value('synced'),
      ),
    );
    await w.db.pillsDao.upsert(
      PillsCompanion.insert(
        id: _pill,
        profileId: _profile,
        name: 'Fictional medication',
        dosage: const Value('10 mg'),
        createdAt: _at,
        updatedAt: _at,
        serverId: const Value(_pill),
        revision: const Value(2),
        syncStatus: const Value('pending'),
      ),
    );
    await w.db
        .into(w.db.medicationDetails)
        .insert(
          MedicationDetailsCompanion.insert(
            pillId: _pill,
            amountJson: '{"kind":"unknown"}',
          ),
        );
    final recorded =
        await PendingOperationRepository(
          w.db,
          access: w.access,
          context: w.context,
        ).record(
          operation: const PendingOperationDraft(
            userId: _owner,
            operationType: 'pill.update',
            entityType: 'pill',
            entityLocalId: _pill,
            parentEntityType: 'profile',
            parentEntityLocalId: _profile,
            payload: {
              'action': 'update',
              'data': {'name': 'Edited offline'},
            },
          ),
          applyProjection: () async {},
        );
    final operation = (await w.db.pendingOperationsDao.getById(
      recorded.operationId,
    ))!;
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) => handler.reject(
          DioException(
            requestOptions: request,
            type: DioExceptionType.badResponse,
            response: Response(
              requestOptions: request,
              statusCode: 409,
              data: {
                'error': {
                  'code': 'CONFLICT_STALE_UPDATE',
                  'message': 'Stale',
                  'retryable': false,
                  'correlationId': 'corr-1',
                  'details': {
                    'currentEntity': {
                      'entityType': 'pills',
                      'id': _pill,
                      'revision': '5',
                      'profileId': _profile,
                      'name': 'Server name',
                      'dosage': '10 mg',
                      'isPrn': false,
                      'form': 'tablet',
                      'legacyDosageReviewed': true,
                      'deletedAt': null,
                      'updatedAt': '2026-10-13T08:00:00.000Z',
                    },
                  },
                },
              },
            ),
          ),
        ),
      ),
    );
    final adapter = V2StableAdapter(
      db: w.db,
      dio: dio,
      writeScope: SyncWriteScope(
        access: w.access,
        capability: await w.access.currentNetworkCapability(),
      ),
    );

    final result = await adapter.send(operation);
    await result.applyReceipt!();

    final pill = (await w.db.pillsDao.getById(_pill))!;
    expect(pill.revision, 5);
    expect(pill.syncStatus, 'synced');
    final detail = await (w.db.select(
      w.db.medicationDetails,
    )..where((row) => row.pillId.equals(_pill))).getSingle();
    expect(detail.legacyDosageReviewed, isTrue);
    expect(detail.form, 'tablet');
  });

  test('a server-wins conflict adopts every field the pull merge adopts '
      '(shape, expiry, contacts and PRN limits)', () async {
    final w = await ProtectedWorkspaceFixture.create(ownerId: _owner);
    addTearDown(w.db.close);
    await w.db.profilesDao.upsert(
      ProfilesCompanion.insert(
        id: _profile,
        userId: _owner,
        name: 'Fictional person',
        createdAt: _at,
        updatedAt: _at,
        serverId: const Value(_profile),
        revision: const Value(2),
        syncStatus: const Value('synced'),
      ),
    );
    await w.db.pillsDao.upsert(
      PillsCompanion.insert(
        id: _pill,
        profileId: _profile,
        name: 'Fictional medication',
        createdAt: _at,
        updatedAt: _at,
        serverId: const Value(_pill),
        revision: const Value(2),
        syncStatus: const Value('pending'),
        isPrn: const Value(true),
        shape: const Value('round'),
        expiresOn: const Value('2027-01-31'),
        prescriberName: const Value('Dr Local'),
        prescriberPhone: const Value('+40 700 000 001'),
        pharmacyName: const Value('Local pharmacy'),
        pharmacyPhone: const Value('+40 700 000 002'),
        prnMaxPer24h: const Value(4),
        prnMinGapMinutes: const Value(240),
      ),
    );
    final recorded =
        await PendingOperationRepository(
          w.db,
          access: w.access,
          context: w.context,
        ).record(
          operation: const PendingOperationDraft(
            userId: _owner,
            operationType: 'pill.update',
            entityType: 'pill',
            entityLocalId: _pill,
            parentEntityType: 'profile',
            parentEntityLocalId: _profile,
            payload: {
              'action': 'update',
              'data': {'name': 'Edited offline'},
            },
          ),
          applyProjection: () async {},
        );
    final operation = (await w.db.pendingOperationsDao.getById(
      recorded.operationId,
    ))!;
    final adapter = V2StableAdapter(
      db: w.db,
      dio: _conflictDio({
        'entityType': 'pills',
        'id': _pill,
        'revision': '6',
        'profileId': _profile,
        'name': 'Server name',
        'dosage': null,
        'notes': 'Server notes',
        'isPrn': true,
        'shape': 'capsule',
        'expiresOn': '2028-03-15',
        'prescriberName': 'Dr Server',
        'pharmacyName': 'Server pharmacy',
        'prnMaxPer24h': 2,
        'prnMinGapMinutes': 480,
        'deletedAt': null,
        'updatedAt': '2026-10-13T08:00:00.000Z',
      }),
      writeScope: SyncWriteScope(
        access: w.access,
        capability: await w.access.currentNetworkCapability(),
      ),
      medicationDetailsExtra: true,
    );

    final result = await adapter.send(operation);
    await result.applyReceipt!();

    final pill = (await w.db.pillsDao.getById(_pill))!;
    expect(pill.syncStatus, 'synced');
    expect(pill.revision, 6);
    expect(pill.name, 'Server name');
    expect(pill.notes, 'Server notes');
    expect(pill.shape, 'capsule');
    expect(pill.expiresOn, '2028-03-15');
    expect(pill.prescriberName, 'Dr Server');
    // Absent on a server with the extras contract means cleared.
    expect(pill.prescriberPhone, isNull);
    expect(pill.pharmacyName, 'Server pharmacy');
    expect(pill.pharmacyPhone, isNull);
    expect(pill.prnMaxPer24h, 2);
    expect(pill.prnMinGapMinutes, 480);
  });

  test(
    'a server-wins conflict keeps what an older server cannot speak for: '
    'extras off, no shape, and a count a held stock edit still carries',
    () async {
      // The server's ledger is off, so the phone holds its stock edit.
      final w = await ProtectedWorkspaceFixture.create(
        ownerId: _owner,
        initialPreferences: {LedgerModeHint.key: false},
      );
      addTearDown(w.db.close);
      await w.db.profilesDao.upsert(
        ProfilesCompanion.insert(
          id: _profile,
          userId: _owner,
          name: 'Fictional person',
          createdAt: _at,
          updatedAt: _at,
          serverId: const Value(_profile),
          revision: const Value(2),
          syncStatus: const Value('synced'),
        ),
      );
      await w.db.pillsDao.upsert(
        PillsCompanion.insert(
          id: _pill,
          profileId: _profile,
          name: 'Fictional medication',
          createdAt: _at,
          updatedAt: _at,
          serverId: const Value(_pill),
          revision: const Value(2),
          syncStatus: const Value('pending'),
          isPrn: const Value(true),
          shape: const Value('round'),
          expiresOn: const Value('2027-01-31'),
          prescriberName: const Value('Dr Local'),
          prescriberPhone: const Value('+40 700 000 001'),
          pharmacyName: const Value('Local pharmacy'),
          pharmacyPhone: const Value('+40 700 000 002'),
          prnMaxPer24h: const Value(4),
          prnMinGapMinutes: const Value(240),
          currentStock: const Value(7),
          stockNeedsRecount: const Value(true),
        ),
      );
      // A stock count held on the phone for the server's ledger.
      await w.db.pendingOperationsDao.enqueue(
        PendingOperationsCompanion.insert(
          id: 'stock',
          userId: _owner,
          mutationId: 'm-stock',
          component: 'medication',
          operationType: 'inventory.correct',
          contractVersion: 2,
          payloadJson: jsonEncode({
            'entityType': 'pill',
            'entityLocalId': _pill,
            'inventoryCommand': {
              'commandId': 'c',
              'action': 'correct',
              'pillId': _pill,
              'targetStock': 7,
            },
          }),
          createdAt: _at,
        ),
      );
      final recorded =
          await PendingOperationRepository(
            w.db,
            access: w.access,
            context: w.context,
          ).record(
            operation: const PendingOperationDraft(
              userId: _owner,
              operationType: 'pill.update',
              entityType: 'pill',
              entityLocalId: _pill,
              parentEntityType: 'profile',
              parentEntityLocalId: _profile,
              payload: {
                'action': 'update',
                'data': {'name': 'Edited offline'},
              },
            ),
            applyProjection: () async {},
          );
      final operation = (await w.db.pendingOperationsDao.getById(
        recorded.operationId,
      ))!;
      final adapter = V2StableAdapter(
        db: w.db,
        // An older server: no shape, no extras, a stale count and no mark.
        dio: _conflictDio({
          'entityType': 'pills',
          'id': _pill,
          'revision': '6',
          'profileId': _profile,
          'name': 'Server name',
          'dosage': null,
          'notes': null,
          'isPrn': true,
          'currentStock': 30,
          'stockNeedsRecount': false,
          'deletedAt': null,
          'updatedAt': '2026-10-13T08:00:00.000Z',
        }),
        writeScope: SyncWriteScope(
          access: w.access,
          capability: await w.access.currentNetworkCapability(),
        ),
      );

      final result = await adapter.send(operation);
      await result.applyReceipt!();

      final pill = (await w.db.pillsDao.getById(_pill))!;
      expect(pill.revision, 6);
      expect(pill.name, 'Server name');
      // Shape is applied only when the server sends it.
      expect(pill.shape, 'round');
      // Extras off on the server: every local value stays.
      expect(pill.expiresOn, '2027-01-31');
      expect(pill.prescriberName, 'Dr Local');
      expect(pill.prescriberPhone, '+40 700 000 001');
      expect(pill.pharmacyName, 'Local pharmacy');
      expect(pill.pharmacyPhone, '+40 700 000 002');
      expect(pill.prnMaxPer24h, 4);
      expect(pill.prnMinGapMinutes, 240);
      // The held stock edit still carries the phone's count and mark.
      expect(pill.currentStock, 7);
      expect(pill.stockNeedsRecount, isTrue);
    },
  );
}

Dio _conflictDio(Map<String, Object?> entity) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) => handler.reject(
        DioException(
          requestOptions: request,
          type: DioExceptionType.badResponse,
          response: Response(
            requestOptions: request,
            statusCode: 409,
            data: {
              'error': {
                'code': 'CONFLICT_REVISION',
                'message': 'Stale',
                'retryable': false,
                'correlationId': 'corr-2',
                'details': {'currentEntity': entity},
              },
            },
          ),
        ),
      ),
    ),
  );
  return dio;
}
