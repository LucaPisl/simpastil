import 'dart:io';
import 'package:drift/native.dart';
import 'package:simpastil/core/auth/credential_refresh_coordinator.dart';
import 'package:simpastil/core/backup/import_service.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/storage/protected_database.dart';
import 'package:simpastil/core/storage/protected_file_store.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import 'protected_workspace_fixture.dart';

class _Keys implements DeviceDatabaseKeyStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String key) async {
    value = key;
  }
}

/// Disposable real encrypted target, independent of production care/key files.
class ProtectedRestoreFixture {
  ProtectedRestoreFixture(
    this.scratch,
    this.workspace,
    this.files,
    this.prepared,
  );
  final Directory scratch;
  final ProtectedWorkspaceFixture workspace;
  final ProtectedFileStore files;
  final PreparedDatabase prepared;
  final preferenceGate = SerialProjectionEffectsGate();
  bool drained = false, resumed = false;
  static Future<ProtectedRestoreFixture> create() async {
    final scratch = await Directory.systemTemp.createTemp(
      'simpastil-full-restore-',
    );
    final legacy = File('${scratch.path}/legacy.db'),
        root = Directory('${scratch.path}/private/care');
    final seed = AppDatabase(NativeDatabase(legacy));
    await seed.customSelect('SELECT 1').get();
    await seed.close();
    final keys = _Keys();
    final prepared = await ProtectedStoreCoordinator(
      root: root,
      legacy: legacy,
      keyStore: keys,
      expectedSchema: AppDatabase.supportedSchemaVersion,
      syncDirectory: (_) async {},
      migrateCandidate: (_) async {},
    ).prepare();
    final workspace = await ProtectedWorkspaceFixture.create(
      database: AppDatabase(NativeDatabase.opened(prepared.openEstablished())),
      initialPreferences: {'app_locale': 'en'},
    );
    final setup = SetupRepository(
      database: workspace.db,
      access: workspace.access,
      context: workspace.context,
    );
    final draft = await setup.resumeOrCreateDraft();
    await setup.savePerson(
      draft.id,
      draft.revision,
      name: 'Fictional previous care',
      avatar: 'P',
    );
    return ProtectedRestoreFixture(
      scratch,
      workspace,
      ProtectedFileStore(
        root: root,
        keyStore: keys,
        maximumSchema: AppDatabase.supportedSchemaVersion,
      ),
      prepared,
    );
  }

  ImportService service({
    WorkspaceContext? context,
    Future<void> Function()? beforeApply,
    beforeCommit,
    Future<void> Function(String)? syncDirectory,
    void Function()? requireInterfaceAccess,
  }) => ImportService(
    database: workspace.db,
    access: workspace.access,
    preferences: workspace.preferences,
    context: context ?? workspace.context,
    store: files,
    refreshGate: NativeCredentialRefreshGate(
      directory: Directory('${scratch.path}/private/auth'),
      syncDirectory: (_) async {},
    ),
    projectionGate: SerialProjectionEffectsGate(),
    preferenceGate: preferenceGate,
    syncDirectory: syncDirectory ?? (_) async {},
    drainRuntime: () async {
      drained = true;
    },
    resumeRuntime: () async {
      resumed = true;
    },
    sourceRecheck: (s) async => s,
    beforeApply: beforeApply,
    requireInterfaceAccess: requireInterfaceAccess,
    beforeCommit: beforeCommit,
  );
  Future<void> close() async {
    await workspace.db.close();
    await scratch.delete(recursive: true);
  }
}
