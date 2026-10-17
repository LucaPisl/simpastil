import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:mocktail/mocktail.dart';

/// Mocktail mock of [FlutterLocalNotificationsPlugin].
class FakeNotificationsPlugin extends Mock
    implements FlutterLocalNotificationsPlugin {}

/// Stubs all methods called by [NotificationService].
void registerFakeNotificationStubs(FakeNotificationsPlugin fake) {
  when(
    () => fake.zonedSchedule(
      any(),
      any(),
      any(),
      any(),
      any(),
      uiLocalNotificationDateInterpretation: any(
        named: 'uiLocalNotificationDateInterpretation',
      ),
      androidScheduleMode: any(named: 'androidScheduleMode'),
      matchDateTimeComponents: any(named: 'matchDateTimeComponents'),
      payload: any(named: 'payload'),
    ),
  ).thenAnswer((_) async {});

  when(() => fake.cancel(any())).thenAnswer((_) async {});
}
