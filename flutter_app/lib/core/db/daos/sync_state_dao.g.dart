// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'sync_state_dao.dart';

// ignore_for_file: type=lint
mixin _$SyncStateDaoMixin on DatabaseAccessor<AppDatabase> {
  $UsersTable get users => attachedDatabase.users;
  $SyncComponentStatesTable get syncComponentStates =>
      attachedDatabase.syncComponentStates;
  $SyncStagingRunsTable get syncStagingRuns => attachedDatabase.syncStagingRuns;
  $SyncStagingItemsTable get syncStagingItems =>
      attachedDatabase.syncStagingItems;
  SyncStateDaoManager get managers => SyncStateDaoManager(this);
}

class SyncStateDaoManager {
  final _$SyncStateDaoMixin _db;
  SyncStateDaoManager(this._db);
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db.attachedDatabase, _db.users);
  $$SyncComponentStatesTableTableManager get syncComponentStates =>
      $$SyncComponentStatesTableTableManager(
        _db.attachedDatabase,
        _db.syncComponentStates,
      );
  $$SyncStagingRunsTableTableManager get syncStagingRuns =>
      $$SyncStagingRunsTableTableManager(
        _db.attachedDatabase,
        _db.syncStagingRuns,
      );
  $$SyncStagingItemsTableTableManager get syncStagingItems =>
      $$SyncStagingItemsTableTableManager(
        _db.attachedDatabase,
        _db.syncStagingItems,
      );
}
