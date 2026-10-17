import 'dart:convert';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/notifications/notification_action_handler.dart';

void main() {
  test(
    'generic Open action navigates to review without invoking a care action',
    () async {
      String? opened;
      await handleNotificationAction(
        NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          actionId: 'open',
          payload: jsonEncode({'kind': 'readiness', 'route': '/settings'}),
        ),
        (route) => opened = route,
      );
      expect(opened, '/settings');
    },
  );
}
