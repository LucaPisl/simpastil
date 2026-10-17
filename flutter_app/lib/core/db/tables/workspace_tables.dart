// Drift checks intentionally refer to their own column getters.
// ignore_for_file: recursive_getters

import 'package:drift/drift.dart';

import 'profiles_table.dart';
import 'users_table.dart';

@DataClassName('CareWorkspace')
class CareWorkspaces extends Table {
  TextColumn get id => text()();
  TextColumn get ownerUserId => text().unique().references(Users, #id)();
  TextColumn get kind =>
      text().check(kind.isIn(const ['local', 'connected']))();
  TextColumn get singletonKey => text().nullable().unique()();
  TextColumn get bindingState =>
      text().check(bindingState.isIn(const ['local', 'unresolved', 'bound']))();
  TextColumn get endpoint => text().nullable()();
  TextColumn get legacyEndpointHint => text().nullable()();
  TextColumn get currentAuthorId => text().nullable()();
  TextColumn get selectedProfileId => text().nullable()();
  BoolColumn get viewEveryone => boolean().withDefault(const Constant(false))();
  BoolColumn get legacyViewerMigrated =>
      boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('WorkspaceAuthor')
class WorkspaceAuthors extends Table {
  TextColumn get id => text()();
  TextColumn get workspaceId => text().references(CareWorkspaces, #id)();
  TextColumn get displayName => text().nullable()();
  TextColumn get provenance =>
      text().check(provenance.isIn(const ['workspace', 'imported']))();
  DateTimeColumn get createdAt => dateTime()();
  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('WorkspaceGrant')
class WorkspaceGrants extends Table {
  TextColumn get workspaceId => text().references(CareWorkspaces, #id)();
  IntColumn get epoch => integer()
      .withDefault(const Constant(1))
      .check(epoch.isBiggerOrEqualValue(1))();
  BoolColumn get isGranted => boolean().withDefault(const Constant(false))();
  IntColumn get sessionGeneration => integer().nullable()();
  IntColumn get networkEpoch => integer().nullable()();
  TextColumn get endpoint => text().nullable()();
  @override
  Set<Column<Object>> get primaryKey => {workspaceId};
}

@DataClassName('DevicePersonReminder')
class DevicePersonReminders extends Table {
  TextColumn get profileId =>
      text().references(Profiles, #id, onDelete: KeyAction.cascade)();
  BoolColumn get enabled => boolean().withDefault(const Constant(false))();
  @override
  Set<Column<Object>> get primaryKey => {profileId};
}

/// Device access state is protected and authoritative across isolates. It is
/// deliberately distinct from care, human authorship and network credentials.
@DataClassName('WorkspaceDeviceState')
class WorkspaceDeviceStates extends Table {
  TextColumn get id => text().check(id.equals('device'))();
  TextColumn get selectedWorkspaceId =>
      text().nullable().references(CareWorkspaces, #id)();
  IntColumn get networkEpoch => integer()
      .withDefault(const Constant(0))
      .check(networkEpoch.isBiggerOrEqualValue(0))();
  TextColumn get networkOwnerId => text().nullable()();
  TextColumn get networkEndpoint => text().nullable()();
  IntColumn get networkGeneration => integer().nullable()();
  TextColumn get networkCredentialId =>
      text().nullable().references(CredentialSlots, #id)();
  TextColumn get configuredEndpoint => text().nullable()();
  IntColumn get installationEpoch => integer()
      .withDefault(const Constant(0))
      .check(installationEpoch.isBiggerOrEqualValue(0))();
  TextColumn get installationKeyId =>
      text().nullable().references(InstallationKeySlots, #id)();
  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('CredentialSlot')
class CredentialSlots extends Table {
  TextColumn get id => text()();
  TextColumn get ownerId => text()();
  TextColumn get endpoint => text()();
  TextColumn get state =>
      text().check(state.isIn(const ['staged', 'published', 'discarded']))();
  DateTimeColumn get createdAt => dateTime()();
  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('InstallationKeySlot')
class InstallationKeySlots extends Table {
  TextColumn get id => text()();
  TextColumn get endpoint => text()();
  TextColumn get state =>
      text().check(state.isIn(const ['staged', 'published', 'discarded']))();
  DateTimeColumn get createdAt => dateTime()();
  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Installation-bound legacy cursors are never inferred from global device
/// preferences. An imported or unresolved collection starts with a full pull.
@DataClassName('WorkspaceSyncCheckpoint')
class WorkspaceSyncCheckpoints extends Table {
  TextColumn get workspaceId => text().references(CareWorkspaces, #id)();
  TextColumn get profileId =>
      text().references(Profiles, #id, onDelete: KeyAction.cascade)();
  TextColumn get channel => text()();
  TextColumn get cursor => text()();
  DateTimeColumn get completedAt => dateTime()();
  @override
  Set<Column<Object>> get primaryKey => {workspaceId, profileId, channel};
}
