import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../db/database.dart';
import '../../notifications/notification_plugin.dart';
import '../../notifications/notification_service.dart';
import 'diagnostic_report.dart';
import 'report_channel.dart';
import 'report_collector.dart';

/// The report sources that need only the phone itself: no database, no
/// providers, no signed-in session. A crash screen can use these alone.
ReportSources platformReportSources({
  required ReportScreen screen,
  required String language,
  ReportChannel? channel,
}) {
  final android = channel ?? ReportChannel();
  return ReportSources(
    app: () => readAppFacts(language: language),
    device: () => readDeviceFacts(screen: screen),
    permissions: readPermissionFacts,
    lastStop: () async {
      final exit = await android.lastExit();
      return exit == null ? null : 'EXIT_${exit.reason.toUpperCase()}';
    },
  );
}

Future<ReportApp?> readAppFacts({String? language}) async {
  final info = await PackageInfo.fromPlatform();
  return ReportApp(
    version: info.version,
    build: int.tryParse(info.buildNumber),
    database: AppDatabase.supportedSchemaVersion,
    language: language,
  );
}

Future<ReportDevice?> readDeviceFacts({required ReportScreen screen}) async {
  if (!Platform.isAndroid) return null;
  final info = await DeviceInfoPlugin().androidInfo;
  return ReportDevice(
    androidRelease: info.version.release,
    sdk: info.version.sdkInt,
    maker: info.manufacturer,
    model: info.model,
    screen: screen,
  );
}

Future<ReportPermissions?> readPermissionFacts() async {
  Future<ReportPermission> check(Future<bool> Function() read) async {
    try {
      return await read() ? ReportPermission.allowed : ReportPermission.denied;
    } on Object {
      return ReportPermission.unknown;
    }
  }

  return ReportPermissions(
    notifications: await check(() => Permission.notification.isGranted),
    exactAlarms: await check(NotificationService.canScheduleExact),
    batteryUnrestricted: await check(
      () => Permission.ignoreBatteryOptimizations.isGranted,
    ),
  );
}

/// How many reminders Android is holding for the app right now.
Future<int?> readScheduledReminderCount() async {
  try {
    return (await notificationsPlugin.pendingNotificationRequests()).length;
  } on Object {
    return null;
  }
}
