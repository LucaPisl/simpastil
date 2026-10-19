import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../fixtures/encrypted_database_fixture.dart';

/// Guards the vendored SQLite3 Multiple Ciphers build in
/// `third_party/sqlite3mc`: it must be the release the pinned `sqlite3`
/// package expects, keep the ChaCha20 defaults existing databases were written
/// with, and read back what it writes itself. The committed fixture written by
/// the previous release is covered in `encrypted_database_fixture_test.dart`.
void main() {
  late Directory scratch;

  setUp(() => scratch = Directory.systemTemp.createTempSync('simpastil-mc-'));
  tearDown(() => scratch.deleteSync(recursive: true));

  test('links the vendored SQLite3 Multiple Ciphers release', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    expect(
      db.select('SELECT sqlite3mc_version()').single.values.single,
      'SQLite3 Multiple Ciphers 2.6.1',
    );
    expect(db.select('SELECT sqlite_version()').single.values.single, '3.54.0');
  });

  test('keeps the ChaCha20 defaults the stored databases rely on', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    // The app only sets `cipher` and `key`; every other parameter is the
    // library default, so a changed default would lock users out.
    String pragma(String name) =>
        db.select('PRAGMA $name').single.values.single.toString();
    expect(pragma('cipher'), 'chacha20');
    db.execute("PRAGMA cipher='chacha20'");
    expect(pragma('kdf_iter'), '64007');
    expect(pragma('legacy'), '0');
    expect(pragma('legacy_page_size'), '4096');
    expect(pragma('plaintext_header_size'), '0');
  });

  test('a database written by this build opens again in WAL mode', () {
    final path = '${scratch.path}/fresh.sqlite';
    writeEncryptedFixture(path);

    final header = File(path).openSync().readSync(16);
    expect(String.fromCharCodes(header), isNot(startsWith('SQLite format 3')));

    final db = sqlite3.open(path, mode: OpenMode.readWrite);
    addTearDown(db.close);
    db.execute("PRAGMA cipher='chacha20'");
    db.execute("PRAGMA key='$encryptedFixtureKey'");
    expect(db.select('PRAGMA integrity_check').single.values.single, 'ok');
    expect(db.select('PRAGMA journal_mode').single.values.single, 'wal');
    final rows = db.select('SELECT pill_name FROM fixture_doses ORDER BY id');
    expect(rows, hasLength(encryptedFixtureRows));
    expect(rows[2]['pill_name'], 'Vitamin D3 éè ✓');
  });

  test('a database written by this build rejects a wrong key', () {
    final path = '${scratch.path}/fresh.sqlite';
    writeEncryptedFixture(path);
    final db = sqlite3.open(path, mode: OpenMode.readWrite);
    addTearDown(db.close);
    db.execute("PRAGMA cipher='chacha20'");
    db.execute("PRAGMA key='not-the-fixture-key'");
    expect(
      () => db.select('SELECT count(*) FROM sqlite_master'),
      throwsA(isA<SqliteException>()),
    );
  });
}
