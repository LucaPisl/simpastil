import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/adapters/legacy_medication_sync_adapter.dart';
import 'package:simpastil/core/sync/adapters/medication_sync_adapter.dart';
import 'package:simpastil/core/sync/capabilities_client.dart';
import 'package:simpastil/core/sync/ledger_mode_hint.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';

import '../../helpers/protected_workspace_fixture.dart';

const _owner = '10000000-0000-4000-8000-000000000501';
const _profile = '10000000-0000-4000-8000-000000000502';
const _pill = '10000000-0000-4000-8000-000000000503';
final _at = DateTime.utc(2026, 10, 12, 8);

/// A refill is a delta only a ledger applies. The app refuses one on a server
/// known to lack the ledger, queues one while the server is unknown, and an
/// older server found later refuses the queued one at send time, with its
/// own reason, instead of stranding it under a mapping wait.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the ledger hint', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('unknown is not a refusal', () async {
      expect(await LedgerModeHint.refillRefused(), isFalse);
    });

    test('an older server is remembered apart from the ledger key', () async {
      await LedgerModeHint.record(
        const CapabilitySnapshot.absent(),
        server: await LedgerModeHint.configuredServer(),
      );
      expect(await LedgerModeHint.read(), isNull);
      expect(await LedgerModeHint.readLegacyServer(), isTrue);
      expect(await LedgerModeHint.refillRefused(), isTrue);

      await LedgerModeHint.record(
        const CapabilitySnapshot.present(
          ServerCapabilities(
            medicationLedgerActive: true,
            minimumClientBuild: 1,
            serverRelease: 'release-test',
          ),
        ),
        server: await LedgerModeHint.configuredServer(),
      );
      expect(await LedgerModeHint.readLegacyServer(), isFalse);
      expect(await LedgerModeHint.refillRefused(), isFalse);
    });

    test('belongs to the server that answered: another address is unknown '
        'again', () async {
      SharedPreferences.setMockInitialValues({
        'server_url': 'https://old.example.test',
      });
      await LedgerModeHint.record(
        const CapabilitySnapshot.absent(),
        server: await LedgerModeHint.configuredServer(),
      );
      expect(await LedgerModeHint.readLegacyServer(), isTrue);
      expect(await LedgerModeHint.refillRefused(), isTrue);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('server_url', 'https://new.example.test');
      expect(await LedgerModeHint.readLegacyServer(), isFalse);
      expect(await LedgerModeHint.refillRefused(), isFalse);

      // Back on the older server, the answer it gave still holds.
      await prefs.setString('server_url', 'https://old.example.test');
      expect(await LedgerModeHint.readLegacyServer(), isTrue);
    });

    test(
      'the device-wide flag an earlier build wrote reads as unknown',
      () async {
        SharedPreferences.setMockInitialValues({
          'server_url': 'https://new.example.test',
          LedgerModeHint.legacyServerKey: true,
        });
        expect(await LedgerModeHint.readLegacyServer(), isFalse);
        expect(await LedgerModeHint.refillRefused(), isFalse);
      },
    );

    test('an inactive ledger refuses', () async {
      SharedPreferences.setMockInitialValues({LedgerModeHint.key: false});
      expect(await LedgerModeHint.refillRefused(), isTrue);
    });

    test('an unreachable server keeps the previous answer', () async {
      await LedgerModeHint.record(
        const CapabilitySnapshot.absent(),
        server: await LedgerModeHint.configuredServer(),
      );
      await LedgerModeHint.record(
        const CapabilitySnapshot.unavailable(),
        server: await LedgerModeHint.configuredServer(),
      );
      expect(await LedgerModeHint.refillRefused(), isTrue);
    });

    group('and a server switch', () {
      const old = 'https://old.example.test';
      const current = 'https://new.example.test';
      const modern = CapabilitySnapshot.present(
        ServerCapabilities(
          medicationLedgerActive: true,
          minimumClientBuild: 1,
          serverRelease: 'release-test',
          recordedMiss: true,
          scheduleWindows: true,
          fractionalStock: true,
          recordedBy: true,
          accountSettings: true,
          accountSelfService: true,
          emailChange: EmailChangeMode.confirm,
        ),
      );

      test('an older server probed before the switch is not saved under the '
          'new address', () async {
        SharedPreferences.setMockInitialValues({'server_url': old});
        final probed = await LedgerModeHint.configuredServer();
        // The person points the app at another server while the probe runs.
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('server_url', current);

        await LedgerModeHint.record(
          const CapabilitySnapshot.absent(),
          server: probed,
        );

        expect(prefs.getString(LedgerModeHint.legacyServerKey), isNull);
        expect(await LedgerModeHint.readLegacyServer(), isFalse);
        expect(await LedgerModeHint.refillRefused(), isFalse);
        // Back on the old server it is still unknown: nothing was saved.
        await prefs.setString('server_url', old);
        expect(await LedgerModeHint.readLegacyServer(), isFalse);
      });

      test('a modern answer probed before the switch is not lent to the new '
          'server', () async {
        SharedPreferences.setMockInitialValues({'server_url': old});
        final probed = await LedgerModeHint.configuredServer();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('server_url', current);

        await LedgerModeHint.record(modern, server: probed);

        expect(await LedgerModeHint.read(), isNull);
        expect(await LedgerModeHint.readRecordedMiss(), isFalse);
        expect(await LedgerModeHint.readFractionalStock(), isFalse);
      });

      test('every hint is unknown on another server and back on the one that '
          'answered', () async {
        SharedPreferences.setMockInitialValues({'server_url': old});
        await LedgerModeHint.record(
          modern,
          server: await LedgerModeHint.configuredServer(),
        );
        Future<List<Object?>> all() async => [
          await LedgerModeHint.read(),
          await LedgerModeHint.readRecordedMiss(),
          await LedgerModeHint.readScheduleWindows(),
          await LedgerModeHint.readFractionalStock(),
          await LedgerModeHint.readRecordedBy(),
          await LedgerModeHint.readAccountSettings(),
          await LedgerModeHint.readAccountSelfService(),
        ];
        expect(await all(), [true, true, true, true, true, true, true]);
        expect(
          await LedgerModeHint.readEmailChangeMode(),
          EmailChangeMode.confirm,
        );

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('server_url', current);
        expect(await all(), [null, false, false, false, false, false, false]);
        expect(
          await LedgerModeHint.readEmailChangeMode(),
          EmailChangeMode.unknown,
        );

        await prefs.setString('server_url', old);
        expect(await all(), [true, true, true, true, true, true, true]);
      });

      test('hints an earlier build wrote without an address still count until '
          'the next answer', () async {
        SharedPreferences.setMockInitialValues({
          'server_url': current,
          LedgerModeHint.key: true,
          LedgerModeHint.fractionalStockKey: true,
        });
        expect(await LedgerModeHint.read(), isTrue);
        expect(await LedgerModeHint.readFractionalStock(), isTrue);
      });
    });
  });

  test('an older server refuses a queued refill without a request', () async {
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
        currentStock: const Value(15),
        syncStatus: const Value('synced'),
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
            mutationId: '10000000-0000-4000-8000-000000000509',
            component: 'medication',
            contractVersion: 2,
            operationType: 'inventory.refill',
            entityType: 'pill',
            entityLocalId: _pill,
            payload: {
              'inventoryCommand': {
                'commandId': '10000000-0000-4000-8000-000000000509',
                'action': 'refill',
                'pillId': _pill,
                'amount': 5,
                'note': null,
              },
            },
            effects: [
              PendingOperationEffectDraft(
                kind: 'inventory',
                legacySourceId: _pill,
                requestFingerprint: 'fingerprint',
              ),
            ],
          ),
          applyProjection: () async {},
        );
    final operation = (await w.db.pendingOperationsDao.getById(
      recorded.operationId,
    ))!;
    var requests = 0;
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          requests++;
          handler.reject(DioException(requestOptions: request));
        },
      ),
    );

    final result = await LegacyMedicationSyncAdapter(
      db: w.db,
      dio: dio,
    ).flush(operation);

    expect(result.status, MedicationMutationStatus.blocked);
    expect(result.safeErrorCode, refillNeedsLedgerCode);
    expect(requests, 0);
  });
}
