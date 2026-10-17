import '../db/database.dart';

/// The routine and medicine a timezone review would repair.
class ScheduleReviewTarget {
  const ScheduleReviewTarget({required this.schedule, required this.pill});
  final Schedule schedule;
  final Pill pill;
}

/// Resolves the routine a schedule review can actually act on, or null when
/// this device cannot reach it. Read-only: no issue, routine or evidence row
/// is changed.
///
/// Both the Sync list and the repair sheet ask this one question, so a review
/// can never be offered as something to open and then refuse to open.
Future<ScheduleReviewTarget?> scheduleReviewTarget(
  AppDatabase db,
  String entityId,
  String userId,
) async {
  final schedule = await db.schedulesDao.getByMappedOrLocalId(entityId);
  if (schedule == null) return null;
  final pill = await db.pillsDao.getById(schedule.pillId);
  if (pill == null) return null;
  final profile = await db.profilesDao.getById(pill.profileId);
  if (profile == null || profile.userId != userId) return null;
  return ScheduleReviewTarget(schedule: schedule, pill: pill);
}
