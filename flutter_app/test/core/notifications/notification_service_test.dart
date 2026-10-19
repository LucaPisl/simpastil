import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:simpastil/core/notifications/notification_service.dart';
import 'package:simpastil/core/notifications/reminder_channel.dart';
import 'package:simpastil/core/projections/projection_command_id.dart';
import 'package:simpastil/core/projections/reminder_projection.dart';
import 'package:simpastil/l10n/app_localizations_en.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../../helpers/fake_notifications_plugin.dart';

class _FakeAndroidPlugin extends Mock
    implements AndroidFlutterLocalNotificationsPlugin {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const appLockChannel = MethodChannel('com.simpastil/app_lock');

  late FakeNotificationsPlugin plugin;
  late NotificationService service;
  late ReminderProjection reminder;

  setUpAll(() {
    tz_data.initializeTimeZones();
    registerFallbackValue(tz.TZDateTime(tz.UTC, 2026));
    registerFallbackValue(const NotificationDetails());
    registerFallbackValue(DateTimeComponents.dayOfWeekAndTime);
    registerFallbackValue(AndroidScheduleMode.exactAllowWhileIdle);
  });

  setUp(() {
    plugin = FakeNotificationsPlugin();
    registerFakeNotificationStubs(plugin);
    service = NotificationService(plugin);
    final projectionId = reminderProjectionId(
      userId: '00000000-0000-4000-8000-000000000001',
      sessionGeneration: 5,
      occurrenceId: '00000000-0000-4000-8000-000000000002',
      kind: 'reminder',
    );
    reminder = ReminderProjection(
      notificationId: notificationIdForProjection(projectionId),
      projectionId: projectionId,
      occurrenceId: '00000000-0000-4000-8000-000000000002',
      userId: '00000000-0000-4000-8000-000000000001',
      sessionGeneration: 5,
      scheduledAtUtc: DateTime.utc(2026, 10, 25, 1, 30),
      timeZone: 'Europe/Bucharest',
      title: 'Time to take Medicine',
      body: 'Medicine 10 mg',
      payload: jsonEncode({
        'occurrenceId': '00000000-0000-4000-8000-000000000002',
        'projectionId': projectionId,
        'userId': '00000000-0000-4000-8000-000000000001',
        'sessionGeneration': 5,
      }),
    );
  });

  test(
    'schedules a one-time exact occurrence with no recurring matcher',
    () async {
      // Read the arguments by name: the plugin's named-parameter API says what
      // each value is, where a positional capture list only implied it.
      final calls = <Invocation>[];
      when(
        () => plugin.zonedSchedule(
          id: any(named: 'id'),
          title: any(named: 'title'),
          body: any(named: 'body'),
          scheduledDate: any(named: 'scheduledDate'),
          notificationDetails: any(named: 'notificationDetails'),
          androidScheduleMode: any(named: 'androidScheduleMode'),
          matchDateTimeComponents: any(named: 'matchDateTimeComponents'),
          payload: any(named: 'payload'),
        ),
      ).thenAnswer((invocation) async => calls.add(invocation));

      await service.schedule(reminder, localizations: AppLocalizationsEn());

      expect(calls, hasLength(1));
      final args = calls.single.namedArguments;
      expect(args[#id], reminder.notificationId);
      expect(args[#title], reminder.title);
      expect(args[#body], reminder.body);
      expect(
        (args[#scheduledDate] as tz.TZDateTime).toUtc(),
        reminder.scheduledAtUtc,
      );
      expect(
        args[#androidScheduleMode],
        AndroidScheduleMode.exactAllowWhileIdle,
      );
      expect(args[#matchDateTimeComponents], isNull);
      final androidDetails =
          (args[#notificationDetails] as NotificationDetails).android!;
      expect(androidDetails.actions!.map((action) => action.id), [
        'taken',
        'snooze',
        'skip',
      ]);
      expect(
        androidDetails.actions!.every((action) => action.showsUserInterface),
        isTrue,
      );
      final payload =
          jsonDecode(args[#payload] as String) as Map<String, dynamic>;
      expect(payload.keys.toSet(), {
        'occurrenceId',
        'projectionId',
        'userId',
        'sessionGeneration',
      });
    },
  );

  test(
    'silent care buttons leave the app closed; the body still opens it',
    () async {
      await service.schedule(
        ReminderProjection(
          notificationId: reminder.notificationId,
          projectionId: reminder.projectionId,
          occurrenceId: reminder.occurrenceId,
          userId: reminder.userId,
          sessionGeneration: reminder.sessionGeneration,
          scheduledAtUtc: reminder.scheduledAtUtc,
          timeZone: reminder.timeZone,
          title: reminder.title,
          body: reminder.body,
          payload: reminder.payload,
          silentActions: true,
        ),
        localizations: AppLocalizationsEn(),
      );

      final result = verify(
        () => plugin.zonedSchedule(
          id: any(named: 'id'),
          title: any(named: 'title'),
          body: any(named: 'body'),
          scheduledDate: any(named: 'scheduledDate'),
          notificationDetails: captureAny(named: 'notificationDetails'),
          androidScheduleMode: any(named: 'androidScheduleMode'),
          matchDateTimeComponents: any(named: 'matchDateTimeComponents'),
          payload: any(named: 'payload'),
        ),
      );
      final androidDetails =
          (result.captured.single as NotificationDetails).android!;
      expect(androidDetails.actions!.map((action) => action.id), [
        'taken',
        'snooze',
        'skip',
      ]);
      expect(
        androidDetails.actions!.any((action) => action.showsUserInterface),
        isFalse,
      );
    },
  );

  test(
    'refreshes only returned active notification IDs through native bridge',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(appLockChannel, (call) async {
            calls.add(call);
            return {
              'active': [reminder.notificationId, reminder.notificationId + 1],
              'refreshed': [reminder.notificationId],
              'skipped': [reminder.notificationId + 1],
              'failed': <int>[],
            };
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(appLockChannel, null);
        debugDefaultTargetPlatformOverride = null;
      });

      final envelope = {
        'id': reminder.notificationId,
        'tag': null,
        'payload': reminder.payload,
        'actions': [
          {'id': 'taken', 'cancelNotification': true},
          {'id': 'snooze', 'cancelNotification': false},
          {'id': 'skip', 'cancelNotification': true},
        ],
      };
      final result = await service.refreshActiveNotificationActions(
        envelopes: [envelope],
      );

      expect(calls, hasLength(1));
      expect(calls.single.method, 'refreshActiveNotificationActions');
      expect(calls.single.arguments, {
        'envelopes': [envelope],
      });
      expect(result.activeIds, {reminder.notificationId});
      expect(result.refreshedIds, {reminder.notificationId});
    },
  );

  AndroidNotificationDetails scheduledAndroidDetails() {
    final result = verify(
      () => plugin.zonedSchedule(
        id: any(named: 'id'),
        title: any(named: 'title'),
        body: any(named: 'body'),
        scheduledDate: any(named: 'scheduledDate'),
        notificationDetails: captureAny(named: 'notificationDetails'),
        androidScheduleMode: any(named: 'androidScheduleMode'),
        matchDateTimeComponents: any(named: 'matchDateTimeComponents'),
        payload: any(named: 'payload'),
      ),
    );
    return (result.captured.single as NotificationDetails).android!;
  }

  group('versioned reminder channel', () {
    test('revision 1 keeps the original id and retires nothing', () {
      expect(currentReminderChannelId(), 'dose_reminders');
      expect(kReminderChannelRevision, 1);
      expect(retiredReminderChannelIds(), isEmpty);
      expect(isKnownReminderChannelId('dose_reminders'), isTrue);
      expect(isKnownReminderChannelId('someone_elses'), isFalse);
    });

    test('later revisions suffix the id and retire every earlier id', () {
      expect(currentReminderChannelId(3), 'dose_reminders_v3');
      expect(retiredReminderChannelIds(3), [
        'dose_reminders',
        'dose_reminders_v2',
      ]);
      expect(isKnownReminderChannelId('dose_reminders_v2', 3), isTrue);
      expect(isKnownReminderChannelId('dose_reminders_v4', 3), isFalse);
    });

    test(
      'initialize leaves retired channels alone; deleting is a separate step',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final android = _FakeAndroidPlugin();
        when(
          () => android.deleteNotificationChannel(
            channelId: any(named: 'channelId'),
          ),
        ).thenAnswer((_) async {});
        when(
          () => plugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >(),
        ).thenReturn(android);
        final bumped = NotificationService(plugin, null, 3);

        await bumped.initialize();
        verifyNever(
          () => android.deleteNotificationChannel(
            channelId: any(named: 'channelId'),
          ),
        );
        await bumped.deleteRetiredChannels();
        await bumped.deleteRetiredChannels();
        verify(
          () => android.deleteNotificationChannel(channelId: 'dose_reminders'),
        ).called(1);
        verify(
          () =>
              android.deleteNotificationChannel(channelId: 'dose_reminders_v2'),
        ).called(1);
        verifyNever(
          () =>
              android.deleteNotificationChannel(channelId: 'dose_reminders_v3'),
        );

        await bumped.schedule(reminder, localizations: AppLocalizationsEn());
        expect(scheduledAndroidDetails().channelId, 'dose_reminders_v3');
      },
    );

    test('a cleanup failure never blocks scheduling', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final android = _FakeAndroidPlugin();
      when(
        () => android.deleteNotificationChannel(
          channelId: any(named: 'channelId'),
        ),
      ).thenThrow(StateError('boom'));
      when(
        () => plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >(),
      ).thenReturn(android);
      final bumped = NotificationService(plugin, null, 2);
      await bumped.initialize();
      await expectLater(bumped.deleteRetiredChannels(), throwsStateError);
      await bumped.schedule(reminder, localizations: AppLocalizationsEn());
    });
  });

  test('full-detail reminders wear the capsule, accent and big text', () async {
    await service.schedule(reminder, localizations: AppLocalizationsEn());
    final android = scheduledAndroidDetails();
    expect(android.channelId, 'dose_reminders');
    expect(android.icon, reminderSmallIcon);
    expect(android.color, const Color(0xFF6E66FA));
    expect(android.category, AndroidNotificationCategory.reminder);
    expect(android.subText, 'Dose reminder');
    expect(android.visibility, NotificationVisibility.public);
    final style = android.styleInformation! as BigTextStyleInformation;
    expect(style.bigText, reminder.body);
  });

  test('private reminders stay one generic line with Open only', () async {
    final private = ReminderProjection(
      notificationId: reminder.notificationId,
      projectionId: reminder.projectionId,
      occurrenceId: reminder.occurrenceId,
      userId: reminder.userId,
      sessionGeneration: reminder.sessionGeneration,
      scheduledAtUtc: reminder.scheduledAtUtc,
      timeZone: reminder.timeZone,
      title: AppLocalizationsEn().core_notifPrivateTitle,
      body: AppLocalizationsEn().core_notifPrivateBody,
      payload: reminder.payload,
      allowCareActions: false,
    );
    await service.schedule(private, localizations: AppLocalizationsEn());
    final android = scheduledAndroidDetails();
    expect(android.channelId, 'dose_reminders');
    expect(android.icon, reminderSmallIcon);
    expect(android.color, const Color(0xFF6E66FA));
    expect(android.styleInformation, isNull);
    expect(android.subText, isNull);
    expect(android.visibility, NotificationVisibility.private);
    expect(android.actions!.map((action) => action.id), ['open']);
  });

  test('notification ID is deterministic and stays within plugin range', () {
    final projectionId = reminderProjectionId(
      userId: '00000000-0000-4000-8000-000000000001',
      sessionGeneration: 4,
      occurrenceId: '00000000-0000-4000-8000-000000000002',
      kind: 'reminder',
    );

    final first = notificationIdForProjection(projectionId);
    final replay = notificationIdForProjection(projectionId);
    final nextGeneration = notificationIdForProjection(
      reminderProjectionId(
        userId: '00000000-0000-4000-8000-000000000001',
        sessionGeneration: 5,
        occurrenceId: '00000000-0000-4000-8000-000000000002',
        kind: 'reminder',
      ),
    );

    expect(first, replay);
    expect(first, inInclusiveRange(0, 0x3FFFFFFF));
    expect(first, isNot(nextGeneration));
  });
}
