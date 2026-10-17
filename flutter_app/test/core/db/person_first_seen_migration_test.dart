import 'dart:io';

import 'package:drift/drift.dart' show Value, Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'database_migration_v1_test.dart' show seedShippedV1;

/// Schema 16 records, per person, when THIS PHONE first knew them. The stamp is
/// device-local and written by a trigger, so every insert path is covered.
void main() {
  const knownCreatedAt = 1760000000;

  Future<void> addOwner(AppDatabase db, String id) => db.usersDao.upsert(
    UsersCompanion.insert(
      id: id,
      email: '$id@example.test',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    ),
  );

  Future<void> addProfile(
    AppDatabase db,
    String id, {
    String owner = 'owner-1',
    String name = 'Fictional person',
    DateTime? createdAt,
  }) => db.profilesDao.upsert(
    ProfilesCompanion.insert(
      id: id,
      userId: owner,
      name: name,
      createdAt: createdAt ?? DateTime.now(),
      updatedAt: createdAt ?? DateTime.now(),
    ),
  );

  Future<List<Map<String, Object?>>> stamps(AppDatabase db) async => [
    for (final row
        in await db
            .customSelect(
              'SELECT profile_id, first_seen_at FROM person_first_seen '
              'ORDER BY profile_id',
            )
            .get())
      row.data,
  ];

  Future<int> userVersion(AppDatabase db) async =>
      (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
        'user_version',
      );

  Future<Set<String>> schemaObjects(AppDatabase db, String type) async => {
    for (final row
        in await db
            .customSelect(
              'SELECT name FROM sqlite_master WHERE type = ?',
              variables: [Variable.withString(type)],
            )
            .get())
      row.read<String>('name'),
  };

  int nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  group('fresh database', () {
    late AppDatabase db;
    setUp(() async {
      db = AppDatabase.forTesting();
      addTearDown(db.close);
      await addOwner(db, 'owner-1');
    });

    test('creates the table and trigger at the current version', () async {
      expect(AppDatabase.supportedSchemaVersion, 18);
      expect(await userVersion(db), 18);
      expect(await schemaObjects(db, 'table'), contains('person_first_seen'));
      expect(await schemaObjects(db, 'trigger'), {'profiles_first_seen'});
    });

    test('stamps a newly inserted profile with the current time', () async {
      final before = nowSeconds();
      // A profile created long ago elsewhere is still first seen "now" here.
      await addProfile(db, 'p-1', createdAt: DateTime.utc(2020, 1, 1));
      final after = nowSeconds();

      final rows = await stamps(db);
      expect(rows, hasLength(1));
      expect(rows.single['profile_id'], 'p-1');
      expect(
        rows.single['first_seen_at'] as int,
        inInclusiveRange(before, after),
      );
      final typed = await db.select(db.personFirstSeen).getSingle();
      expect(
        typed.firstSeenAt.millisecondsSinceEpoch ~/ 1000,
        rows.single['first_seen_at'],
      );
    });

    test('an update or a sync-style upsert never re-stamps', () async {
      await addProfile(db, 'p-1');
      // Pin the stamp to a known value so any rewrite is detectable.
      await db.customStatement(
        'UPDATE person_first_seen SET first_seen_at = $knownCreatedAt',
      );

      await (db.update(db.profiles)..where((t) => t.id.equals('p-1'))).write(
        const ProfilesCompanion(name: Value('Renamed')),
      );
      expect((await stamps(db)).single['first_seen_at'], knownCreatedAt);

      // ProfilesDao.upsert (insertOnConflictUpdate) is what the sync merger
      // uses; it takes the DO UPDATE path of an existing row.
      await addProfile(db, 'p-1', name: 'Merged from server');
      expect((await db.profilesDao.getById('p-1'))?.name, 'Merged from server');
      expect((await stamps(db)).single['first_seen_at'], knownCreatedAt);

      // A raw upsert and an ignored insert behave the same way.
      await db.customStatement(
        "INSERT INTO profiles (id, user_id, name, created_at, updated_at) "
        "VALUES ('p-1', 'owner-1', 'Again', 1, 1) "
        "ON CONFLICT(id) DO UPDATE SET name = excluded.name",
      );
      await db.customStatement(
        "INSERT OR IGNORE INTO profiles (id, user_id, name, created_at, updated_at) "
        "VALUES ('p-1', 'owner-1', 'Ignored', 1, 1)",
      );
      expect((await stamps(db)).single['first_seen_at'], knownCreatedAt);
    });

    test('a second profile gets its own stamp', () async {
      await addProfile(db, 'p-1');
      await addProfile(db, 'p-2');
      expect((await stamps(db)).map((r) => r['profile_id']), ['p-1', 'p-2']);
    });

    test('deleting the profile cascades when foreign keys are enforced', () async {
      // The app never enables foreign keys itself, so the declared cascade only
      // applies where the SQLite build enforces them; clearAllUserData deletes
      // explicitly. A leftover stamp is harmless: reads inner-join profiles.
      await db.customStatement('PRAGMA foreign_keys = ON');
      await addProfile(db, 'p-1');
      await addProfile(db, 'p-2');
      await (db.delete(db.profiles)..where((t) => t.id.equals('p-1'))).go();
      expect((await stamps(db)).map((r) => r['profile_id']), ['p-2']);
    });

    test('clearAllUserData removes the stamps of that user only', () async {
      await addOwner(db, 'owner-2');
      await addProfile(db, 'p-1');
      await addProfile(db, 'p-2', owner: 'owner-2');
      await db.clearAllUserData('owner-1');
      expect((await stamps(db)).map((r) => r['profile_id']), ['p-2']);
    });
  });

  group('upgrade from schema 15 and 14', () {
    late Directory dir;
    late File file;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('person-first-seen');
      addTearDown(() => dir.delete(recursive: true));
      file = File('${dir.path}/care.db');
    });

    /// Builds a current-shape store, then rewinds it to what [version] left:
    /// no table, no trigger, one known profile.
    Future<void> rewind(int version) async {
      final db = AppDatabase(NativeDatabase(file));
      await addOwner(db, 'owner-1');
      await db.customSelect('SELECT 1').get();
      await db.close();
      final raw = sqlite.sqlite3.open(file.path);
      raw.execute('DROP TRIGGER profiles_first_seen');
      raw.execute('DROP TABLE person_first_seen');
      raw.execute(
        "INSERT INTO profiles (id, user_id, name, created_at, updated_at) "
        "VALUES ('p-old', 'owner-1', 'Fictional old', $knownCreatedAt, $knownCreatedAt)",
      );
      raw.execute('PRAGMA user_version = $version');
      raw.close();
    }

    for (final version in [15, 14]) {
      test(
        'schema $version backfills created_at and arms the trigger',
        () async {
          await rewind(version);
          final db = AppDatabase(NativeDatabase(file));
          addTearDown(db.close);

          expect(await userVersion(db), 18);
          expect(
            await schemaObjects(db, 'table'),
            contains('person_first_seen'),
          );
          expect(await schemaObjects(db, 'trigger'), {'profiles_first_seen'});
          expect(await stamps(db), [
            {'profile_id': 'p-old', 'first_seen_at': knownCreatedAt},
          ]);

          final before = nowSeconds();
          await addProfile(db, 'p-new');
          final rows = await stamps(db);
          expect(rows.map((r) => r['profile_id']), ['p-new', 'p-old']);
          expect(
            rows.first['first_seen_at'] as int,
            greaterThanOrEqualTo(before),
          );
          expect(rows.last['first_seen_at'], knownCreatedAt);
        },
      );
    }

    test('re-running the step on a current-shape store is harmless', () async {
      var db = AppDatabase(NativeDatabase(file));
      await addOwner(db, 'owner-1');
      await addProfile(db, 'p-1');
      await db.customStatement(
        'UPDATE person_first_seen SET first_seen_at = $knownCreatedAt',
      );
      await db.close();
      final raw = sqlite.sqlite3.open(file.path);
      raw.execute('PRAGMA user_version = 15');
      raw.close();

      db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);
      expect(await userVersion(db), 18);
      expect((await stamps(db)).single['first_seen_at'], knownCreatedAt);
    });
  });

  group('upgrade from the shipped v1 store', () {
    for (final seedUsers in [true, false]) {
      test('backfills profile-1 (seedUsers: $seedUsers)', () async {
        final db = AppDatabase(
          NativeDatabase.memory(
            setup: (d) => seedShippedV1(d, seedUsers: seedUsers),
          ),
        );
        addTearDown(db.close);

        expect(await userVersion(db), 18);
        expect(await stamps(db), [
          {'profile_id': 'profile-1', 'first_seen_at': knownCreatedAt},
        ]);
        expect(await schemaObjects(db, 'trigger'), {'profiles_first_seen'});
      });
    }
  });
}
