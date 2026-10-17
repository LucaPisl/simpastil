import 'package:drift/drift.dart';

/// Local mirror of the server `users` table.
///
/// Note: [passwordHash] is intentionally omitted — passwords are never stored
/// on the client. Only the user's identity fields are cached locally.
@DataClassName('User')
class Users extends Table {
  @override
  String get tableName => 'users';

  TextColumn get id => text()();
  TextColumn get email => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get sessionGeneration => integer().withDefault(const Constant(0))();

  // ── Sync metadata ─────────────────────────────────────────────────────────
  TextColumn get serverId => text().nullable()();
  TextColumn get syncStatus => text().withDefault(const Constant('pending'))();
  IntColumn get lastSyncAt => integer().nullable()();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
