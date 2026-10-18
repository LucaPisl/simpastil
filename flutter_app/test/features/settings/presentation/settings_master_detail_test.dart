import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/device/battery_optimization.dart';
import 'package:simpastil/core/l10n/locale_provider.dart';
import 'package:simpastil/core/notifications/next_reminders.dart';
import 'package:simpastil/core/notifications/notification_plugin.dart';
import 'package:simpastil/core/notifications/reminder_preferences.dart';
import 'package:simpastil/core/server/server_config_notifier.dart';
import 'package:simpastil/core/theme/theme_provider.dart';
import 'package:simpastil/core/workspace/workspace_provider.dart';
import 'package:simpastil/core/storage/recovery_copy_service.dart';
import 'package:simpastil/core/storage/storage_inventory_service.dart';
import 'package:simpastil/features/auth/auth_provider.dart';
import 'package:simpastil/features/pills/pill_provider.dart';
import 'package:simpastil/features/profiles/profile_provider.dart';
import 'package:simpastil/features/settings/presentation/appearance_preview.dart';
import 'package:simpastil/features/settings/presentation/appearance_screen.dart';
import 'package:simpastil/features/settings/presentation/backup_settings_screen.dart';
import 'package:simpastil/features/settings/presentation/language_settings.dart';
import 'package:simpastil/features/settings/presentation/layout_chooser_screen.dart';
import 'package:simpastil/features/settings/presentation/people_settings_section.dart';
import 'package:simpastil/features/settings/presentation/reminder_settings_section.dart';
import 'package:simpastil/features/settings/presentation/settings_overview.dart';
import 'package:simpastil/features/settings/presentation/settings_pane.dart';
import 'package:simpastil/features/settings/presentation/settings_screen.dart';
import 'package:simpastil/features/settings/presentation/storage_settings_screen.dart';
import 'package:simpastil/core/api/api_client.dart';
import 'package:simpastil/features/updates/data/update_hint.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/l10n/app_localizations_en.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;

import '../../../helpers/fake_notifications_plugin.dart';
import '../../../helpers/planned_dose_fixture.dart';
import '../../../helpers/protected_workspace_fixture.dart';
import '../../../helpers/review_rendering.dart';

const _alex = '00000000-0000-4000-8000-0000000000a1';

const _permissionChannel = MethodChannel(
  'flutter.baseflow.com/permissions/methods',
);

class _AuthNotifier extends AuthNotifier {
  @override
  AuthState build() => const AuthAuthenticated('u1');
}

class _ThemeModeNotifier extends ThemeModeNotifier {
  @override
  Future<AppThemeMode> build() async => AppThemeMode.system;
}

class _PrimaryProfileNotifier extends PrimaryProfileNotifier {
  @override
  Future<String?> build() async => null;
}

class _SiblingDetectionNotifier extends SiblingDetectionNotifier {
  @override
  SiblingDetectionMode build() => SiblingDetectionMode.nameAndDosage;
}

class _ServerConfigNotifier extends ServerConfigNotifier {
  @override
  String? build() => null;
}

/// The windows the Settings tablet work is held to, with their names.
const _windows = <String, Size>{
  'expanded': Size(1205, 753),
  'medium': Size(753, 1205),
  'phone': Size(412, 915),
  'small phone': Size(360, 800),
};

/// A window of [size] logical pixels. `setSurfaceSize` only changes what the
/// tree is laid out in; the size MediaQuery reports, and so the window class,
/// follows the view.
void _view(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Settings itself, or, with [pushed], a plain first page with a button that
/// opens it, the way Settings sits over Today.
Widget _home({required bool pushed}) => pushed
    ? Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
              ),
              child: const Text('Open settings'),
            ),
          ),
        ),
      )
    : const SettingsScreen();

/// Settings with a fictional workspace. A few planned doses give the Next
/// reminders list something to show. With [pushed] the screen sits over a
/// plain first page, the way Settings sits over Today.
Future<ProviderContainer> _mount(
  WidgetTester tester, {
  Locale locale = const Locale('en'),
  double scale = 1,
  Brightness brightness = Brightness.light,
  bool pushed = false,
  bool doses = true,
  Widget? page,
  List<Override> extraOverrides = const [],
}) async {
  final prefs = await SharedPreferences.getInstance();
  final fixture = await ProtectedWorkspaceFixture.create(
    ownerId: 'u1',
    preferences: prefs,
  );
  final planned = <MedicationOccurrence>[];
  if (doses) {
    final now = DateTime.now();
    final base = DateTime(now.year, now.month, now.day, now.hour + 2);
    final stamp = now.toUtc();
    final times = [
      base,
      base.add(const Duration(hours: 3)),
      DateTime(now.year, now.month, now.day + 1, 8),
      DateTime(now.year, now.month, now.day + 2, 21),
    ];
    for (var i = 0; i < times.length; i++) {
      planned.add(
        await storePlannedDose(
          fixture.db,
          userId: 'u1',
          id: 'dose-$i',
          at: times[i].toUtc(),
          now: stamp,
          pill: [
            'Fictional vitamin',
            'Fictional iron',
            'Fictional zinc',
            'Fictional D',
          ][i],
          dosage: ['1 tablet', '10 mg', '2 capsules', '1 drop'][i],
          profileId: _alex,
          profileName: 'Alex',
          scheduleId: 'schedule-$i',
        ),
      );
    }
  }
  final container = ProviderContainer(
    overrides: [
      ...fixture.overrides,
      serverConfigProvider.overrideWith(() => _ServerConfigNotifier()),
      authNotifierProvider.overrideWith(() => _AuthNotifier()),
      profileListProvider.overrideWith((_) => Stream.value(const [])),
      primaryProfileIdProvider.overrideWith(() => _PrimaryProfileNotifier()),
      themeModeNotifierProvider.overrideWith(() => _ThemeModeNotifier()),
      siblingDetectionModeProvider.overrideWith(
        () => _SiblingDetectionNotifier(),
      ),
      storageSettingsSnapshotProvider.overrideWith(
        (_) async => const StorageSettingsSnapshot(
          StorageInventory({
            StorageCategory.care: null,
            StorageCategory.recovery: 0,
          }),
          RecoveryCopyCheck(RecoveryCopyState.absent),
          RecoveryCopyCheck(RecoveryCopyState.absent),
        ),
      ),
      nextRemindersSourceProvider.overrideWith(
        (ref) => Stream.value(
          NextRemindersSource(
            userId: 'u1',
            identity: null,
            activeProfileIds: const {_alex},
            occurrences: planned,
            preferences: ReminderPreferences(),
          ),
        ),
      ),
      ...extraOverrides,
    ],
  );
  await container.read(workspaceContextProvider.future);
  addTearDown(container.dispose);
  addTearDown(fixture.db.close);
  final theme = reviewRenderingTheme(
    brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: locale,
        theme: theme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: RepaintBoundary(key: reviewCaptureKey, child: child!),
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: page ?? _home(pushed: pushed),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (pushed) {
    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
  }
  return container;
}

/// A widget test that unmounts what it mounted: Reminders reads a Drift stream
/// whose cancelled watch leaves a zero-length timer, which the test would
/// otherwise end with.
void _test(String name, Future<void> Function(WidgetTester tester) body) {
  testWidgets(name, (tester) async {
    await body(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}

final _en = AppLocalizationsEn();

class _Battery extends BatteryOptimization {
  _Battery(this.restricted);
  bool restricted;
  int requests = 0;
  @override
  Future<bool> isRestricted() async => restricted;
  @override
  Future<bool> requestUnrestricted() async {
    requests++;
    restricted = false;
    return true;
  }
}

Finder _row(SettingsSection section) =>
    find.byKey(ValueKey('settings-row-${section.name}'));

/// The fill of the list row for [section]: the primary container when it is
/// the open one, nothing otherwise.
Color? _rowFill(WidgetTester tester, SettingsSection section) => tester
    .widget<Material>(
      find.descendant(of: _row(section), matching: find.byType(Material)).first,
    )
    .color;

/// Scrolls the Reminders page until [finder] is built and on screen: the page
/// builds its cards lazily.
Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    300,
    scrollable: find
        .descendant(
          of: find.byType(ReminderSettingsSection),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pumpAndSettle();
}

Future<void> _open(WidgetTester tester, SettingsSection section) async {
  await tester.ensureVisible(_row(section));
  await tester.pumpAndSettle();
  await tester.tap(_row(section));
  await tester.pumpAndSettle();
}

SettingsPaneScope _pane(WidgetTester tester) => SettingsPaneScope.maybeOf(
  tester.element(find.byKey(const ValueKey('settings-pane'))),
)!;

/// The pane's own scope sits inside the pane, so ask from a page in it.
SettingsPaneScope _paneOf(WidgetTester tester, Type page) =>
    SettingsPaneScope.maybeOf(tester.element(find.byType(page)))!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    tz_data.initializeTimeZones();
    await loadReviewFonts();
  });

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

  group('expanded window', () {
    _test('shows the update card above the list, as the phone does', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        UpdateHint.latestBuildKey: simpastilClientBuild + 1,
        UpdateHint.releaseUrlKey:
            'https://github.com/LucaPisl/simpastil/releases/tag/v1.2.0',
        UpdateHint.sourceKey: 'github',
      });
      _view(tester, _windows['expanded']!);
      await _mount(tester);
      final card = find.byKey(const ValueKey('update-available-card'));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('settings-list')),
          matching: card,
        ),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(card).dy,
        lessThan(tester.getTopLeft(_row(SettingsSection.layout)).dy),
      );
    });

    _test('shows the list on the left and Reminders open beside it', (
      tester,
    ) async {
      _view(tester, _windows['expanded']!);
      await _mount(tester);
      final list = find.byKey(const ValueKey('settings-list'));
      final pane = find.byKey(const ValueKey('settings-pane'));
      expect(list, findsOneWidget);
      expect(pane, findsOneWidget);
      expect(tester.getSize(list).width, 320);
      expect(tester.getTopLeft(pane).dx, greaterThanOrEqualTo(320));
      expect(
        find.descendant(
          of: pane,
          matching: find.byType(ReminderSettingsSection),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: pane,
          matching: find.text(SettingsSection.reminders.label(_en)),
        ),
        findsOneWidget,
      );
      // Every row of the phone's overview is in the list.
      for (final section in SettingsSection.values) {
        expect(_row(section), findsOneWidget, reason: section.name);
      }
      expect(find.text('Reduce motion'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    _test('puts Next reminders and the Preview beside the settings', (
      tester,
    ) async {
      _view(tester, _windows['expanded']!);
      await _mount(tester);
      final next = find.byKey(const ValueKey('next-reminders'));
      final preview = find.byKey(const ValueKey('reminder-preview'));
      expect(next, findsOneWidget);
      expect(preview, findsOneWidget);
      expect(find.byKey(const ValueKey('next-dose-0')), findsOneWidget);
      // Two columns: the preview is to the right of the list of reminders.
      expect(
        tester.getTopLeft(preview).dx,
        greaterThan(tester.getTopRight(next).dx),
      );
      // The test notification is under the preview, in the same right-hand column.
      expect(find.text(_en.t15_sendTest), findsOneWidget);
      expect(
        tester.getTopLeft(find.text(_en.t15_sendTest)).dx,
        greaterThan(tester.getTopRight(next).dx),
      );
    });

    _test('highlights the open row and moves it with a tap', (tester) async {
      _view(tester, _windows['expanded']!);
      await _mount(tester);
      final scheme = Theme.of(
        tester.element(find.byKey(const ValueKey('settings-list'))),
      ).colorScheme;
      expect(
        _rowFill(tester, SettingsSection.reminders),
        scheme.primaryContainer,
      );
      expect(_rowFill(tester, SettingsSection.people), Colors.transparent);
      await _open(tester, SettingsSection.people);
      expect(_rowFill(tester, SettingsSection.people), scheme.primaryContainer);
      expect(_rowFill(tester, SettingsSection.reminders), Colors.transparent);
    });

    final pages = <SettingsSection, Type>{
      SettingsSection.people: PeopleSettingsSection,
      SettingsSection.layout: LayoutChooserScreen,
      SettingsSection.colors: AppearanceScreen,
      SettingsSection.accessibility: AppearanceScreen,
      SettingsSection.language: LanguageSettingsPage,
      SettingsSection.backups: BackupSettingsScreen,
      SettingsSection.storage: StorageSettingsScreen,
    };
    for (final entry in pages.entries) {
      _test('opens ${entry.key.name} in the pane without leaving the list', (
        tester,
      ) async {
        _view(tester, _windows['expanded']!);
        await _mount(tester, pushed: true);
        await _open(tester, entry.key);
        final pane = find.byKey(const ValueKey('settings-pane'));
        expect(
          find.descendant(of: pane, matching: find.byType(entry.value)),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('settings-list')), findsOneWidget);
        // Nothing was pushed: Back still goes to the page below Settings.
        expect(find.byType(ReminderSettingsSection), findsNothing);
        expect(
          find.descendant(of: pane, matching: find.text(entry.key.label(_en))),
          findsWidgets,
        );
        expect(tester.takeException(), isNull);
      });
    }

    _test('keeps the colour editor options left, its preview right, '
        'Cancel and Apply in the header', (tester) async {
      _view(tester, _windows['expanded']!);
      await _mount(tester, pushed: true);
      await _open(tester, SettingsSection.colors);
      final options = find.byKey(const ValueKey('appearance-scroll'));
      final preview = find.byKey(const ValueKey('appearance-preview-scroll'));
      expect(options, findsOneWidget);
      expect(preview, findsOneWidget);
      expect(
        tester.getTopLeft(preview).dx,
        greaterThanOrEqualTo(tester.getTopRight(options).dx),
      );
      expect(
        find.byKey(const ValueKey('appearance-preview-heading')),
        findsOneWidget,
      );
      // Cancel and Apply are kept, in the pane's header.
      final apply = find.byKey(const ValueKey('appearance-apply'));
      final cancel = find.byKey(const ValueKey('appearance-cancel'));
      expect(apply, findsOneWidget);
      expect(cancel, findsOneWidget);
      expect(tester.getTopLeft(apply).dy, lessThan(80));
      expect(tester.getTopLeft(cancel).dy, lessThan(80));
      expect(
        find.text('Preview on this device'),
        findsOneWidget,
        reason:
            'the preview is the colour editor\'s own, named for this device',
      );
      expect(find.text('Preview on this tablet'), findsNothing);
      // The pane's right column is filled: the forms and states preview is
      // open by default, under the example card, inside the pane.
      final forms = find.byType(AppearanceFormsPreview);
      expect(forms, findsOneWidget);
      expect(
        tester.getTopLeft(forms).dx,
        greaterThanOrEqualTo(tester.getTopRight(options).dx),
      );
      expect(
        find.descendant(of: preview, matching: forms),
        findsOneWidget,
        reason: 'it scrolls with the preview pane, not the options',
      );
      // The section's outline is painted over its content: the preview has a
      // fill of its own, which would hide the sides of an outline underneath.
      final outline = find
          .ancestor(
            of: find.byKey(const ValueKey('appearance-forms-preview')),
            matching: find.byType(DecoratedBox),
          )
          .first;
      expect(
        tester.widget<DecoratedBox>(outline).position,
        DecorationPosition.foreground,
      );
    });

    _test('opens the display options from the Accessibility row', (
      tester,
    ) async {
      _view(tester, _windows['expanded']!);
      await _mount(tester);
      await _open(tester, SettingsSection.colors);
      expect(find.byKey(const ValueKey('appearance-dynamic')), findsNothing);
      await _open(tester, SettingsSection.accessibility);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('appearance-dynamic')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('settings-pane')),
          matching: find.text(SettingsSection.accessibility.label(_en)),
        ),
        findsWidgets,
      );
    });

    _test('opens the layout chooser in the pane from the colour editor', (
      tester,
    ) async {
      _view(tester, _windows['expanded']!);
      await _mount(tester, pushed: true);
      await _open(tester, SettingsSection.colors);
      final tile = find.byKey(const ValueKey('appearance-layout'));
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(find.byType(LayoutChooserScreen), findsOneWidget);
      expect(
        _rowFill(tester, SettingsSection.layout),
        isNot(Colors.transparent),
      );
      expect(find.byType(AppearanceScreen), findsNothing);
    });

    _test('chooses the language in the pane, without a sheet', (tester) async {
      _view(tester, _windows['expanded']!);
      final container = await _mount(tester);
      await _open(tester, SettingsSection.language);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(LanguageChoiceList), findsOneWidget);
      await tester.tap(find.text(_en.settings_languageRomanian));
      await tester.pumpAndSettle();
      expect(container.read(localeOverrideProvider), const Locale('ro'));
      // The pane stays open on the language page.
      expect(find.byType(LanguageSettingsPage), findsOneWidget);
    });
  });

  group('medium window', () {
    _test('shows a narrower list beside the open page', (tester) async {
      _view(tester, _windows['medium']!);
      await _mount(tester);
      expect(
        tester.getSize(find.byKey(const ValueKey('settings-list'))).width,
        256,
      );
      expect(find.byType(ReminderSettingsSection), findsOneWidget);
      // The pane is too narrow for two columns: one column, preview below.
      final next = find.byKey(const ValueKey('next-reminders'));
      final preview = find.byKey(const ValueKey('reminder-preview'));
      await _reveal(tester, next);
      final nextRight = tester.getTopRight(next).dx;
      await _reveal(tester, preview);
      expect(tester.getTopLeft(preview).dx, lessThan(nextRight));
      await _open(tester, SettingsSection.colors);
      expect(find.byType(AppearanceScreen), findsOneWidget);
      // One column: Cancel and Apply are in the bottom bar.
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('appearance-apply'))).dy,
        greaterThan(600),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('phone', () {
    _test('keeps the overview and pushes each page over it', (tester) async {
      _view(tester, _windows['phone']!);
      await _mount(tester);
      expect(find.byKey(const ValueKey('settings-list')), findsNothing);
      expect(find.byKey(const ValueKey('settings-pane')), findsNothing);
      expect(find.byType(ReminderSettingsSection), findsNothing);
      await tester.tap(find.text(SettingsSection.reminders.label(_en)).first);
      await tester.pumpAndSettle();
      expect(find.byType(ReminderSettingsSection), findsOneWidget);
      // A pushed page keeps its own back arrow and is not in a pane.
      expect(
        SettingsPaneScope.maybeOf(
          tester.element(find.byType(ReminderSettingsSection)),
        ),
        isNull,
      );
      expect(find.byType(BackButton), findsOneWidget);
      // One column: the preview sits under Next reminders.
      final next = find.byKey(const ValueKey('next-reminders'));
      final preview = find.byKey(const ValueKey('reminder-preview'));
      await _reveal(tester, next);
      final nextRight = tester.getTopRight(next).dx;
      await _reveal(tester, preview);
      expect(tester.getTopLeft(preview).dx, lessThan(nextRight));
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(ReminderSettingsSection), findsNothing);
      expect(find.text(SettingsSection.reminders.label(_en)), findsWidgets);
    });

    _test('says how battery limits stand and offers to lift them', (
      tester,
    ) async {
      _view(tester, _windows['phone']!);
      final battery = _Battery(true);
      await _mount(
        tester,
        extraOverrides: [
          batteryOptimizationProvider.overrideWithValue(battery),
        ],
      );
      await tester.tap(find.text(SettingsSection.reminders.label(_en)).first);
      await tester.pumpAndSettle();
      final status = find.byKey(const ValueKey('battery-status'));
      await _reveal(tester, status);
      expect(find.text('Battery saver may delay reminders'), findsOneWidget);
      expect(find.text('App settings'), findsOneWidget);

      final allow = find.byKey(const ValueKey('battery-allow'));
      await _reveal(tester, allow);
      await tester.tap(allow);
      await tester.pumpAndSettle();
      expect(battery.requests, 1);
      expect(find.text('No battery limits for Simpastil'), findsOneWidget);
      expect(find.byKey(const ValueKey('battery-allow')), findsNothing);
      // The way to Android's own app settings stays.
      expect(find.text('App settings'), findsOneWidget);
    });

    _test('still opens the language in a sheet', (tester) async {
      _view(tester, _windows['phone']!);
      await _mount(tester);
      await tester.ensureVisible(find.text(_en.settings_language));
      await tester.tap(find.text(_en.settings_language).first);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(LanguageChoiceList), findsOneWidget);
      expect(find.byType(LanguageSettingsPage), findsNothing);
    });

    _test('keeps the colour editor as one page with a bottom bar', (
      tester,
    ) async {
      _view(tester, _windows['phone']!);
      // The phone's Colors row pushes this page on the app router.
      await _mount(tester, page: const AppearanceScreen());
      expect(
        find.byKey(const ValueKey('appearance-preview-scroll')),
        findsNothing,
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('appearance-apply'))).dy,
        greaterThan(600),
      );
    });

    _test('gives Reminders the example preview, written for this device', (
      tester,
    ) async {
      _view(tester, _windows['phone']!);
      await _mount(tester, doses: false);
      await tester.tap(find.text(SettingsSection.reminders.label(_en)).first);
      await tester.pumpAndSettle();
      await _reveal(tester, find.byKey(const ValueKey('next-reminders')));
      expect(
        find.text('No reminders are planned for the next 30 days.'),
        findsOneWidget,
      );
      await _reveal(tester, find.byKey(const ValueKey('reminder-preview')));
      expect(
        find.text('An example. No reminder is planned yet.'),
        findsOneWidget,
      );
    });
  });

  group('turning the tablet', () {
    _test('keeps the open page when the window changes class', (tester) async {
      _view(tester, _windows['expanded']!);
      await _mount(tester, pushed: true);
      await _open(tester, SettingsSection.people);
      expect(find.byType(PeopleSettingsSection), findsOneWidget);
      // Down to a phone: the overview, with no pane.
      tester.view.physicalSize = _windows['phone']!;
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-pane')), findsNothing);
      // Back up: the same page is open again.
      tester.view.physicalSize = _windows['medium']!;
      await tester.pumpAndSettle();
      expect(find.byType(PeopleSettingsSection), findsOneWidget);
      expect(
        _rowFill(tester, SettingsSection.people),
        isNot(Colors.transparent),
      );
    });
  });

  group('Back on a wide window', () {
    _test('leaves Settings from any page, with the system Back', (
      tester,
    ) async {
      _view(tester, _windows['expanded']!);
      await _mount(tester, pushed: true);
      await _open(tester, SettingsSection.people);
      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-list')), findsNothing);
      expect(find.text('Open settings'), findsOneWidget);
    });

    _test('leaves Settings from the list\'s arrow', (tester) async {
      _view(tester, _windows['expanded']!);
      await _mount(tester, pushed: true);
      await tester.tap(find.byKey(const ValueKey('settings-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-list')), findsNothing);
      expect(find.text('Open settings'), findsOneWidget);
    });

    _test('leaves Settings from the list\'s arrow on a medium window', (
      tester,
    ) async {
      _view(tester, _windows['medium']!);
      await _mount(tester, pushed: true);
      await _open(tester, SettingsSection.about);
      await tester.tap(find.byKey(const ValueKey('settings-back')));
      await tester.pumpAndSettle();
      expect(find.text('Open settings'), findsOneWidget);
    });

    _test('stays while the open page is busy', (tester) async {
      _view(tester, _windows['expanded']!);
      await _mount(tester, pushed: true);
      final scope = _paneOf(tester, ReminderSettingsSection);
      scope.leaveBlocked.value = true;
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-list')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('settings-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-list')), findsOneWidget);
      // Another row is not opened while the page works either.
      await _open(tester, SettingsSection.people);
      expect(find.byType(PeopleSettingsSection), findsNothing);
      expect(find.byType(ReminderSettingsSection), findsOneWidget);
      // Once it is done, Back leaves again.
      scope.leaveBlocked.value = false;
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-list')), findsNothing);
    });

    _test('undoes a page\'s own step before it leaves', (tester) async {
      _view(tester, _windows['expanded']!);
      await _mount(tester, pushed: true);
      var undone = 0;
      final scope = _paneOf(tester, ReminderSettingsSection);
      scope.stepBack.value = () {
        undone++;
        scope.stepBack.value = null;
      };
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(undone, 1);
      expect(find.byKey(const ValueKey('settings-list')), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-list')), findsNothing);
    });

    _test('goes back through the backup steps, then leaves', (tester) async {
      _view(tester, _windows['expanded']!);
      await _mount(tester, pushed: true);
      await _open(tester, SettingsSection.backups);
      await tester.tap(find.text(_en.t15_checkBackup));
      await tester.pumpAndSettle();
      expect(find.text(_en.t15_checkBackup), findsWidgets);
      expect(find.text(_en.t15_createBackup), findsNothing);
      // Back is the page's step first: it returns to the Backups page.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-list')), findsOneWidget);
      expect(find.text(_en.t15_createBackup), findsOneWidget);
      // On the first step Back leaves Settings.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-list')), findsNothing);
    });

    _test('does not keep a page\'s step when another row is opened', (
      tester,
    ) async {
      _view(tester, _windows['expanded']!);
      await _mount(tester, pushed: true);
      await _open(tester, SettingsSection.backups);
      await tester.tap(find.text(_en.t15_checkBackup));
      await tester.pumpAndSettle();
      await _open(tester, SettingsSection.people);
      expect(_pane(tester).stepBack.value, isNull);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-list')), findsNothing);
    });
  });

  group('phone Back', () {
    _test('goes from a page to the overview, then leaves Settings', (
      tester,
    ) async {
      _view(tester, _windows['phone']!);
      await _mount(tester, pushed: true);
      await tester.tap(find.text(SettingsSection.reminders.label(_en)).first);
      await tester.pumpAndSettle();
      expect(find.byType(ReminderSettingsSection), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ReminderSettingsSection), findsNothing);
      expect(find.text('Open settings'), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Open settings'), findsOneWidget);
    });
  });

  // Nothing overflows at the sizes the layout is held to, in both languages,
  // both brightnesses and with large text. When REVIEW_CAPTURE_DIR is set each
  // state is also written there as a picture for the review.
  group('every size and text scale', () {
    for (final entry in _windows.entries) {
      final compact = entry.value.width < 600;
      for (final scale in [1.0, 1.3]) {
        for (final dark in [false, true]) {
          final name =
              '${entry.key.replaceAll(' ', '-')}-'
              '${scale == 1 ? 'x1' : 'x1.3'}-${dark ? 'dark' : 'light'}';
          final locale = dark ? const Locale('ro') : const Locale('en');
          final brightness = dark ? Brightness.dark : Brightness.light;
          // A phone shows each page on its own; a wide window opens it beside
          // the list.
          _test('Reminders fit: $name', (tester) async {
            _view(tester, entry.value);
            await _mount(
              tester,
              scale: scale,
              brightness: brightness,
              locale: locale,
              page: compact
                  ? const SettingsScreen(section: SettingsSection.reminders)
                  : null,
            );
            expect(tester.takeException(), isNull);
            await captureReview(tester, 'settings-reminders-$name');
            if (compact) {
              await _reveal(
                tester,
                find.byKey(const ValueKey('reminder-preview')),
              );
              expect(tester.takeException(), isNull);
              await captureReview(tester, 'settings-reminders-$name-preview');
            }
          });
          _test('the other pages fit: $name', (tester) async {
            if (compact) {
              // A phone shows the pages that moved into the pane on their own.
              _view(tester, entry.value);
              await _mount(
                tester,
                scale: scale,
                brightness: brightness,
                locale: locale,
                page: const LayoutChooserScreen(),
              );
              expect(tester.takeException(), isNull);
              await captureReview(tester, 'settings-layout-$name');
              return;
            }
            _view(tester, entry.value);
            await _mount(
              tester,
              scale: scale,
              brightness: brightness,
              locale: locale,
            );
            for (final section in [
              SettingsSection.layout,
              SettingsSection.language,
              SettingsSection.backups,
              SettingsSection.people,
            ]) {
              await _open(tester, section);
              expect(tester.takeException(), isNull);
              await captureReview(tester, 'settings-${section.name}-$name');
            }
          });
          _test('the colour editor fits: $name', (tester) async {
            _view(tester, entry.value);
            await _mount(
              tester,
              scale: scale,
              brightness: brightness,
              locale: locale,
              page: compact ? const AppearanceScreen() : null,
            );
            if (!compact) await _open(tester, SettingsSection.colors);
            expect(tester.takeException(), isNull);
            await captureReview(tester, 'settings-colors-$name');
          });
        }
      }
    }
  });
}
