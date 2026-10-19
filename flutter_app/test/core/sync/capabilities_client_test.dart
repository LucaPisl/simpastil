import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/sync/capabilities_client.dart';

const _url = 'https://github.com/LucaPisl/simpastil/releases/tag/v1.1.0';

Future<CapabilitySnapshot> _refresh(Map<String, Object?> extra) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) => handler.resolve(
        Response<Map<String, dynamic>>(
          data: {
            'apiNamespace': 'v1',
            'medicationLedgerActive': false,
            'minimumClientBuild': 1,
            'serverRelease': 'r',
            'contracts': {
              'componentSync': 2,
              'legacySplitReconciliation': 1,
              'medicationBridgeCommands': 1,
              'medicationBridgeSync': 1,
              'medicationCommands': 3,
              'medicationDetails': 1,
            },
            ...extra,
          },
          statusCode: 200,
          requestOptions: options,
        ),
      ),
    ),
  );
  return CapabilitiesClient(dio).refresh();
}

void main() {
  test('valid latest release fields parse', () async {
    final snapshot = await _refresh({
      'latestClientBuild': 4,
      'latestReleaseUrl': _url,
    });
    expect(snapshot.capabilities!.latestClientBuild, 4);
    expect(snapshot.capabilities!.latestReleaseUrl, _url);
  });

  test(
    'invalid latest release fields become null, snapshot stays present',
    () async {
      final snapshot = await _refresh({
        'latestClientBuild': '4',
        'latestReleaseUrl': 'https://evil.example/x',
      });
      expect(snapshot.availability, CapabilityAvailability.present);
      expect(snapshot.capabilities!.latestClientBuild, isNull);
      expect(snapshot.capabilities!.latestReleaseUrl, isNull);
    },
  );

  test('a server without the fields is unchanged', () async {
    final snapshot = await _refresh({});
    expect(snapshot.availability, CapabilityAvailability.present);
    expect(snapshot.capabilities!.latestClientBuild, isNull);
  });

  group('emailReset', () {
    test('available and unavailable are read as sent', () async {
      expect(
        (await _refresh({'emailReset': 'available'})).capabilities!.emailReset,
        EmailResetAvailability.available,
      );
      expect(
        (await _refresh({
          'emailReset': 'unavailable',
        })).capabilities!.emailReset,
        EmailResetAvailability.unavailable,
      );
    });

    test('a server without the field, or with junk, is unknown', () async {
      expect(
        (await _refresh({})).capabilities!.emailReset,
        EmailResetAvailability.unknown,
      );
      final junk = await _refresh({'emailReset': 42});
      expect(junk.availability, CapabilityAvailability.present);
      expect(junk.capabilities!.emailReset, EmailResetAvailability.unknown);
    });
  });
}
