import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/auth/credential_refresh_coordinator.dart';
import 'package:simpastil/core/backup/backup_file_access.dart';
import 'package:simpastil/core/backup/backup_import_session.dart';
import 'package:simpastil/core/backup/backup_service.dart';
import 'package:simpastil/core/backup/import_service.dart';
import 'package:simpastil/core/backup/restore_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/storage/protected_database.dart';
import 'package:simpastil/core/storage/protected_file_store.dart';
import 'package:simpastil/core/storage/recovery_copy_service.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil_storage/simpastil_storage.dart';
import 'package:timezone/data/latest_all.dart' as tz;

import '../test/helpers/care_recording_fixture.dart';
import '../test/helpers/protected_workspace_fixture.dart';

class _QaKeys implements DeviceDatabaseKeyStore {
  const _QaKeys(this.name);
  final String name;
  static const storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  @override
  Future<String?> read() => storage.read(key: name);
  @override
  Future<void> write(String key) => storage.write(key: name, value: key);
}

Future<String> _productionFiles(Directory directory) async {
  final result = <String, String>{};
  if (await directory.exists()) {
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File) {
        result[entity.path.substring(directory.path.length)] = sha256
            .convert(await entity.readAsBytes())
            .toString();
      }
    }
  }
  final keys = result.keys.toList()..sort();
  return sha256
      .convert(
        utf8.encode(jsonEncode({for (final key in keys) key: result[key]})),
      )
      .toString();
}

/// Run with flutter run on owned emulator-5582, never flutter test/uninstall.
/// Separate QA care directory, key and preference prefix preserve all app care.
/// Initial and restart are separate actual Android processes; an operator
/// completes real SAVE/OPEN pickers. Retain QA originals after any failure.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native protected replacement and real process reopen',
    (tester) async {
      expect(
        Platform.isAndroid &&
            const bool.fromEnvironment('SIMPASTIL_RESTORE_TEST'),
        isTrue,
      );
      const run = String.fromEnvironment('SIMPASTIL_RESTORE_QA_RUN');
      expect(RegExp(r'^[a-z0-9-]{1,32}$').hasMatch(run), isTrue);
      const restart = bool.fromEnvironment('SIMPASTIL_RESTORE_QA_RESTART');
      tz.initializeTimeZones();
      const native = SimpastilStorage();
      final base = await native.noBackupPath();
      final qa = Directory('$base/restore-qa-$run');
      final root = Directory('${qa.path}/care');
      final production = Directory('$base/care');
      final productionBefore = await _productionFiles(production);
      SharedPreferences.setPrefix('simpastil_restore_qa_$run.');
      final preferences = await SharedPreferences.getInstance();
      const keys = _QaKeys('simpastil_restore_qa_key_$run');
      if (!restart) {
        expect(
          await qa.exists(),
          isFalse,
          reason: 'Fresh isolated QA run only; never erase prior originals',
        );
        await qa.create(recursive: true);
        await native.syncDirectory(qa.parent.path);
        final seed = AppDatabase(NativeDatabase(File('${qa.path}/legacy.db')));
        await seed.customSelect('SELECT 1').get();
        await seed.close();
      } else {
        expect(await root.exists(), isTrue);
        expect(await keys.read(), isNotNull);
      }
      final prepared = await ProtectedStoreCoordinator(
        root: root,
        legacy: File('${qa.path}/legacy.db'),
        keyStore: keys,
        expectedSchema: 11,
        migrateCandidate: (_) async {},
        syncDirectory: (path) => native.syncDirectory(path),
      ).prepare();
      final target = await ProtectedWorkspaceFixture.create(
        database: AppDatabase(
          NativeDatabase.opened(prepared.openEstablished()),
        ),
        preferences: preferences,
      );
      addTearDown(target.db.close);
      final store = ProtectedFileStore(
        root: root,
        keyStore: keys,
        maximumSchema: 11,
      );
      final preferenceGate = NativeProjectionEffectsGate(
        directory: Directory('${qa.path}/preferences'),
      );
      if (restart) {
        final receipt =
            (await target.db.select(target.db.importReceipts).get()).single;
        expect(receipt.mode, 'full');
        expect(
          (await target.db.select(target.db.profiles).get()).single.name,
          'Fictional Alex',
        );
        expect(
          await target.db.select(target.db.occurrenceEvents).get(),
          hasLength(2),
        );
        expect(
          await target.db.select(target.db.pendingOperations).get(),
          isEmpty,
        );
        expect(preferences.getString('app_locale'), 'ro');
        expect(
          (await RecoveryCopyService(
            store,
          ).check(await store.manifest())).state,
          RecoveryCopyState.checked,
        );
        expect(
          await RestorePreferencesService(
            database: target.db,
            preferences: preferences,
            effectsGate: preferenceGate,
          ).reconcile(),
          PreferenceRestoreState.none,
        );
        await target.access.requireCurrent(target.context);
        expect(await _productionFiles(production), productionBefore);
        debugPrint(
          'PORTABLE_RESTORE_NATIVE_RESTART_ACCEPTED care-history preferences recovery current-grant production-files-unchanged',
        );
        return;
      }
      final setup = SetupRepository(
        database: target.db,
        access: target.access,
        context: target.context,
      );
      final draft = await setup.resumeOrCreateDraft();
      await setup.savePerson(
        draft.id,
        draft.revision,
        name: 'Fictional previous native care',
        avatar: 'P',
      );
      await preferences.setString('app_locale', 'ro');
      final source = await CareRecordingFixture.create(
        preferences: preferences,
      );
      addTearDown(source.db.close);
      final historical = CareRecordingService(
        database: source.db,
        access: source.workspace.access,
        context: source.workspace.context,
        clock: () => DateTime.utc(2026, 9, 30, 9),
      );
      await historical.commit(
        await historical.prepareTakenNow(
          personId: source.person.id,
          occurrenceId: source.occurrence.id,
          expectedStateVersion: 0,
        ),
      );
      const files = AndroidBackupFileAccess();
      final sourceBackups = BackupService(
        database: source.db,
        access: source.workspace.access,
        preferences: preferences,
        files: files,
      );
      final captured = await sourceBackups.captureFull();
      const password = 'Fictional protected restore test password';
      debugPrint('PORTABLE_RESTORE_PICKER_SAVE');
      final saved = await sourceBackups.save(captured, password: password);
      expect(saved.status, BackupSaveStatus.savedChecked);
      await preferences.setString('app_locale', 'en');
      final backups = BackupService(
        database: target.db,
        access: target.access,
        preferences: preferences,
        files: files,
      );
      debugPrint('PORTABLE_RESTORE_PICKER_OPEN');
      final selected = await backups.selectSource();
      expect(selected, isNotNull);
      var drained = false, resumed = false;
      final session = await BackupImportSession.open(
        backup: backups,
        source: selected!,
        password: password,
        buildImport: (_, recheck) async => ImportService(
          database: target.db,
          access: target.access,
          preferences: preferences,
          context: target.context,
          store: store,
          sourceRecheck: recheck,
          refreshGate: NativeCredentialRefreshGate(
            directory: Directory('${qa.path}/auth'),
            syncDirectory: (path) => native.syncDirectory(path.path),
          ),
          projectionGate: NativeProjectionEffectsGate(
            directory: Directory('${qa.path}/projections'),
          ),
          preferenceGate: preferenceGate,
          syncDirectory: (path) => native.syncDirectory(path),
          drainRuntime: () async {
            drained = true;
          },
          resumeRuntime: () async {
            resumed = true;
          },
        ),
      );
      addTearDown(session.close);
      final plan = await session.preview(const ImportSelection.full());
      expect(plan.affectedPeople.single.name, 'Fictional previous native care');
      final marker = await store.manifest();
      final key = await keys.read();
      await keys.write('controlled-invalid-qa-key');
      try {
        await expectLater(
          session.apply(plan),
          throwsA(
            isA<ImportFailure>().having(
              (e) => e.code,
              'code',
              ImportFailureCode.recoveryUnavailable,
            ),
          ),
        );
      } finally {
        await keys.write(key!);
      }
      expect((await store.manifest()).revision, marker.revision);
      expect(
        (await target.db.select(target.db.profiles).get()).single.name,
        'Fictional previous native care',
      );
      expect(await target.db.select(target.db.importReceipts).get(), isEmpty);
      expect(resumed, isTrue);
      final result = await session.apply(plan);
      expect(drained, isTrue);
      expect(result.recoveryChecked, isTrue);
      expect(result.preferences, ImportPreferenceState.completed);
      expect(
        result.projectionsPending,
        isTrue,
        reason: 'Harness does not claim optional OS publication',
      );
      expect(preferences.getString('app_locale'), 'ro');
      expect(
        (await target.db.select(target.db.profiles).get()).single.name,
        'Fictional Alex',
      );
      expect(
        (await RecoveryCopyService(store).check(await store.manifest())).state,
        RecoveryCopyState.checked,
      );
      final recovery = (await store.manifest()).recovery!;
      final original = await store.verify(recovery, 'recovery.db');
      expect(original.rows['profiles'], 1);
      expect(
        await readProtectedRecoveryPreferences(
          root: root,
          keyStore: keys,
          generation: recovery,
          expectedDigest:
              ((await store.manifest()).value['recoveryEvidence']
                      as Map)['preferencesDigest']
                  as String,
        ),
        containsPair('app_locale', 'en'),
      );
      final current = await target.access.currentContext();
      final care = CareRecordingService(
        database: target.db,
        access: target.access,
        context: current,
        clock: () => DateTime.utc(2026, 10, 1, 9),
      );
      final events = await target.db.select(target.db.occurrenceEvents).get();
      final archived = events.single;
      expect(
        (await target.db.select(target.db.careEventDetails).get())
            .single
            .authorId,
        source.workspace.context.authorId,
      );
      final latest = (await target.db.medicationLedgerDao.getOccurrenceById(
        source.occurrence.id,
      ))!;
      final undone = await care.commit(
        await care.prepareUndoForEntry(
          personId: source.person.id,
          occurrenceId: latest.id,
          expectedStateVersion: latest.stateVersion,
          headEventId: archived.id,
        ),
      );
      expect(undone.authorId, current.authorId);
      expect(
        await target.db.select(target.db.occurrenceEvents).get(),
        hasLength(2),
      );
      expect((await session.apply(plan)).alreadyApplied, isTrue);
      expect(
        await target.db.select(target.db.occurrenceEvents).get(),
        hasLength(2),
      );
      expect(await _productionFiles(production), productionBefore);
      debugPrint(
        'PORTABLE_RESTORE_NATIVE_INITIAL_ACCEPTED SAF-source native-barriers refused-bad-recovery protected-copy local-care original-author Undo idempotent production-files-unchanged',
      );
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
