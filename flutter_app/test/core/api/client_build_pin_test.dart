import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/api/api_client.dart';

void main() {
  test('simpastilClientBuild equals the pubspec build number', () {
    final version = RegExp(
      r'^version:\s*\S+\+(\d+)\s*$',
      multiLine: true,
    ).firstMatch(File('pubspec.yaml').readAsStringSync());
    expect(version, isNotNull, reason: 'pubspec.yaml needs version: x.y.z+N');
    expect(
      simpastilClientBuild,
      int.parse(version!.group(1)!),
      reason:
          'Bump simpastilClientBuild and the pubspec +N together; the server '
          'minimum-build gate compares this value.',
    );
  });

  // Storing an every-few-days or dated routine raises the account's minimum
  // build to the server's schedule-windows build. A client below it would be
  // locked out by the routines it just saved.
  test('simpastilClientBuild reaches the schedule-windows build', () {
    final gate = RegExp(r'SCHEDULE_WINDOWS_MIN_CLIENT_BUILD\s*=\s*(\d+)')
        .firstMatch(
          File(
            '../server/src/modules/schedules/schedule-windows.ts',
          ).readAsStringSync(),
        );
    expect(gate, isNotNull);
    expect(
      simpastilClientBuild,
      greaterThanOrEqualTo(int.parse(gate!.group(1)!)),
    );
  });
}
