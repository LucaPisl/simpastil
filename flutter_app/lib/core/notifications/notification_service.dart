import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../../l10n/app_localizations.dart';
import '../utils/app_logger.dart';
import '../projections/reminder_id_ledger.dart';
import '../projections/reminder_projection.dart';
import 'notification_plugin.dart';
import 'reminder_channel.dart';
import 'reminder_readiness.dart';

const _kLegacyIdsPreferencePrefix = 'notif_ids_';
const _kProjectionRegistryKey = 'notification_projection_registry_v1';
const _kProjectionStatusPrefix = 'notification_projection_status_v1_';
const _kLegacyMigrationKey = 'notification_occurrence_migration_v1';
const _kAppLockChannel = 'com.simpastil/app_lock';

/// Monochrome tilted capsule (`res/drawable/ic_stat_capsule.xml`); Android
/// tints it with [reminderAccent]. Kept from resource shrinking by
/// `res/raw/keep.xml`.
const reminderSmallIcon = 'ic_stat_capsule';

/// Brand violet for the small icon, app name and action labels.
const reminderAccent = Color(0xFF6E66FA);

Future<void> _notificationWorkQueue = Future<void>.value();

Future<T> serializeNotificationWork<T>(Future<T> Function() operation) {
  final next = _notificationWorkQueue.then((_) => operation());
  _notificationWorkQueue = next.then<void>((_) {}).catchError((Object _) {});
  return next;
}

List<AndroidNotificationAction> _localizedActions(AppLocalizations l) => [
  AndroidNotificationAction(
    'taken',
    l.core_notifActionTaken,
    showsUserInterface: true,
  ),
  AndroidNotificationAction(
    'snooze',
    l.core_notifActionSnooze,
    showsUserInterface: true,
  ),
  AndroidNotificationAction(
    'skip',
    l.core_notifActionSkip,
    showsUserInterface: true,
  ),
];

class NotificationService
    implements
        ReminderReadinessPlatform,
        ActiveReminderNotificationPlatform,
        RetiredChannelNotificationPlatform {
  NotificationService([
    FlutterLocalNotificationsPlugin? plugin,
    MethodChannel? appLockChannel,
    int channelRevision = kReminderChannelRevision,
  ]) : _channelRevision = channelRevision,
       _plugin = plugin ?? notificationsPlugin,
       _appLockChannel =
           appLockChannel ?? const MethodChannel(_kAppLockChannel);

  final FlutterLocalNotificationsPlugin _plugin;
  final MethodChannel _appLockChannel;
  final int _channelRevision;
  bool _retiredChannelsDeleted = false;

  String get _kChannelId => currentReminderChannelId(_channelRevision);

  /// Deletes the channels of every retired revision (Android only). A no-op
  /// until the revision is bumped.
  ///
  /// Never call this before reminders have moved: the plugin recreates a
  /// channel from the details of whatever it posts, so deleting a channel
  /// that a pending alarm still names makes that alarm resurrect it. The
  /// reconciler reschedules every reminder onto the current channel (it treats
  /// a registry entry from an older revision as stale) and calls this only
  /// after a pass in which every workspace came out current.
  @override
  Future<void> deleteRetiredChannels() async {
    if (_retiredChannelsDeleted) return;
    final retired = retiredReminderChannelIds(_channelRevision);
    if (retired.isNotEmpty &&
        (Platform.isAndroid ||
            defaultTargetPlatform == TargetPlatform.android)) {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      for (final id in retired) {
        await android?.deleteNotificationChannel(id);
      }
    }
    _retiredChannelsDeleted = true;
  }

  /// Refreshes eligible actions on currently visible Android notifications.
  /// The native side reports which verified candidates were active separately
  /// from which replacements succeeded, so callers can retain a visible dose
  /// while retrying a failed optional refresh.
  Future<ActiveNotificationActionRefreshResult>
  refreshActiveNotificationActions({
    required List<Map<String, Object?>> envelopes,
  }) async {
    if (!Platform.isAndroid &&
        defaultTargetPlatform != TargetPlatform.android) {
      return const ActiveNotificationActionRefreshResult.empty();
    }
    final candidateIds = {
      for (final envelope in envelopes)
        if (envelope['id'] is int) envelope['id'] as int,
    };
    if (candidateIds.isEmpty) {
      return const ActiveNotificationActionRefreshResult.empty();
    }
    final result = await _appLockChannel.invokeMapMethod<String, Object?>(
      'refreshActiveNotificationActions',
      {'envelopes': envelopes},
    );
    if (result == null) {
      throw const FormatException('Missing active notification refresh result');
    }
    Set<int> readIds(String key) {
      final raw = result[key];
      if (raw is! List || raw.any((value) => value is! int)) {
        throw FormatException('Invalid active notification $key result');
      }
      return raw.whereType<int>().where(candidateIds.contains).toSet();
    }

    final activeIds = readIds('active');
    final refreshedIds = readIds('refreshed');
    final skippedIds = readIds('skipped');
    final failedIds = readIds('failed');
    if (!activeIds.containsAll(refreshedIds) ||
        !activeIds.containsAll(failedIds)) {
      throw const FormatException('Inconsistent active notification result');
    }
    return ActiveNotificationActionRefreshResult(
      activeIds: activeIds,
      refreshedIds: refreshedIds,
      skippedIds: skippedIds,
      failedIds: failedIds,
    );
  }

  static String get legacyIdsPreferencePrefix => _kLegacyIdsPreferencePrefix;

  /// Initialize timezone data before any named-zone occurrence is scheduled.
  static Future<void> initializeTimeZones() async {
    tz_data.initializeTimeZones();
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(info.identifier));
    } on Object {
      // The occurrence's explicit IANA zone remains authoritative.
    }
  }

  /// Returns true when Android exact-alarm delivery is currently available.
  static Future<bool> canScheduleExact() async {
    if (!Platform.isAndroid &&
        defaultTargetPlatform != TargetPlatform.android) {
      return true;
    }
    final result = await notificationsPlugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.canScheduleExactNotifications();
    final ok = result ?? false;
    AppLogger.info('NotifService', 'canScheduleExact=$ok');
    return ok;
  }

  static Future<void> requestPostNotificationsPermission() async {
    await notificationsPlugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
  }

  @override
  Future<void> initialize() async {
    await initializeTimeZones();
  }

  @override
  Future<bool> hasExactAlarmPermission() => _hasExactAlarmPermission();

  Future<bool> _hasExactAlarmPermission() async {
    if (!Platform.isAndroid &&
        defaultTargetPlatform != TargetPlatform.android) {
      return true;
    }
    final result = await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.canScheduleExactNotifications();
    return result ?? false;
  }

  @override
  Future<bool> hasNotificationPermission() async {
    if (Platform.isAndroid || defaultTargetPlatform == TargetPlatform.android) {
      return await _plugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.areNotificationsEnabled() ??
          false;
    }
    if (Platform.isIOS || defaultTargetPlatform == TargetPlatform.iOS) {
      final permission = await _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.checkPermissions();
      return permission?.isEnabled == true ||
          permission?.isProvisionalEnabled == true;
    }
    return false;
  }

  /// Foreground setup explicitly invokes this; initialization never prompts.
  @override
  Future<void> requestReminderAccess() async {
    if (Platform.isAndroid || defaultTargetPlatform == TargetPlatform.android) {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (await android?.requestNotificationsPermission() == true) {
        await android?.requestExactAlarmsPermission();
      }
    } else if (Platform.isIOS || defaultTargetPlatform == TargetPlatform.iOS) {
      await _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    }
  }

  @override
  Future<void> scheduleTest(
    ReminderTestNotification test, {
    required AppLocalizations localizations,
  }) => _plugin.zonedSchedule(
    test.id,
    localizations.core_notifTestTitle,
    localizations.core_notifTestBody,
    tz.TZDateTime.from(test.scheduledAtUtc, tz.UTC),
    NotificationDetails(
      android: AndroidNotificationDetails(
        _kChannelId,
        localizations.core_notifChannelName,
        channelDescription: localizations.core_notifChannelDesc,
        importance: Importance.high,
        priority: Priority.high,
        icon: reminderSmallIcon,
        color: reminderAccent,
        category: AndroidNotificationCategory.reminder,
        styleInformation: BigTextStyleInformation(
          localizations.core_notifTestBody,
        ),
        visibility: NotificationVisibility.private,
        actions: [
          AndroidNotificationAction(
            'open',
            localizations.core_notifActionOpen,
            showsUserInterface: true,
          ),
        ],
      ),
    ),
    uiLocalNotificationDateInterpretation:
        UILocalNotificationDateInterpretation.absoluteTime,
    androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    payload: test.payload,
  );

  @override
  Future<List<PlatformReminderRequest>> pendingRequests() async {
    final pending = await _plugin.pendingNotificationRequests();
    return [
      for (final request in pending)
        PlatformReminderRequest(
          id: request.id,
          title: request.title ?? '',
          body: request.body ?? '',
          payload: request.payload,
        ),
    ];
  }

  @override
  Future<List<PlatformActiveReminder>> activeReminders() async {
    return [
      for (final item in await _plugin.getActiveNotifications())
        if (item.id != null)
          PlatformActiveReminder(
            id: item.id!,
            tag: item.tag,
            channelId: item.channelId,
            title: item.title ?? '',
            body: item.body ?? '',
            payload: item.payload,
          ),
    ];
  }

  @override
  Future<void> schedule(
    ReminderProjection reminder, {
    required AppLocalizations localizations,
  }) {
    final location = tz.getLocation(reminder.timeZone);
    final scheduled = tz.TZDateTime.from(reminder.scheduledAtUtc, location);
    return _plugin.zonedSchedule(
      reminder.notificationId,
      reminder.title,
      reminder.body,
      scheduled,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _kChannelId,
          localizations.core_notifChannelName,
          channelDescription: localizations.core_notifChannelDesc,
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
          icon: reminderSmallIcon,
          color: reminderAccent,
          category: AndroidNotificationCategory.reminder,
          // Full details: the body may wrap when expanded and the header
          // says what kind of alert this is. Private reminders stay a
          // single generic line with nothing more to reveal.
          styleInformation: reminder.allowCareActions
              ? BigTextStyleInformation(reminder.body)
              : null,
          subText: reminder.allowCareActions
              ? localizations.r6_notifSubText
              : null,
          visibility: reminder.allowCareActions
              ? NotificationVisibility.public
              : NotificationVisibility.private,
          actions: reminder.allowCareActions
              ? _localizedActions(localizations)
              : [
                  AndroidNotificationAction(
                    'open',
                    localizations.core_notifActionOpen,
                    showsUserInterface: true,
                  ),
                ],
        ),
      ),
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      matchDateTimeComponents: null,
      payload: reminder.payload,
    );
  }

  @override
  Future<void> cancel(int notificationId) => _plugin.cancel(notificationId);

  @override
  Future<void> cancelAll() => _plugin.cancelAll();
}

class ActiveNotificationActionRefreshResult {
  const ActiveNotificationActionRefreshResult({
    required this.activeIds,
    required this.refreshedIds,
    required this.skippedIds,
    required this.failedIds,
  });

  const ActiveNotificationActionRefreshResult.empty()
    : activeIds = const {},
      refreshedIds = const {},
      skippedIds = const {},
      failedIds = const {};

  final Set<int> activeIds;
  final Set<int> refreshedIds;
  final Set<int> skippedIds;
  final Set<int> failedIds;
}

final notificationServiceProvider = Provider<NotificationService>(
  (ref) => NotificationService(),
);

/// Removes owned reminders during explicit session teardown. A plugin that
/// has not initialized yet must not block token/session cleanup.
Future<void> cancelAllScheduledNotifications() async {
  await serializeNotificationWork(() async {
    var cancelled = false;
    try {
      await NotificationService().cancelAll();
      cancelled = true;
    } on Object catch (error) {
      AppLogger.warning(
        'NotifService',
        'cancelAllScheduledNotifications skipped: ${error.runtimeType}',
      );
    }
    if (!cancelled) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final ownedKeys = prefs.getKeys().where(
        (key) =>
            key.startsWith(_kLegacyIdsPreferencePrefix) ||
            key.startsWith(_kProjectionStatusPrefix) ||
            key == _kProjectionRegistryKey ||
            key == reminderIdLedgerKey ||
            key == _kLegacyMigrationKey,
      );
      for (final key in ownedKeys.toList()) {
        await prefs.remove(key);
      }
    } on Object catch (error) {
      AppLogger.warning(
        'NotifService',
        'Reminder registry cleanup failed: ${error.runtimeType}',
      );
    }
  });
}
