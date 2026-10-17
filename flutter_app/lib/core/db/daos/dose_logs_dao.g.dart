// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'dose_logs_dao.dart';

// ignore_for_file: type=lint
mixin _$DoseLogsDaoMixin on DatabaseAccessor<AppDatabase> {
  $UsersTable get users => attachedDatabase.users;
  $ProfilesTable get profiles => attachedDatabase.profiles;
  $PillsTable get pills => attachedDatabase.pills;
  $SchedulesTable get schedules => attachedDatabase.schedules;
  $DoseLogsTable get doseLogs => attachedDatabase.doseLogs;
  DoseLogsDaoManager get managers => DoseLogsDaoManager(this);
}

class DoseLogsDaoManager {
  final _$DoseLogsDaoMixin _db;
  DoseLogsDaoManager(this._db);
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db.attachedDatabase, _db.users);
  $$ProfilesTableTableManager get profiles =>
      $$ProfilesTableTableManager(_db.attachedDatabase, _db.profiles);
  $$PillsTableTableManager get pills =>
      $$PillsTableTableManager(_db.attachedDatabase, _db.pills);
  $$SchedulesTableTableManager get schedules =>
      $$SchedulesTableTableManager(_db.attachedDatabase, _db.schedules);
  $$DoseLogsTableTableManager get doseLogs =>
      $$DoseLogsTableTableManager(_db.attachedDatabase, _db.doseLogs);
}
