// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'schedules_dao.dart';

// ignore_for_file: type=lint
mixin _$SchedulesDaoMixin on DatabaseAccessor<AppDatabase> {
  $UsersTable get users => attachedDatabase.users;
  $ProfilesTable get profiles => attachedDatabase.profiles;
  $PillsTable get pills => attachedDatabase.pills;
  $SchedulesTable get schedules => attachedDatabase.schedules;
  SchedulesDaoManager get managers => SchedulesDaoManager(this);
}

class SchedulesDaoManager {
  final _$SchedulesDaoMixin _db;
  SchedulesDaoManager(this._db);
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db.attachedDatabase, _db.users);
  $$ProfilesTableTableManager get profiles =>
      $$ProfilesTableTableManager(_db.attachedDatabase, _db.profiles);
  $$PillsTableTableManager get pills =>
      $$PillsTableTableManager(_db.attachedDatabase, _db.pills);
  $$SchedulesTableTableManager get schedules =>
      $$SchedulesTableTableManager(_db.attachedDatabase, _db.schedules);
}
