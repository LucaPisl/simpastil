import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/api/api_client.dart';
import 'package:simpastil/core/sync/capabilities_client.dart';

Map<String, Object?> _body({
  Map<String, Object?> contractOverrides = const {},
  int minimumClientBuild = 1,
  Map<String, Object?> extra = const {},
}) => {
  'apiNamespace': 'v1',
  'medicationLedgerActive': false,
  'minimumClientBuild': minimumClientBuild,
  'serverRelease': 'migration-0019',
  ...extra,
  'contracts': {
    'componentSync': 2,
    'legacySplitReconciliation': 1,
    'medicationBridgeCommands': 1,
    'medicationBridgeSync': 1,
    'medicationCommands': 2,
    ...contractOverrides,
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

void main() {
  test('matching contracts and a satisfied build are not blocked', () async {
    final snapshot = await _refresh(_body());
    expect(snapshot.availability, CapabilityAvailability.present);
    expect(snapshot.protocol, SyncProtocol.componentSync);
    expect(snapshot.blockedStableCode, isNull);
  });

  test('a contract newer than this app surfaces update required', () async {
    final snapshot = await _refresh(
      _body(contractOverrides: {'componentSync': 3}),
    );
    expect(snapshot.clientUpdateRequired, isTrue);
    expect(snapshot.protocol, SyncProtocol.blocked);
    expect(snapshot.blockedStableCode, clientUpgradeRequiredCode);
    expect(clientUpgradeRequiredCode, 'CLIENT_UPGRADE_REQUIRED');
  });

  test(
    'an older or missing contract is a server problem, not an app update',
    () async {
      final older = await _refresh(
        _body(contractOverrides: {'medicationCommands': 1}),
      );
      expect(older.clientUpdateRequired, isFalse);
      expect(older.blockedStableCode, 'SERVER_CAPABILITIES_UNAVAILABLE');

      final missing = await _refresh(
        _body(contractOverrides: {'medicationBridgeSync': null}),
      );
      expect(missing.clientUpdateRequired, isFalse);
      expect(missing.blockedStableCode, 'SERVER_CAPABILITIES_UNAVAILABLE');
    },
  );

  test(
    'minimumClientBuild above this build surfaces update required',
    () async {
      final snapshot = await _refresh(
        _body(minimumClientBuild: simpastilClientBuild + 1),
      );
      expect(snapshot.availability, CapabilityAvailability.present);
      expect(snapshot.protocol, SyncProtocol.blocked);
      expect(snapshot.blockedStableCode, clientUpgradeRequiredCode);
    },
  );

  test('a minimum equal to this build still syncs', () async {
    final snapshot = await _refresh(
      _body(minimumClientBuild: simpastilClientBuild),
    );
    expect(snapshot.protocol, SyncProtocol.componentSync);
    expect(snapshot.blockedStableCode, isNull);
  });

  group('medication command contract 3 (recorded misses)', () {
    test('contract 2 syncs but never records misses', () async {
      final snapshot = await _refresh(_body());
      expect(snapshot.protocol, SyncProtocol.componentSync);
      expect(snapshot.capabilities!.recordedMiss, isFalse);
    });

    test('contract 3 with the additive flag records misses', () async {
      final snapshot = await _refresh(
        _body(
          contractOverrides: {'medicationCommands': 3},
          extra: {'recordedMiss': true},
        ),
      );
      expect(snapshot.protocol, SyncProtocol.componentSync);
      expect(snapshot.blockedStableCode, isNull);
      expect(snapshot.capabilities!.recordedMiss, isTrue);
    });

    test('contract 3 without the flag still syncs, without misses', () async {
      final snapshot = await _refresh(
        _body(contractOverrides: {'medicationCommands': 3}),
      );
      expect(snapshot.protocol, SyncProtocol.componentSync);
      expect(snapshot.capabilities!.recordedMiss, isFalse);
    });

    test('the flag alone never enables misses on contract 2', () async {
      final snapshot = await _refresh(_body(extra: {'recordedMiss': true}));
      expect(snapshot.capabilities!.recordedMiss, isFalse);
    });

    test('ledgerPrn opens as-needed doses on an active ledger', () async {
      final snapshot = await _refresh(
        _body(
          contractOverrides: {
            'medicationCommands': 3,
            'medicationBridgePrnCommands': 1,
            'medicationBridgePrnSync': 5,
          },
          extra: {'recordedMiss': true, 'ledgerPrn': true},
        ),
      );
      expect(snapshot.capabilities!.ledgerPrn, isTrue);
    });

    test('a server without ledgerPrn keeps as-needed doses waiting', () async {
      final snapshot = await _refresh(
        _body(
          contractOverrides: {
            'medicationCommands': 3,
            'medicationBridgePrnCommands': 1,
            'medicationBridgePrnSync': 5,
          },
          extra: {'recordedMiss': true},
        ),
      );
      expect(snapshot.capabilities!.ledgerPrn, isFalse);
    });

    test('contract 4 is newer than this app: update required', () async {
      final snapshot = await _refresh(
        _body(contractOverrides: {'medicationCommands': 4}),
      );
      expect(snapshot.clientUpdateRequired, isTrue);
      expect(snapshot.protocol, SyncProtocol.blocked);
      expect(snapshot.blockedStableCode, clientUpgradeRequiredCode);
    });
  });
}
