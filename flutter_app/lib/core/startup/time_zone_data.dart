import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Headless care readers need the saved named zones before decoding routines.
/// A warm foreground engine keeps its already detected local location.
void ensureTimeZoneData() {
  if (!tz.timeZoneDatabase.isInitialized) tzdata.initializeTimeZones();
}
