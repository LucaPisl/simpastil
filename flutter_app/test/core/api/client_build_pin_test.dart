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
}
