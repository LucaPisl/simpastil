import 'dart:convert';

import 'package:timezone/timezone.dart' as tz;

import '../../l10n/app_localizations.dart';
import '../db/daos/medication_ledger_dao.dart';
import '../medication/local_occurrence_snapshot.dart';
import '../notifications/reminder_channel.dart';
import '../notifications/reminder_copy.dart';
import '../notifications/reminder_preferences.dart';
import '../utils/app_logger.dart';
import 'projection_command_id.dart';
import 'projection_identity.dart';

/// How a reminder's Taken, Snooze and Skip buttons behave. Version 1 opens the
/// app for an explicit review (the only safe route while app lock is on, since
/// a headless engine cannot unlock). Version 2 runs the action in the
/// background without opening the app. The version is stored with the
/// reminder so a changed lock policy re-publishes it.
const reminderForegroundActionVersion = 1;
const reminderSilentActionVersion = 2;

enum ReminderPlatformKind { android, ios, other }

class ReminderProjection {
  const ReminderProjection({
    required this.notificationId,
    required this.projectionId,
    required this.occurrenceId,
    required this.userId,
    required this.sessionGeneration,
    required this.scheduledAtUtc,
    required this.timeZone,
    required this.title,
    required this.body,
    required this.payload,
    this.identity,
    this.stateVersion,
    this.allowCareActions = true,
    this.silentActions = false,
    this.followUpMinutes,
  });

  /// The same reminder under another notification id, for collision probing.
  ReminderProjection withNotificationId(int id) => ReminderProjection(
    notificationId: id,
    projectionId: projectionId,
    occurrenceId: occurrenceId,
    userId: userId,
    sessionGeneration: sessionGeneration,
    scheduledAtUtc: scheduledAtUtc,
    timeZone: timeZone,
    title: title,
    body: body,
    payload: payload,
    identity: identity,
    stateVersion: stateVersion,
    allowCareActions: allowCareActions,
    silentActions: silentActions,
    followUpMinutes: followUpMinutes,
  );

  final int notificationId;
  final String projectionId;
  final String occurrenceId;
  final String userId;
  final int sessionGeneration;
  final DateTime scheduledAtUtc;
  final String timeZone;
  final String title;
  final String body;
  final String payload;
  final ProjectionIdentity? identity;
  final int? stateVersion;
  final bool allowCareActions;

  /// True when the care buttons act in the background instead of opening the
  /// app. Only ever set while app lock is off.
  final bool silentActions;

  int get actionPresentationVersion => silentActions
      ? reminderSilentActionVersion
      : reminderForegroundActionVersion;

  /// Minutes after the planned time for a follow-up reminder; null for the
  /// first reminder and for a snooze.
  final int? followUpMinutes;

  Map<String, Object?> toRegistryEntry() => {
    if (identity != null) ...identity!.toJson(),
    'id': notificationId,
    'kind': 'reminder',
    if (stateVersion != null) 'stateVersion': stateVersion,
    'projectionId': projectionId,
    'occurrenceId': occurrenceId,
    'userId': userId,
    'sessionGeneration': sessionGeneration,
    'scheduledAtUtc': scheduledAtUtc.toIso8601String(),
    'allowCareActions': allowCareActions,
    'channelRevision': kReminderChannelRevision,
    if (followUpMinutes != null) 'followUpMinutes': followUpMinutes,
    if (allowCareActions)
      'actionPresentationVersion': actionPresentationVersion,
  };
}

class ReminderProjectionBatch {
  ReminderProjectionBatch({
    required List<ReminderProjection> reminders,
    required this.availableCount,
    required this.coverageShortened,
    required this.invalidOccurrenceCount,
  }) : reminders = List.unmodifiable(reminders);

  final List<ReminderProjection> reminders;
  final int availableCount;
  final bool coverageShortened;
  final int invalidOccurrenceCount;
}

class PlatformReminderRequest {
  const PlatformReminderRequest({
    required this.id,
    required this.title,
    required this.body,
    required this.payload,
  });

  final int id;
  final String title;
  final String body;
  final String? payload;
}

/// Optional delivered-alert inventory. Android does not expose PendingIntent
/// payloads, so protected registry identity remains the authority.
class PlatformActiveReminder {
  const PlatformActiveReminder({
    required this.id,
    required this.title,
    required this.body,
    this.tag,
    this.channelId,
    this.payload,
  });
  final int id;
  final String title;
  final String body;
  final String? tag;
  final String? channelId;
  final String? payload;
}

abstract interface class ActiveReminderNotificationPlatform {
  Future<List<PlatformActiveReminder>> activeReminders();
}

/// Optional: removes the channels of retired revisions. The reconciler calls
/// it only after a pass that moved every reminder onto the current channel.
abstract interface class RetiredChannelNotificationPlatform {
  Future<void> deleteRetiredChannels();
}

abstract interface class ReminderNotificationPlatform {
  Future<void> initialize();
  Future<bool> hasExactAlarmPermission();
  Future<bool> hasNotificationPermission();
  Future<List<PlatformReminderRequest>> pendingRequests();
  Future<void> schedule(
    ReminderProjection reminder, {
    required AppLocalizations localizations,
  });
  Future<void> cancel(int notificationId);
  Future<void> cancelAll();
}

class ReminderProjectionBuilder {
  const ReminderProjectionBuilder();

  static const _androidHorizon = Duration(days: 30);
  static const _iosReminderLimit = 64;

  ReminderProjectionBatch build({
    required List<MedicationOccurrenceRecord> records,
    required Set<String> activeProfileIds,
    required String userId,
    required int sessionGeneration,
    required DateTime now,
    required ReminderPlatformKind platform,
    required AppLocalizations localizations,
    ProjectionIdentity? identity,
    ReminderPreferences? preferences,
    bool silentActions = false,
  }) {
    if (sessionGeneration < 1) {
      throw ArgumentError.value(sessionGeneration, 'sessionGeneration');
    }

    final nowUtc = now.toUtc();
    final endUtc = nowUtc.add(_androidHorizon);
    final candidates = <ReminderProjection>[];
    var invalidCount = 0;

    for (final record in records) {
      final occurrence = record.occurrence;
      final plannedAt = occurrence.plannedAt?.toUtc();
      if (occurrence.userId != userId ||
          occurrence.source != 'scheduled' ||
          !occurrence.expected ||
          occurrence.provenance != 'exact' ||
          occurrence.state != 'pending' ||
          occurrence.supersededAt != null ||
          plannedAt == null) {
        continue;
      }
      if (platform != ReminderPlatformKind.ios && plannedAt.isAfter(endUtc)) {
        continue;
      }

      try {
        final snapshot = decodeScheduleSnapshot(
          jsonDecode(occurrence.scheduleSnapshotJson) as Map<String, dynamic>,
        );
        if (!snapshotOwns(snapshot, userId, identity?.workspaceId) ||
            !activeProfileIds.contains(snapshot.profileId) ||
            snapshot.frequency == 'prn' ||
            snapshot.timeZone != occurrence.timeZone ||
            snapshot.pillName.trim().isEmpty) {
          continue;
        }
        tz.getLocation(occurrence.timeZone);

        final choice =
            preferences?.choiceFor(occurrence.scheduleId) ??
            ScheduleReminderChoice();
        if (!choice.enabled) continue;
        final fullDetails = preferences?.fullDetails ?? true;
        for (final offset in [0, ...choice.followUpMinutes]) {
          final scheduledAt = plannedAt.add(Duration(minutes: offset));
          if (!scheduledAt.isAfter(nowUtc) ||
              (platform != ReminderPlatformKind.ios &&
                  scheduledAt.isAfter(endUtc))) {
            continue;
          }
          final projectionId = reminderProjectionId(
            userId: userId,
            sessionGeneration: sessionGeneration,
            occurrenceId: occurrence.id,
            kind: offset == 0 ? 'reminder' : followUpReminderKind(offset),
            workspaceId: identity?.workspaceId,
            grantEpoch: identity?.grantEpoch,
            stateVersion: identity == null ? null : occurrence.stateVersion,
          );
          final notificationId = notificationIdForProjection(projectionId);
          final payload = jsonEncode({
            if (identity != null) ...identity.toJson(),
            'occurrenceId': occurrence.id,
            'projectionId': projectionId,
            'userId': userId,
            'sessionGeneration': sessionGeneration,
            if (identity != null) 'stateVersion': occurrence.stateVersion,
            if (offset != 0) 'followUpMinutes': offset,
          });
          final dosage = snapshot is LocalOccurrenceSnapshot
              ? snapshot.amount.isUnknown
                    ? null
                    : '${snapshot.amount.quantityText} ${snapshot.amount.unit}'
              : snapshot.dosage;
          final copy = doseReminderCopy(
            localizations,
            fullDetails: fullDetails,
            pillName: snapshot.pillName,
            dosage: dosage,
            followUpMinutes: offset,
          );
          candidates.add(
            ReminderProjection(
              notificationId: notificationId,
              projectionId: projectionId,
              occurrenceId: occurrence.id,
              userId: userId,
              sessionGeneration: sessionGeneration,
              scheduledAtUtc: scheduledAt,
              timeZone: occurrence.timeZone,
              title: copy.title,
              body: copy.body,
              payload: payload,
              identity: identity,
              stateVersion: identity == null ? null : occurrence.stateVersion,
              allowCareActions: fullDetails,
              silentActions: silentActions && fullDetails,
              followUpMinutes: offset == 0 ? null : offset,
            ),
          );
        }
      } on Object {
        // An unsupported snapshot or time zone is not safe to guess from.
        invalidCount++;
      }
    }

    candidates.sort((a, b) {
      final timeOrder = a.scheduledAtUtc.compareTo(b.scheduledAtUtc);
      return timeOrder != 0
          ? timeOrder
          : a.occurrenceId.compareTo(b.occurrenceId);
    });

    final ids = <int>{};
    var collisions = 0;
    final assigned = <String, int>{};
    // Probe in projection-id order so the result never depends on the order
    // the occurrences were read. An id taken by another reminder of this batch
    // moves along a fixed sequence; the reconciler records the id it got.
    final byProjection = candidates.toList()
      ..sort((a, b) => a.projectionId.compareTo(b.projectionId));
    for (final reminder in byProjection) {
      var probe = 0;
      var id = notificationIdForProjection(reminder.projectionId);
      while (!ids.add(id)) {
        probe++;
        if (probe > maxNotificationIdProbe) {
          id = -1;
          break;
        }
        id = notificationIdForProjection(reminder.projectionId, probe: probe);
      }
      if (probe > 0) collisions++;
      if (id >= 0) assigned[reminder.projectionId] = id;
    }
    if (collisions > 0) {
      AppLogger.warning(
        'ReminderProjectionBuilder',
        'Reminder id collision resolved for $collisions reminder(s)',
      );
    }
    final placed = [
      for (final reminder in candidates)
        // A reminder that found no free id within the probe bound is dropped
        // (counted as invalid) rather than aborting the whole batch.
        if (assigned[reminder.projectionId] case final int id)
          id == reminder.notificationId
              ? reminder
              : reminder.withNotificationId(id)
        else
          null,
    ];
    invalidCount += placed.where((item) => item == null).length;
    candidates
      ..clear()
      ..addAll(placed.whereType<ReminderProjection>());

    final coverageShortened =
        platform == ReminderPlatformKind.ios &&
        candidates.length > _iosReminderLimit;
    final reminders = platform == ReminderPlatformKind.ios
        ? candidates.take(_iosReminderLimit).toList()
        : candidates;

    return ReminderProjectionBatch(
      reminders: reminders,
      availableCount: candidates.length,
      coverageShortened: coverageShortened,
      invalidOccurrenceCount: invalidCount,
    );
  }
}

const _notificationIdMask = 0x3FFFFFFF;
const _notificationIdProbeStep = 0x9E3779B1;

/// How many alternatives follow the base id when two reminders collide.
const maxNotificationIdProbe = 16;

/// The 30-bit id for [projectionId]. [probe] 0 is the base id every earlier
/// build used; higher values are the deterministic collision alternatives.
int notificationIdForProjection(String projectionId, {int probe = 0}) =>
    ((int.parse(projectionId.replaceAll('-', '').substring(0, 8), radix: 16) &
            _notificationIdMask) +
        probe * _notificationIdProbeStep) &
    _notificationIdMask;

/// True when [id] is the base id or one of the collision alternatives of
/// [projectionId]. Payload and projection id are still checked separately.
bool notificationIdMatchesProjection(String projectionId, int id) {
  for (var probe = 0; probe <= maxNotificationIdProbe; probe++) {
    if (notificationIdForProjection(projectionId, probe: probe) == id) {
      return true;
    }
  }
  return false;
}

/// Re-assigns notification ids so a reminder keeps the id it already holds.
///
/// The builder probes per batch, so a projection that appears or disappears
/// would otherwise shift a colliding neighbour onto a different id while its
/// old alarm is still armed. [preferred] maps projection ids to the id the
/// registry or the pending list already records for them; [occupied] holds ids
/// held by something else (another owner, a snooze, low stock, readiness).
/// Projections without a usable preferred id take the first free probe id in
/// projectionId order. One that finds none is dropped, logged and reported
/// through [onDropped] so the caller can count it as degraded.
List<ReminderProjection> stabilizeReminderIds(
  List<ReminderProjection> reminders, {
  required Map<String, int> preferred,
  required Set<int> occupied,
  void Function(int dropped)? onDropped,
}) {
  final used = <int>{};
  final assigned = <String, int>{};
  final ordered = [...reminders]
    ..sort((a, b) => a.projectionId.compareTo(b.projectionId));
  for (final reminder in ordered) {
    final id = preferred[reminder.projectionId];
    if (id != null &&
        notificationIdMatchesProjection(reminder.projectionId, id) &&
        !occupied.contains(id) &&
        used.add(id)) {
      assigned[reminder.projectionId] = id;
    }
  }
  var dropped = 0;
  for (final reminder in ordered) {
    if (assigned.containsKey(reminder.projectionId)) continue;
    var placed = false;
    for (var probe = 0; probe <= maxNotificationIdProbe; probe++) {
      final id = notificationIdForProjection(
        reminder.projectionId,
        probe: probe,
      );
      if (!occupied.contains(id) && used.add(id)) {
        assigned[reminder.projectionId] = id;
        placed = true;
        break;
      }
    }
    if (!placed) dropped++;
  }
  if (dropped > 0) {
    onDropped?.call(dropped);
    AppLogger.warning(
      'ReminderProjectionBuilder',
      'No free reminder id for $dropped reminder(s)',
    );
  }
  return [
    for (final reminder in reminders)
      if (assigned[reminder.projectionId] case final int id)
        id == reminder.notificationId
            ? reminder
            : reminder.withNotificationId(id),
  ];
}
