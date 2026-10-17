import 'package:sqlite3/sqlite3.dart';

/// Full v3 schema from 8ada146; v4 adds revision/session fields and unique server identities.
/// Generated SQLite DDL spelling is normalized; constraints retain v3 semantics.
void seedLegacyV3(Database database) {
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
    r'''CREATE TABLE "pills" ("id" TEXT NOT NULL, "profile_id" TEXT NOT NULL REFERENCES profiles (id) ON DELETE CASCADE, "name" TEXT NOT NULL, "dosage" TEXT NULL, "notes" TEXT NULL, "color" TEXT NULL, "current_stock" INTEGER NULL, "low_stock_threshold" INTEGER NULL, "is_prn" INTEGER NOT NULL DEFAULT 0 CHECK ("is_prn" IN (0, 1)), "created_at" INTEGER NOT NULL, "updated_at" INTEGER NOT NULL, "server_id" TEXT NULL, "sync_status" TEXT NOT NULL DEFAULT 'pending', "last_sync_at" INTEGER NULL, "is_deleted" INTEGER NOT NULL DEFAULT 0 CHECK ("is_deleted" IN (0, 1)), PRIMARY KEY ("id"))''',
  );
  database.execute(
    r'''CREATE TABLE "schedules" ("id" TEXT NOT NULL, "pill_id" TEXT NOT NULL REFERENCES pills (id) ON DELETE CASCADE, "hour" INTEGER NOT NULL, "minute" INTEGER NOT NULL, "frequency" TEXT NOT NULL, "frequency_days" TEXT NULL, "is_active" INTEGER NOT NULL DEFAULT 1 CHECK ("is_active" IN (0, 1)), "created_at" INTEGER NOT NULL, "updated_at" INTEGER NOT NULL, "server_id" TEXT NULL, "sync_status" TEXT NOT NULL DEFAULT 'pending', "last_sync_at" INTEGER NULL, "is_deleted" INTEGER NOT NULL DEFAULT 0 CHECK ("is_deleted" IN (0, 1)), PRIMARY KEY ("id"))''',
  );
  database.execute(
    r'''CREATE TABLE "dose_logs" ("id" TEXT NOT NULL, "schedule_id" TEXT NOT NULL REFERENCES schedules (id) ON DELETE CASCADE, "scheduled_at" INTEGER NOT NULL, "taken_at" INTEGER NULL, "status" TEXT NOT NULL, "note" TEXT NULL, "created_at" INTEGER NOT NULL, "updated_at" INTEGER NOT NULL, "server_id" TEXT NULL, "sync_status" TEXT NOT NULL DEFAULT 'pending', "last_sync_at" INTEGER NULL, "is_deleted" INTEGER NOT NULL DEFAULT 0 CHECK ("is_deleted" IN (0, 1)), PRIMARY KEY ("id"))''',
  );
  const timestamp = 1760000000000;
  database.execute(
    "INSERT INTO users (id, email, created_at, updated_at, sync_status) VALUES ('user-1', 'u@example.test', $timestamp, $timestamp, 'synced')",
  );
  database.execute(
    "INSERT INTO profiles (id, user_id, name, created_at, updated_at, sync_status) VALUES ('profile-1', 'user-1', 'Test', $timestamp, $timestamp, 'synced')",
  );
  database.execute(
    "INSERT INTO pills (id, profile_id, name, is_prn, current_stock, created_at, updated_at, sync_status) VALUES ('pill-1', 'profile-1', 'Medication', 1, 10, $timestamp, $timestamp, 'pending')",
  );
  database.execute(
    "INSERT INTO schedules (id, pill_id, hour, minute, frequency, created_at, updated_at, sync_status) VALUES ('schedule-1', 'pill-1', 8, 0, 'daily', $timestamp, $timestamp, 'synced')",
  );
  database.execute(
    "INSERT INTO dose_logs (id, schedule_id, scheduled_at, taken_at, status, created_at, updated_at, sync_status) VALUES ('dose-1', 'schedule-1', $timestamp, $timestamp, 'taken', $timestamp, $timestamp, 'pending')",
  );
  database.execute(
    "INSERT INTO dose_logs (id, schedule_id, scheduled_at, taken_at, status, created_at, updated_at, sync_status) VALUES ('dose-2', 'schedule-1', $timestamp, $timestamp, 'taken', $timestamp, $timestamp, 'pending')",
  );
  database.execute('PRAGMA user_version = 3');
}
