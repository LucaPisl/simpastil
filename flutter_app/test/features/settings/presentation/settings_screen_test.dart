import 'dart:async';

import 'package:dio/dio.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:mocktail/mocktail.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/notifications/notification_plugin.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/protection/app_lock_controller.dart';
import 'package:simpastil/core/errors/app_error.dart';
import 'package:simpastil/core/server/server_config_notifier.dart';
import 'package:simpastil/core/storage/portable_preference_writer.dart';
import 'package:simpastil/core/sync/sync_status_notifier.dart';
import 'package:simpastil/core/theme/theme_provider.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import 'package:simpastil/core/workspace/workspace_provider.dart';
import 'package:simpastil/core/storage/recovery_copy_service.dart';
import 'package:simpastil/core/storage/storage_inventory_service.dart';
import 'package:simpastil/features/auth/auth_provider.dart';
import 'package:simpastil/features/auth/auth_repository.dart';
import 'package:simpastil/features/pills/pill_provider.dart';
import 'package:simpastil/features/profiles/profile_provider.dart';
import 'package:simpastil/features/settings/presentation/change_password_sheet.dart';
import 'package:simpastil/features/settings/presentation/settings_screen.dart';
import 'package:simpastil/features/settings/migration_issue_provider.dart';
import 'package:simpastil/features/settings/presentation/settings_overview.dart';
import 'package:simpastil/features/settings/presentation/backup_settings_screen.dart';
import 'package:simpastil/features/settings/presentation/storage_settings_screen.dart';
import 'package:simpastil/l10n/app_localizations.dart';

import '../../../helpers/fake_notifications_plugin.dart';
import '../../../helpers/review_rendering.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import '../../../helpers/protected_workspace_fixture.dart';

const _permissionChannel = MethodChannel(
  'flutter.baseflow.com/permissions/methods',
);

Override _storageSnapshotOverride() =>
    storageSettingsSnapshotProvider.overrideWith(
      (_) async => const StorageSettingsSnapshot(
        StorageInventory({
          StorageCategory.care: null,
          StorageCategory.recovery: 0,
        }),
        RecoveryCopyCheck(RecoveryCopyState.absent),
        RecoveryCopyCheck(RecoveryCopyState.absent),
      ),
    );

class _FakeAuthNotifier extends AuthNotifier {
  @override
  AuthState build() => const AuthAuthenticated('u1');
}

class _GuardedAuthRepository extends Fake implements AuthRepository {
  int setupCalls = 0;

  @override
  Future<Result<TotpSetupResult>> setup2fa() async {
    setupCalls++;
    throw StateError('2FA setup must not run until requested');
  }
}

class _FallbackAuthenticator implements DeviceAuthenticator {
  String? fallbackLabel;
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
  }) async {
    this.fallbackLabel = fallbackLabel;
    return false;
  }
}

class _FakeThemeModeNotifier extends ThemeModeNotifier {
  @override
  Future<AppThemeMode> build() async => AppThemeMode.system;
}

class _FakePrimaryProfileNotifier extends PrimaryProfileNotifier {
  @override
  Future<String?> build() async => null;
}

class _FakeSiblingDetectionNotifier extends SiblingDetectionNotifier {
  @override
  SiblingDetectionMode build() => SiblingDetectionMode.nameAndDosage;
}

class _FakeServerConfigNotifier extends ServerConfigNotifier {
  _FakeServerConfigNotifier(this._url);
  final String? _url;

  @override
  String? build() => _url;
}

class _FailingSyncStatusNotifier extends SyncStatusNotifier {
  @override
  SyncStatus build() => SyncStatus(
    phase: SyncPhase.failure,
    lastError: 'You appear to be offline',
    failingSince: DateTime(2026, 6, 11, 14, 2),
    pendingCount: 3,
  );
}

class _IdleSyncStatusNotifier extends SyncStatusNotifier {
  @override
  SyncStatus build() => SyncStatus(
    phase: SyncPhase.idle,
    lastSuccessAt: DateTime.now().subtract(const Duration(minutes: 2)),
  );
}

class _MutableSyncStatusNotifier extends SyncStatusNotifier {
  @override
  SyncStatus build() => SyncStatus(
    phase: SyncPhase.idle,
    lastSuccessAt: DateTime(2026, 10, 8, 12),
  );

  void reportOffline() {
    state = SyncStatus(
      phase: SyncPhase.failure,
      lastError: 'You appear to be offline',
      failingSince: DateTime(2026, 10, 8, 12, 1),
      pendingCount: 2,
    );
  }
}

final class _SettingsProviderObserver extends ProviderObserver {
  int migrationIssueStarts = 0;
  int migrationIssueUpdates = 0;
  int syncStatusStarts = 0;
  int syncStatusUpdates = 0;
  int profileListStarts = 0;
  int profileMembershipStarts = 0;
  int primaryProfileStarts = 0;

  bool get hasProfileSubscription =>
      profileListStarts > 0 ||
      profileMembershipStarts > 0 ||
      primaryProfileStarts > 0;

  @override
  void didAddProvider(ProviderObserverContext context, Object? value) {
    final provider = context.provider;
    if (provider == migrationIssuesProvider) migrationIssueStarts++;
    if (provider == syncStatusProvider) syncStatusStarts++;
    if (provider == profileListProvider) profileListStarts++;
    if (provider == profileMembershipProvider) profileMembershipStarts++;
    if (provider == primaryProfileIdProvider) primaryProfileStarts++;
  }

  @override
  void didUpdateProvider(
    ProviderObserverContext context,
    Object? previousValue,
    Object? newValue,
  ) {
    final provider = context.provider;
    if (provider == migrationIssuesProvider) migrationIssueUpdates++;
    if (provider == syncStatusProvider) syncStatusUpdates++;
  }
}

Future<Widget> _buildApp({
  required SharedPreferences prefs,
  String? serverUrl,
  List<Override> overrides = const [],
  Locale? locale,
  SettingsSection? section = SettingsSection.reminders,
  bool reducedMotion = false,
  TextScaler textScaler = TextScaler.noScaling,
  ThemeData? theme,
  void Function(ProjectionEffectsGate)? preferenceGateReady,
  List<ProviderObserver> observers = const [],
}) async {
  final fixture = await ProtectedWorkspaceFixture.create(
    ownerId: 'u1',
    preferences: prefs,
  );
  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      ...fixture.overrides,
      serverConfigProvider.overrideWith(
        () => _FakeServerConfigNotifier(serverUrl),
      ),
      authNotifierProvider.overrideWith(() => _FakeAuthNotifier()),
      profileListProvider.overrideWith((_) => Stream.value(const [])),
      primaryProfileIdProvider.overrideWith(
        () => _FakePrimaryProfileNotifier(),
      ),
      themeModeNotifierProvider.overrideWith(() => _FakeThemeModeNotifier()),
      siblingDetectionModeProvider.overrideWith(
        () => _FakeSiblingDetectionNotifier(),
      ),
      ...overrides,
    ],
    observers: observers,
  );
  // Riverpod 3 pauses an unlistened provider, and a paused subscription never
  // sees the database streams close; keep one listener until teardown.
  container.listen(workspaceContextProvider, (_, _) {});
  await container.read(workspaceContextProvider.future);
  // Teardowns run last-in first-out: dispose the container, which cancels any
  // paused database subscriptions, before the database closes its streams.
  addTearDown(fixture.db.close);
  addTearDown(container.dispose);
  preferenceGateReady?.call(container.read(portablePreferenceGateProvider));
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      locale: locale,
      theme: theme == null ? null : reviewRenderingTheme(theme),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(disableAnimations: reducedMotion, textScaler: textScaler),
        child: RepaintBoundary(key: reviewCaptureKey, child: child!),
      ),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SettingsScreen(section: section),
    ),
  );
}

/// A window of [size] logical pixels. `setSurfaceSize` only changes what the
/// tree is laid out in; the size MediaQuery reports, and so the window class,
/// follows the view.
void _view(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

class _RejectedReviewRepository extends MigrationIssueResolutionRepository {
  _RejectedReviewRepository(this.failure) : super(Dio());
  final Object failure;
  @override
  Future<void> resolveMedicationIssue(
    MigrationIssueSummary issue,
    MedicationIssueDisposition disposition,
  ) async => throw failure;
}

MigrationIssueSummary _reviewIssue({bool actionable = true}) =>
    MigrationIssueSummary(
      id: 'fictional-review',
      entityId: 'fictional-operation',
      issueCode: actionable
          ? 'legacy_split_checkpoint'
          : 'legacy_delivery_uncertain',
      revision: 1,
      resolutionState: 'unresolved',
      kind: actionable
          ? MigrationIssueKind.medication
          : MigrationIssueKind.other,
      createdAt: DateTime.utc(2026, 10, 6),
      isServerIssue: actionable,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadReviewFonts);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    notificationsPlugin = FakeNotificationsPlugin();
    PackageInfo.setMockInitialValues(
      appName: 'Simpastil',
      packageName: 'simpastil',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_permissionChannel, (call) async {
          if (call.method == 'checkPermissionStatus') return 0;
          if (call.method == 'openAppSettings') return false;
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_permissionChannel, null);
  });

  for (final language in ['en', 'ro']) {
    testWidgets(
      'retired routine information offers no impossible repair in $language',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(412, 914));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final prefs = await SharedPreferences.getInstance();
        await tester.pumpWidget(
          await _buildApp(
            prefs: prefs,
            section: SettingsSection.data,
            locale: Locale(language),
            theme: AppTheme.dark(),
            textScaler: const TextScaler.linear(1.3),
            overrides: [
              migrationIssuesProvider.overrideWith(
                (_) => Stream.value([
                  MigrationIssueSummary(
                    id: 'retired-routine',
                    entityId: 'retired-schedule',
                    issueCode: 'schedule_timezone_review_required',
                    revision: 1,
                    resolutionState: 'unresolved',
                    kind: MigrationIssueKind.schedule,
                    createdAt: DateTime.utc(2026, 10, 6),
                    isServerIssue: true,
                    retainedInformation: RetainedSyncInformation.retiredRoutine,
                  ),
                  MigrationIssueSummary(
                    id: 'retired-stock',
                    entityId: 'retired-medication',
                    issueCode: 'sync_item_needs_review',
                    revision: 1,
                    resolutionState: 'unresolved',
                    kind: MigrationIssueKind.other,
                    createdAt: DateTime.utc(2026, 10, 7),
                    isServerIssue: false,
                    retainedInformation: RetainedSyncInformation.retiredStock,
                  ),
                ]),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('legacy-routine-review-entry')),
          findsNothing,
        );
        expect(
          find.text(
            language == 'en'
                ? 'A schedule needs review'
                : 'Un program necesită revizuire',
          ),
          findsNothing,
        );
        expect(
          find.textContaining(
            language == 'en'
                ? 'removed medications or routines'
                : 'medicamente sau programe eliminate',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await captureReview(tester, 'retired-routine-$language');
      },
    );
  }

  testWidgets(
    'a kept uncertainty keeps its details and opens Fix sync problems',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(412, 914));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        await _buildApp(
          prefs: prefs,
          theme: AppTheme.light(),
          section: SettingsSection.data,
          overrides: [
            migrationIssuesProvider.overrideWith(
              (_) => Stream.value([_reviewIssue(actionable: false)]),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('A change needs review'), 200);
      final tile = tester.widget<ListTile>(
        find.ancestor(
          of: find.text('A change needs review'),
          matching: find.byType(ListTile),
        ),
      );
      expect(tile.onTap, isNotNull);
      expect(tile.trailing, isNotNull);
      expect(find.text('Open to review the available choices'), findsNothing);
      expect(
        find.text(
          'This is waiting in Fix sync problems, where you can resolve it. Its details are retained.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('no review action'), findsNothing);
      await captureReview(tester, 'informational-review-light');
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      expect(find.text('legacy_delivery_uncertain'), findsOneWidget);
    },
  );

  for (final language in ['en', 'ro']) {
    testWidgets('linked dose review is clear and scrollable in $language', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(412, 914));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final prefs = await SharedPreferences.getInstance();
      final issue = _reviewIssue().withReviewContext(
        dose: LocalDoseReviewContext(
          medicationName: 'Example medication',
          scheduledAt: DateTime.utc(2026, 10, 8, 10),
          localState: 'taken',
        ),
      );
      await tester.pumpWidget(
        await _buildApp(
          prefs: prefs,
          locale: Locale(language),
          theme: AppTheme.dark(),
          textScaler: const TextScaler.linear(1.3),
          section: SettingsSection.data,
          overrides: [
            migrationIssuesProvider.overrideWith((_) => Stream.value([issue])),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Example medication'), 200);
      await tester.tap(find.text('Example medication'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          language == 'ro'
              ? 'Înregistrare pe acest dispozitiv'
              : 'Record on this device',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Synced stock'), findsNothing);
      expect(find.textContaining('Stoc sincronizat'), findsNothing);
      expect(
        find.text(
          language == 'ro'
              ? 'Păstrează starea serverului'
              : 'Keep server state',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await captureReview(tester, 'linked-dose-review-$language');
    });
  }

  for (final failure in [
    (
      status: 409,
      code: 'CONFLICT_STALE_UPDATE',
      message:
          'This review changed or is no longer ready. Sync, then open it again.',
    ),
    (
      status: 500,
      code: 'INTERNAL_ERROR',
      message:
          'The server could not confirm this review. Sync to check its status before retrying.',
    ),
    (
      status: 401,
      code: 'AUTH_REQUIRED',
      message: 'Sign in again before submitting this review.',
    ),
  ]) {
    testWidgets(
      'review failure ${failure.status} is classified and does not dismiss its evidence',
      (tester) async {
        final prefs = await SharedPreferences.getInstance();
        final request = RequestOptions(
          path: '/medication/legacy-split/reconcile',
        );
        final error = DioException(
          requestOptions: request,
          response: Response(
            requestOptions: request,
            statusCode: failure.status,
            data: {
              'error': {
                'code': failure.code,
                'message': 'PRIVATE_SERVER_DETAIL',
              },
            },
          ),
          type: DioExceptionType.badResponse,
        );
        await tester.pumpWidget(
          await _buildApp(
            prefs: prefs,
            section: SettingsSection.data,
            overrides: [
              migrationIssuesProvider.overrideWith(
                (_) => Stream.value([_reviewIssue()]),
              ),
              migrationIssueResolutionRepositoryProvider.overrideWithValue(
                _RejectedReviewRepository(error),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('A medication update needs review'),
          200,
        );
        await tester.tap(find.text('A medication update needs review'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Keep server state'));
        await tester.pumpAndSettle();
        expect(find.text(failure.message), findsOneWidget);
        expect(find.text('A medication update needs review'), findsOneWidget);
        expect(find.textContaining('PRIVATE_SERVER_DETAIL'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Data offers one batch time review and keeps individual issues', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final issues = [
      'schedule_timezone_review_required',
      'schedule_timezone_review_required',
      'invalid_schedule_frequency_days',
      'legacy_delivery_uncertain',
    ];
    await tester.pumpWidget(
      await _buildApp(
        prefs: prefs,
        section: SettingsSection.data,
        overrides: [
          migrationIssuesProvider.overrideWith(
            (_) => Stream.value([
              for (var i = 0; i < issues.length; i++)
                MigrationIssueSummary(
                  id: 'fictional-issue-$i',
                  entityId: 'fictional-schedule-$i',
                  issueCode: issues[i],
                  revision: 1,
                  resolutionState: 'unresolved',
                  kind: i == 3
                      ? MigrationIssueKind.other
                      : MigrationIssueKind.schedule,
                  createdAt: DateTime.utc(2026, 10, 4),
                  isServerIssue: true,
                ),
            ]),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('legacy-routine-review-entry')),
      findsOneWidget,
    );
    expect(find.text('Review routine times together'), findsOneWidget);
    expect(find.text('A schedule needs review'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'overview groups remain readable and existing reminders are reachable',
    (tester) async {
      _view(tester, const Size(412, 914));
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(await _buildApp(prefs: prefs, section: null));
      await tester.pumpAndSettle();
      expect(find.text('Make Simpastil work for you'), findsOneWidget);
      expect(find.text('App layout'), findsOneWidget);
      expect(find.text('Colors and theme'), findsOneWidget);
      expect(find.text('Snooze duration'), findsNothing);
      expect(find.text('Journal'), findsNothing);
      await tester.tap(find.text('Reminders'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Snooze duration'), 200);
      expect(find.text('Snooze duration'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('App layout'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'Romanian dark large text keeps data entries reachable with reduced motion',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      _view(tester, const Size(412, 914));
      await tester.pumpWidget(
        await _buildApp(
          prefs: prefs,
          section: null,
          locale: const Locale('ro'),
          theme: ThemeData.dark(),
          textScaler: const TextScaler.linear(2),
          reducedMotion: true,
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Copii de siguranță'), 200);
      await tester.pump();
      await tester.tap(find.text('Copii de siguranță'));
      await tester.pump();
      expect(
        find.text(
          'Un fișier portabil pentru restaurarea datelor. Rapoartele PDF sau CSV nu sunt copii restaurabile.',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      final route = ModalRoute.of(
        tester.element(find.byType(BackupSettingsScreen)),
      );
      expect(route!.animation!.value, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('lock settings pass the app locale to device authentication', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final authenticator = _FallbackAuthenticator();
    final controller = AppLockController(
      AppLockPolicyStore(
        SharedAppLockPolicyStorage(prefs),
        gate: SerialProjectionEffectsGate(),
      ),
      authenticator,
    );
    await tester.pumpWidget(
      await _buildApp(
        prefs: prefs,
        locale: const Locale('ro'),
        section: SettingsSection.protection,
        overrides: [appLockControllerProvider.overrideWith((_) => controller)],
      ),
    );
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('settings-app-lock'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(authenticator.fallbackLabel, 'Folosește blocarea dispozitivului');
    expect(controller.current.enabled, isFalse);
    expect(
      find.text('Blocarea aplicației nu a fost modificată.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'default initialization waits and displays restored preferences',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      late ProjectionEffectsGate gate;
      final app = await _buildApp(
        prefs: prefs,
        preferenceGateReady: (value) => gate = value,
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      final restore = gate.run(() async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      await tester.binding.setSurfaceSize(const Size(1600, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      try {
        await tester.pumpWidget(app);
        await tester.pumpAndSettle();
        expect(prefs.getInt('snooze_duration_minutes_u1'), isNull);
        expect(prefs.getInt('auto_miss_delay_minutes_u1'), isNull);
        // The restore owns the barrier while publishing its reviewed values.
        await prefs.setInt('snooze_duration_minutes_u1', 30);
        await prefs.setInt('auto_miss_delay_minutes_u1', 45);
        await prefs.setBool('auto_miss_enabled_u1', true);
      } finally {
        release.complete();
        await restore;
      }
      await tester.pumpAndSettle();
      expect(prefs.getInt('snooze_duration_minutes_u1'), 30);
      expect(prefs.getInt('auto_miss_delay_minutes_u1'), 45);
      expect(find.text('30 min'), findsOneWidget);
      expect(find.text('45 min'), findsOneWidget);
    },
  );

  testWidgets('a later user setting waits for restore and stays saved', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'snooze_duration_minutes_u1': 15,
      'auto_miss_delay_minutes_u1': 15,
    });
    final prefs = await SharedPreferences.getInstance();
    late ProjectionEffectsGate gate;
    await tester.binding.setSurfaceSize(const Size(1600, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      await _buildApp(
        prefs: prefs,
        preferenceGateReady: (value) => gate = value,
      ),
    );
    await tester.pumpAndSettle();
    final entered = Completer<void>();
    final release = Completer<void>();
    final restore = gate.run(() async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    try {
      await tester.tap(find.byTooltip('Increase Snooze duration'));
      await tester.pumpAndSettle();
      expect(prefs.getInt('snooze_duration_minutes_u1'), 15);
      await prefs.setInt('snooze_duration_minutes_u1', 30);
    } finally {
      release.complete();
      await restore;
    }
    await tester.pumpAndSettle();
    expect(prefs.getInt('snooze_duration_minutes_u1'), 20);
    await prefs.reload();
    expect(prefs.getInt('snooze_duration_minutes_u1'), 20);
    expect(find.text('20 min'), findsOneWidget);
  });

  testWidgets('shows snooze row and hides auto-miss row when disabled', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'auto_miss_enabled_u1': false});
    final prefs = await SharedPreferences.getInstance();

    await tester.binding.setSurfaceSize(const Size(1600, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(await _buildApp(prefs: prefs));
    await tester.pumpAndSettle();

    expect(find.text('Snooze duration'), findsOneWidget);
    expect(find.text('Record as missed after'), findsNothing);
  });

  testWidgets('shows auto-miss delay row only when enabled', (tester) async {
    SharedPreferences.setMockInitialValues({'auto_miss_enabled_u1': true});
    final prefs = await SharedPreferences.getInstance();

    await tester.binding.setSurfaceSize(const Size(1600, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(await _buildApp(prefs: prefs));
    await tester.pumpAndSettle();

    expect(find.text('Snooze duration'), findsOneWidget);
    expect(find.text('Record as missed after'), findsOneWidget);
  });

  group('record missed doses', () {
    testWidgets('says it records on every device and is not undone by off', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.binding.setSurfaceSize(const Size(1600, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(await _buildApp(prefs: prefs));
      await tester.pumpAndSettle();

      expect(find.text('Record missed doses'), findsOneWidget);
      expect(find.textContaining('on every device'), findsOneWidget);
      expect(find.textContaining('does not undo'), findsOneWidget);
    });

    testWidgets('switching on starts looking back from now, off clears it', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.binding.setSurfaceSize(const Size(1600, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(await _buildApp(prefs: prefs));
      await tester.pumpAndSettle();

      // Nobody has answered, so recording is already on and the first tap is
      // the one that stops it.
      expect(find.text('Record as missed after'), findsOneWidget);

      await tester.tap(find.text('Record missed doses'));
      await tester.pumpAndSettle();

      expect(prefs.getBool('auto_miss_enabled_u1'), isFalse);
      expect(prefs.getInt('auto_miss_since_u1'), isNull);
      expect(find.text('Record as missed after'), findsNothing);

      final before = DateTime.now().toUtc().millisecondsSinceEpoch;
      await tester.tap(find.text('Record missed doses'));
      await tester.pumpAndSettle();

      expect(prefs.getBool('auto_miss_enabled_u1'), isTrue);
      final since = prefs.getInt('auto_miss_since_u1');
      expect(since, isNotNull);
      expect(since! >= before, isTrue);
      expect(find.text('Record as missed after'), findsOneWidget);
    });

    // The shared fixture is a connected workspace; [local] swaps in a local one.
    Future<void> open(
      WidgetTester tester,
      Map<String, Object> values, {
      bool local = false,
    }) async {
      SharedPreferences.setMockInitialValues({
        'auto_miss_enabled_u1': true,
        ...values,
      });
      final prefs = await SharedPreferences.getInstance();
      await tester.binding.setSurfaceSize(const Size(1600, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        await _buildApp(
          prefs: prefs,
          overrides: [
            if (local)
              workspaceContextProvider.overrideWith(
                (ref) => Stream.value(
                  const WorkspaceContext(
                    workspaceId: 'w1',
                    ownerUserId: 'u1',
                    authorId: 'a1',
                    kind: WorkspaceKind.local,
                    accessEpoch: 1,
                  ),
                ),
              ),
          ],
        ),
      );
      await tester.pumpAndSettle();
    }

    const flag = ValueKey('auto-miss-server-unsupported');

    testWidgets('a connected server without recorded misses is flagged', (
      tester,
    ) async {
      await open(tester, {});
      expect(find.byKey(flag), findsOneWidget);
      expect(find.text('Record as missed after'), findsOneWidget);
    });

    testWidgets('a server on the old contract is flagged', (tester) async {
      await open(tester, {
        'server_medication_ledger_active': true,
        'server_records_missed_doses': false,
      });
      expect(find.byKey(flag), findsOneWidget);
    });

    testWidgets('a connected server that records misses shows no flag', (
      tester,
    ) async {
      await open(tester, {
        'server_medication_ledger_active': true,
        'server_records_missed_doses': true,
      });
      expect(find.byKey(flag), findsNothing);
      expect(find.text('Record as missed after'), findsOneWidget);
    });

    testWidgets('a local workspace shows no flag', (tester) async {
      await open(tester, {}, local: true);
      expect(find.byKey(flag), findsNothing);
      expect(find.text('Record as missed after'), findsOneWidget);
    });
  });

  testWidgets('plus button updates snooze duration by 5 minutes', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'auto_miss_enabled_u1': false});
    final prefs = await SharedPreferences.getInstance();

    await tester.binding.setSurfaceSize(const Size(1600, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(await _buildApp(prefs: prefs));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Increase Snooze duration'));
    await tester.pumpAndSettle();

    expect(find.text('20 min'), findsOneWidget);
  });

  testWidgets('tapping snooze row opens dialog and accepts manual value', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'auto_miss_enabled_u1': false});
    final prefs = await SharedPreferences.getInstance();

    await tester.binding.setSurfaceSize(const Size(1600, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(await _buildApp(prefs: prefs));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Snooze duration'));
    await tester.pumpAndSettle();

    expect(find.text('Minutes'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '37');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('37 min'), findsOneWidget);
  });

  group('sync status row', () {
    testWidgets('shows failure state with error and pending count', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      await tester.binding.setSurfaceSize(const Size(1600, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        await _buildApp(
          prefs: prefs,
          section: SettingsSection.data,
          overrides: [
            syncStatusProvider.overrideWith(_FailingSyncStatusNotifier.new),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Offline'), findsOneWidget);
      expect(find.textContaining('You appear to be offline'), findsOneWidget);
      expect(find.textContaining('since 2:02 PM'), findsOneWidget);
      expect(find.textContaining('3 changes waiting'), findsOneWidget);
    });

    testWidgets('shows synced state', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      await tester.binding.setSurfaceSize(const Size(1600, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        await _buildApp(
          prefs: prefs,
          section: SettingsSection.data,
          overrides: [
            syncStatusProvider.overrideWith(_IdleSyncStatusNotifier.new),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Synced'), findsOneWidget);
      expect(find.text('Last synced'), findsNothing); // old tile replaced
    });
  });

  final initializationCases =
      <({String name, SettingsSection? section, bool reminders, bool about})>[
        (name: 'overview', section: null, reminders: false, about: false),
        (
          name: 'protection',
          section: SettingsSection.protection,
          reminders: false,
          about: false,
        ),
        (
          name: 'medication',
          section: SettingsSection.medication,
          reminders: false,
          about: false,
        ),
        (
          name: 'people',
          section: SettingsSection.people,
          reminders: false,
          about: false,
        ),
        (
          name: 'account',
          section: SettingsSection.account,
          reminders: false,
          about: false,
        ),
        (
          name: 'data',
          section: SettingsSection.data,
          reminders: false,
          about: false,
        ),
        (
          name: 'about',
          section: SettingsSection.about,
          reminders: false,
          about: true,
        ),
        (
          name: 'backups',
          section: SettingsSection.backups,
          reminders: false,
          about: false,
        ),
        (
          name: 'storage',
          section: SettingsSection.storage,
          reminders: false,
          about: false,
        ),
        (
          name: 'reminders',
          section: SettingsSection.reminders,
          reminders: true,
          about: false,
        ),
      ];

  for (final page in initializationCases) {
    testWidgets('${page.name} initializes only its settings capabilities', (
      tester,
    ) async {
      final previousPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      // The phone's overview; a wider window opens Reminders beside the list.
      if (page.section == null) _view(tester, const Size(412, 914));
      try {
        final prefs = await SharedPreferences.getInstance();
        var permissionChecks = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_permissionChannel, (call) async {
              if (call.method == 'checkPermissionStatus') permissionChecks++;
              if (call.method == 'checkPermissionStatus') return 0;
              if (call.method == 'openAppSettings') return false;
              return null;
            });
        final fakeNotifications = FakeNotificationsPlugin();
        notificationsPlugin = fakeNotifications;

        await tester.pumpWidget(
          await _buildApp(
            prefs: prefs,
            section: page.section,
            overrides: page.section == SettingsSection.storage
                ? [_storageSnapshotOverride()]
                : const [],
          ),
        );
        await tester.pumpAndSettle();

        if (page.reminders) {
          expect(permissionChecks, greaterThan(0));
          verify(
            () => fakeNotifications
                .resolvePlatformSpecificImplementation<
                  AndroidFlutterLocalNotificationsPlugin
                >(),
          ).called(greaterThan(0));
          expect(prefs.getInt('snooze_duration_minutes_u1'), 15);
          expect(prefs.getInt('auto_miss_delay_minutes_u1'), 60);
        } else {
          expect(permissionChecks, 0);
          verifyNever(
            () => fakeNotifications
                .resolvePlatformSpecificImplementation<
                  AndroidFlutterLocalNotificationsPlugin
                >(),
          );
          expect(prefs.getInt('snooze_duration_minutes_u1'), isNull);
          expect(prefs.getInt('auto_miss_delay_minutes_u1'), isNull);
        }
        if (page.about) {
          expect(find.text('v1.0.0+1'), findsOneWidget);
        } else {
          expect(find.text('v1.0.0+1'), findsNothing);
        }

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      } finally {
        debugDefaultTargetPlatformOverride = previousPlatform;
      }
    });
  }

  final subscriptionCases =
      <
        ({
          String name,
          SettingsSection? section,
          bool issues,
          bool sync,
          bool profiles,
        })
      >[
        (
          name: 'overview',
          section: null,
          issues: false,
          sync: false,
          profiles: false,
        ),
        (
          name: 'protection',
          section: SettingsSection.protection,
          issues: false,
          sync: false,
          profiles: false,
        ),
        (
          name: 'medication',
          section: SettingsSection.medication,
          issues: false,
          sync: false,
          profiles: false,
        ),
        (
          name: 'account',
          section: SettingsSection.account,
          issues: false,
          sync: false,
          profiles: false,
        ),
        (
          name: 'about',
          section: SettingsSection.about,
          issues: false,
          sync: false,
          profiles: false,
        ),
        (
          name: 'reminders',
          section: SettingsSection.reminders,
          issues: false,
          sync: false,
          // The status reads which people are switched on for this device,
          // so "Reminders on" is never shown when nobody is.
          profiles: true,
        ),
        (
          name: 'people',
          section: SettingsSection.people,
          issues: false,
          sync: false,
          profiles: true,
        ),
        (
          name: 'data',
          section: SettingsSection.data,
          issues: true,
          sync: true,
          profiles: false,
        ),
        (
          name: 'backups',
          section: SettingsSection.backups,
          issues: false,
          sync: false,
          profiles: false,
        ),
        (
          name: 'storage',
          section: SettingsSection.storage,
          issues: false,
          sync: false,
          profiles: false,
        ),
      ];

  for (final page in subscriptionCases) {
    testWidgets('${page.name} subscribes only to its section state', (
      tester,
    ) async {
      if (page.section == null) _view(tester, const Size(412, 914));
      final prefs = await SharedPreferences.getInstance();
      final observer = _SettingsProviderObserver();
      await tester.pumpWidget(
        await _buildApp(
          prefs: prefs,
          section: page.section,
          observers: [observer],
          overrides: page.section == SettingsSection.storage
              ? [_storageSnapshotOverride()]
              : const [],
        ),
      );
      await tester.pumpAndSettle();

      expect(observer.migrationIssueStarts > 0, page.issues);
      expect(observer.syncStatusStarts > 0, page.sync);
      expect(observer.hasProfileSubscription, page.profiles);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }

  testWidgets('Data follows live issue and sync updates', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final observer = _SettingsProviderObserver();
    final issueChanges = StreamController<List<MigrationIssueSummary>>();
    final syncStatus = _MutableSyncStatusNotifier();
    await tester.binding.setSurfaceSize(const Size(1600, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      await _buildApp(
        prefs: prefs,
        section: SettingsSection.data,
        observers: [observer],
        overrides: [
          migrationIssuesProvider.overrideWith((_) => issueChanges.stream),
          syncStatusProvider.overrideWith(() => syncStatus),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Synced'), findsOneWidget);

    issueChanges.add([_reviewIssue()]);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('A medication update needs review'), findsOneWidget);
    expect(find.text('Review needed'), findsOneWidget);

    issueChanges.add(const []);
    syncStatus.reportOffline();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('Offline'), findsOneWidget);
    expect(find.text('A medication update needs review'), findsNothing);
    expect(observer.migrationIssueStarts, 1);
    expect(observer.migrationIssueUpdates, greaterThan(0));
    expect(observer.syncStatusStarts, 1);
    expect(observer.syncStatusUpdates, greaterThan(0));
    expect(observer.hasProfileSubscription, isFalse);

    unawaited(issueChanges.close());
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('Data hides previous reviews during failure and retry', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final changes = StreamController<List<MigrationIssueSummary>>.broadcast();
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      await _buildApp(
        prefs: prefs,
        section: SettingsSection.data,
        overrides: [
          migrationIssuesProvider.overrideWith((_) => changes.stream),
        ],
      ),
    );
    await tester.pumpAndSettle();
    changes.add([_reviewIssue()]);
    await tester.pumpAndSettle();
    expect(find.text('A medication update needs review'), findsOneWidget);

    changes.addError(StateError('Fictional revoked review access'));
    await tester.pumpAndSettle();
    expect(find.text('A medication update needs review'), findsNothing);
    expect(
      find.byKey(const ValueKey('sync-review-unavailable')),
      findsOneWidget,
    );
    expect(
      find.text(
        'These details are temporarily unavailable. Your data is preserved.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('A medication update needs review'), findsNothing);
    expect(find.text('Loading…'), findsOneWidget);

    changes.add([_reviewIssue()]);
    await tester.pumpAndSettle();
    expect(find.text('A medication update needs review'), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-review-unavailable')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    unawaited(changes.close());
  });

  testWidgets('password sheet validates locally and resets when reopened', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await tester.binding.setSurfaceSize(const Size(412, 914));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      await _buildApp(
        prefs: prefs,
        section: SettingsSection.account,
        serverUrl: 'https://fictional-account.example',
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Change password'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update password'));
    await tester.pumpAndSettle();

    expect(find.text('Current password is required'), findsOneWidget);
    expect(find.text('New password is required'), findsOneWidget);
    expect(find.text('Please confirm your new password'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).first, 'synthetic-only');
    Navigator.of(tester.element(find.byType(ChangePasswordSheet))).pop();
    await tester.pumpAndSettle();
    expect(find.text('Current password is required'), findsNothing);

    await tester.tap(find.text('Change password'));
    await tester.pumpAndSettle();
    expect(find.text('Current password is required'), findsNothing);
    expect(find.text('New password is required'), findsNothing);
    expect(find.text('Please confirm your new password'), findsNothing);
    expect(
      tester
          .widget<TextFormField>(find.byType(TextFormField).first)
          .controller!
          .text,
      isEmpty,
    );
  });

  testWidgets('2FA sheet opens with choices but no setup or secret', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final authRepository = _GuardedAuthRepository();
    await tester.binding.setSurfaceSize(const Size(412, 914));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      await _buildApp(
        prefs: prefs,
        section: SettingsSection.account,
        serverUrl: 'https://fictional-account.example',
        overrides: [authRepositoryProvider.overrideWithValue(authRepository)],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Two-factor authentication').first);
    await tester.pumpAndSettle();

    expect(find.text('Set up 2FA'), findsOneWidget);
    expect(find.text('Manual entry key:'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(authRepository.setupCalls, 0);
  });

  // Every settings page shares the window class's content width, so column
  // edges line up from Today to Settings, and its scroll view spans the pane
  // so a swipe in the side margins scrolls the page. These are the pages
  // pushed over the phone's overview: on a wide window the same pages sit in
  // the pane instead (settings_master_detail_test.dart). The colour editor and
  // the layout chooser lay themselves out in their own tests.
  for (final size in [const Size(1205, 753), const Size(753, 1205)]) {
    final column = size.width >= 840 ? 720.0 : 640.0;
    final sections = <SettingsSection>[
      for (final section in SettingsSection.values)
        if (section != SettingsSection.layout &&
            section != SettingsSection.colors &&
            section != SettingsSection.accessibility)
          section,
    ];
    for (final section in sections) {
      testWidgets('settings ${section.name} keeps one centred column at '
          '${size.width.toInt()}x${size.height.toInt()}', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final prefs = await SharedPreferences.getInstance();
        await tester.pumpWidget(
          await _buildApp(
            prefs: prefs,
            section: section,
            serverUrl: 'https://fictional-account.example',
            overrides: [
              if (section == SettingsSection.storage)
                _storageSnapshotOverride(),
            ],
          ),
        );
        await tester.pumpAndSettle();
        final list = find.byType(ListView).first;
        expect(tester.getSize(list).width, size.width);
        final padding = tester
            .widget<ListView>(list)
            .padding!
            .resolve(TextDirection.ltr);
        // The page's own padding sits inside a gutter that centres the
        // column: nothing is wider than the token.
        final gutter = (size.width - column) / 2;
        expect(padding.left, greaterThanOrEqualTo(gutter));
        expect(padding.right, greaterThanOrEqualTo(gutter));
        expect(padding.left, padding.right);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
