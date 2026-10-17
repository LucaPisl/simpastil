// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'pills_dao.dart';

// ignore_for_file: type=lint
mixin _$PillsDaoMixin on DatabaseAccessor<AppDatabase> {
  $UsersTable get users => attachedDatabase.users;
  $ProfilesTable get profiles => attachedDatabase.profiles;
  $PillsTable get pills => attachedDatabase.pills;
  PillsDaoManager get managers => PillsDaoManager(this);
}

class PillsDaoManager {
  final _$PillsDaoMixin _db;
  PillsDaoManager(this._db);
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db.attachedDatabase, _db.users);
  $$ProfilesTableTableManager get profiles =>
      $$ProfilesTableTableManager(_db.attachedDatabase, _db.profiles);
  $$PillsTableTableManager get pills =>
      $$PillsTableTableManager(_db.attachedDatabase, _db.pills);
}
