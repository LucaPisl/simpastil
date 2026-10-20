import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/doses/slot_engine.dart';
import '../../core/medication/routine_definition.dart'
    show parseRoutineDate, routineDateKey;
import '../../core/utils/app_clock.dart';

// Compatibility re-export: existing consumers import dateOnly from here.
// Remove once they import the slot engine directly.
export '../../core/doses/slot_engine.dart' show dateOnly;

/// Which calendar day the dashboard is showing. Always date-floored.
///
/// Day stepping uses the DateTime constructor (`day - 1` / `day + 1`)
/// rather than Duration arithmetic so midnight stays midnight across DST
/// transitions. Not persisted: app restart and notification taps land on
/// today.
///
/// A screen left open on today follows the calendar: when [todayProvider]
/// moves to a new day (local midnight, or the app returning to the foreground),
/// a selection that was on the old today moves with it. A deliberately chosen
/// earlier day stays where it is.
class SelectedDateNotifier extends Notifier<DateTime> {
  DateTime _now() => ref.read(appClockProvider)();

  @override
  DateTime build() {
    ref.listen<String>(todayProvider, (previous, next) {
      if (previous != null && routineDateKey(state) == previous) {
        // The key's date, as a local midnight like every other selection.
        final day = parseRoutineDate(next);
        state = DateTime(day.year, day.month, day.day);
      }
    });
    return dateOnly(_now());
  }

  /// Moves back one calendar day. Unlimited.
  void previousDay() =>
      state = DateTime(state.year, state.month, state.day - 1);

  /// Moves forward one calendar day, never past today.
  ///
  /// "Today" is evaluated at call time, not at [build] time, so the guard
  /// stays correct if the app sits open across midnight.
  void nextDay() {
    final next = DateTime(state.year, state.month, state.day + 1);
    if (next.isAfter(dateOnly(_now()))) return;
    state = next;
  }

  /// Jumps to [d] (floored), clamped to today.
  void select(DateTime d) {
    final today = dateOnly(_now());
    final floored = dateOnly(d);
    state = floored.isAfter(today) ? today : floored;
  }

  /// Returns to today.
  void backToToday() => state = dateOnly(_now());
}

final selectedDateProvider = NotifierProvider<SelectedDateNotifier, DateTime>(
  SelectedDateNotifier.new,
);
