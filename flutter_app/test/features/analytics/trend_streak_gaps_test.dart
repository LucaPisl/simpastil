import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/medication_command.dart';
import 'package:simpastil/core/medication/medication_repository.dart';
import 'package:simpastil/core/utils/app_clock.dart';
import 'package:simpastil/features/analytics/analytics_providers.dart';
import 'package:simpastil/features/analytics/trend_stats.dart';
import 'package:simpastil/features/profiles/profile_provider.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../helpers/care_recording_fixture.dart';
import '../../helpers/held_provider_read.dart';

/// A local routine writes its occurrence rows when a day is looked at or a
/// reminder is prepared. After weeks without either, the doses that fell due
/// in between have no row at all, so the dose history alone cannot see them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  Future<TrendStats> trend(
    CareRecordingFixture f, {
    required DateTime now,
    bool takeFirstDay = true,
  }) async {
    if (takeFirstDay) {
      await MedicationRepository(
        f.db,
        access: f.workspace.access,
        context: f.workspace.context,
      ).apply(
        userId: f.workspace.context.ownerUserId,
        occurrenceId: f.occurrence.id,
        action: MedicationAction.take,
        actualTimeKnown: true,
        actualAt: DateTime.utc(2026, 9, 30, 9, 15),
      );
    }
    final c = await f.workspace.createContainer(
      extraOverrides: [appClockProvider.overrideWithValue(() => now)],
    );
    addTearDown(c.dispose);
    // The people in view arrive from a stream; the streak reads them once.
    c.listen(profileListProvider, (_, _) {});
    await c.readHeld(profileListProvider);
    final sub = c.listen(trendStatsProvider, (_, _) {});
    addTearDown(sub.close);
    return c.readHeld(trendStatsProvider);
  }

  test('days the routine owed a dose with no row end the streak', () async {
    final f = await CareRecordingFixture.create();
    addTearDown(f.db.close);
    // The routine began on 30 September and only that day was ever written.
    // Two weeks on, 1 to 15 October fell due and were never recorded.
    final stats = await trend(f, now: DateTime.utc(2026, 10, 16, 12));
    expect(stats.hasScheduledDoses, isTrue);
    expect(stats.streak, (current: 0, best: 1));
  });

  test('the streak is whole while the rows keep up', () async {
    final f = await CareRecordingFixture.create();
    addTearDown(f.db.close);
    // The morning after, nothing has yet fallen due that has no row.
    final stats = await trend(f, now: DateTime.utc(2026, 10, 1, 8));
    expect(stats.streak, (current: 1, best: 1));
  });
}
