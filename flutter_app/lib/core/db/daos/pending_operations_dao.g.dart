// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'pending_operations_dao.dart';

// ignore_for_file: type=lint
mixin _$PendingOperationsDaoMixin on DatabaseAccessor<AppDatabase> {
  $UsersTable get users => attachedDatabase.users;
  $PendingOperationsTable get pendingOperations =>
      attachedDatabase.pendingOperations;
  $PendingOperationEffectsTable get pendingOperationEffects =>
      attachedDatabase.pendingOperationEffects;
  PendingOperationsDaoManager get managers => PendingOperationsDaoManager(this);
}

class PendingOperationsDaoManager {
  final _$PendingOperationsDaoMixin _db;
  PendingOperationsDaoManager(this._db);
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db.attachedDatabase, _db.users);
  $$PendingOperationsTableTableManager get pendingOperations =>
      $$PendingOperationsTableTableManager(
        _db.attachedDatabase,
        _db.pendingOperations,
      );
  $$PendingOperationEffectsTableTableManager get pendingOperationEffects =>
      $$PendingOperationEffectsTableTableManager(
        _db.attachedDatabase,
        _db.pendingOperationEffects,
      );
}
