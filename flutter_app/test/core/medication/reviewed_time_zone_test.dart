import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/reviewed_time_zone.dart';
import 'package:timezone/data/latest.dart' as tzdata;
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
}
