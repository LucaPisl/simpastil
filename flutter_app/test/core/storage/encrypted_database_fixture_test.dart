import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../fixtures/encrypted_database_fixture.dart';

/// Guards the on-disk compatibility of existing users' encrypted databases
/// across SQLite / SQLite3 Multiple Ciphers upgrades. The fixture file was
/// written by the build that shipped before the sqlite3 3.7 upgrade (see
/// `test/fixtures/encrypted_database_fixture.dart`) and must never be
/// regenerated just to make this test pass.
void main() {
  late Directory scratch;
  late String copy;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('simpastil-fixture-');
    copy = '${scratch.path}/store.sqlite';
    File(encryptedFixturePath).copySync(copy);
  });

  tearDown(() => scratch.deleteSync(recursive: true));

  test('fixture is not a plaintext SQLite file', () {
    final header = File(copy).openSync().readSync(16);
    expect(String.fromCharCodes(header), isNot(startsWith('SQLite format 3')));
  });

  test('opens with the app cipher setup and reads the stored rows', () {
    final db = sqlite3.open(copy, mode: OpenMode.readWrite);
    addTearDown(db.close);
    // Same sequence as _configureCipher in protected_database.dart.
    expect(db.select('PRAGMA cipher'), isNotEmpty);
    db.execute("PRAGMA cipher='chacha20'");
    db.execute("PRAGMA key='$encryptedFixtureKey'");
    expect(db.select('SELECT count(*) FROM sqlite_master'), isNotEmpty);

    expect(db.userVersion, 7);
    expect(db.select('PRAGMA integrity_check').single.values.single, 'ok');
    expect(db.select('PRAGMA journal_mode').single.values.single, 'wal');
    final rows = db.select(
      'SELECT id, pill_name, taken_at, note FROM fixture_doses ORDER BY id',
    );
    expect(rows, hasLength(encryptedFixtureRows));
    expect(rows[0]['pill_name'], 'Aspirin');
    expect(rows[0]['note'], 'morning');
    expect(rows[1]['note'], isNull);
    expect(rows[2]['pill_name'], 'Vitamin D3 éè ✓');
    expect(rows[2]['taken_at'], 1700007200);
  });

  test('wrong key is rejected instead of reading garbage', () {
    final db = sqlite3.open(copy, mode: OpenMode.readWrite);
    addTearDown(db.close);
    db.execute("PRAGMA cipher='chacha20'");
    db.execute("PRAGMA key='not-the-fixture-key'");
    expect(
      () => db.select('SELECT count(*) FROM sqlite_master'),
      throwsA(isA<SqliteException>()),
    );
  });

  test('written rows survive a reopen (WAL write path still works)', () {
    var db = sqlite3.open(copy, mode: OpenMode.readWrite);
    db.execute("PRAGMA cipher='chacha20'");
    db.execute("PRAGMA key='$encryptedFixtureKey'");
    db.execute(
      "INSERT INTO fixture_doses VALUES ('occ-4', 'New', 1700010800, NULL)",
    );
    db.close();
    db = sqlite3.open(copy, mode: OpenMode.readWrite);
    addTearDown(db.close);
    db.execute("PRAGMA cipher='chacha20'");
    db.execute("PRAGMA key='$encryptedFixtureKey'");
    expect(
      db.select('SELECT count(*) AS c FROM fixture_doses').single['c'],
      encryptedFixtureRows + 1,
    );
  });
}
