import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/projections/reminder_eligibility.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;

import '../../helpers/care_recording_fixture.dart';

/// The rule both the reconciler and the Reminders page use to decide whether a
/// pending dose still belongs to a live routine.
void main() {
  setUpAll(tz_data.initializeTimeZones);

  late CareRecordingFixture f;
  late Schedule schedule;
  late String owner;
  late String workspace;

  setUp(() async {
    f = await CareRecordingFixture.create();
    schedule = (await f.db.schedulesDao.getActiveSchedules()).single;
    owner = f.workspace.context.ownerUserId;
    workspace = f.workspace.context.workspaceId;
  });
  tearDown(() => f.db.close());

  bool eligible({
    MedicationOccurrence? occurrence,
    Pill? pill,
    Schedule? routine,
    bool pillListed = true,
    bool scheduleListed = true,
    String? ownerId,
    String? workspaceId,
  }) => isEligibleReminderOccurrence(
    occurrence ?? f.occurrence,
    pillsById: pillListed ? {f.pill.id: pill ?? f.pill} : const {},
    schedulesById: scheduleListed
        ? {schedule.id: routine ?? schedule}
        : const {},
    ownerId: ownerId ?? owner,
    workspaceId: workspaceId ?? workspace,
  );

  test('a live routine dose is eligible', () {
    expect(eligible(), isTrue);
    // The workspace is optional, as it is when a snapshot is checked alone.
    expect(
      isEligibleReminderOccurrence(
        f.occurrence,
        pillsById: {f.pill.id: f.pill},
        schedulesById: {schedule.id: schedule},
        ownerId: owner,
      ),
      isTrue,
    );
  });

  test('a medication or routine that is no longer active is not', () {
    expect(eligible(pillListed: false), isFalse);
    expect(eligible(scheduleListed: false), isFalse);
  });

  test('a routine that belongs to another medication is not', () {
    expect(eligible(routine: schedule.copyWith(pillId: 'another')), isFalse);
  });

  test('a snapshot of another owner or workspace is not', () {
    expect(eligible(ownerId: 'someone-else'), isFalse);
    expect(eligible(workspaceId: 'another-workspace'), isFalse);
  });

  test('a medication that moved to another person is not', () {
    expect(eligible(pill: f.pill.copyWith(profileId: 'another')), isFalse);
  });

  test('a dose frozen in another time zone is not', () {
    expect(
      eligible(
        occurrence: f.occurrence.copyWith(timeZone: 'Pacific/Kiritimati'),
      ),
      isFalse,
    );
  });

  test('a snapshot that cannot be read is not', () {
    expect(
      eligible(occurrence: f.occurrence.copyWith(scheduleSnapshotJson: '[]')),
      isFalse,
    );
    expect(
      eligible(occurrence: f.occurrence.copyWith(scheduleSnapshotJson: '{')),
      isFalse,
    );
  });
}
