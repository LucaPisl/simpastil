import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../medication/routine_definition.dart' show routineDateKey;

/// The device clock that calendar-day reads use: what is coming up, the week
/// strip, the stock forecast, the History windows. Tests override it to pin or
/// move the day; the app never does.
///
/// This is separate from the scene clock, which only drives the sky and can be
/// pinned to a time of day for screenshots.
final appClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Today's local date as `yyyy-MM-dd`.
///
/// It starts from [appClockProvider] and moves on when `TodayRollover`, which
/// the app keeps mounted above every screen, sees local midnight pass or the
/// app return to the foreground. A read that is keyed to the day, or that
/// anchors a window on it, watches this so a screen left open overnight turns
/// to the new day instead of carrying on with yesterday.
final todayProvider = StateProvider<String>(
  (ref) => routineDateKey(ref.watch(appClockProvider)()),
);
