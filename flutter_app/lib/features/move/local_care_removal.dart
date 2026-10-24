import 'package:drift/drift.dart';

import '../../core/db/database.dart';

/// Removes moved people from this phone's local care, with everything that
/// belongs to them: medications, routines, doses, their history and stock.
///
/// It runs only after a Move has been checked against the account, and only
/// when the person asks for it. The local workspace, its user and anyone not
/// in [profileIds] stay. Deleting is ordered so it never leans on cascades.
Future<void> removeLocalCare(
  AppDatabase database, {
  required String localWorkspaceId,
  required String localOwnerId,
  required Set<String> profileIds,
}) async {
  if (profileIds.isEmpty) return;
  await database.transaction(() async {
    final profiles =
        await (database.select(database.profiles)..where(
              (p) => p.userId.equals(localOwnerId) & p.id.isIn(profileIds),
            ))
            .get();
    final ownedProfiles = {for (final p in profiles) p.id};
    if (ownedProfiles.isEmpty) return;
    final pills = await (database.select(
      database.pills,
    )..where((p) => p.profileId.isIn(ownedProfiles))).get();
    final pillIds = {for (final p in pills) p.id};
    final schedules = pillIds.isEmpty
        ? const <Schedule>[]
        : await (database.select(
            database.schedules,
          )..where((s) => s.pillId.isIn(pillIds))).get();
    final scheduleIds = {for (final s in schedules) s.id};
    final occurrences = pillIds.isEmpty
        ? const <MedicationOccurrence>[]
        : await (database.select(database.medicationOccurrences)..where(
                (o) => o.userId.equals(localOwnerId) & o.pillId.isIn(pillIds),
              ))
              .get();
    final occurrenceIds = {for (final o in occurrences) o.id};
    final events = occurrenceIds.isEmpty
        ? const <OccurrenceEvent>[]
        : await (database.select(
            database.occurrenceEvents,
          )..where((e) => e.occurrenceId.isIn(occurrenceIds))).get();
    final eventIds = {for (final e in events) e.id};

    if (eventIds.isNotEmpty) {
      await (database.delete(database.careEventDetails)..where(
            (d) =>
                d.workspaceId.equals(localWorkspaceId) &
                d.eventId.isIn(eventIds),
          ))
          .go();
    }
    if (pillIds.isNotEmpty) {
      await (database.delete(database.inventoryEvents)..where(
            (i) => i.userId.equals(localOwnerId) & i.pillId.isIn(pillIds),
          ))
          .go();
    }
    if (eventIds.isNotEmpty) {
      await (database.delete(
        database.occurrenceEvents,
      )..where((e) => e.id.isIn(eventIds))).go();
    }
    if (occurrenceIds.isNotEmpty) {
      await (database.delete(
        database.medicationOccurrences,
      )..where((o) => o.id.isIn(occurrenceIds))).go();
    }
    if (pillIds.isNotEmpty) {
      await (database.delete(database.reviewedStockBalances)..where(
            (b) =>
                b.workspaceId.equals(localWorkspaceId) & b.pillId.isIn(pillIds),
          ))
          .go();
      await (database.delete(database.localRoutines)..where(
            (r) =>
                r.workspaceId.equals(localWorkspaceId) & r.pillId.isIn(pillIds),
          ))
          .go();
      await (database.delete(
        database.medicationDetails,
      )..where((d) => d.pillId.isIn(pillIds))).go();
    }
    await (database.delete(database.setupDrafts)..where(
          (d) =>
              d.workspaceId.equals(localWorkspaceId) &
              (d.profileId.isIn(ownedProfiles) |
                  (pillIds.isEmpty
                      ? const Constant(false)
                      : d.medicationId.isIn(pillIds))),
        ))
        .go();
    if (scheduleIds.isNotEmpty) {
      await (database.delete(
        database.deviceScheduleReminders,
      )..where((r) => r.scheduleId.isIn(scheduleIds))).go();
      await (database.delete(
        database.doseLogs,
      )..where((l) => l.scheduleId.isIn(scheduleIds))).go();
      await (database.delete(
        database.schedules,
      )..where((s) => s.id.isIn(scheduleIds))).go();
    }
    await (database.delete(
      database.devicePersonReminders,
    )..where((r) => r.profileId.isIn(ownedProfiles))).go();
    await (database.delete(
      database.personFirstSeen,
    )..where((r) => r.profileId.isIn(ownedProfiles))).go();
    await (database.delete(
      database.workspaceSyncCheckpoints,
    )..where((r) => r.profileId.isIn(ownedProfiles))).go();
    if (pillIds.isNotEmpty) {
      await (database.delete(
        database.pills,
      )..where((p) => p.id.isIn(pillIds))).go();
    }
    await (database.delete(
      database.profiles,
    )..where((p) => p.id.isIn(ownedProfiles))).go();
    await (database.update(database.careWorkspaces)..where(
          (w) =>
              w.id.equals(localWorkspaceId) &
              w.selectedProfileId.isIn(ownedProfiles),
        ))
        .write(const CareWorkspacesCompanion(selectedProfileId: Value(null)));
  });
}
