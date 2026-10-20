import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/backup/backup_import_session.dart';
import 'package:simpastil/core/backup/backup_providers.dart';
import 'package:simpastil/core/backup/import_service.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/protection/app_lock_controller.dart';
import 'package:simpastil/features/settings/presentation/backup_settings_screen.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/widgets/person_avatar.dart';
import 'package:timezone/data/latest_all.dart' as tz;

import '../../../helpers/protected_workspace_fixture.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import '../../../core/backup/backup_service_test.dart'
    show MemoryDestination, databaseFacts;

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
    String? fallbackLabel,
  }) async => true;
  @override
  Future<DeviceAuthenticationContext> context() async =>
      const DeviceAuthenticationContext(leaveGeneration: 0, foreground: true);
}

Future<void> _settle(WidgetTester tester) async {
  for (var attempt = 0; attempt < 80; attempt++) {
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
  await tester.pumpAndSettle();
}

void main() {
  setUp(tz.initializeTimeZones);
  testWidgets('a refused capture does not create an empty destination', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = await ProtectedWorkspaceFixture.create();
    var chose = false;
    var refused = false;
    final files = MemoryDestination()
      ..onChoose = () async {
        chose = true;
      };
    final container = await fixture.createContainer(
      extraOverrides: [
        backupFileAccessProvider.overrideWithValue(files),
        backupInterfaceLeaseProvider.overrideWithValue(
          () => () {
            if (refused) throw StateError('Fictional expired capture');
          },
        ),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(fixture.db.close);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: BackupSettingsScreen(),
        ),
      ),
    );
    await tester.tap(find.text('Create backup'));
    await _settle(tester);
    // Access changes after preview but before opening the system picker.
    refused = true;
    await tester.ensureVisible(find.text('Choose save location'));
    await tester.tap(find.text('Choose save location'));
    await _settle(tester);
    expect(chose, isFalse);
    expect(files.writes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'password default, explicit destination save, check has no activation',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 1800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final f = await ProtectedWorkspaceFixture.create();
      final setup = SetupRepository(
        database: f.db,
        access: f.access,
        context: f.context,
      );
      final draft = await setup.resumeOrCreateDraft();
      await setup.savePerson(
        draft.id,
        draft.revision,
        name: 'Fictional Alex',
        avatar: 'A',
      );
      final files = MemoryDestination();
      final container = await f.createContainer(
        extraOverrides: [
          backupFileAccessProvider.overrideWithValue(files),
          openBackupImportProvider.overrideWith(
            (ref) =>
                (source, {password}) => BackupImportSession.open(
                  backup: ref.read(backupServiceProvider),
                  source: source,
                  password: password,
                  buildImport: (_, _) async => ImportService(
                    database: f.db,
                    access: f.access,
                    preferences: f.preferences,
                    context: f.context,
                  ),
                ),
          ),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(f.db.close);
      final before = await databaseFacts(f.db);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: BackupSettingsScreen(),
          ),
        ),
      );
      await tester.tap(find.text('Create backup'));
      await _settle(tester);
      final group = tester.widget<RadioGroup<bool>>(
        find.byType(RadioGroup<bool>),
      );
      expect(group.groupValue, isTrue);
      await tester.ensureVisible(find.text('Choose save location'));
      await tester.tap(find.text('Choose save location'));
      await _settle(tester);
      expect(files.writes, 0);
      await tester.enterText(
        find.byType(TextField).at(0),
        'Fictional backup password',
      );
      await tester.enterText(
        find.byType(TextField).at(1),
        'Fictional backup password',
      );
      await tester.ensureVisible(find.text('Save to chosen location'));
      await tester.tap(find.text('Save to chosen location'));
      await _settle(tester);
      expect(files.writes, 1);
      expect(
        find.textContaining('Saved and checked on this device'),
        findsOneWidget,
      );
      expect(await databaseFacts(f.db), before);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Check backup'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose backup file'));
      await _settle(tester);
      await tester.enterText(
        find.byType(TextField),
        'Fictional backup password',
      );
      await tester.tap(find.text('Open chosen file'));
      await _settle(tester);
      expect(find.text('File checks passed'), findsOneWidget);
      expect(find.text('Your current data is unchanged.'), findsOneWidget);
      expect(find.text('File integrity'), findsOneWidget);
      expect(find.text('Passed'), findsOneWidget);
      expect(find.text('Backup format'), findsOneWidget);
      expect(find.text('Supported'), findsOneWidget);
      await tester.ensureVisible(find.text('Review restore options'));
      await tester.tap(find.text('Review restore options'));
      await tester.pumpAndSettle();
      expect(find.text('How to restore'), findsOneWidget);
      expect(find.byType(PersonAvatar), findsWidgets);
      expect(find.text('0 people selected'), findsOneWidget);
      expect(
        find.text('Nothing changes until you review and apply.'),
        findsOneWidget,
      );
      final choice = tester.widget<CheckboxListTile>(
        find.byType(CheckboxListTile).first,
      );
      expect(choice.controlAffinity, ListTileControlAffinity.leading);
      await tester.ensureVisible(find.byType(CheckboxListTile).first);
      await tester.tap(find.byType(CheckboxListTile).first);
      await tester.pumpAndSettle();
      expect(find.text('1 person selected'), findsOneWidget);
      await tester.ensureVisible(find.text('Review import').last);
      await tester.tap(find.text('Review import').last);
      await _settle(tester);
      expect(find.text('Nothing imported yet.'), findsOneWidget);
      expect(await databaseFacts(f.db), before);
    },
  );

  testWidgets(
    'Home drops password and reviewed source; renewed unlock needs explicit new open',
    (tester) async {
      final f = await ProtectedWorkspaceFixture.create(
        initialPreferences: {
          appLockPolicyKey: const AppLockPolicy(
            enabled: true,
            revision: 'fixture',
          ).encode(),
        },
      );
      final lock = AppLockController(
        AppLockPolicyStore(
          SharedAppLockPolicyStorage(f.preferences),
          gate: SerialProjectionEffectsGate(),
        ),
        _Authentication(),
      );
      final files = MemoryDestination();
      final container = await f.createContainer(
        extraOverrides: [
          appLockControllerProvider.overrideWith((_) => lock),
          backupFileAccessProvider.overrideWithValue(files),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(f.db.close);
      expect(await lock.unlock('Fictional'), isTrue);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: BackupSettingsScreen(),
          ),
        ),
      );
      await tester.tap(find.text('Check backup'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose backup file'));
      await _settle(tester);
      await tester.enterText(
        find.byType(TextField),
        'Secret fictional password',
      );
      lock.userLeft();
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      expect(files.writes, 0);
      expect(find.text('File checks passed'), findsNothing);
      lock.resume();
      expect(await lock.unlock('Renewed fictional'), isTrue);
      await tester.pumpAndSettle();
      expect(find.text('Open chosen file'), findsOneWidget);
      expect(find.text('File checks passed'), findsNothing);
    },
  );
  testWidgets(
    'Home dismisses protected contents dialog and renewed unlock cannot revive it',
    (tester) async {
      final f = await ProtectedWorkspaceFixture.create(
        initialPreferences: {
          appLockPolicyKey: const AppLockPolicy(
            enabled: true,
            revision: 'fixture',
          ).encode(),
        },
      );
      final lock = AppLockController(
        AppLockPolicyStore(
          SharedAppLockPolicyStorage(f.preferences),
          gate: SerialProjectionEffectsGate(),
        ),
        _Authentication(),
      );
      final container = await f.createContainer(
        extraOverrides: [appLockControllerProvider.overrideWith((_) => lock)],
      );
      addTearDown(container.dispose);
      addTearDown(f.db.close);
      expect(await lock.unlock('Fictional'), isTrue);
      final before = await databaseFacts(f.db);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: BackupSettingsScreen(),
          ),
        ),
      );
      await tester.tap(find.text('Create backup'));
      await _settle(tester);
      await tester.tap(find.text('View contents'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      lock.userLeft();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      lock.resume();
      expect(await lock.unlock('Renewed fictional'), isTrue);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('View contents'), findsNothing);
      expect(await databaseFacts(f.db), before);
    },
  );
}
