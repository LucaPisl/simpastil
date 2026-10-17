// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'migration_issues_dao.dart';

// ignore_for_file: type=lint
mixin _$MigrationIssuesDaoMixin on DatabaseAccessor<AppDatabase> {
  $UsersTable get users => attachedDatabase.users;
  $MigrationIssuesTable get migrationIssues => attachedDatabase.migrationIssues;
  MigrationIssuesDaoManager get managers => MigrationIssuesDaoManager(this);
}

class MigrationIssuesDaoManager {
  final _$MigrationIssuesDaoMixin _db;
  MigrationIssuesDaoManager(this._db);
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db.attachedDatabase, _db.users);
  $$MigrationIssuesTableTableManager get migrationIssues =>
      $$MigrationIssuesTableTableManager(
        _db.attachedDatabase,
        _db.migrationIssues,
      );
}
