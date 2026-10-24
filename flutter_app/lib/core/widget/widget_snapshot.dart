import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:drift/drift.dart' show Variable;

import '../db/daos/medication_ledger_dao.dart';
import '../db/database.dart';
import '../medication/current_name_display.dart';
import '../medication/local_occurrence_snapshot.dart';
import '../medication/medication_look.dart';
import '../medication/medication_shape.dart';
import '../medication/pill_color_display.dart';
import '../medication/routine_repository.dart';
import '../projections/projection_effects_gate.dart';
import '../projections/projection_identity.dart';
import '../workspace/workspace_access_repository.dart';
import '../workspace/workspace_context.dart';
import 'protected_widget_publisher.dart';
import '../doses/slot_engine.dart';
import '../projections/projection_command_id.dart';
import '../session/session_generation_repository.dart';
import '../storage/preference_keys.dart';
import '../storage/appearance_preferences.dart';
import '../utils/app_logger.dart';

/// HomeWidget storage key for the JSON snapshot.
const kWidgetSnapshotKey = kTodayDosesKey;

/// HomeWidget storage key for the snapshot's calendar day (yyyy-MM-dd).
/// The Kotlin provider compares it against the current day to detect
/// midnight rollover and request a recompute.
const kWidgetSnapshotDayKey = kSnapshotDayKey;

/// The Android AppWidgetProvider class name.
const kWidgetProviderName = 'DoseWidgetProvider';

/// The colour the widget draws a medication in: the display colour, so it
/// matches the app. Empty when the medication has none, and the widget uses
/// its own default.
String widgetColorOf(String? hex) => hex == null ? '' : displayHexFor(hex);

/// The two fields the widget draws a medication's pill with: `shape` (one of
/// the nine wire names) and `imprint` (one or two letters, possibly empty).
/// A widget that predates them ignores both; a payload without them draws the
/// widget's older capsule.
Map<String, String> widgetLookOf(
  Pill pill,
  Map<String, MedicationLook>? looks,
) {
  final look = looks?[pill.id];
  return {
    'shape': (look?.shape ?? effectiveMedicationShape(pill.shape, null)).wire,
    'imprint': look?.imprint ?? imprintInitial(pill.name),
  };
}

Future<void> _widgetWriteQueue = Future<void>.value();

Future<void> _enqueueWidgetWrite(Future<void> Function() operation) {
  final next = _widgetWriteQueue.then((_) => operation());
  _widgetWriteQueue = next.catchError((Object _) {});
  return next;
}

String _dayString(DateTime day) =>
    '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

/// Builds the widget JSON from today's slots. Pure — same slot engine as the
/// dashboard and calendar, so all three surfaces always agree.
Map<String, dynamic> buildWidgetSnapshot({
  required List<({Pill pill, List<Schedule> schedules})> pillsWithSchedules,
  required List<DoseLog> logs,
  required DateTime now,
  bool prnInStats = false,
  bool prnInWidget = false,
  bool fullDetails = true,
  List<MedicationOccurrenceRecord>? occurrenceRecords,
  String? activeUserId,
  int? sessionGeneration,
  ProjectionIdentity? projectionIdentity,
  Map<String, MedicationLook>? looks,
}) {
  final today = dateOnly(now);
  final hasActiveIdentity =
      activeUserId != null &&
      activeUserId.isNotEmpty &&
      sessionGeneration != null &&
      sessionGeneration >= 0;
  if (!fullDetails) {
    return {
      if (projectionIdentity != null)
        'projectionIdentity': projectionIdentity.toJson(),
      'authenticated': hasActiveIdentity,
      'active_user_id': hasActiveIdentity ? activeUserId : null,
      'session_generation': hasActiveIdentity ? sessionGeneration : null,
      'day': _dayString(today),
      'taken': 0,
      'total': 0,
      'doses': const <Object>[],
      'private': true,
    };
  }

  final logByKey = {
    for (final l in logs) slotKey(l.scheduleId, l.scheduledAt): l,
  };

  final scheduledDoses = <Map<String, dynamic>>[];
  final prnDoses = <Map<String, dynamic>>[];
  if (occurrenceRecords == null) {
    for (final pws in pillsWithSchedules) {
      if (pws.pill.isPrn) {
        final sentinel = pws.schedules
            .where((s) => s.frequency == 'prn')
            .firstOrNull;
        if (sentinel == null) continue;
        final count = logs
            .where((l) => l.scheduleId == sentinel.id && l.status == 'taken')
            .length;
        final entry = {
          'scheduleId': sentinel.id,
          'scheduledAt': now.toIso8601String(),
          'pill': '${pws.pill.name} (PRN)',
          'time': '$count× today',
          'status': count > 0 ? 'taken' : 'pending',
          'color': widgetColorOf(pws.pill.color),
          ...widgetLookOf(pws.pill, looks),
          'isPrn': true,
        };
        if (prnInWidget) prnDoses.add(entry);
        continue;
      }

      for (final slot in expectedSlotsFor(pws.schedules, today)) {
        final log = logByKey[slotKey(slot.schedule.id, slot.scheduledAt)];
        final status = computeDoseStatus(log);
        final h = slot.scheduledAt.hour.toString().padLeft(2, '0');
        final m = slot.scheduledAt.minute.toString().padLeft(2, '0');
        scheduledDoses.add({
          'scheduleId': slot.schedule.id,
          'scheduledAt': slot.scheduledAt.toIso8601String(),
          'pill': pws.pill.name,
          'time': '$h:$m',
          'status': status.name,
          'color': widgetColorOf(pws.pill.color),
          ...widgetLookOf(pws.pill, looks),
        });
      }
    }
  } else {
    _appendOccurrenceDoses(
      records: occurrenceRecords,
      pillsWithSchedules: pillsWithSchedules,
      now: now,
      prnInWidget: prnInWidget,
      scheduledDoses: scheduledDoses,
      prnDoses: prnDoses,
      activeUserId: activeUserId,
      sessionGeneration: sessionGeneration,
      projectionIdentity: projectionIdentity,
      looks: looks,
    );
  }
  scheduledDoses.sort(
    (a, b) =>
        (a['scheduledAt'] as String).compareTo(b['scheduledAt'] as String),
  );

  final scheduledTaken = scheduledDoses
      .where((d) => d['status'] == 'taken' && d['isPrn'] != true)
      .length;
  final scheduledTotal = scheduledDoses.where((d) => d['isPrn'] != true).length;

  final doses = [...scheduledDoses, ...prnDoses];

  return {
    if (projectionIdentity != null)
      'projectionIdentity': projectionIdentity.toJson(),
    'authenticated': hasActiveIdentity,
    'active_user_id': hasActiveIdentity ? activeUserId : null,
    'session_generation': hasActiveIdentity ? sessionGeneration : null,
    'day': _dayString(today),
    'taken': scheduledTaken,
    'total': scheduledTotal,
    'doses': doses,
  };
}

/// Computes today's snapshot from the local DB — no Riverpod, callable from
/// background entry points. [now] is injectable for tests.
Future<Map<String, dynamic>> computeWidgetSnapshot({
  required AppDatabase db,
  required SharedPreferences prefs,
  DateTime? now,
  WorkspaceAccessRepository? access,
  WorkspaceContext? context,
}) async {
  final clock = now ?? DateTime.now();
  final protected =
      access ??
      WorkspaceAccessRepository(db, effectsGate: privateProjectionEffectsGate);
  final captured = context ?? await protected.currentContext();
  return protected.withGrant(captured, () async {
    final userId = captured.ownerUserId;
    final dayKey = _dayString(dateOnly(clock));
    final reminderSettings =
        await (db.select(db.deviceReminderSettings)
              ..where((row) => row.workspaceId.equals(captured.workspaceId)))
            .getSingleOrNull();
    final identity = ProjectionIdentity.fromContext(captured);
    if (reminderSettings?.fullDetails == false) {
      return buildWidgetSnapshot(
        pillsWithSchedules: const [],
        logs: const [],
        now: clock,
        fullDetails: false,
        activeUserId: userId,
        sessionGeneration: identity.grantEpoch,
        projectionIdentity: identity,
      );
    }
    await RoutineRepository(
      database: db,
      access: protected,
      context: captured,
      clock: () => clock,
    ).ensureMaterialized(fromLocalDate: dayKey, throughLocalDate: dayKey);

    final profileRows = await db
        .customSelect(
          'SELECT p.* FROM profiles p JOIN device_person_reminders r ON r.profile_id=p.id WHERE p.user_id=? AND p.is_deleted=0 AND r.enabled=1',
          variables: [Variable<String>(userId)],
          readsFrom: {db.profiles, db.devicePersonReminders},
        )
        .get();
    final profiles = profileRows
        .map((row) => db.profiles.map(row.data))
        .toList();
    final pillsWithSchedules = <({Pill pill, List<Schedule> schedules})>[];
    for (final profile in profiles) {
      for (final pill in await db.pillsDao.getByProfileId(profile.id)) {
        pillsWithSchedules.add((
          pill: pill,
          schedules: (await db.schedulesDao.getByPillId(
            pill.id,
          )).where((row) => !row.isDeleted && row.isActive).toList(),
        ));
      }
    }
    final pillsById = {
      for (final entry in pillsWithSchedules) entry.pill.id: entry.pill,
    };
    final records =
        (await db.medicationLedgerDao.getForUserLocalDateRange(
          userId,
          dayKey,
          dayKey,
        )).where((record) {
          final pill = pillsById[record.occurrence.pillId];
          if (pill == null) return false;
          try {
            final snapshot = decodeScheduleSnapshot(
              jsonDecode(record.occurrence.scheduleSnapshotJson)
                  as Map<String, dynamic>,
            );
            return snapshotOwns(snapshot, userId, captured.workspaceId) &&
                snapshot.profileId == pill.profileId &&
                snapshot.timeZone == record.occurrence.timeZone;
          } on Object {
            return false;
          }
        }).toList();
    // Imprints are worked out among all of the person's medications, not
    // just those on the widget, so a pill reads the same as in the app.
    final looks = buildMedicationLooks(
      await readMedicationLookRows(db, userId),
    );
    return buildWidgetSnapshot(
      pillsWithSchedules: pillsWithSchedules,
      logs: const [],
      prnInStats: prefs.getBool(prnInStatsPreferenceKey(userId)) ?? false,
      prnInWidget: prefs.getBool(prnInWidgetPreferenceKey(userId)) ?? false,
      occurrenceRecords: records,
      activeUserId: userId,
      sessionGeneration: identity.grantEpoch,
      projectionIdentity: identity,
      looks: looks,
      now: clock,
    );
  });
}

void _appendOccurrenceDoses({
  required List<MedicationOccurrenceRecord> records,
  required List<({Pill pill, List<Schedule> schedules})> pillsWithSchedules,
  required DateTime now,
  required bool prnInWidget,
  required List<Map<String, dynamic>> scheduledDoses,
  required List<Map<String, dynamic>> prnDoses,
  required String? activeUserId,
  required int? sessionGeneration,
  ProjectionIdentity? projectionIdentity,
  Map<String, MedicationLook>? looks,
}) {
  final pillsById = {
    for (final item in pillsWithSchedules) item.pill.id: item.pill,
  };
  final prnCounts = <String, int>{};
  for (final record in records) {
    final occurrence = record.occurrence;
    final pillId = occurrence.pillId;
    if (occurrence.supersededAt != null ||
        (projectionIdentity != null &&
            occurrence.userId != projectionIdentity.ownerId) ||
        pillId == null ||
        !pillsById.containsKey(pillId)) {
      continue;
    }
    if (occurrence.source == 'prn') {
      if (occurrence.state == 'taken') {
        prnCounts.update(pillId, (count) => count + 1, ifAbsent: () => 1);
      }
      continue;
    }
    if (occurrence.source != 'scheduled' ||
        !occurrence.expected ||
        occurrence.plannedAt == null) {
      continue;
    }
    Map<String, dynamic>? snapshot;
    try {
      final decoded = jsonDecode(occurrence.scheduleSnapshotJson);
      if (decoded is Map<String, dynamic>) snapshot = decoded;
    } on FormatException {
      snapshot = null;
    }
    final localTime = occurrence.plannedLocalTime ?? '00:00:00';
    // The stored state is shown as it is. A recorded miss reads "missed" and
    // carries no actions on the widget (only pending doses do).
    final status = switch (occurrence.state) {
      'taken' => 'taken',
      'skipped' => 'skipped',
      'missed' => 'missed',
      _ => 'pending',
    };
    scheduledDoses.add({
      'rowKind': 'scheduled',
      if (projectionIdentity != null) ...{
        ...projectionIdentity.toJson(),
        'active_user_id': projectionIdentity.ownerId,
        'session_generation': projectionIdentity.grantEpoch,
        'stateVersion': occurrence.stateVersion,
      },
      'scheduleId': occurrence.scheduleId ?? '',
      'scheduledAt': occurrence.plannedAt!.toUtc().toIso8601String(),
      'pill': showsCurrentName(occurrence.state)
          ? pillsById[pillId]!.name
          : snapshot?['pillName'] as String? ?? pillsById[pillId]!.name,
      'time': localTime.substring(0, 5),
      'status': status,
      'color': widgetColorOf(pillsById[pillId]!.color),
      ...widgetLookOf(pillsById[pillId]!, looks),
      if (activeUserId != null &&
          activeUserId.isNotEmpty &&
          sessionGeneration != null &&
          sessionGeneration >= 0 &&
          occurrence.userId == activeUserId &&
          occurrence.provenance == 'exact' &&
          occurrence.state == 'pending') ...{
        'active_user_id': activeUserId,
        'session_generation': sessionGeneration,
        'occurrenceId': occurrence.id,
        'projectionId': widgetProjectionId(
          userId: activeUserId,
          sessionGeneration: sessionGeneration,
          occurrenceId: occurrence.id,
          workspaceId: projectionIdentity?.workspaceId,
          grantEpoch: projectionIdentity?.grantEpoch,
          stateVersion: projectionIdentity == null
              ? null
              : occurrence.stateVersion,
        ),
      },
    });
  }

  if (!prnInWidget) return;
  for (final item in pillsWithSchedules.where((entry) => entry.pill.isPrn)) {
    final count = prnCounts[item.pill.id] ?? 0;
    final scheduleId = item.schedules
        .where((schedule) => schedule.frequency == 'prn')
        .firstOrNull
        ?.id;
    prnDoses.add({
      'rowKind': 'prnSummary',
      if (projectionIdentity != null) ...{
        ...projectionIdentity.toJson(),
        'active_user_id': projectionIdentity.ownerId,
        'session_generation': projectionIdentity.grantEpoch,
      },
      'scheduleId': scheduleId ?? '',
      'scheduledAt': now.toIso8601String(),
      'pill': '${item.pill.name} (PRN)',
      'time': '$count× today',
      'status': count > 0 ? 'taken' : 'pending',
      'color': widgetColorOf(item.pill.color),
      ...widgetLookOf(item.pill, looks),
      'isPrn': true,
    });
  }
}

/// Recomputes and pushes the snapshot to the home-screen widget.
///
/// Never throws — widget refresh must not break callers (dose mutations,
/// sync, notification actions); on failure the widget keeps stale content.
/// When [db] is omitted a private instance is opened and closed (background
/// entry points); a passed [db] is left open (app callers own it).
Future<void> publishWidgetSnapshot({
  AppDatabase? db,
  SessionIdentity? identity,
  ProjectionIdentity? projectionIdentity,
  WorkspaceAccessRepository? access,
  ProjectionEffectsGate? effectsGate,
  WidgetProjectionPlatform? platform,
}) => _enqueueWidgetWrite(() async {
  final ownDb = db == null;
  final database = db ?? AppDatabase();
  try {
    final gate = effectsGate ?? privateProjectionEffectsGate;
    final protected =
        access ?? WorkspaceAccessRepository(database, effectsGate: gate);
    // Old foreground callers pass their captured network identity. Resolve it
    // once against protected state; it is never a workspace grant epoch.
    if (identity != null) {
      final network = await protected.currentNetworkCapability();
      if (network == null ||
          (network.ownerId, network.generation) != identity) {
        return;
      }
      final context = await protected.contextForOwner(network.ownerId);
      if (context == null || context.networkEpoch != network.epoch) return;
      final resolved = ProjectionIdentity.fromContext(context);
      if (projectionIdentity != null && projectionIdentity != resolved) return;
      projectionIdentity = resolved;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final captured =
        projectionIdentity ??
        ProjectionIdentity.fromContext(await protected.currentContext());
    var themeMode = AppearanceMode.system.name;
    try {
      final appearance = await AppearancePreferencesRepository(
        SharedAppearancePreferenceStorage(prefs),
      ).load();
      themeMode = appearance.mode.name;
    } on Object {
      // An unreadable viewer preference must not prevent valid care publication
      // or silently replace the retained appearance evidence.
    }
    final clock = DateTime.now();
    await ProtectedWidgetPublisher(
      access: protected,
      effectsGate: gate,
      platform: platform ?? NativeWidgetProjectionPlatform(),
      build: (context) => computeWidgetSnapshot(
        db: database,
        prefs: prefs,
        now: clock,
        access: protected,
        context: context,
      ),
    ).publish(captured, themeMode: themeMode);
  } on Object catch (error) {
    AppLogger.warning(
      'WidgetSnapshot',
      'Publication unavailable: ${error.runtimeType}',
    );
  } finally {
    if (ownDb) {
      try {
        await database.close();
      } on Object {
        /* Optional projection. */
      }
    }
  }
});

Future<void> clearWidgetSnapshot({
  DateTime? now,
  ProjectionIdentity? identity,
  WorkspaceAccessRepository? access,
  WidgetProjectionPlatform? platform,
  ProjectionEffectsGate? effectsGate,
}) => _enqueueWidgetWrite(() async {
  // Unowned teardown is deliberately a no-op. The caller must capture the
  // retired grant before revocation; current preferences are not authority.
  if (identity == null || access == null) return;
  try {
    await ProtectedWidgetPublisher(
      access: access,
      effectsGate: effectsGate ?? privateProjectionEffectsGate,
      platform: platform ?? NativeWidgetProjectionPlatform(),
      build: (_) async => throw StateError('Retirement does not compute care'),
    ).retire(identity);
  } on Object catch (error) {
    AppLogger.warning(
      'WidgetSnapshot',
      'Retirement unavailable: ${error.runtimeType}',
    );
  }
});

Future<void> retireUnavailableWidgetSnapshot({
  required WorkspaceAccessRepository access,
  WidgetProjectionPlatform? platform,
  ProjectionEffectsGate? effectsGate,
}) => _enqueueWidgetWrite(
  () => ProtectedWidgetPublisher(
    access: access,
    effectsGate: effectsGate ?? privateProjectionEffectsGate,
    platform: platform ?? NativeWidgetProjectionPlatform(),
    build: (_) async => throw StateError('Retirement does not compute care'),
  ).retireUnavailable(),
);
