import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/medication_command.dart';
import 'package:simpastil/core/medication/medication_repository.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/protection/app_lock_controller.dart';
import 'package:simpastil/features/analytics/export/export_bottom_sheet.dart';
import 'package:simpastil/features/profiles/profile_provider.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/l10n/app_localizations_en.dart';
import 'package:timezone/data/latest.dart' as tz;

import '../../../helpers/care_recording_fixture.dart';

class _PendingPrimary extends PrimaryProfileNotifier {
  _PendingPrimary(this.result);
  final Future<String?> result;
  @override
  Future<String?> build() => result;
}

class _DeviceAuthentication implements DeviceAuthenticator {
  @override
  void Function(String)? onCredentialPromptPaused;
  @override
  void Function(String)? onCredentialPromptResumed;
  @override
  Future<bool> isSupported() async => true;
  @override
  Future<DeviceAuthenticationContext> context() async =>
      const DeviceAuthenticationContext(leaveGeneration: 0, foreground: true);
  @override
  Future<bool> authenticate(
    String reason, {
    required String attemptId,
    String? fallbackLabel,
  }) async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tz.initializeTimeZones);
  const channel = MethodChannel('dev.fluttercommunity.plus/share');
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');

  Future<void> flushUntil(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(done(), isTrue);
  }

  Future<(CareRecordingFixture, ProviderContainer, Directory)> mount(
    WidgetTester tester, {
    Completer<String?>? selection,
    Completer<void>? dismissed,
    bool lockEnabled = false,
    Completer<void>? generationStarted,
    Completer<String>? previewDirectory,
  }) async {
    final f = await CareRecordingFixture.create();
    await MedicationRepository(
      f.db,
      access: f.workspace.access,
      context: f.workspace.context,
    ).apply(
      userId: f.workspace.context.ownerUserId,
      occurrenceId: f.occurrence.id,
      action: MedicationAction.take,
      actualTimeKnown: false,
      commandIdOverride: '40000000-0000-4000-8000-000000000901',
    );
    final directory = Directory.systemTemp.createTempSync('report-ui-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (_) async {
          generationStarted?.complete();
          return previewDirectory == null
              ? directory.path
              : await previewDirectory.future;
        });
    await f.workspace.preferences.setBool(legacyAppLockKey, lockEnabled);
    final lock = AppLockController(
      AppLockPolicyStore(
        SharedAppLockPolicyStorage(f.workspace.preferences),
        gate: SerialProjectionEffectsGate(),
      ),
      _DeviceAuthentication(),
    );
    if (lockEnabled) expect(await lock.unlock('Fictional report'), isTrue);
    final container = await f.workspace.createContainer(
      extraOverrides: [
        appLockControllerProvider.overrideWith((_) => lock),
        if (selection != null)
          primaryProfileIdProvider.overrideWith(
            () => _PendingPrimary(selection.future),
          ),
      ],
    );
    if (selection == null) {
      await container.read(primaryProfileIdProvider.future);
    }
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await f.db.close();
      container.dispose();
      await tester.pump();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathChannel, null);
      directory.deleteSync(recursive: true);
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  await showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => SingleChildScrollView(
                      child: ExportBottomSheet(
                        now: () => CareRecordingFixture.planned,
                      ),
                    ),
                  );
                  dismissed?.complete();
                },
                child: const Text('Open report'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CSV'));
    await tester.pump();
    return (f, container, directory);
  }

  testWidgets(
    'unresolved person waits, then exports the captured person and format',
    (tester) async {
      final selection = Completer<String?>();
      final dismissed = Completer<void>();
      final (f, _, directory) = await mount(
        tester,
        selection: selection,
        dismissed: dismissed,
      );
      final shared = <String>[];
      final delivered = Completer<void>();
      final shareReturned = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final paths = (call.arguments as Map)['paths'] as List;
            expect(paths.single, endsWith('.csv'));
            shared.add(await File(paths.single as String).readAsString());
            delivered.complete();
            await shareReturned.future;
            return '';
          });
      await tester.runAsync(
        () => tester.tap(find.text(AppLocalizationsEn().export_exportAndShare)),
      );
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      expect(
        shared,
        isEmpty,
        reason: 'Loading selection must not become Everyone.',
      );
      expect(directory.listSync(), isEmpty);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.tap(find.text('PDF'));
      selection.complete(f.person.id);
      await flushUntil(tester, () => delivered.isCompleted);
      expect(dismissed.isCompleted, isFalse);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
        reason: 'Sharing must finish before the export can finish.',
      );
      expect(directory.listSync(), hasLength(1));
      shareReturned.complete();
      // Directory disappearance precedes completion of File.delete's Future.
      // Keep real I/O running until the actual export dismisses its sheet.
      await flushUntil(
        tester,
        () => dismissed.isCompleted && directory.listSync().isEmpty,
      );
      await tester.pumpAndSettle();
      expect(find.byType(ExportBottomSheet), findsNothing);
      expect(shared.single, contains(f.person.name));
      expect(shared.single, contains(f.pill.name));
      expect(directory.listSync(), isEmpty);
      expect((await f.db.select(f.db.occurrenceEvents).get()), hasLength(1));
    },
  );

  testWidgets(
    'background during generation revokes disclosure and cleans files',
    (tester) async {
      final started = Completer<void>();
      final previewDirectory = Completer<String>();
      final (f, container, directory) = await mount(
        tester,
        lockEnabled: true,
        generationStarted: started,
        previewDirectory: previewDirectory,
      );
      var shares = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
            shares++;
            return '';
          });
      await tester.runAsync(
        () => tester.tap(find.text(AppLocalizationsEn().export_exportAndShare)),
      );
      await flushUntil(tester, () => started.isCompleted);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      expect(directory.listSync(), isEmpty);
      container.read(appLockControllerProvider.notifier).suspend();
      expect(container.read(appLockControllerProvider).canAccess, isFalse);
      previewDirectory.complete(directory.path);
      await flushUntil(
        tester,
        () =>
            directory.listSync().isEmpty &&
            tester.widget<FilledButton>(find.byType(FilledButton)).onPressed !=
                null,
      );
      await tester.pumpAndSettle();
      expect(shares, 0);
      expect(directory.listSync(), isEmpty);
      final l = AppLocalizationsEn();
      expect(
        find.text(l.export_failed(l.shared_somethingWentWrong)),
        findsOneWidget,
      );
      expect(await f.db.select(f.db.occurrenceEvents).get(), hasLength(1));
    },
  );

  testWidgets('share failure is localized and removes private working files', (
    tester,
  ) async {
    final (_, _, directory) = await mount(tester);
    final attempted = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          attempted.complete();
          throw PlatformException(code: 'private-report-path-and-care');
        });
    await tester.runAsync(
      () => tester.tap(find.text(AppLocalizationsEn().export_exportAndShare)),
    );
    await flushUntil(
      tester,
      () =>
          attempted.isCompleted &&
          directory.listSync().isEmpty &&
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed !=
              null,
    );
    await tester.pumpAndSettle();
    final l = AppLocalizationsEn();
    expect(
      find.text(l.export_failed(l.shared_somethingWentWrong)),
      findsOneWidget,
    );
    expect(find.textContaining('private-report-path-and-care'), findsNothing);
    expect(directory.listSync(), isEmpty);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
  });

  testWidgets('closing while person selection loads never dispatches sharing', (
    tester,
  ) async {
    final selection = Completer<String?>();
    final (f, container, directory) = await mount(tester, selection: selection);
    var shares = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          shares++;
          return '';
        });
    await tester.runAsync(
      () => tester.tap(find.text(AppLocalizationsEn().export_exportAndShare)),
    );
    await tester.pumpWidget(const SizedBox());
    selection.complete(f.person.id);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(shares, 0);
    expect(directory.listSync(), isEmpty);
    expect(tester.takeException(), isNull);
    await f.db.close();
    container.dispose();
    await tester.pumpAndSettle();
  });
}
