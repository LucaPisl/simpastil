import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'database_migration_v1_test.dart' show seedShippedV1;

/// The shipped build left `users` empty while profiles carried the server
/// account UUID. Schema 15 repairs that: the owner keeps its id and gets an
/// unresolved connected workspace that must pass original-server review.
void main() {
  Future<List<Map<String, Object?>>> workspaces(AppDatabase db) async => [
    for (final row
        in await db
            .customSelect(
              'SELECT * FROM care_workspaces ORDER BY owner_user_id',
            )
            .get())
      row.data,
  ];

  test('the shipped empty users table gains an unresolved workspace', () async {
    final db = AppDatabase(
      NativeDatabase.memory(
        setup: (database) => seedShippedV1(database, seedUsers: false),
      ),
    );
    addTearDown(db.close);

    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(
      version.read<int>('user_version'),
      AppDatabase.supportedSchemaVersion,
    );
    final owner = await db.usersDao.getById('user-1');
    expect(owner, isNotNull);
    expect(owner!.serverId, 'user-1');

    final rows = await workspaces(db);
    expect(rows, hasLength(1));
    expect(rows.single['owner_user_id'], 'user-1');
    expect(rows.single['kind'], 'connected');
    expect(rows.single['binding_state'], 'unresolved');
    expect(rows.single['endpoint'], isNull);
    expect(rows.single['current_author_id'], isNull);
    expect(rows.single['legacy_viewer_migrated'], 0);
    final grants = await db
        .customSelect('SELECT is_granted FROM workspace_grants')
        .get();
    expect(grants.single.read<int>('is_granted'), 0);

    // Owner ids and the retained care are intact.
    expect((await db.profilesDao.getById('profile-1'))?.userId, 'user-1');
    expect((await db.pillsDao.getById('pill-1'))?.name, 'Alpha');
    expect(await db.doseLogsDao.getByScheduleId('schedule-1'), hasLength(1));
  });

  test(
    'a store already at schema 14 receives the repair on the next open',
    () async {
      final dir = await Directory.systemTemp.createTemp('orphan-owner');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/care.db');

      // Current-shape store as the 14 build left it: care, but no users row
      // and no workspace for the account.
      var db = AppDatabase(NativeDatabase(file));
      await db.customSelect('SELECT 1').get();
      await db.close();
      final raw = sqlite.sqlite3.open(file.path);
      raw.execute('PRAGMA foreign_keys = OFF');
      raw.execute(
        "INSERT INTO profiles (id, user_id, name, created_at, updated_at) VALUES ('p-1','acct-1','Fictional',1760000000,1760000000)",
      );
      raw.execute(
        "INSERT INTO profiles (id, user_id, name, created_at, updated_at) VALUES ('p-2','acct-2','Fictional two',1760000000,1760000000)",
      );
      raw.execute('PRAGMA user_version = 14');
      raw.close();

      db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);
      final rows = await workspaces(db);
      expect({
        for (final r in rows) r['owner_user_id'],
      }, containsAll(['acct-1', 'acct-2']));
      for (final id in ['acct-1', 'acct-2']) {
        final row = rows.singleWhere((r) => r['owner_user_id'] == id);
        expect(row['binding_state'], 'unresolved');
        expect(await db.usersDao.getById(id), isNotNull);
      }
      expect((await db.profilesDao.getById('p-1'))?.userId, 'acct-1');
      expect((await db.profilesDao.getById('p-2'))?.userId, 'acct-2');
    },
  );

  test('is idempotent and leaves existing workspaces alone', () async {
    final dir = await Directory.systemTemp.createTemp('orphan-owner-twice');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/care.db');
    var db = AppDatabase(
      NativeDatabase(file, setup: (d) => seedShippedV1(d, seedUsers: false)),
    );
    final first = await workspaces(db);
    expect(first, hasLength(1));
    // A local standalone workspace is created at first launch; it is never
    // treated as an orphan.
    await db.close();

    for (var i = 0; i < 2; i++) {
      final raw = sqlite.sqlite3.open(file.path);
      raw.execute('PRAGMA user_version = 14');
      raw.close();
      db = AppDatabase(NativeDatabase(file));
      expect(await workspaces(db), first);
      await db.close();
    }
  });

  test('retained rows make an owner populated without a users row', () async {
    final db = AppDatabase.forTesting();
    addTearDown(db.close);
    expect(await db.ownerHasRetainedRows('nobody'), isFalse);
    await db.customStatement('PRAGMA foreign_keys = OFF');
    await db.customInsert(
      "INSERT INTO profiles (id, user_id, name, created_at, updated_at) VALUES ('p-9','acct-9','Fictional',1760000000,1760000000)",
      variables: const <Variable<Object>>[],
    );
    expect(await db.ownerHasRetainedRows('acct-9'), isTrue);
    expect(await db.ownerHasRetainedRows('acct-8'), isFalse);
  });
}
