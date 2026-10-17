import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/doses/slot_engine.dart';

// Compatibility re-export: existing consumers import dateOnly from here.
// Remove once they import the slot engine directly.
export '../../core/doses/slot_engine.dart' show dateOnly;

/// Which calendar day the dashboard is showing. Always date-floored.
///
/// Day stepping uses the DateTime constructor (`day - 1` / `day + 1`)
/// rather than Duration arithmetic so midnight stays midnight across DST
/// transitions. Not persisted: app restart and notification taps land on
/// today.
class SelectedDateNotifier extends Notifier<DateTime> {
  @override
  DateTime build() => dateOnly(DateTime.now());

  /// Moves back one calendar day. Unlimited.
  void previousDay() =>
      state = DateTime(state.year, state.month, state.day - 1);

  /// Moves forward one calendar day, never past today.
  ///
  /// "Today" is evaluated at call time, not at [build] time, so the guard
  /// stays correct if the app sits open across midnight.
  void nextDay() {
    final next = DateTime(state.year, state.month, state.day + 1);
    if (next.isAfter(dateOnly(DateTime.now()))) return;
    state = next;
  }

  /// Jumps to [d] (floored), clamped to today.
  void select(DateTime d) {
    final today = dateOnly(DateTime.now());
    final floored = dateOnly(d);
    state = floored.isAfter(today) ? today : floored;
  }

  /// Returns to today.
  void backToToday() => state = dateOnly(DateTime.now());
}

final selectedDateProvider = NotifierProvider<SelectedDateNotifier, DateTime>(
  SelectedDateNotifier.new,
);
