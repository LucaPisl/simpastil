import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/account_settlement_merger.dart';
import 'package:simpastil/core/sync/adapters/v2_stable_adapter.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';
import 'package:simpastil/core/sync/stable_record_merger.dart';
import 'package:simpastil/core/sync/sync_write_scope.dart';

import '../../helpers/protected_workspace_fixture.dart';

const _owner = '10000000-0000-4000-8000-000000000501';
const _profile = '10000000-0000-4000-8000-000000000502';
const _pill = '10000000-0000-4000-8000-000000000503';
const _mutation = '10000000-0000-4000-8000-000000000504';
final _at = DateTime.utc(2026, 10, 12, 8);

Map<String, dynamic> _item(Map<String, dynamic> extras) => {
  'id': _pill,
  'profileId': _profile,
  'revision': '5',
  'name': 'Fakeolol',
  'dosage': null,
  'notes': null,
  'color': null,
  'currentStock': 3,
  'lowStockThreshold': null,
  'isPrn': true,
  'deletedAt': null,
  'createdAt': '2026-10-12T08:00:00.000Z',
  'updatedAt': '2026-10-13T08:00:00.000Z',
  ...extras,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('merging a pulled pill', () {
    late AppDatabase db;

    setUp(() async {
      db = AppDatabase.forTesting();
      await db.usersDao.upsert(
        UsersCompanion.insert(
          id: 'u1',
          email: 'u@example.com',
          createdAt: _at,
          updatedAt: _at,
        ),
      );
      await db.profilesDao.upsert(
        ProfilesCompanion.insert(
          id: _profile,
          userId: 'u1',
          name: 'P',
          createdAt: _at,
          updatedAt: _at,
          serverId: const Value(_profile),
          syncStatus: const Value('synced'),
        ),
      );
      await db.pillsDao.upsert(
        PillsCompanion.insert(
          id: _pill,
          profileId: _profile,
          name: 'Old',
          createdAt: _at,
          updatedAt: _at,
          serverId: const Value(_pill),
          revision: const Value(2),
          syncStatus: const Value('synced'),
          prnMaxPer24h: const Value(3),
          expiresOn: const Value('2027-01-01'),
          prescriberPhone: const Value('+40 21 555 0100'),
        ),
      );
    });
    tearDown(() async => db.close());

    StableRecordMerger merger({required bool capable}) => StableRecordMerger(
      db,
      reviews: AccountSettlementMerger(db),
      medicationDetailsExtra: capable,
    );

    test('with the contract, the keys present are stored', () async {
      await merger(capable: true).mergePill(
        _item({
          'prnMaxPer24h': 4,
          'prnMinGapMinutes': 240,
          'expiresOn': '2027-02-03',
          'prescriberName': 'Dr Fictional',
          'prescriberPhone': '+40 21 555 0100',
          'pharmacyName': 'Fictional Pharmacy',
          'pharmacyPhone': '112',
        }),
        {_profile: _profile},
        {},
      );
      final pill = (await db.pillsDao.getById(_pill))!;
      expect(pill.prnMaxPer24h, 4);
      expect(pill.prnMinGapMinutes, 240);
      expect(pill.expiresOn, '2027-02-03');
      expect(pill.prescriberName, 'Dr Fictional');
      expect(pill.pharmacyPhone, '112');
    });

    test('with the contract, an absent key means cleared', () async {
      await merger(
        capable: true,
      ).mergePill(_item({'prnMaxPer24h': 4}), {_profile: _profile}, {});
      final pill = (await db.pillsDao.getById(_pill))!;
      expect(pill.prnMaxPer24h, 4);
      expect(pill.expiresOn, isNull);
      expect(pill.prescriberPhone, isNull);
    });

    test('a value up to the server maximum is kept', () async {
      await merger(capable: true).mergePill(
        _item({'prnMaxPer24h': 48, 'prnMinGapMinutes': 2880}),
        {_profile: _profile},
        {},
      );
      final pill = (await db.pillsDao.getById(_pill))!;
      expect(pill.prnMaxPer24h, 48);
      expect(pill.prnMinGapMinutes, 2880);
    });

    test('an invalid wire value is dropped, not stored', () async {
      await merger(capable: true).mergePill(
        _item({
          'prnMaxPer24h': 'many',
          'expiresOn': '2027-13-45',
          'prescriberPhone': 'call me',
        }),
        {_profile: _profile},
        {},
      );
      final pill = (await db.pillsDao.getById(_pill))!;
      expect(pill.prnMaxPer24h, isNull);
      expect(pill.expiresOn, isNull);
      expect(pill.prescriberPhone, isNull);
    });

    test('without the contract, the device keeps its values', () async {
      await merger(
        capable: false,
      ).mergePill(_item({}), {_profile: _profile}, {});
      final pill = (await db.pillsDao.getById(_pill))!;
      expect(pill.name, 'Fakeolol');
      expect(pill.prnMaxPer24h, 3);
      expect(pill.expiresOn, '2027-01-01');
      expect(pill.prescriberPhone, '+40 21 555 0100');
    });
  });

  group('sending a pill create', () {
    Future<Map<String, dynamic>> body({required bool capable}) async {
      final workspace = await ProtectedWorkspaceFixture.create(ownerId: _owner);
      addTearDown(workspace.db.close);
      await workspace.db.profilesDao.upsert(
        ProfilesCompanion.insert(
          id: _profile,
          userId: _owner,
          name: 'Fictional person',
          createdAt: _at,
          updatedAt: _at,
          serverId: const Value(_profile),
          syncStatus: const Value('synced'),
        ),
      );
      await workspace.db.pillsDao.upsert(
        PillsCompanion.insert(
          id: _pill,
          profileId: _profile,
          name: 'Fakeolol',
          createdAt: _at,
          updatedAt: _at,
        ),
      );
      final recorded =
          await PendingOperationRepository(
            workspace.db,
            access: workspace.access,
            context: workspace.context,
          ).record(
            operation: const PendingOperationDraft(
              userId: _owner,
              mutationId: _mutation,
              operationType: 'pill.create',
              entityType: 'pill',
              entityLocalId: _pill,
              parentEntityType: 'profile',
              parentEntityLocalId: _profile,
              payload: {
                'action': 'create',
                'data': {
                  'name': 'Fakeolol',
                  'dosage': null,
                  'notes': null,
                  'color': null,
                  'lowStockThreshold': null,
                  'isPrn': true,
                  'prnMaxPer24h': 3,
                  'prnMinGapMinutes': null,
                  'expiresOn': '2027-01-01',
                  'prescriberName': null,
                  'prescriberPhone': '+40 21 555 0100',
                  'pharmacyName': null,
                  'pharmacyPhone': null,
                },
              },
            ),
            applyProjection: () async {},
          );
      final operation = (await workspace.db.pendingOperationsDao.getById(
        recorded.operationId,
      ))!;
      final bodies = <Map<String, dynamic>>[];
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            bodies.add(
              Map<String, dynamic>.of(request.data as Map<String, dynamic>),
            );
            handler.resolve(
              Response(
                requestOptions: request,
                statusCode: 201,
                data: {'id': _pill, 'revision': '1'},
              ),
            );
          },
        ),
      );
      await V2StableAdapter(
        db: workspace.db,
        dio: dio,
        medicationDetailsExtra: capable,
        writeScope: SyncWriteScope(
          access: workspace.access,
          capability: await workspace.access.currentNetworkCapability(),
        ),
      ).send(operation);
      return bodies.single;
    }

    test(
      'with the contract, set keys are sent and unset ones omitted',
      () async {
        final sent = await body(capable: true);
        expect(sent['prnMaxPer24h'], 3);
        expect(sent['expiresOn'], '2027-01-01');
        expect(sent['prescriberPhone'], '+40 21 555 0100');
        expect(sent.containsKey('prnMinGapMinutes'), isFalse);
        expect(sent.containsKey('pharmacyName'), isFalse);
      },
    );

    test('without the contract, none of the keys are sent', () async {
      final sent = await body(capable: false);
      for (final key in [
        'prnMaxPer24h',
        'prnMinGapMinutes',
        'expiresOn',
        'prescriberName',
        'prescriberPhone',
        'pharmacyName',
        'pharmacyPhone',
      ]) {
        expect(sent.containsKey(key), isFalse, reason: key);
      }
    });
  });
}
