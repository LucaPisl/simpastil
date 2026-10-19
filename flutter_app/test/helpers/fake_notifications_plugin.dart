import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:mocktail/mocktail.dart';

/// Mocktail mock of [FlutterLocalNotificationsPlugin].
class FakeNotificationsPlugin extends Mock
    implements FlutterLocalNotificationsPlugin {}

/// Stubs all methods called by [NotificationService].
void registerFakeNotificationStubs(FakeNotificationsPlugin fake) {
  when(
    () => fake.zonedSchedule(
      id: any(named: 'id'),
      title: any(named: 'title'),
      body: any(named: 'body'),
      scheduledDate: any(named: 'scheduledDate'),
      notificationDetails: any(named: 'notificationDetails'),
      androidScheduleMode: any(named: 'androidScheduleMode'),
      matchDateTimeComponents: any(named: 'matchDateTimeComponents'),
      payload: any(named: 'payload'),
    ),
  ).thenAnswer((_) async {});

  when(() => fake.cancel(id: any(named: 'id'))).thenAnswer((_) async {});
}
