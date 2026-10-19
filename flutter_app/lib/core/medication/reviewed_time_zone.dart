import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Setup presents this actual device identifier for review. Failure stays
/// unavailable; a time-zone abbreviation or guessed UTC cannot become a plan.
Future<String> readReviewedDeviceTimeZone({
  Future<String> Function()? readIdentifier,
}) async {
  if (tz.timeZoneDatabase.locations.isEmpty) {
    tzdata.initializeTimeZones();
  }
  final identifier =
      await (readIdentifier?.call() ??
          FlutterTimezone.getLocalTimezone().then((info) => info.identifier));
  tz.getLocation(identifier);
  return identifier;
}

final deviceTimeZoneProvider = FutureProvider<String>(
  (ref) => readReviewedDeviceTimeZone(),
);
