import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../db/daos/medication_ledger_dao.dart';
import '../db/database.dart';
import '../medication/current_name_display.dart';
import '../medication/local_occurrence_snapshot.dart';
import '../medication/occurrence_materializer.dart';
import '../projections/projection_identity.dart';
import '../projections/reminder_eligibility.dart';
import '../projections/reminder_projection.dart';
import '../workspace/workspace_access_repository.dart';
import '../workspace/workspace_context.dart';
import '../workspace/workspace_provider.dart';
import 'reminder_copy.dart';
import 'reminder_preferences.dart';

/// One reminder this device is planned to show, as the Reminders page lists it.
class UpcomingReminder {
  const UpcomingReminder({
    required this.occurrenceId,
    required this.pillName,
    required this.dosage,
    required this.profileId,
    required this.profileName,
    required this.at,
    required this.copy,
  });

  final String occurrenceId;
  final String pillName;
  final String? dosage;
  final String profileId;
  final String profileName;

  /// When the notification fires, in this device's own time zone.
  final DateTime at;

  /// The words the notification carries, with the privacy choice applied.
  final ReminderCopy copy;
}

/// The next reminders on this device and how the first one will look.
class NextRemindersPlan {
  const NextRemindersPlan({
    required this.upcoming,
    required this.fullDetails,
    required this.availableCount,
    required this.peopleCount,
  });

  /// Nearest first. Follow-up reminders are not listed: they repeat a dose
  /// that is already in the list.
  final List<UpcomingReminder> upcoming;

  /// The privacy choice the copy was made with. False keeps names and
  /// amounts off the notification, and removes its care actions.
  final bool fullDetails;

  /// Planned doses with a reminder inside the horizon, listed or not.
  final int availableCount;

  /// People switched on for reminders on this device. With more than one, a
  /// list names whose dose each reminder is.
  final int peopleCount;

  UpcomingReminder? get first => upcoming.isEmpty ? null : upcoming.first;
}

/// What the plan is made from: only occurrences this device would actually
/// schedule a reminder for, and the choices that change what it shows.
class NextRemindersSource {
  const NextRemindersSource({
    required this.userId,
    required this.identity,
    required this.activeProfileIds,
    required this.occurrences,
    required this.preferences,
  });

  final String userId;
  final ProjectionIdentity? identity;

  /// People switched on for reminders on this device.
  final Set<String> activeProfileIds;
  final List<MedicationOccurrence> occurrences;
  final ReminderPreferences preferences;
}

/// Plans the next [limit] reminders from [source].
///
/// This is the reminder builder itself, run on the same data the reconciler
/// reads, so the list and the preview say what the device would schedule: the
/// 30-day horizon, per-schedule choices, people switched off on this device
/// and the privacy wording all apply. Nothing is scheduled or written.
NextRemindersPlan planNextReminders(
  NextRemindersSource source, {
  required DateTime now,
  required AppLocalizations localizations,
  int limit = 4,
}) {
  final batch = const ReminderProjectionBuilder().build(
    records: [
      for (final occurrence in source.occurrences)
        MedicationOccurrenceRecord(occurrence: occurrence, events: const []),
    ],
    activeProfileIds: source.activeProfileIds,
    userId: source.userId,
    // Only identifies the batch; nothing here is registered or scheduled.
    sessionGeneration: 1,
    now: now,
    platform: ReminderPlatformKind.android,
    localizations: localizations,
    identity: source.identity,
    preferences: source.preferences,
  );
  final byId = {
    for (final occurrence in source.occurrences) occurrence.id: occurrence,
  };
  final upcoming = <UpcomingReminder>[];
  var available = 0;
  for (final reminder in batch.reminders) {
    if (reminder.followUpMinutes != null) continue;
    available++;
    if (upcoming.length >= limit) continue;
    final occurrence = byId[reminder.occurrenceId];
    if (occurrence == null) continue;
    final ScheduleSnapshotV1 snapshot;
    try {
      snapshot = decodeScheduleSnapshot(
        jsonDecode(occurrence.scheduleSnapshotJson) as Map<String, dynamic>,
      );
    } on Object {
      continue;
    }
    final dosage = snapshot is LocalOccurrenceSnapshot
        ? snapshot.amount.isUnknown
              ? null
              : '${snapshot.amount.quantityText} ${snapshot.amount.unit}'
        : snapshot.dosage;
    upcoming.add(
      UpcomingReminder(
        occurrenceId: occurrence.id,
        pillName: snapshot.pillName,
        dosage: dosage,
        profileId: snapshot.profileId,
        profileName: snapshot.profileName,
        at: reminder.scheduledAtUtc.toLocal(),
        copy: ReminderCopy(title: reminder.title, body: reminder.body),
      ),
    );
  }
  return NextRemindersPlan(
    upcoming: upcoming,
    fullDetails: source.preferences.fullDetails,
    availableCount: available,
    peopleCount: source.activeProfileIds.length,
  );
}

/// Reads what the Reminders page needs. It mirrors the reconciler's own read
/// (the same eligibility rules) but never materialises, schedules or writes.
class NextRemindersRepository {
  const NextRemindersRepository({
    required this.database,
    required this.access,
    required this.context,
  });

  final AppDatabase database;
  final WorkspaceAccessRepository access;
  final WorkspaceContext context;

  Stream<NextRemindersSource> watch() => database
      .customSelect(
        // Drift shares identical SQL streams; keep this dependency set distinct.
        'SELECT 1 AS next_reminders_changes',
        readsFrom: {
          database.profiles,
          database.pills,
          database.schedules,
          database.medicationOccurrences,
          database.devicePersonReminders,
          database.deviceScheduleReminders,
          database.deviceReminderSettings,
          database.workspaceGrants,
        },
      )
      .watch()
      .asyncMap((_) => load());

  Future<NextRemindersSource> load() => access.withGrant(context, () async {
    final owner = context.ownerUserId;
    final profileRows = await database
        .customSelect(
          'SELECT p.* FROM profiles p JOIN device_person_reminders r ON r.profile_id=p.id WHERE p.user_id=? AND p.is_deleted=0 AND r.enabled=1',
          variables: [Variable<String>(owner)],
          readsFrom: {database.profiles, database.devicePersonReminders},
        )
        .get();
    final profiles = [
      for (final row in profileRows) database.profiles.map(row.data),
    ];
    final occurrenceRows = await database
        .customSelect(
          "SELECT * FROM medication_occurrences WHERE user_id=? AND source='scheduled' AND provenance='exact' AND state='pending' AND superseded_at IS NULL",
          variables: [Variable<String>(owner)],
          readsFrom: {database.medicationOccurrences},
        )
        .get();
    final pills = [
      for (final profile in profiles)
        ...await database.pillsDao.getByProfileId(profile.id),
    ];
    final pillsById = {
      for (final pill in pills)
        if (!pill.isPrn) pill.id: pill,
    };
    final schedulesById = {
      for (final schedule in await database.schedulesDao.getActiveSchedules())
        if (pillsById.containsKey(schedule.pillId)) schedule.id: schedule,
    };
    final preferences = await ReminderPreferencesRepository(
      database: database,
      access: access,
      context: context,
    ).load();
    final names = {for (final pill in pills) pill.id: pill.name};
    final eligible = <MedicationOccurrence>[];
    for (final row in occurrenceRows) {
      final occurrence = database.medicationOccurrences.map(row.data);
      if (!isEligibleReminderOccurrence(
        occurrence,
        pillsById: pillsById,
        schedulesById: schedulesById,
        ownerId: owner,
        workspaceId: context.workspaceId,
      )) {
        continue;
      }
      eligible.add(withCurrentName(occurrence, names));
    }
    return NextRemindersSource(
      userId: owner,
      identity: ProjectionIdentity.fromContext(context),
      activeProfileIds: {for (final profile in profiles) profile.id},
      occurrences: eligible,
      preferences: preferences,
    );
  });
}

/// What the next reminders are made from, kept current while the Reminders
/// page is open.
final nextRemindersSourceProvider =
    StreamProvider.autoDispose<NextRemindersSource>((ref) async* {
      final context = await ref.watch(workspaceContextProvider.future);
      yield* NextRemindersRepository(
        database: ref.watch(databaseProvider),
        access: ref.watch(workspaceAccessRepositoryProvider),
        context: context,
      ).watch();
    });
