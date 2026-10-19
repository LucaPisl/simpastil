import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

/// Test-only key for the committed fixture. It protects no real data.
const encryptedFixtureKey = 'simpastil-fixture-key-not-a-secret-0001';

/// Path of the committed fixture, relative to `flutter_app/`.
const encryptedFixturePath = 'test/fixtures/encrypted/chacha20_wal_v1.sqlite';

/// Number of rows the fixture holds in `fixture_doses`.
const encryptedFixtureRows = 3;

/// Writes the fixture with the exact cipher setup the app uses
/// (`protected_database.dart`: `PRAGMA cipher='chacha20'`, `PRAGMA key`, WAL).
///
/// Only call this to regenerate the fixture with a build you trust; the whole
/// point of the committed file is that it was written by an earlier SQLite3
/// Multiple Ciphers release than the one under test.
void writeEncryptedFixture(String path) {
  final file = File(path);
  if (file.existsSync()) file.deleteSync();
  final db = sqlite3.open(path);
  try {
    db.execute("PRAGMA cipher='chacha20'");
    db.execute("PRAGMA key='$encryptedFixtureKey'");
    db.execute('PRAGMA journal_mode=WAL');
    db.execute('''
      CREATE TABLE fixture_doses (
        id TEXT NOT NULL PRIMARY KEY,
        pill_name TEXT NOT NULL,
        taken_at INTEGER NOT NULL,
        note TEXT
      )
    ''');
    db.execute('''
      INSERT INTO fixture_doses (id, pill_name, taken_at, note) VALUES
        ('occ-1', 'Aspirin', 1700000000, 'morning'),
        ('occ-2', 'Metformin', 1700003600, NULL),
        ('occ-3', 'Vitamin D3 éè ✓', 1700007200, 'unicode ok')
    ''');
    db.userVersion = 7;
    db.select('PRAGMA wal_checkpoint(TRUNCATE)');
  } finally {
    db.close();
  }
}
