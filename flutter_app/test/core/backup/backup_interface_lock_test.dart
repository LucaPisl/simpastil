import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/backup/backup_file_access.dart';
import 'package:simpastil/core/backup/backup_providers.dart';
import 'package:simpastil/core/backup/backup_service.dart';
import 'package:simpastil/core/backup/import_service.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/protection/app_lock_controller.dart';
import 'package:timezone/data/latest.dart' as tz;

import '../../helpers/protected_workspace_fixture.dart';
import '../../helpers/protected_restore_fixture.dart';
import 'backup_service_test.dart' show MemoryDestination, databaseFacts;
import 'full_restore_test.dart' show fullSource;

class _Policy implements AppLockPolicyStorage {
  String value = const AppLockPolicy(
    enabled: true,
    revision: 'fixture',
  ).encode();
  @override
  Object? get policyValue => value;
  @override
  Object? get legacyValue => null;
  @override
  Future<void> reload() async {}
  @override
  Future<bool> write(String next) async {
    value = next;
    return true;
  }
}

class _Authentication implements DeviceAuthenticator {
  @override
  void Function(String)? onCredentialPromptPaused;
  @override
  void Function(String)? onCredentialPromptResumed;
  @override
  Future<bool> isSupported() async => true;
  @override
  Future<bool> authenticate(
    String reason, {
    required String attemptId,
    String fallbackLabel = 'Use device lock',
  }) async => true;
  @override
  Future<DeviceAuthenticationContext> context() async =>
      const DeviceAuthenticationContext(leaveGeneration: 0, foreground: true);
}

class _Files extends MemoryDestination {
  Future<void> Function()? onOpen, onRead;
  int reads = 0;
  @override
  Future<BackupFileLocation?> chooseOpen() async {
    await onOpen?.call();
    return const BackupFileLocation('chosen', 'Example.simpbak');
  }

  @override
  Future<Uint8List> read(BackupFileLocation location) async {
    reads++;
    await onRead?.call();
    return super.read(location);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(tz.initializeTimeZones);
  AppLockController controller() => AppLockController(
    AppLockPolicyStore(_Policy(), gate: SerialProjectionEffectsGate()),
    _Authentication(),
  );

  for (final boundary in [
    'picker',
    'source picker',
    'source read',
    'snapshot',
  ]) {
    test('production backup lease refuses Home at $boundary', () async {
      final f = await ProtectedWorkspaceFixture.create();
      addTearDown(f.db.close);
      final lock = controller();
      final files = _Files();
      final container = await f.createContainer(
        extraOverrides: [
          appLockControllerProvider.overrideWith((_) => lock),
          backupFileAccessProvider.overrideWithValue(files),
        ],
      );
      addTearDown(container.dispose);
      expect(await lock.unlock('Fictional test'), isTrue);
      final service = container.read(backupServiceProvider);
      final snapshot = await service.captureFull();
      final before = await databaseFacts(f.db);
      if (boundary == 'picker') {
        files.onChoose = () async => lock.userLeft();
        await expectLater(
          service.save(snapshot, allowClear: true),
          throwsA(isA<AppLockRequired>()),
        );
        expect(files.writes, 0);
      } else if (boundary == 'snapshot') {
        lock.userLeft();
        lock.resume();
        expect(await lock.unlock('Fictional renewed unlock'), isTrue);
        await expectLater(
          service.save(snapshot, allowClear: true),
          throwsA(isA<AppLockRequired>()),
        );
        expect(files.writes, 0);
      } else {
        await service.save(snapshot, allowClear: true);
        final written = List<int>.of(files.bytes!);
        if (boundary == 'source picker') {
          files.reads = 0;
          files.onOpen = () async => lock.userLeft();
          await expectLater(
            service.selectSource(),
            throwsA(isA<AppLockRequired>()),
          );
          expect(files.reads, 0);
        } else {
          final selected = (await service.selectSource())!;
          files.onRead = () async => lock.userLeft();
          await expectLater(
            service.checkSource(selected),
            throwsA(isA<AppLockRequired>()),
          );
        }
        expect(files.bytes, written);
      }
      expect(await databaseFacts(f.db), before);
    });
  }

  test(
    'source picker returns a harmless choice; reading waits for a fresh unlock',
    () async {
      final f = await ProtectedWorkspaceFixture.create();
      addTearDown(f.db.close);
      final lock = controller();
      final files = _Files();
      final container = await f.createContainer(
        extraOverrides: [
          appLockControllerProvider.overrideWith((_) => lock),
          backupFileAccessProvider.overrideWithValue(files),
        ],
      );
      addTearDown(container.dispose);
      expect(await lock.unlock('Fictional test'), isTrue);
      final service = container.read(backupServiceProvider);
      final snapshot = await service.captureFull();
      await service.save(snapshot, allowClear: true);
      final before = await databaseFacts(f.db);
      files.reads = 0;
      files.onOpen = () async => lock.userLeft();

      final choice = await service.chooseSource();

      expect(choice, isNotNull);
      final selectedChoice = choice!;
      expect(selectedChoice.displayName, 'Example.simpbak');
      expect(lock.state.canAccess, isFalse);
      expect(files.reads, 0);
      await expectLater(
        service.openSource(selectedChoice),
        throwsA(isA<AppLockRequired>()),
      );
      expect(files.reads, 0);

      lock.resume();
      expect(await lock.unlock('Fictional renewed unlock'), isTrue);
      final selected = await service.openSource(selectedChoice);
      expect(files.reads, 1);
      final checked = await service.checkSource(selected);
      expect(checked.document.toJson(), snapshot.document.toJson());
      expect(files.reads, 2);
      expect(await databaseFacts(f.db), before);
    },
  );

  test(
    'destination choice survives picker lock but rejects the old snapshot',
    () async {
      final f = await ProtectedWorkspaceFixture.create();
      addTearDown(f.db.close);
      final lock = controller();
      final files = _Files();
      final container = await f.createContainer(
        extraOverrides: [
          appLockControllerProvider.overrideWith((_) => lock),
          backupFileAccessProvider.overrideWithValue(files),
        ],
      );
      addTearDown(container.dispose);
      expect(await lock.unlock('Fictional test'), isTrue);
      final service = container.read(backupServiceProvider);
      final staleSnapshot = await service.captureFull();
      final before = await databaseFacts(f.db);
      files.onChoose = () async => lock.userLeft();

      final choice = await service.chooseDestination();

      expect(choice, isNotNull);
      final selectedChoice = choice!;
      expect(selectedChoice.displayName, 'Example.simpbak');
      expect(lock.state.canAccess, isFalse);
      expect(files.writes, 0);
      await expectLater(
        service.saveToDestination(
          staleSnapshot,
          selectedChoice,
          allowClear: true,
        ),
        throwsA(isA<AppLockRequired>()),
      );
      expect(files.writes, 0);

      lock.resume();
      expect(await lock.unlock('Fictional renewed unlock'), isTrue);
      await expectLater(
        service.saveToDestination(
          staleSnapshot,
          selectedChoice,
          allowClear: true,
        ),
        throwsA(isA<AppLockRequired>()),
      );
      expect(files.writes, 0);

      final freshSnapshot = await service.captureFull();
      final result = await service.saveToDestination(
        freshSnapshot,
        selectedChoice,
        allowClear: true,
      );
      expect(result.status, BackupSaveStatus.savedChecked);
      expect(files.writes, 1);
      expect(await databaseFacts(f.db), before);
    },
  );

  test(
    'Home at full restore final commit preserves original care and active file/key',
    () async {
      final fixture = await ProtectedRestoreFixture.create();
      addTearDown(fixture.close);
      final source = await ProtectedWorkspaceFixture.create();
      addTearDown(source.db.close);
      final lock = controller();
      addTearDown(lock.dispose);
      expect(await lock.unlock('Fictional test'), isTrue);
      final lease = lock.captureAccess();
      final service = fixture.service(
        requireInterfaceAccess: lease.requireCurrent,
        beforeCommit: () async => lock.userLeft(),
      );
      final plan = await service.preview(
        await fullSource(source),
        const ImportSelection.full(),
      );
      final before = await databaseFacts(fixture.workspace.db);
      final marker = await fixture.files.manifest();
      final key = await fixture.files.keyStore.read();
      await expectLater(service.apply(plan), throwsA(isA<ImportFailure>()));
      expect(await databaseFacts(fixture.workspace.db), before);
      // Recovery metadata may advance before rollback; the active original
      // care file and its encryption key must never be replaced.
      expect((await fixture.files.manifest()).active, marker.active);
      expect(await fixture.files.keyStore.read(), key);
      expect(fixture.resumed, isTrue);
    },
  );
}
