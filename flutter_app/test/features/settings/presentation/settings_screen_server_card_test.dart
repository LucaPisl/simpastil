import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/notifications/notification_plugin.dart';

import '../../../helpers/fake_notifications_plugin.dart';
import '../../../helpers/protected_workspace_fixture.dart';
import 'package:simpastil/core/server/server_config_notifier.dart';
import 'package:simpastil/core/theme/theme_provider.dart';
import 'package:simpastil/features/auth/auth_provider.dart';
import 'package:simpastil/features/pills/pill_provider.dart';
import 'package:simpastil/features/profiles/profile_provider.dart';
import 'package:simpastil/features/settings/presentation/settings_screen.dart';
import 'package:simpastil/l10n/app_localizations.dart';

class _FakeAuthNotifier extends AuthNotifier {
  _FakeAuthNotifier({this.signedIn = true, this.loading = false});
  final bool signedIn;
  final bool loading;
  @override
  AuthState build() => loading
      ? const AuthLoading()
      : signedIn
      ? const AuthAuthenticated('u1')
      : const AuthUnauthenticated();
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

class _FakeDynamicColorNotifier extends DynamicColorNotifier {
  @override
  Future<bool> build() async => true;
}

class _FakeFontSizeNotifier extends FontSizeNotifier {
  @override
  Future<AppFontSize> build() async => AppFontSize.defaultSize;
}

class _FakeHighContrastNotifier extends HighContrastNotifier {
  @override
  Future<bool> build() async => false;
}

Future<Widget> _buildApp({
  required SharedPreferences prefs,
  String? serverUrl,
  bool signedIn = true,
  bool loading = false,
}) async {
  final fixture = await ProtectedWorkspaceFixture.create(
    ownerId: 'u1',
    preferences: prefs,
  );
  final container = await fixture.createContainer(
    extraOverrides: [
      serverConfigProvider.overrideWith(
        () => _FakeServerConfigNotifier(serverUrl),
      ),
      authNotifierProvider.overrideWith(
        () => _FakeAuthNotifier(signedIn: signedIn, loading: loading),
      ),
      profileListProvider.overrideWith((_) => Stream.value(const [])),
      localCareKeptProvider.overrideWith((_) => Stream.value(false)),
      primaryProfileIdProvider.overrideWith(
        () => _FakePrimaryProfileNotifier(),
      ),
      themeModeNotifierProvider.overrideWith(() => _FakeThemeModeNotifier()),
      siblingDetectionModeProvider.overrideWith(
        () => _FakeSiblingDetectionNotifier(),
      ),
      dynamicColorNotifierProvider.overrideWith(
        () => _FakeDynamicColorNotifier(),
      ),
      fontSizeNotifierProvider.overrideWith(() => _FakeFontSizeNotifier()),
      highContrastNotifierProvider.overrideWith(
        () => _FakeHighContrastNotifier(),
      ),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(fixture.db.close);
  return UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SettingsScreen(),
    ),
  );
}

/// The phone's overview. A wider window shows the list and a page side by side
/// (settings_master_detail_test.dart); `setSurfaceSize` would not change the
/// window class, so the view itself is resized.
void _phoneView(WidgetTester tester) {
  tester.view.physicalSize = const Size(412, 914);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

const _permissionChannel = MethodChannel(
  'flutter.baseflow.com/permissions/methods',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  testWidgets('shows server hostname card when serverConfigProvider is set', (
    tester,
  ) async {
    _phoneView(tester);
    SharedPreferences.setMockInitialValues({
      'server_url': 'https://mypills.example.com',
    });
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      await _buildApp(prefs: prefs, serverUrl: 'https://mypills.example.com'),
    );
    await tester.pumpAndSettle();

    // The server card is below the viewport in the lazy ListView — scroll
    // until the widget is built and visible.
    await tester.scrollUntilVisible(
      find.text('mypills.example.com'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('mypills.example.com'), findsOneWidget);
  });

  testWidgets('a server not yet signed in to shows no host in the list', (
    tester,
  ) async {
    _phoneView(tester);
    SharedPreferences.setMockInitialValues({
      'server_url': 'https://mypills.example.com',
    });
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      await _buildApp(
        prefs: prefs,
        serverUrl: 'https://mypills.example.com',
        signedIn: false,
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Server connection'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Not signed in yet'), findsOneWidget);
    expect(find.text('mypills.example.com'), findsNothing);
  });

  testWidgets('a sign-in still loading never says Not signed in yet', (
    tester,
  ) async {
    _phoneView(tester);
    SharedPreferences.setMockInitialValues({
      'server_url': 'https://mypills.example.com',
    });
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      await _buildApp(
        prefs: prefs,
        serverUrl: 'https://mypills.example.com',
        loading: true,
      ),
    );
    await tester.pump();

    await tester.scrollUntilVisible(
      find.text('Server connection'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Not signed in yet'), findsNothing);
    expect(find.text('Checking your sign-in'), findsWidgets);
  });

  testWidgets('hides server card when serverConfigProvider is null', (
    tester,
  ) async {
    _phoneView(tester);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(await _buildApp(prefs: prefs, serverUrl: null));
    await tester.pumpAndSettle();

    // Scroll to the bottom to be sure the server section wasn't rendered.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -1000));
    await tester.pumpAndSettle();
    expect(find.text('Connected server'), findsNothing);
  });

  testWidgets('shows Not set when no device name stored', (tester) async {
    _phoneView(tester);
    SharedPreferences.setMockInitialValues({
      'server_url': 'https://mypills.example.com',
    });
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      await _buildApp(prefs: prefs, serverUrl: 'https://mypills.example.com'),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Server connection'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Server connection'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Device name'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Device name'), findsOneWidget);
    expect(find.text('Not set'), findsOneWidget);
  });

  testWidgets('shows stored device name', (tester) async {
    _phoneView(tester);
    SharedPreferences.setMockInitialValues({
      'server_url': 'https://mypills.example.com',
      'simpastil_device_name': 'My Galaxy S24',
    });
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      await _buildApp(prefs: prefs, serverUrl: 'https://mypills.example.com'),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Server connection'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Server connection'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('My Galaxy S24'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('My Galaxy S24'), findsOneWidget);
  });
}
