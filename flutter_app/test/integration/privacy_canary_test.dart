import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/utils/safe_diagnostics.dart';

void main() {
  test(
    'client diagnostics retain safe route metadata and exclude request canaries',
    () {
      const canaries = [
        'private-user-identifier',
        'private-pill-name',
        'fixture-user@example.invalid',
        'reset-fragment-secret',
        'raw-medication-body',
      ];
      final event = SafeDiagnostics.httpEvent(
        event: 'http_failed',
        path:
            '/profiles/private-user-identifier/pills/private-pill-name?token=reset-fragment-secret&body=raw-medication-body',
        statusCode: 409,
        duration: const Duration(milliseconds: 325),
        correlationId: 'not-a-safe-correlation-id',
        retryCount: 1,
        clientBuild: 2,
        component: 'medication',
      );
      final serialized = jsonEncode(event);

      expect(event['route'], '/profiles/:id/pills/:id');
      expect(event['statusClass'], '4xx');
      expect(event['correlationId'], isNull);
      for (final canary in canaries) {
        expect(serialized, isNot(contains(canary)));
      }
    },
  );
}
