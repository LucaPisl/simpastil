import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:sqlite3/sqlite3.dart';

/// Schema v1 as shipped (initial commit): no stock/PRN columns on pills, no
/// `note` or `updated_at` on dose_logs, no revision/session columns.
///
/// The shipped build never wrote the `users` table although profiles carried the
/// server account UUID; pass `seedUsers: false` for that faithful shape.
void seedShippedV1(Database database, {bool seedUsers = true}) {
  database.execute('PRAGMA foreign_keys = ON');
  database.execute(
    r'''CREATE TABLE "users" ("id" TEXT NOT NULL, "email" TEXT NOT NULL, "created_at" INTEGER NOT NULL, "updated_at" INTEGER NOT NULL, "server_id" TEXT NULL, "sync_status" TEXT NOT NULL DEFAULT 'pending', "last_sync_at" INTEGER NULL, "is_deleted" INTEGER NOT NULL DEFAULT 0 CHECK ("is_deleted" IN (0, 1)), PRIMARY KEY ("id"))''',
  );
  database.execute(
    r'''CREATE TABLE "refresh_tokens" ("id" TEXT NOT NULL, "user_id" TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE, "family_id" TEXT NOT NULL, "expires_at" INTEGER NOT NULL, "revoked" INTEGER NOT NULL DEFAULT 0 CHECK ("revoked" IN (0, 1)), "created_at" INTEGER NOT NULL, "server_id" TEXT NULL, "sync_status" TEXT NOT NULL DEFAULT 'pending', "last_sync_at" INTEGER NULL, "is_deleted" INTEGER NOT NULL DEFAULT 0 CHECK ("is_deleted" IN (0, 1)), PRIMARY KEY ("id"))''',
  );
  database.execute(
    r'''CREATE TABLE "profiles" ("id" TEXT NOT NULL, "user_id" TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE, "name" TEXT NOT NULL, "avatar_emoji" TEXT NOT NULL DEFAULT '👤', "is_active" INTEGER NOT NULL DEFAULT 1 CHECK ("is_active" IN (0, 1)), "created_at" INTEGER NOT NULL, "updated_at" INTEGER NOT NULL, "server_id" TEXT NULL, "sync_status" TEXT NOT NULL DEFAULT 'pending', "last_sync_at" INTEGER NULL, "is_deleted" INTEGER NOT NULL DEFAULT 0 CHECK ("is_deleted" IN (0, 1)), PRIMARY KEY ("id"))''',
  );
  database.execute(
    r'''CREATE TABLE "pills" ("id" TEXT NOT NULL, "profile_id" TEXT NOT NULL REFERENCES profiles (id) ON DELETE CASCADE, "name" TEXT NOT NULL, "dosage" TEXT NULL, "notes" TEXT NULL, "color" TEXT NULL, "created_at" INTEGER NOT NULL, "updated_at" INTEGER NOT NULL, "server_id" TEXT NULL, "sync_status" TEXT NOT NULL DEFAULT 'pending', "last_sync_at" INTEGER NULL, "is_deleted" INTEGER NOT NULL DEFAULT 0 CHECK ("is_deleted" IN (0, 1)), PRIMARY KEY ("id"))''',
  );
  database.execute(
    r'''CREATE TABLE "schedules" ("id" TEXT NOT NULL, "pill_id" TEXT NOT NULL REFERENCES pills (id) ON DELETE CASCADE, "hour" INTEGER NOT NULL, "minute" INTEGER NOT NULL, "frequency" TEXT NOT NULL, "frequency_days" TEXT NULL, "is_active" INTEGER NOT NULL DEFAULT 1 CHECK ("is_active" IN (0, 1)), "created_at" INTEGER NOT NULL, "updated_at" INTEGER NOT NULL, "server_id" TEXT NULL, "sync_status" TEXT NOT NULL DEFAULT 'pending', "last_sync_at" INTEGER NULL, "is_deleted" INTEGER NOT NULL DEFAULT 0 CHECK ("is_deleted" IN (0, 1)), PRIMARY KEY ("id"))''',
  );
  database.execute(
    r'''CREATE TABLE "dose_logs" ("id" TEXT NOT NULL, "schedule_id" TEXT NOT NULL REFERENCES schedules (id) ON DELETE CASCADE, "scheduled_at" INTEGER NOT NULL, "taken_at" INTEGER NULL, "status" TEXT NOT NULL, "created_at" INTEGER NOT NULL, "server_id" TEXT NULL, "sync_status" TEXT NOT NULL DEFAULT 'pending', "last_sync_at" INTEGER NULL, "is_deleted" INTEGER NOT NULL DEFAULT 0 CHECK ("is_deleted" IN (0, 1)), PRIMARY KEY ("id"))''',
  );
  const ts = 1760000000;
  if (seedUsers) {
    database.execute(
      "INSERT INTO users (id, email, created_at, updated_at, sync_status) VALUES ('user-1', 'u@example.test', $ts, $ts, 'synced')",
    );
  }
  if (!seedUsers) database.execute('PRAGMA foreign_keys = OFF');
  database.execute(
    "INSERT INTO profiles (id, user_id, name, created_at, updated_at, sync_status) VALUES ('profile-1', 'user-1', 'Test', $ts, $ts, 'synced')",
  );
  database.execute(
    "INSERT INTO pills (id, profile_id, name, dosage, created_at, updated_at, sync_status) VALUES ('pill-1', 'profile-1', 'Alpha', '5mg', $ts, $ts, 'synced'), ('pill-2', 'profile-1', 'Beta', NULL, $ts, $ts, 'synced')",
  );
  database.execute(
    "INSERT INTO schedules (id, pill_id, hour, minute, frequency, created_at, updated_at, sync_status) VALUES ('schedule-1', 'pill-1', 8, 0, 'daily', $ts, $ts, 'synced'), ('schedule-2', 'pill-2', 20, 30, 'daily', $ts, $ts, 'synced')",
  );
  database.execute(
    "INSERT INTO dose_logs (id, schedule_id, scheduled_at, taken_at, status, created_at, sync_status) VALUES ('dose-1', 'schedule-1', $ts, ${ts + 60}, 'taken', ${ts + 30}, 'synced')",
  );
  database.execute('PRAGMA user_version = 1');
}

void main() {
  test('schema v1 database with a taken dose migrates to current', () async {
    final db = AppDatabase(NativeDatabase.memory(setup: seedShippedV1));
    addTearDown(db.close);

    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(
      version.read<int>('user_version'),
      AppDatabase.supportedSchemaVersion,
    );

    expect(await db.profilesDao.getById('profile-1'), isNotNull);
    expect((await db.pillsDao.getById('pill-1'))?.name, 'Alpha');
    expect((await db.pillsDao.getById('pill-2'))?.name, 'Beta');
    expect(
      await db.customSelect('SELECT id FROM schedules').get(),
      hasLength(2),
    );

    final logs = await db.doseLogsDao.getByScheduleId('schedule-1');
    expect(logs, hasLength(1));
    final dose = logs.single;
    expect(dose.status, 'taken');
    expect(
      dose.takenAt,
      DateTime.fromMillisecondsSinceEpoch(1760000060 * 1000),
    );
    expect(dose.note, isNull);
    expect(dose.updatedAt, dose.createdAt);
  });
}
