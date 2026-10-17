import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../../l10n/app_localizations_en.dart';
import '../db/database.dart';
import '../protection/access_gate.dart';
import '../protection/app_lock_controller.dart';
import '../inventory/inventory_service.dart';
import '../medication/medication_command.dart';
import '../medication/medication_repository.dart';
import '../projections/projection_command_id.dart';
import '../projections/projection_identity.dart';
import '../projections/projection_effects_gate.dart';
import '../projections/reminder_projection.dart';
import '../projections/reminder_retry.dart';
import '../workspace/workspace_access_repository.dart';
import '../workspace/workspace_context.dart';
import '../projections/projection_reconciler.dart';
import '../session/session_generation_repository.dart';
import '../utils/app_logger.dart';
import '../startup/time_zone_data.dart';
import '../widget/widget_snapshot.dart';
import 'notification_plugin.dart';
import 'notification_service.dart';

const _kActionTaken = 'taken';
const _kActionSkip = 'skip';
const _kActionSnooze = 'snooze';
const _kDefaultSnoozeMins = 15;

class ReminderActionPayload {
  const ReminderActionPayload({
    required this.occurrenceId,
    required this.projectionId,
    required this.userId,
    required this.sessionGeneration,
    this.projectionIdentity,
    this.stateVersion,
    this.followUpMinutes,
  });

  final String occurrenceId;
  final String projectionId;
  final String userId;
  final int sessionGeneration;
  final ProjectionIdentity? projectionIdentity;
  final int? stateVersion;
  final int? followUpMinutes;

  SessionIdentity get identity => (userId, sessionGeneration);
}

ReminderActionPayload? parseReminderActionPayload(String? raw) {
  if (raw == null) return null;
  try {
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic>) return null;
    final isProtected = value['version'] == 2;
    final keys = {
      'occurrenceId',
      'projectionId',
      'userId',
      'sessionGeneration',
      if (value.containsKey('followUpMinutes')) 'followUpMinutes',
      if (isProtected) ...{
        'version',
        'workspaceId',
        'grantEpoch',
        'stateVersion',
      },
    };
    if (value.keys.toSet().difference(keys).isNotEmpty ||
        value.length != keys.length ||
        value['occurrenceId'] is! String ||
        (value['occurrenceId'] as String).isEmpty ||
        value['projectionId'] is! String ||
        (value['projectionId'] as String).isEmpty ||
        value['userId'] is! String ||
        (value['userId'] as String).isEmpty ||
        value['sessionGeneration'] is! int ||
        (value['sessionGeneration'] as int) < 1 ||
        (value.containsKey('followUpMinutes') &&
            (value['followUpMinutes'] is! int ||
                (value['followUpMinutes'] as int) <= 0))) {
      return null;
    }
    final identity = isProtected ? ProjectionIdentity.fromJson(value) : null;
    if (isProtected &&
        (identity == null ||
            identity.grantEpoch != value['sessionGeneration'] ||
            value['stateVersion'] is! int ||
            (value['stateVersion'] as int) < 0)) {
      return null;
    }
    return ReminderActionPayload(
      occurrenceId: value['occurrenceId'] as String,
      projectionId: value['projectionId'] as String,
      userId: value['userId'] as String,
      sessionGeneration: value['sessionGeneration'] as int,
      projectionIdentity: identity,
      stateVersion: isProtected ? value['stateVersion'] as int : null,
      followUpMinutes: value['followUpMinutes'] as int?,
    );
  } on FormatException {
    return null;
  }
}

bool reminderProjectionMatchesAction(ReminderActionPayload payload) {
  final reminderId = reminderProjectionId(
    userId: payload.userId,
    sessionGeneration: payload.sessionGeneration,
    occurrenceId: payload.occurrenceId,
    kind: payload.followUpMinutes == null
        ? 'reminder'
        : followUpReminderKind(payload.followUpMinutes!),
    workspaceId: payload.projectionIdentity?.workspaceId,
    grantEpoch: payload.projectionIdentity?.grantEpoch,
    stateVersion: payload.stateVersion,
  );
  final snoozeId = reminderProjectionId(
    userId: payload.userId,
    sessionGeneration: payload.sessionGeneration,
    occurrenceId: payload.occurrenceId,
    kind: 'snooze',
    workspaceId: payload.projectionIdentity?.workspaceId,
    grantEpoch: payload.projectionIdentity?.grantEpoch,
    stateVersion: payload.stateVersion,
  );
  return payload.projectionId == reminderId ||
      (payload.followUpMinutes == null && payload.projectionId == snoozeId);
}

bool reminderActionIsCurrent(
  ReminderActionPayload payload,
  SessionIdentity? activeIdentity,
) =>
    payload.identity == activeIdentity &&
    reminderProjectionMatchesAction(payload);

/// Validates a notification request before the locked app routes to explicit
/// dose review. The OS action verb is retained as context, never dispatched.
Future<String?> validateNotificationActionForReview(
  NotificationResponse response, {
  required AppDatabase db,
  required WorkspaceAccessRepository access,
}) async {
  ensureTimeZoneData();
  if (response.actionId != null &&
      !const {
        'open',
        _kActionTaken,
        _kActionSkip,
        _kActionSnooze,
      }.contains(response.actionId)) {
    return null;
  }
  final payload = parseReminderActionPayload(response.payload);
  final projection = payload?.projectionIdentity;
  final stateVersion = payload?.stateVersion;
  if (payload == null ||
      !reminderProjectionMatchesAction(payload) ||
      projection == null ||
      stateVersion == null ||
      (response.id != null &&
          !notificationIdMatchesProjection(
            payload.projectionId,
            response.id!,
          ))) {
    return null;
  }

  try {
    final context = await projection.resolve(access);
    if (context == null ||
        context.ownerUserId != payload.userId ||
        context.accessEpoch != payload.sessionGeneration) {
      return null;
    }

    final kind = payload.followUpMinutes != null
        ? followUpReminderKind(payload.followUpMinutes!)
        : payload.projectionId ==
              reminderProjectionId(
                userId: projection.ownerId,
                sessionGeneration: projection.grantEpoch,
                occurrenceId: payload.occurrenceId,
                kind: 'reminder',
                workspaceId: projection.workspaceId,
                grantEpoch: projection.grantEpoch,
                stateVersion: stateVersion,
              )
        ? 'reminder'
        : 'snooze';
    final current =
        await MedicationRepository(
          db,
          access: access,
          context: context,
        ).isCurrentReminderActionForReview(
          occurrenceId: payload.occurrenceId,
          projectionId: payload.projectionId,
          kind: kind,
          deliveredStateVersion: stateVersion,
        );
    if (!current) return null;
    await access.requireCurrent(context);
    return payload.occurrenceId;
  } on WorkspaceAccessFailure {
    return null;
  }
}

/// New payloads navigate by exact occurrence identity; old route payloads stay
/// readable only for a transition window while migration cancels old alarms.
String? extractRouteFromPayload(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  final reminder = parseReminderActionPayload(raw);
  if (reminder != null) {
    return '/home?dose=${Uri.encodeQueryComponent(reminder.occurrenceId)}';
  }
  try {
    final value = jsonDecode(raw);
    if (value is Map<String, dynamic>) return value['route'] as String?;
  } on FormatException {
    // Legacy notifications may have stored a plain route string.
  }
  return raw;
}

Future<AppLocalizations> _resolveL10nAsync() async {
  final prefs = await SharedPreferences.getInstance();
  final code = prefs.getString('app_locale');
  final locale = code != null
      ? Locale(code)
      : Locale(Platform.localeName.split('_').first);
  try {
    return lookupAppLocalizations(locale);
  } on Object {
    // lookupAppLocalizations supports only en/ro; keep reminders schedulable.
    return AppLocalizationsEn();
  }
}

/// Foreground/background (not killed) action callback.
Future<void> handleNotificationAction(
  NotificationResponse response,
  void Function(String route) navigateTo, {
  AppDatabase? database,
  WorkspaceAccessRepository? access,
}) async {
  if (response.actionId == null || response.actionId == 'open') {
    final route = extractRouteFromPayload(response.payload);
    if (route != null) navigateTo(route);
    return;
  }
  await dispatchNotificationAction(
    response,
    plugin: notificationsPlugin,
    database: database,
    access: access,
  );
}

/// Killed-process callback.
@pragma('vm:entry-point')
Future<void> handleBackgroundNotificationAction(
  NotificationResponse response,
) async {
  if (response.actionId == null) return;

  WidgetsFlutterBinding.ensureInitialized();
  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
  );
  await dispatchNotificationAction(response, plugin: plugin);
}

Future<void> dispatchNotificationAction(
  NotificationResponse response, {
  required FlutterLocalNotificationsPlugin plugin,
  AppDatabase? database,
  WorkspaceAccessRepository? access,
  ProjectionReconciler? projectionReconciler,
  AccessGate? accessGate,
  Future<void> Function(Duration delay)? scheduleReconcileRetry,
  List<Duration> reconcileRetryDelays = reminderActionRetryDelays,
  Future<void> Function(Duration)? reconcileRetryWait,
}) async {
  final payload = parseReminderActionPayload(response.payload);
  if (payload == null || !reminderProjectionMatchesAction(payload)) return;

  final projection = payload.projectionIdentity;
  if (projection == null) return;
  ensureTimeZoneData();
  final ownDb = database == null;
  final db = database ?? AppDatabase();
  try {
    final protectedAccess =
        access ??
        WorkspaceAccessRepository(
          db,
          effectsGate: privateProjectionEffectsGate,
        );
    final context = await projection.resolve(protectedAccess);
    if (context == null) return;
    final prefs = await SharedPreferences.getInstance();
    final headlessGate =
        accessGate ??
        AccessGate(AppLockPolicyStore(SharedAppLockPolicyStorage(prefs)));
    final generations = SessionGenerationRepository(
      prefs,
      access: protectedAccess,
    );
    final reconciler =
        projectionReconciler ??
        _reconcilerForAction(
          db: db,
          prefs: prefs,
          generations: generations,
          plugin: plugin,
        );
    if (response.actionId == _kActionSnooze) {
      final minutes =
          (prefs.getInt('snooze_duration_minutes_${projection.ownerId}') ??
                  _kDefaultSnoozeMins)
              .clamp(1, 120)
              .toInt();
      await reconciler.scheduleSnooze(
        identity: payload.identity,
        projectionIdentity: projection,
        deliveredStateVersion: payload.stateVersion,
        occurrenceId: payload.occurrenceId,
        delay: Duration(minutes: minutes),
        requireEffectAdmission: headlessGate.requireHeadlessAdmission,
        localizations: await _resolveL10nAsync(),
      );
      return;
    }
    if (response.actionId != _kActionTaken &&
        response.actionId != _kActionSkip) {
      return;
    }
    final action = response.actionId == _kActionTaken
        ? MedicationAction.take
        : MedicationAction.skip;
    final reminderId = reminderProjectionId(
      userId: projection.ownerId,
      sessionGeneration: projection.grantEpoch,
      occurrenceId: payload.occurrenceId,
      kind: payload.followUpMinutes == null
          ? 'reminder'
          : followUpReminderKind(payload.followUpMinutes!),
      workspaceId: projection.workspaceId,
      grantEpoch: projection.grantEpoch,
      stateVersion: payload.stateVersion,
    );
    Pill? committedStock;
    final inventory = InventoryService(
      db,
      access: protectedAccess,
      context: context,
    );
    await headlessGate.runHeadless(
      () =>
          MedicationRepository(
            db,
            access: protectedAccess,
            context: context,
            onStockChanged: (pill) async => committedStock = pill,
          ).applyDeviceAction(
            occurrenceId: payload.occurrenceId,
            projectionId: payload.projectionId,
            kind: payload.projectionId == reminderId
                ? payload.followUpMinutes == null
                      ? 'reminder'
                      : followUpReminderKind(payload.followUpMinutes!)
                : 'snooze',
            action: action,
            deliveredStateVersion: payload.stateVersion,
          ),
    );
    if (committedStock != null) {
      await inventory.notifyPillStockChanged(committedStock!);
    }
    await protectedAccess.requireCurrent(context);
    await publishWidgetSnapshot(
      db: db,
      access: protectedAccess,
      projectionIdentity: projection,
    );
    // The dose is committed; the reminders must now follow it. A busy or
    // failed pass is retried here a few times and then handed to a one-off
    // background task, rechecking the session before every new attempt.
    await retryReconcileAfterAction(
      attempt: () async {
        try {
          final report = await reconciler.reconcile(
            projectionIdentity: projection,
          );
          return report != null && !report.degraded;
        } on Object catch (error) {
          AppLogger.warning(
            'NotificationAction',
            'Reminder follow-up pass failed: ${error.runtimeType}',
          );
          return false;
        }
      },
      stillCurrent: () async {
        try {
          await protectedAccess.requireCurrent(context);
          return true;
        } on Object {
          return false;
        }
      },
      handOff: scheduleReconcileRetry ?? scheduleReminderRetryTask,
      delays: reconcileRetryDelays,
      wait: reconcileRetryWait,
    );
  } on Object catch (error) {
    AppLogger.warning(
      'NotificationAction',
      'Occurrence action unavailable: ${error.runtimeType}',
    );
  } finally {
    if (ownDb) {
      try {
        await db.close();
      } on Object {
        /* Failed protected open stays unavailable. */
      }
    }
  }
}

ProjectionReconciler _reconcilerForAction({
  required AppDatabase db,
  required SharedPreferences prefs,
  required SessionGenerationRepository generations,
  required FlutterLocalNotificationsPlugin plugin,
}) => ProjectionReconciler(
  database: db,
  preferences: prefs,
  generations: generations,
  platform: NotificationService(plugin),
  platformKind: ProjectionReconciler.currentPlatformKind,
);
