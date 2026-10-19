import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/main.dart';
import '../../helpers/protected_workspace_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('initializing reminders does not demand device permissions', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    // The plugin resolves its platform implementation lazily; a device run
    // registers it automatically, a unit test has to do so itself.
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    final calls = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channels = [
      MethodChannel('dexterous.com/flutter/local_notifications'),
      MethodChannel('flutter.baseflow.com/permissions/methods'),
      MethodChannel('flutter_timezone'),
    ];
    for (final channel in channels) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return switch (call.method) {
          'getLocalTimezone' => 'Europe/Bucharest',
          'getNotificationAppLaunchDetails' => {
            'notificationLaunchedApp': false,
          },
          'requestPermissions' => <int, int>{},
          'pendingNotificationRequests' => <dynamic>[],
          _ => true,
        };
      });
    }
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      for (final channel in channels) {
        messenger.setMockMethodCallHandler(channel, null);
      }
    });
    final fixture = await ProtectedWorkspaceFixture.create();
    final container = ProviderContainer(overrides: fixture.overrides);
    addTearDown(() async {
      container.dispose();
      await fixture.db.close();
    });
    await container
        .read(foregroundProjectionOperationsProvider)
        .initializeNotifications();
    expect(calls, contains('initialize'));
    expect(calls.where((call) => call.startsWith('request')), isEmpty);
  });
}
