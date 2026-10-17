import 'dart:convert';

import '../../l10n/app_localizations.dart';
import '../db/database.dart';
import '../medication/local_occurrence_snapshot.dart';
import '../notifications/reminder_copy.dart';
import '../notifications/reminder_preferences.dart';
import '../session/session_generation_repository.dart';
import 'projection_command_id.dart';
import 'projection_identity.dart';
import 'reminder_projection.dart';

// Pure reminder planning. Nothing here touches native notifications, the
// registry, the clock or the database; the reconciler keeps the grant and
// generation rechecks immediately before every native effect.

// Android commonly limits each app to 500 alarms, including background work.
// Leave room for readiness checks, snoozes and non-reminder platform work.
const androidReminderBudget = 450;

/// Each eligible shared workspace gets an equal share of the Android budget.
int androidWorkspaceShare(int eligibleWorkspaces) =>
    androidReminderBudget ~/ (eligibleWorkspaces == 0 ? 1 : eligibleWorkspaces);

/// Alarms this projection may hold after other owners' pending alarms.
int androidAdmissionBudget({
  required int otherPendingCount,
  required int workspaceShare,
}) => (androidReminderBudget - otherPendingCount).clamp(0, workspaceShare);

class AndroidBudgetSelection {
  const AndroidBudgetSelection({
    required this.selected,
    required this.shortened,
  });

  final Map<int, ReminderProjection> selected;
  final bool shortened;
}

/// Keeps the nearest reminders (ties broken by projection ID) within [budget].
AndroidBudgetSelection selectWithinAndroidBudget(
  Map<int, ReminderProjection> desiredById,
  int budget,
) {
  final ordered = desiredById.values.toList()
    ..sort((a, b) {
      final time = a.scheduledAtUtc.compareTo(b.scheduledAtUtc);
      return time != 0 ? time : a.projectionId.compareTo(b.projectionId);
    });
  if (ordered.length <= budget) {
    return AndroidBudgetSelection(selected: desiredById, shortened: false);
  }
  return AndroidBudgetSelection(
    selected: {
      for (final item in ordered.take(budget)) item.notificationId: item,
    },
    shortened: true,
  );
}

/// A visible or pending effect may stay only if its care actions are allowed,
/// or it was already published in the private presentation.
bool isPrivacySafeToRetain(
  ReminderProjection desired,
  PlatformReminderRequest? actual,
  Map<String, Object?>? stored,
) =>
    desired.allowCareActions ||
    (actual != null &&
        actual.title == desired.title &&
        actual.body == desired.body &&
        stored?['allowCareActions'] == false &&
        stored?['publicationPending'] != true);

Set<int> privacySafeReminderIds(
  Map<int, ReminderProjection> desiredById, {
  required Map<int, PlatformReminderRequest> pendingById,
  required Map<int, Map<String, Object?>> registry,
}) => {
  for (final entry in desiredById.entries)
    if (isPrivacySafeToRetain(
      entry.value,
      pendingById[entry.key],
      registry[entry.key],
    ))
      entry.key,
};

/// Rebuilds still-valid snoozes from registry entries and pending requests.
/// [owns] decides whether a registry value belongs to the current session
/// or projection identity.
Map<int, ReminderProjection> planActiveSnoozes({
  required Map<int, Map<String, Object?>> registry,
  required Map<int, PlatformReminderRequest> pendingById,
  required List<MedicationOccurrence> occurrences,
  required Set<String> activeProfileIds,
  required SessionIdentity identity,
  required ReminderPreferences preferences,
  required AppLocalizations localizations,
  required DateTime now,
  required bool Function(Object? value) owns,
  ProjectionIdentity? projectionIdentity,
}) {
  final occurrencesById = {for (final item in occurrences) item.id: item};
  final active = <int, ReminderProjection>{};
  for (final entry in registry.entries) {
    final value = entry.value;
    if (value['kind'] != 'snooze' || !owns(value)) continue;
    final occurrenceId = value['occurrenceId'];
    final scheduledAt = value['scheduledAtUtc'];
    final occurrence = occurrencesById[occurrenceId];
    final request = pendingById[entry.key];
    if (occurrence == null ||
        request == null ||
        scheduledAt is! String ||
        occurrence.userId != identity.$1 ||
        occurrence.source != 'scheduled' ||
        !occurrence.expected ||
        occurrence.provenance != 'exact' ||
        occurrence.state != 'pending' ||
        (projectionIdentity != null &&
            value['stateVersion'] != occurrence.stateVersion) ||
        occurrence.supersededAt != null ||
        occurrence.pillId == null ||
        occurrence.scheduleId == null) {
      continue;
    }
    final projectionId = reminderProjectionId(
      userId: identity.$1,
      sessionGeneration: identity.$2,
      occurrenceId: occurrence.id,
      kind: 'snooze',
      workspaceId: projectionIdentity?.workspaceId,
      grantEpoch: projectionIdentity?.grantEpoch,
      stateVersion: projectionIdentity == null ? null : occurrence.stateVersion,
    );
    final expectedPayload = jsonEncode({
      if (projectionIdentity != null) ...projectionIdentity.toJson(),
      'occurrenceId': occurrence.id,
      'projectionId': projectionId,
      'userId': identity.$1,
      'sessionGeneration': identity.$2,
      if (projectionIdentity != null) 'stateVersion': occurrence.stateVersion,
    });
    if (value['projectionId'] != projectionId ||
        request.payload != expectedPayload) {
      continue;
    }
    try {
      final retainedInstant = DateTime.parse(scheduledAt).toUtc();
      if (!retainedInstant.isAfter(now.toUtc())) continue;
      final snapshot = decodeScheduleSnapshot(
        jsonDecode(occurrence.scheduleSnapshotJson) as Map<String, dynamic>,
      );
      if (snapshot.timeZone != occurrence.timeZone ||
          !activeProfileIds.contains(snapshot.profileId)) {
        continue;
      }
      final snoozed = snoozedReminderCopy(
        localizations,
        fullDetails: preferences.fullDetails,
        pillName: snapshot.pillName,
      );
      active[entry.key] = ReminderProjection(
        notificationId: entry.key,
        projectionId: projectionId,
        occurrenceId: occurrence.id,
        userId: identity.$1,
        sessionGeneration: identity.$2,
        identity: projectionIdentity,
        stateVersion: projectionIdentity == null
            ? null
            : occurrence.stateVersion,
        scheduledAtUtc: retainedInstant,
        timeZone: occurrence.timeZone,
        title: snoozed.title,
        body: snoozed.body,
        payload: expectedPayload,
        allowCareActions: preferences.fullDetails,
      );
    } on Object {
      continue;
    }
  }
  return active;
}

// ── Audit: pending reminders nothing recognises ─────────────────────────────

/// Alarms and registry entries written less than this long before a pass began
/// belong to an effect that may still be in flight in another isolate.
const reminderAuditGrace = Duration(seconds: 60);

enum ReminderAuditReason {
  /// The pre-occurrence envelope: a bare route such as `/home`, or route JSON
  /// naming a schedule.
  legacy,

  /// A modern-looking payload no registry entry or workspace accounts for.
  unowned,

  /// A registry entry for an id that is no longer desired.
  stale,

  /// No payload at all, or one that is neither a route nor our JSON.
  unparseable,

  /// An id the ledger remembers arming that the plugin no longer lists.
  ledgerGhost,
}

class ReminderAuditPlan {
  const ReminderAuditPlan({
    this.cancel = const {},
    this.deferredReason,
    this.pendingBefore = 0,
  });

  /// Ids to cancel and why. Includes ledger ghosts absent from the pending list.
  final Map<int, ReminderAuditReason> cancel;

  /// Why nothing was planned, or null when the audit may act.
  final String? deferredReason;
  final int pendingBefore;

  bool get deferred => deferredReason != null;
}

/// How long a `publicationPending` mark may block the audit. A publish takes
/// seconds; a mark older than this belongs to a process that died mid-publish,
/// and the reconciler settles that entry itself.
const publicationPendingTtl = Duration(minutes: 10);

/// True while [entry] is marked mid-publish and the mark is still plausible.
/// A mark without a time (written by an older build) keeps blocking.
bool publicationInFlight(Map<String, Object?> entry, DateTime now) {
  if (entry['publicationPending'] != true) return false;
  final raw = entry['publicationPendingAt'];
  final at = raw is String ? DateTime.tryParse(raw) : null;
  if (at == null) return true;
  return now.toUtc().difference(at.toUtc()) < publicationPendingTtl;
}

/// Plans cancellation of every pending reminder that is neither desired nor
/// protected. Pure: the reconciler supplies the union of what all workspaces
/// want and keeps the grant, care-revision and gate checks around each cancel.
///
/// Protected: a desired id whose payload names the desired projection; a
/// delivered reminder the pass verified ([preservedIds]); a low-stock or
/// readiness registry entry; and anything recorded in [ledger] at or after
/// [passStartedAt] minus [reminderAuditGrace].
ReminderAuditPlan planReminderAudit({
  required bool allWorkspacesReady,
  required Map<int, PlatformReminderRequest> pendingById,
  required Map<int, Set<String>> desiredProjectionIds,
  required Set<int> preservedIds,
  required Set<int> activeIds,
  required Map<int, Map<String, Object?>> registry,
  required Map<int, DateTime> ledger,
  required DateTime now,
  DateTime? passStartedAt,
}) {
  if (!allWorkspacesReady) {
    return ReminderAuditPlan(
      deferredReason: 'notReady',
      pendingBefore: pendingById.length,
    );
  }
  if (registry.values.any((entry) => publicationInFlight(entry, now))) {
    // Another isolate is mid-publish; its alarm may not be recorded yet.
    return ReminderAuditPlan(
      deferredReason: 'publicationPending',
      pendingBefore: pendingById.length,
    );
  }
  final start = passStartedAt != null && passStartedAt.isBefore(now)
      ? passStartedAt
      : now;
  final cutoff = start.toUtc().subtract(reminderAuditGrace);
  bool recent(int id) {
    final at = ledger[id];
    return at != null && !at.isBefore(cutoff);
  }

  bool protectedByRegistry(int id) {
    final kind = registry[id]?['kind'];
    return kind == 'lowStock' || kind == 'readiness';
  }

  final cancel = <int, ReminderAuditReason>{};
  for (final entry in pendingById.entries) {
    final id = entry.key;
    final payloadProjection = _auditPayloadProjectionId(entry.value.payload);
    if (preservedIds.contains(id) ||
        (payloadProjection != null &&
            (desiredProjectionIds[id]?.contains(payloadProjection) ?? false)) ||
        protectedByRegistry(id) ||
        recent(id)) {
      continue;
    }
    cancel[id] = _auditReason(entry.value.payload, registry[id]);
  }
  for (final id in ledger.keys) {
    if (pendingById.containsKey(id) ||
        cancel.containsKey(id) ||
        desiredProjectionIds.containsKey(id) ||
        preservedIds.contains(id) ||
        activeIds.contains(id) ||
        protectedByRegistry(id) ||
        recent(id)) {
      continue;
    }
    cancel[id] = ReminderAuditReason.ledgerGhost;
  }
  return ReminderAuditPlan(cancel: cancel, pendingBefore: pendingById.length);
}

Object? _auditDecode(String? raw) {
  if (raw == null) return null;
  try {
    return jsonDecode(raw);
  } on FormatException {
    return null;
  }
}

String? _auditPayloadProjectionId(String? raw) {
  final value = _auditDecode(raw);
  return value is Map && value['projectionId'] is String
      ? value['projectionId'] as String
      : null;
}

ReminderAuditReason _auditReason(String? raw, Map<String, Object?>? entry) {
  if (raw == null) return ReminderAuditReason.unparseable;
  final value = _auditDecode(raw);
  if (value == null) {
    return raw.startsWith('/')
        ? ReminderAuditReason.legacy
        : ReminderAuditReason.unparseable;
  }
  if (value is! Map) return ReminderAuditReason.unparseable;
  if (value['projectionId'] is! String) {
    return value.containsKey('route') || value.containsKey('scheduleId')
        ? ReminderAuditReason.legacy
        : ReminderAuditReason.unparseable;
  }
  return entry != null
      ? ReminderAuditReason.stale
      : ReminderAuditReason.unowned;
}

/// The (workspace, occurrence, kind) a delivered reminder belongs to, or null
/// when its kind cannot be told apart. A snooze and a first reminder carry
/// the same payload shape, so the registry has to say which one it is.
String? activeReminderGroup(
  PlatformActiveReminder active,
  Map<String, Object?>? entry,
) {
  final payload = _auditDecode(active.payload);
  final source = payload is Map && payload['occurrenceId'] is String
      ? payload
      : entry;
  final occurrenceId = source?['occurrenceId'];
  if (occurrenceId is! String) return null;
  final workspaceId = source?['workspaceId'] ?? '';
  final String? kind;
  if (entry != null && entry['kind'] == 'snooze') {
    kind = 'snooze';
  } else if (entry != null && entry['followUpMinutes'] is int) {
    kind = 'followUp:${entry['followUpMinutes']}';
  } else if (payload is Map && payload['followUpMinutes'] is int) {
    kind = 'followUp:${payload['followUpMinutes']}';
  } else if (entry != null && entry['kind'] == 'reminder' && payload is Map) {
    kind = 'reminder';
  } else {
    // Not provably the first reminder: leave it alone.
    kind = null;
  }
  return kind == null ? null : '$workspaceId|$occurrenceId|$kind';
}

/// Several delivered notifications for one (occurrence, kind) are leftovers of
/// an earlier state version or of an alarm nothing retired. Keeps only the one
/// matching the desired id (or a verified delivered one) and returns the rest.
Set<int> planActiveDedupe({
  required List<PlatformActiveReminder> active,
  required Map<int, Map<String, Object?>> registry,
  required Set<int> keepIds,
  required bool Function(String? channelId) isAppChannel,
  required Map<int, DateTime> ledger,
  required DateTime now,
  DateTime? passStartedAt,
}) {
  final start = passStartedAt != null && passStartedAt.isBefore(now)
      ? passStartedAt
      : now;
  final cutoff = start.toUtc().subtract(reminderAuditGrace);
  final groups = <String, List<int>>{};
  for (final item in active) {
    final kind = registry[item.id]?['kind'];
    if (item.tag != null ||
        kind == 'lowStock' ||
        kind == 'readiness' ||
        (item.channelId != null && !isAppChannel(item.channelId))) {
      continue;
    }
    final group = activeReminderGroup(item, registry[item.id]);
    if (group != null) groups.putIfAbsent(group, () => []).add(item.id);
  }
  final cancel = <int>{};
  for (final ids in groups.values) {
    if (ids.length < 2) continue;
    final kept = ids.where(keepIds.contains).toSet();
    final candidates = ids.where((id) => !kept.contains(id)).toList();
    if (kept.isEmpty && candidates.isNotEmpty) {
      // Nothing is known to be wanted: keep the newest delivered one (by the
      // ledger's first-seen time; an id the ledger never saw counts as oldest)
      // so the person still sees one reminder, and retire the rest.
      candidates.sort((a, b) {
        final byTime = (ledger[a] ?? _epoch).compareTo(ledger[b] ?? _epoch);
        return byTime != 0 ? byTime : a.compareTo(b);
      });
      candidates.removeLast();
    }
    for (final id in candidates) {
      final at = ledger[id];
      if (!(at != null && !at.isBefore(cutoff))) cancel.add(id);
    }
  }
  return cancel;
}

final _epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

/// Whether the channels of retired revisions can be deleted without losing a
/// reminder. Deleting a channel dismisses what is delivered on it and makes
/// the plugin resurrect it for any alarm still naming it, so none may remain:
/// no pending reminder whose registry entry was recorded on an earlier
/// revision, and no delivered reminder on a retired channel that is wanted or
/// registered.
bool retiredChannelsClear({
  required Map<int, Map<String, Object?>> registry,
  required Set<int> pendingIds,
  required List<PlatformActiveReminder> active,
  required Set<int> wantedIds,
  required Set<String> retiredChannelIds,
  required int currentRevision,
}) {
  for (final entry in registry.entries) {
    final value = entry.value;
    final kind = value['kind'];
    if ((kind != 'reminder' && kind != 'snooze') ||
        !pendingIds.contains(entry.key)) {
      continue;
    }
    final revision = value['channelRevision'];
    if ((revision is int ? revision : 1) < currentRevision) return false;
  }
  for (final item in active) {
    if (retiredChannelIds.contains(item.channelId) &&
        (wantedIds.contains(item.id) || registry.containsKey(item.id))) {
      return false;
    }
  }
  return true;
}
