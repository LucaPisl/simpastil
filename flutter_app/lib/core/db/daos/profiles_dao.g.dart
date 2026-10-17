// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'profiles_dao.dart';

// ignore_for_file: type=lint
mixin _$ProfilesDaoMixin on DatabaseAccessor<AppDatabase> {
  $UsersTable get users => attachedDatabase.users;
  $ProfilesTable get profiles => attachedDatabase.profiles;
  ProfilesDaoManager get managers => ProfilesDaoManager(this);
}

class ProfilesDaoManager {
  final _$ProfilesDaoMixin _db;
  ProfilesDaoManager(this._db);
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db.attachedDatabase, _db.users);
  $$ProfilesTableTableManager get profiles =>
      $$ProfilesTableTableManager(_db.attachedDatabase, _db.profiles);
}
