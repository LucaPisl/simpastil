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
              'fractionalStock': 1,
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

  group('accountSettings', () {
    test('an absent contract reads as unsupported', () async {
      expect((await _refresh({})).capabilities!.accountSettings, isFalse);
    });

    test(
      'contract 1 reads as supported; a newer one asks for an update',
      () async {
        Future<CapabilitySnapshot> flag(Object? v) => _refresh({
          'contracts': {
            'componentSync': 2,
            'legacySplitReconciliation': 1,
            'medicationBridgeCommands': 1,
            'medicationBridgeSync': 1,
            'fractionalStock': 1,
            'medicationCommands': 3,
            'medicationDetails': 1,
            'accountSettings': v,
          },
        });
        expect((await flag(1)).capabilities!.accountSettings, isTrue);
        expect((await flag(2)).capabilities, isNull);
        expect((await flag(true)).capabilities!.accountSettings, isFalse);
      },
    );
  });

  group('accountSelfService and emailChange', () {
    Map<String, Object?> body(Object? contract, Object? mode) => {
      'contracts': {
        'componentSync': 2,
        'legacySplitReconciliation': 1,
        'medicationBridgeCommands': 1,
        'medicationBridgeSync': 1,
        'fractionalStock': 1,
        'medicationCommands': 3,
        'medicationDetails': 1,
        'accountSelfService': contract,
      },
      'emailChange': mode,
    };

    test('absent reads as unsupported with an unknown mode', () async {
      final c = (await _refresh({})).capabilities!;
      expect(c.accountSelfService, isFalse);
      expect(c.emailChange, EmailChangeMode.unknown);
    });

    test(
      'contract 1 and the mode are read; a newer contract asks to update',
      () async {
        final c = (await _refresh(body(1, 'confirm'))).capabilities!;
        expect(c.accountSelfService, isTrue);
        expect(c.emailChange, EmailChangeMode.confirm);
        expect(
          (await _refresh(body(1, 'immediate'))).capabilities!.emailChange,
          EmailChangeMode.immediate,
        );
        expect(
          (await _refresh(body(1, 'later'))).capabilities!.emailChange,
          EmailChangeMode.unknown,
        );
        expect((await _refresh(body(2, 'confirm'))).capabilities, isNull);
      },
    );
  });

  group('scheduleWindows and movedHistory', () {
    test('absent flags read as unsupported', () async {
      final capabilities = (await _refresh({})).capabilities!;
      expect(capabilities.scheduleWindows, isFalse);
      expect(capabilities.movedHistory, isFalse);
    });

    test('true flags are read as sent, independently', () async {
      final both = (await _refresh({
        'scheduleWindows': true,
        'movedHistory': true,
      })).capabilities!;
      expect(both.scheduleWindows, isTrue);
      expect(both.movedHistory, isTrue);
      final one = (await _refresh({'scheduleWindows': true})).capabilities!;
      expect(one.scheduleWindows, isTrue);
      expect(one.movedHistory, isFalse);
    });

    test(
      'anything but a true boolean is unsupported and not an error',
      () async {
        final snapshot = await _refresh({
          'scheduleWindows': 'true',
          'movedHistory': 1,
        });
        expect(snapshot.availability, CapabilityAvailability.present);
        expect(snapshot.capabilities!.scheduleWindows, isFalse);
        expect(snapshot.capabilities!.movedHistory, isFalse);
      },
    );
  });

  group('medicationShapes', () {
    test(
      'a server without the contract is usable and keeps shapes local',
      () async {
        final snapshot = await _refresh({});
        expect(snapshot.availability, CapabilityAvailability.present);
        expect(snapshot.capabilities!.medicationShapes, isFalse);
        expect(snapshot.clientUpdateRequired, isFalse);
      },
    );

    test('contract 1 is read as sent', () async {
      final snapshot = await _refresh({
        'contracts': {
          'componentSync': 2,
          'legacySplitReconciliation': 1,
          'medicationBridgeCommands': 1,
          'medicationBridgeSync': 1,
          'fractionalStock': 1,
          'medicationCommands': 3,
          'medicationDetails': 1,
          'medicationShapes': 1,
        },
      });
      expect(snapshot.capabilities!.medicationShapes, isTrue);
    });

    test('a newer shape contract asks for an app update', () async {
      final snapshot = await _refresh({
        'contracts': {
          'componentSync': 2,
          'legacySplitReconciliation': 1,
          'medicationBridgeCommands': 1,
          'medicationBridgeSync': 1,
          'fractionalStock': 1,
          'medicationCommands': 3,
          'medicationShapes': 2,
        },
      });
      expect(snapshot.clientUpdateRequired, isTrue);
    });
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
