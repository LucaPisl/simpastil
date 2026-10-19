import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/reviewed_time_zone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

void main() {
  setUpAll(tzdata.initializeTimeZones);
  test(
    'reviewed device zone is a valid identifier and does not reset alert zone',
    () async {
      tz.setLocalLocation(tz.getLocation('Europe/Bucharest'));
      expect(
        await readReviewedDeviceTimeZone(
          readIdentifier: () async => 'America/New_York',
        ),
        'America/New_York',
      );
      expect(tz.local.name, 'Europe/Bucharest');
      await expectLater(
        readReviewedDeviceTimeZone(
          readIdentifier: () async => 'Fictional/Unrecognized',
        ),
        throwsA(isA<Exception>()),
      );
      expect(tz.local.name, 'Europe/Bucharest');
    },
  );

  test('a device that reports a legacy zone id still resolves it', () async {
    // timezone 0.11 narrowed the "common" database to canonical names. The
    // review reads the device's own identifier, which Android may still report
    // as a legacy alias, so the full database has to be what gets loaded.
    tz.timeZoneDatabase.locations.clear();
    for (final identifier in ['Asia/Calcutta', 'Europe/Kiev', 'UTC']) {
      expect(
        await readReviewedDeviceTimeZone(
          readIdentifier: () async => identifier,
        ),
        identifier,
      );
      tz.timeZoneDatabase.locations.clear();
    }
    tzdata.initializeTimeZones();
  });
}
