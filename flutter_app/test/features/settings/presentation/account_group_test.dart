import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/server/server_config_notifier.dart';
import 'package:simpastil/core/theme/theme_provider.dart';
import 'package:simpastil/core/workspace/workspace_provider.dart';
import 'package:simpastil/features/auth/auth_provider.dart';
import 'package:simpastil/features/profiles/profile_provider.dart';
import 'package:simpastil/features/settings/presentation/account_actions_section.dart';
import 'package:simpastil/features/settings/presentation/account_follow_widgets.dart';
import 'package:simpastil/features/settings/presentation/account_self_service_sheets.dart';
import 'package:simpastil/features/settings/presentation/account_settings_section.dart';
import 'package:simpastil/features/settings/presentation/settings_master_detail.dart';
import 'package:simpastil/features/settings/presentation/settings_overview.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';

import '../../../helpers/protected_workspace_fixture.dart';
import '../../../helpers/review_rendering.dart';

class _Auth extends AuthNotifier {
  _Auth(this._state);
  final AuthState _state;
  @override
  AuthState build() => _state;
}

class _Server extends ServerConfigNotifier {
  @override
  String? build() => 'https://pills.example.test';
}

class _ThemeMode extends ThemeModeNotifier {
  @override
  Future<AppThemeMode> build() async => AppThemeMode.system;
}

class _Primary extends PrimaryProfileNotifier {
  @override
  Future<String?> build() async => null;
}

Future<void> _mount(
  WidgetTester tester,
  Widget home, {
  AuthState auth = const AuthAuthenticated('u1'),
  Locale locale = const Locale('en'),
  Brightness brightness = Brightness.light,
  double scale = 1,
  // Tall, so the whole lazy overview is built and can be compared.
  Size size = const Size(412, 2600),
  bool selfService = true,
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final prefs = await SharedPreferences.getInstance();
  final fixture = await ProtectedWorkspaceFixture.create(
    ownerId: 'u1',
    preferences: prefs,
  );
  final overrides = <Override>[
    ...fixture.overrides,
    serverConfigProvider.overrideWith(_Server.new),
    authNotifierProvider.overrideWith(() => _Auth(auth)),
    profileListProvider.overrideWith((_) => Stream.value(const [])),
    localCareKeptProvider.overrideWith((_) => Stream.value(false)),
    primaryProfileIdProvider.overrideWith(_Primary.new),
    themeModeNotifierProvider.overrideWith(_ThemeMode.new),
    accountSelfServiceSupportedProvider.overrideWith((_) async => selfService),
    accountSettingsSupportedProvider.overrideWith((_) async => true),
    accountSettingsNoteProvider.overrideWith((_) async => const []),
  ];
  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: overrides,
  );
  container.listen(workspaceContextProvider, (_, _) {});
  await container.read(workspaceContextProvider.future);
  addTearDown(fixture.db.close);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: locale,
        theme: reviewRenderingTheme(
          brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: home,
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

double _y(WidgetTester tester, Finder finder) =>
    tester.getTopLeft(finder.first).dy;

Finder _key(String key) => find.byKey(ValueKey(key));

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find.byType(Scrollable).first,
  );
}

SettingsOverview _overview() =>
    SettingsOverview(onSection: (_) {}, onLanguage: () {});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadReviewFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Account group holds the actions in order, Delete last and set '
      'apart', (tester) async {
    await _mount(tester, _overview());
    await _scrollTo(tester, _key('delete-account'));
    final order = [
      _y(tester, _key('change-password')),
      _y(tester, _key('two-factor')),
      _y(tester, _key('change-email')),
      _y(tester, _key('export-data')),
      _y(tester, _key('delete-account')),
    ];
    expect(order, [...order]..sort());
    // Change password reads like its siblings: a subtitle and a chevron.
    expect(find.text('Use a new password to sign in'), findsOneWidget);
    expect(
      find.descendant(
        of: _key('change-password'),
        matching: find.byIcon(Icons.chevron_right),
      ),
      findsOneWidget,
    );
    // Delete is its own group, in the error colour, and worded as well.
    expect(
      find.descendant(
        of: _key('account-group'),
        matching: _key('delete-account'),
      ),
      findsNothing,
    );
    final title = tester.widget<Text>(
      find.descendant(
        of: _key('delete-account'),
        matching: find.text('Delete account'),
      ),
    );
    final scheme = Theme.of(tester.element(_key('delete-account'))).colorScheme;
    expect(title.style?.color, scheme.error);
    // The group sits between Your data and Privacy and access.
    expect(find.text('Account'), findsOneWidget);
    expect(
      _y(tester, find.text('Account')),
      lessThan(_y(tester, find.text('Privacy and access'))),
    );
    expect(
      _y(tester, find.text('Account')),
      greaterThan(_y(tester, find.text('Your data'))),
    );
  });

  testWidgets('Change email, export and delete appear only when the server '
      'offers them', (tester) async {
    await _mount(tester, _overview(), selfService: false);
    await _scrollTo(tester, _key('change-password'));
    expect(_key('change-password'), findsOneWidget);
    expect(_key('change-email'), findsNothing);
    expect(_key('export-data'), findsNothing);
    expect(_key('delete-account'), findsNothing);
  });

  testWidgets('Server connection keeps only the server, the device name and '
      'Log out', (tester) async {
    await _mount(tester, const AccountSettingsSection());
    expect(find.text('Connected server'), findsOneWidget);
    expect(_key('log-out'), findsOneWidget);
    for (final gone in [
      'change-password',
      'change-email',
      'export-data',
      'delete-account',
    ]) {
      expect(_key(gone), findsNothing, reason: gone);
    }
    expect(find.text('Change password'), findsNothing);
    expect(find.text('Export my data'), findsNothing);
    expect(find.text('Delete account'), findsNothing);
  });

  testWidgets('Everything else follows your account closes the overview', (
    tester,
  ) async {
    await _mount(tester, _overview());
    await _scrollTo(tester, _key('account-follows-line'));
    expect(
      _y(tester, _key('account-follows-line')),
      greaterThan(_y(tester, find.text('About'))),
    );
  });

  testWidgets('App layout shows its Only on this device label', (tester) async {
    await _mount(tester, _overview());
    expect(_key('device-only-todayLayout'), findsOneWidget);
    expect(
      _y(tester, _key('device-only-todayLayout')),
      greaterThan(_y(tester, _key('layout-entry'))),
    );
  });

  testWidgets('a sign-in still loading never says Not signed in yet', (
    tester,
  ) async {
    await _mount(
      tester,
      const AccountSettingsSection(),
      auth: const AuthLoading(),
      settle: false,
    );
    expect(find.text('Not signed in yet'), findsNothing);
    expect(find.text('Checking your sign-in'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(_key('finish-signing-in'), findsNothing);
  });

  testWidgets('a settled signed-out device still says Not signed in yet', (
    tester,
  ) async {
    await _mount(
      tester,
      const AccountSettingsSection(),
      auth: const AuthUnauthenticated(),
    );
    expect(find.text('Not signed in yet'), findsOneWidget);
    expect(_key('finish-signing-in'), findsOneWidget);
  });

  testWidgets('the overview hides the Account group while signed out', (
    tester,
  ) async {
    await _mount(tester, _overview(), auth: const AuthUnauthenticated());
    expect(_key('account-group'), findsNothing);
  });

  group('wide window', () {
    testWidgets('lists Account between Your data and Privacy and opens it', (
      tester,
    ) async {
      var selected = SettingsSection.reminders;
      await _mount(
        tester,
        StatefulBuilder(
          builder: (context, setState) => SettingsMasterDetail(
            selected: selected,
            onSelected: (s) => setState(() => selected = s),
          ),
        ),
        size: const Size(1205, 753),
      );
      final row = _key('settings-row-yourAccount');
      await _scrollTo(tester, row);
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      final pane = _key('settings-pane');
      expect(
        find.descendant(of: pane, matching: _key('change-password')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: pane, matching: _key('delete-account')),
        findsOneWidget,
      );
    });
  });

  for (final brightness in Brightness.values) {
    testWidgets('Account group meets the guidelines in ${brightness.name} at '
        'text scale 1.3', (tester) async {
      final handle = tester.ensureSemantics();
      await _mount(
        tester,
        const AccountActionsSection(),
        brightness: brightness,
        scale: 1.3,
      );
      expect(tester.takeException(), isNull);
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });
  }

  testWidgets('Account group renders in Romanian', (tester) async {
    await _mount(
      tester,
      const AccountActionsSection(),
      locale: const Locale('ro'),
      scale: 1.3,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Cont'), findsWidgets);
    expect(find.text('Schimbă parola'), findsOneWidget);
    expect(find.text('Schimbă e-mailul'), findsOneWidget);
    expect(find.text('Exportă datele mele'), findsOneWidget);
    expect(find.text('Șterge contul'), findsOneWidget);
    expect(
      find.text('Folosește o parolă nouă ca să te conectezi'),
      findsOneWidget,
    );
  });
}
