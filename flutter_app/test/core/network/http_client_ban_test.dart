import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every connection to the user's Simpastil server must go through the one
/// factory that installs certificate pinning. A bare `Dio(` or `HttpClient(`
/// anywhere else would silently skip the pin, so this test fails the build.
void main() {
  const factory = 'lib/core/network/http_clients.dart';
  const networkFiles = {
    factory,
    'lib/core/network/pinned_connection.dart',
    'lib/core/network/spki_fingerprint.dart',
  };

  List<File> dartFiles() => Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'))
      .toList();

  String relative(File file) => file.path.replaceAll(r'\', '/');

  /// Source lines that are not comments, with the number for messages.
  Iterable<MapEntry<int, String>> codeLines(File file) sync* {
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final trimmed = lines[i].trimLeft();
      if (trimmed.startsWith('//')) continue;
      yield MapEntry(i + 1, lines[i]);
    }
  }

  test('no Dio, HttpClient or adapter is built outside the factory', () {
    final pattern = RegExp(r'\b(Dio|HttpClient|IOHttpClientAdapter)\(');
    final offenders = <String>[];
    for (final file in dartFiles()) {
      if (relative(file) == factory) continue;
      for (final line in codeLines(file)) {
        if (pattern.hasMatch(line.value)) {
          offenders.add('${relative(file)}:${line.key}: ${line.value.trim()}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'Build clients with createServerDio (the Simpastil server) or '
          'createNonPinningExternalDio (other services) from $factory.',
    );
  });

  test('the factory still builds both kinds of client', () {
    final source = File(factory).readAsStringSync();
    expect(source, contains('createServerDio'));
    expect(source, contains('createNonPinningExternalDio'));
    expect(source, contains('connectionFactory'));
  });

  test(
    'certificate callbacks and raw TLS sockets stay in the network layer',
    () {
      final offenders = <String>[];
      for (final file in dartFiles()) {
        final path = relative(file);
        for (final line in codeLines(file)) {
          final text = line.value;
          if (text.contains('badCertificateCallback') ||
              text.contains('validateCertificate')) {
            offenders.add('$path:${line.key}: pinning must not use $text');
          }
          if (!networkFiles.contains(path) &&
              RegExp(r'\bSecureSocket\.').hasMatch(text)) {
            offenders.add(
              '$path:${line.key}: raw TLS outside lib/core/network',
            );
          }
        }
      }
      expect(offenders, isEmpty);
    },
  );
}
