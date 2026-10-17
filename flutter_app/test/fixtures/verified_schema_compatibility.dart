import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/isolate.dart';
import 'package:drift/native.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';

const _legacyIdentityTables = ['profiles', 'pills', 'schedules', 'dose_logs'];

/// Checks all constraints/indexes, permitting only four independently verified
/// legacy partial unique indexes in place of inline server_id UNIQUE clauses.
Future<void> verifyLegacySchemaCompatibility(
  AppDatabase actual,
  String key,
  Directory scratch,
) async {
  try {
    await actual.validateDatabaseSchema();
    return;
  } on SchemaMismatch catch (difference) {
    String compact(String value) =>
        value.replaceAll(RegExp(r'\s+'), ' ').trim();
    final expected = _legacyIdentityTables
        .map(
          (table) =>
              '$table: columns: server_id: Not equal: `NULL UNIQUE` (expected) and `NULL` (actual)',
        )
        .join(' ');
    expect(compact(difference.explanation), compact(expected));
  }
  for (final table in _legacyIdentityTables) {
    final index = await actual
        .customSelect(
          "SELECT sql FROM sqlite_master WHERE name='${table}_server_id_unique'",
        )
        .getSingle();
    String compact(String value) =>
        value.toLowerCase().replaceAll(RegExp(r'[\s"]'), '');
    expect(
      compact(index.read<String>('sql')),
      compact(
        'CREATE UNIQUE INDEX ${table}_server_id_unique ON $table(server_id) WHERE server_id IS NOT NULL',
      ),
    );
    final indexInfo = await actual
        .customSelect('PRAGMA index_info("${table}_server_id_unique")')
        .get();
    expect(indexInfo.map((row) => row.read<String>('name')), ['server_id']);
  }

  await actual.customStatement('PRAGMA foreign_keys=ON');
  Matcher constraint(int code) => throwsA(
    isA<DriftRemoteException>().having(
      (error) => error.remoteCause,
      'remoteCause',
      isA<SqliteException>().having(
        (error) => error.extendedResultCode,
        'constraint',
        code,
      ),
    ),
  );
  await actual.customStatement('SAVEPOINT constraint_check');
  try {
    for (final table in _legacyIdentityTables) {
      final columns = await actual
          .customSelect('PRAGMA table_info("$table")')
          .get();
      final names = columns
          .map((column) => column.read<String>('name'))
          .toList();
      final values = names
          .map(
            (name) => name == 'id'
                ? "'constraint-$table'"
                : name == 'server_id'
                ? "'collision-$table'"
                : '"$name"',
          )
          .join(',');
      await actual.customStatement(
        'INSERT INTO "$table" SELECT $values FROM "$table" LIMIT 1',
      );
      await expectLater(
        actual.customStatement('UPDATE "$table" SET server_id=? WHERE id!=?', [
          'collision-$table',
          'constraint-$table',
        ]),
        constraint(2067),
      );
      await actual.customStatement('UPDATE "$table" SET server_id=NULL');
      await actual.customStatement(
        'INSERT INTO "$table" SELECT $values FROM "$table" WHERE id=? ON CONFLICT(id) DO UPDATE SET updated_at=excluded.updated_at',
        ['constraint-$table'],
      );
    }
    await expectLater(
      actual.customStatement(
        "UPDATE profiles SET is_active=2 WHERE id='profile-1'",
      ),
      constraint(275),
    );
    await expectLater(
      actual.customStatement(
        "UPDATE profiles SET user_id='nonexistent' WHERE id='profile-1'",
      ),
      constraint(787),
    );
    await expectLater(
      actual.customStatement(
        "UPDATE inventory_events SET kind='dose', delta=0",
      ),
      constraint(275),
    );
  } finally {
    await actual.customStatement('ROLLBACK TO constraint_check');
    await actual.customStatement('RELEASE constraint_check');
  }

  final copy = File('${scratch.path}/schema-verification.db');
  await actual.customStatement(
    "VACUUM INTO '${copy.path.replaceAll("'", "''")}'",
  );
  final normalized = _VerificationDatabase(
    NativeDatabase(
      copy,
      setup: (raw) {
        raw.execute("PRAGMA cipher='chacha20'");
        raw.execute("PRAGMA key='$key'");
      },
    ),
  );
  try {
    await normalized.customSelect('SELECT 1').get();
    for (final table in <TableInfo<Table, dynamic>>[
      normalized.profiles,
      normalized.pills,
      normalized.schedules,
      normalized.doseLogs,
    ]) {
      // Only this disposable encrypted copy gains the four inline declarations.
      // ignore: experimental_member_use
      await normalized.createMigrator().alterTable(TableMigration(table));
    }
    await normalized.validateDatabaseSchema();
  } finally {
    await normalized.close();
    await copy.delete();
  }
}

class _VerificationDatabase extends AppDatabase {
  _VerificationDatabase(super.executor);
}
