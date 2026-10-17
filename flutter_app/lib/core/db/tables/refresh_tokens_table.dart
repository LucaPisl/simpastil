import 'package:drift/drift.dart';

import 'users_table.dart';

/// Minimal client-side mirror of the server `refresh_tokens` table.
///
/// The actual refresh token string is stored in [TokenService] via
/// flutter_secure_storage — NOT here. This table is used only to track
/// session metadata (expiry, revocation) for multi-device sync awareness.
@DataClassName('RefreshToken')
class RefreshTokens extends Table {
  @override
  String get tableName => 'refresh_tokens';

  TextColumn get id => text()();
  TextColumn get userId =>
      text().references(Users, #id, onDelete: KeyAction.cascade)();
  TextColumn get familyId => text()();
  DateTimeColumn get expiresAt => dateTime()();
  BoolColumn get revoked => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();

  // ── Sync metadata ─────────────────────────────────────────────────────────
  TextColumn get serverId => text().nullable()();
  TextColumn get syncStatus => text().withDefault(const Constant('pending'))();
  IntColumn get lastSyncAt => integer().nullable()();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
