import 'package:drift/drift.dart';

import 'users_table.dart';

/// The last value the server holds for each setting that follows the account,
/// with the revision it holds it at. It is the base a local edit is sent
/// against; the value itself is also written into the store the app reads
/// (a preference or a reminder row), so no reader changes. A null value is a
/// cleared key. Device-local: never part of a backup.
class AccountSettingValues extends Table {
  TextColumn get userId =>
      text().references(Users, #id, onDelete: KeyAction.cascade)();
  TextColumn get settingKey => text().named('key')();
  TextColumn get valueJson => text().nullable()();
  IntColumn get revision => integer()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {userId, settingKey};
}

/// A local edit waiting to be sent. One row per key, so a newer edit replaces
/// an older unsent one. A null value clears the key. [ifAbsent] marks the
/// first-sync snapshot, which only fills keys the account has never held.
class PendingAccountSettings extends Table {
  TextColumn get userId =>
      text().references(Users, #id, onDelete: KeyAction.cascade)();
  TextColumn get settingKey => text().named('key')();
  TextColumn get valueJson => text().nullable()();
  IntColumn get baseRevision => integer()();
  BoolColumn get ifAbsent => boolean().withDefault(const Constant(false))();
  DateTimeColumn get queuedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {userId, settingKey};
}
