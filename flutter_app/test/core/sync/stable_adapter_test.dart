import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/adapters/legacy_stable_adapter.dart';
import 'package:simpastil/core/sync/adapters/stable_record_adapter.dart';
import 'package:simpastil/core/sync/adapters/v2_stable_adapter.dart';
import 'package:simpastil/core/sync/capabilities_client.dart';

void main() {
  test('capability failure is not mistaken for an old server', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final legacy = LegacyStableAdapter(db: db, dio: Dio());
    final versioned = V2StableAdapter(db: db, dio: Dio());

    expect(
      StableRecordAdapter.forCapabilities(
        const CapabilitySnapshot.absent(),
        legacy: legacy,
        versioned: versioned,
      ),
      same(legacy),
    );
    expect(
      StableRecordAdapter.forCapabilities(
        const CapabilitySnapshot.unavailable(),
        legacy: legacy,
        versioned: versioned,
      ),
      isNull,
    );

    final oldServerDio = Dio();
    oldServerDio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) => handler.reject(
          DioException(
            requestOptions: options,
            response: Response(statusCode: 404, requestOptions: options),
            type: DioExceptionType.badResponse,
          ),
        ),
      ),
    );
    expect(
      (await CapabilitiesClient(oldServerDio).refresh()).availability,
      CapabilityAvailability.absent,
    );

    final offlineDio = Dio();
    offlineDio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) => handler.reject(
          DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
          ),
        ),
      ),
    );
    expect(
      (await CapabilitiesClient(offlineDio).refresh()).availability,
      CapabilityAvailability.unavailable,
    );
  });

  test(
    'local connection guard refusal stays separate from transport failure',
    () async {
      final guardedDio = Dio();
      guardedDio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.cancel,
              message: 'Connection access is unavailable',
            ),
          ),
        ),
      );

      final result = await CapabilitiesClient(guardedDio).refresh();

      expect(result.availability.name, 'localAccessUnavailable');
      expect(result.protocol, SyncProtocol.blocked);
      expect(result.medicationSyncOrder, isEmpty);
    },
  );

  test('capability selection chooses exactly one protocol family', () {
    expect(
      const CapabilitySnapshot.absent().protocol,
      SyncProtocol.legacyCompatibility,
    );
    expect(
      const CapabilitySnapshot.unavailable().protocol,
      SyncProtocol.blocked,
    );
    expect(
      const CapabilitySnapshot.present(
        ServerCapabilities(
          medicationLedgerActive: false,
          minimumClientBuild: 2,
          serverRelease: 'release-test',
        ),
      ).protocol,
      SyncProtocol.componentSync,
    );
  });

  test(
    'present capabilities always reconcile before the current authority',
    () {
      const inactive = CapabilitySnapshot.present(
        ServerCapabilities(
          medicationLedgerActive: false,
          minimumClientBuild: 2,
          serverRelease: 'release-test',
        ),
      );
      const active = CapabilitySnapshot.present(
        ServerCapabilities(
          medicationLedgerActive: true,
          minimumClientBuild: 2,
          serverRelease: 'release-test',
        ),
      );

      expect(inactive.medicationSyncOrder, [
        MedicationSyncStep.permanentReconciliation,
        MedicationSyncStep.inactiveBridge,
      ]);
      expect(active.medicationSyncOrder, [
        MedicationSyncStep.permanentReconciliation,
        MedicationSyncStep.activeLedger,
      ]);
    },
  );

  test('schedule weekdays convert from local JSON text to wire int[]', () {
    expect(frequencyDaysToWire('[1,3,5]'), [1, 3, 5]);
    expect(frequencyDaysToWire([2, 4, 6]), [2, 4, 6]);
    expect(frequencyDaysToWire(null), isNull);
  });
}
