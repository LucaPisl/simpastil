import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/sync/account_settlement_merger.dart';
import 'package:simpastil/core/sync/adapters/stable_record_adapter.dart';
import 'package:simpastil/core/sync/adapters/v2_stable_adapter.dart';
import 'package:simpastil/core/sync/capabilities_client.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';
import 'package:simpastil/core/sync/stable_record_merger.dart';
import 'package:simpastil/core/sync/sync_write_scope.dart';

import '../../helpers/protected_workspace_fixture.dart';

const _ownerId = '10000000-0000-4000-8000-000000000601';
const _profileId = '10000000-0000-4000-8000-000000000602';
const _pillId = '10000000-0000-4000-8000-000000000603';
const _mutationId = '10000000-0000-4000-8000-000000000604';
final _at = DateTime.utc(2026, 10, 17, 8);

Map<String, Object?> _capabilities({Object? medicationDetails = 1}) => {
  'apiNamespace': 'v1',
  'medicationLedgerActive': true,
  'minimumClientBuild': 1,
  'serverRelease': 'migration-0025',
  'contracts': {
    'componentSync': 2,
    'legacySplitReconciliation': 1,
    'medicationBridgeCommands': 1,
    'medicationBridgeSync': 1,
    'medicationCommands': 3,
    'medicationDetails': ?medicationDetails,
  },
};

Future<CapabilitySnapshot> _refresh(Map<String, Object?> body) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) => handler.resolve(
        Response<Map<String, dynamic>>(
          data: Map<String, dynamic>.from(body),
          statusCode: 200,
          requestOptions: options,
        ),
      ),
    ),
  );
  return CapabilitiesClient(dio).refresh();
}

/// A pill change row as the component sync hands it back, with [details]
/// merged in so a test can also build one that mentions no details at all.
Map<String, dynamic> _pillChange({
  String revision = '2',
  Map<String, Object?> details = const {},
}) => {
  'id': _pillId,
  'profileId': _profileId,
  'revision': revision,
  'name': 'Fakeolol',
  'dosage': '10 mg',
  'notes': null,
  'color': null,
  'currentStock': null,
  'lowStockThreshold': null,
  'isPrn': false,
  'deletedAt': null,
  'createdAt': '2026-10-17T08:00:00.000Z',
  'updatedAt': '2026-10-17T09:00:00.000Z',
  ...details,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('capabilities', () {
    test('a server that keeps the details says so', () async {
      final snapshot = await _refresh(_capabilities());
      expect(snapshot.availability, CapabilityAvailability.present);
      expect(snapshot.capabilities!.medicationDetails, isTrue);
    });

    test(
      'a server without the contract is usable, not an app update',
      () async {
        final snapshot = await _refresh(_capabilities(medicationDetails: null));
        expect(snapshot.availability, CapabilityAvailability.present);
        expect(snapshot.capabilities!.medicationDetails, isFalse);
        expect(snapshot.clientUpdateRequired, isFalse);
        expect(snapshot.blockedStableCode, isNull);
      },
    );

    test('a newer detail contract asks for an app update', () async {
      final snapshot = await _refresh(_capabilities(medicationDetails: 2));
      expect(snapshot.clientUpdateRequired, isTrue);
    });
  });

  group('pull', () {
    late AppDatabase db;
    late StableRecordMerger merger;

    setUp(() async {
      db = AppDatabase.forTesting();
      merger = StableRecordMerger(db, reviews: AccountSettlementMerger(db));
      await db.usersDao.upsert(
        UsersCompanion.insert(
          id: _ownerId,
          email: 'fictional@example.com',
          createdAt: _at,
          updatedAt: _at,
        ),
      );
      await db.profilesDao.upsert(
        ProfilesCompanion.insert(
          id: _profileId,
          userId: _ownerId,
          name: 'Fictional person',
          createdAt: _at,
          updatedAt: _at,
          serverId: const Value(_profileId),
          syncStatus: const Value('synced'),
        ),
      );
      await db.pillsDao.upsert(
        PillsCompanion.insert(
          id: _pillId,
          profileId: _profileId,
          name: 'Fakeolol',
          createdAt: _at,
          updatedAt: _at,
          serverId: const Value(_pillId),
          revision: const Value(1),
          syncStatus: const Value('synced'),
        ),
      );
      await db
          .into(db.medicationDetails)
          .insert(
            MedicationDetailsCompanion.insert(
              pillId: _pillId,
              packageStrength: const Value('20 mg'),
              form: const Value('tablet'),
              amountJson: jsonEncode(
                MedicationAmount.known('2', 'tablet').toJson(),
              ),
              legacyDosageReviewed: const Value(true),
            ),
          );
    });
    tearDown(() async => db.close());

    Future<MedicationDetail?> detail() => (db.select(
      db.medicationDetails,
    )..where((row) => row.pillId.equals(_pillId))).getSingleOrNull();

    test(
      'a change that mentions no details leaves the local review alone',
      () async {
        await merger.mergePill(_pillChange(), {_profileId: _profileId}, {});
        final row = (await detail())!;
        expect(row.packageStrength, '20 mg');
        expect(row.form, 'tablet');
        expect(row.legacyDosageReviewed, isTrue);
        expect(
          MedicationAmount.fromJson(
            Map<String, Object?>.from(jsonDecode(row.amountJson) as Map),
          ).quantityText,
          '2',
        );
      },
    );

    test('the details a change does carry are adopted', () async {
      await merger.mergePill(
        _pillChange(
          details: {
            'amountPerUse': {
              'version': 1,
              'state': 'known',
              'quantity': '1/2',
              'unit': 'tablet',
            },
            'packageStrength': '40 mg',
            'form': 'capsule',
            'legacyDosageReviewed': true,
          },
        ),
        {_profileId: _profileId},
        {},
      );
      final row = (await detail())!;
      expect(row.packageStrength, '40 mg');
      expect(row.form, 'capsule');
      final amount = MedicationAmount.fromJson(
        Map<String, Object?>.from(jsonDecode(row.amountJson) as Map),
      );
      expect(amount.quantityText, '1/2');
      expect(amount.unit, 'tablet');
    });

    test(
      'an empty detail set from an upgraded server clears the review',
      () async {
        await merger.mergePill(
          _pillChange(
            details: {
              'amountPerUse': null,
              'packageStrength': null,
              'form': null,
              'legacyDosageReviewed': false,
            },
          ),
          {_profileId: _profileId},
          {},
        );
        final row = (await detail())!;
        expect(row.packageStrength, isNull);
        expect(row.legacyDosageReviewed, isFalse);
      },
    );

    test('an amount this build cannot read is stored as unset', () async {
      await merger.mergePill(
        _pillChange(
          details: {
            'amountPerUse': {'version': 99, 'state': 'known'},
            'packageStrength': '40 mg',
          },
        ),
        {_profileId: _profileId},
        {},
      );
      final row = (await detail())!;
      expect(row.packageStrength, '40 mg');
      expect(
        MedicationAmount.fromJson(
          Map<String, Object?>.from(jsonDecode(row.amountJson) as Map),
        ).isUnknown,
        isTrue,
      );
    });

    test('a medicine with an unsent review of its own is untouched', () async {
      await (db.update(db.pills)..where((row) => row.id.equals(_pillId))).write(
        const PillsCompanion(syncStatus: Value('pending')),
      );
      await merger.mergePill(
        _pillChange(
          details: {
            'amountPerUse': null,
            'packageStrength': null,
            'form': null,
            'legacyDosageReviewed': false,
          },
        ),
        {_profileId: _profileId},
        {},
      );
      expect((await detail())!.packageStrength, '20 mg');
    });
  });

  group('request', () {
    Future<(PendingOperation, ProtectedWorkspaceFixture)> queued() async {
      final workspace = await ProtectedWorkspaceFixture.create(
        ownerId: _ownerId,
      );
      await workspace.db.profilesDao.upsert(
        ProfilesCompanion.insert(
          id: _profileId,
          userId: _ownerId,
          name: 'Fictional person',
          createdAt: _at,
          updatedAt: _at,
          serverId: const Value(_profileId),
          syncStatus: const Value('synced'),
        ),
      );
      await workspace.db.pillsDao.upsert(
        PillsCompanion.insert(
          id: _pillId,
          profileId: _profileId,
          name: 'Fakeolol',
          dosage: const Value('10 mg'),
          createdAt: _at,
          updatedAt: _at,
          serverId: const Value(_pillId),
          revision: const Value(1),
          syncStatus: const Value('pending'),
        ),
      );
      final recorded =
          await PendingOperationRepository(
            workspace.db,
            access: workspace.access,
            context: workspace.context,
          ).record(
            operation: const PendingOperationDraft(
              userId: _ownerId,
              mutationId: _mutationId,
              operationType: 'pill.update',
              entityType: 'pill',
              entityLocalId: _pillId,
              parentEntityType: 'profile',
              parentEntityLocalId: _profileId,
              payload: {
                'action': 'update',
                'data': {
                  'name': 'Fakeolol',
                  'dosage': '10 mg',
                  'notes': null,
                  'color': null,
                  'lowStockThreshold': null,
                  'isPrn': false,
                  'amountPerUse': {
                    'version': 1,
                    'state': 'known',
                    'quantity': '2',
                    'unit': 'tablet',
                  },
                  'packageStrength': '20 mg',
                  'form': 'tablet',
                  'legacyDosageReviewed': true,
                },
              },
            ),
            applyProjection: () async {},
          );
      return (
        (await workspace.db.pendingOperationsDao.getById(
          recorded.operationId,
        ))!,
        workspace,
      );
    }

    Future<Map<String, dynamic>> sent(
      ProtectedWorkspaceFixture workspace,
      PendingOperation operation, {
      required bool medicationDetails,
    }) async {
      late Map<String, dynamic> body;
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            body = Map<String, dynamic>.of(
              request.data as Map<String, dynamic>,
            );
            handler.resolve(
              Response(
                requestOptions: request,
                statusCode: 200,
                data: {'id': _pillId, 'revision': '2'},
              ),
            );
          },
        ),
      );
      final result = await V2StableAdapter(
        db: workspace.db,
        dio: dio,
        writeScope: SyncWriteScope(
          access: workspace.access,
          capability: await workspace.access.currentNetworkCapability(),
        ),
        medicationDetails: medicationDetails,
      ).send(operation);
      expect(result.status, StableMutationStatus.acknowledged);
      return body;
    }

    test('a server that keeps the details receives them', () async {
      final (operation, workspace) = await queued();
      addTearDown(workspace.db.close);
      final body = await sent(workspace, operation, medicationDetails: true);
      expect(body['packageStrength'], '20 mg');
      expect(body['form'], 'tablet');
      expect(body['legacyDosageReviewed'], true);
      expect((body['amountPerUse'] as Map)['quantity'], '2');
    });

    test(
      'a server without the contract gets the medicine without them',
      () async {
        final (operation, workspace) = await queued();
        addTearDown(workspace.db.close);
        final body = await sent(workspace, operation, medicationDetails: false);
        expect(body.keys, isNot(contains('packageStrength')));
        expect(body.keys, isNot(contains('form')));
        expect(body.keys, isNot(contains('amountPerUse')));
        expect(body.keys, isNot(contains('legacyDosageReviewed')));
        // The medicine's own fields still travel, so the edit is not lost and
        // the operation is not left stuck.
        expect(body['name'], 'Fakeolol');
        expect(body['baseRevision'], '1');
      },
    );
  });
}
