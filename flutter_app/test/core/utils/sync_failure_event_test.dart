import 'package:drift/drift.dart';
import 'package:drift/isolate.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/utils/safe_diagnostics.dart';

QueryExecutor _openMemory() => NativeDatabase.memory();

void main() {
  test('a SQLite error from the database isolate keeps its category and '
      'codes', () async {
    final isolate = await DriftIsolate.spawn(_openMemory);
    final connection = await isolate.connect(singleClientMode: true);
    final database = _Db(connection);
    addTearDown(database.close);
    await database.customStatement('CREATE TABLE t (a INTEGER CHECK (a > 0))');
    Object? caught;
    try {
      await database.customStatement('INSERT INTO t VALUES (-1)');
    } catch (error) {
      caught = error;
    }
    expect(caught, isA<DriftRemoteException>());
    final event = SafeDiagnostics.syncFailureEvent(
      component: 'medication',
      phase: SyncFailurePhase.mergeApply,
      error: caught!,
    );
    expect(event['category'], 'sqlite');
    expect(event['sqliteCode'], 19);
    expect(event['sqliteExtendedCode'], 275);
    expect(event.values.join(), isNot(contains('CHECK')));
  });
}

class _Db extends GeneratedDatabase {
  _Db(super.executor);

  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => const [];

  @override
  Iterable<DatabaseSchemaEntity> get allSchemaEntities => const [];

  @override
  int get schemaVersion => 1;
}
