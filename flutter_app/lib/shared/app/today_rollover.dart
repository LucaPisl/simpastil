import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/medication/routine_definition.dart' show routineDateKey;
import '../../core/utils/app_clock.dart';

/// Keeps [todayProvider] on the device's calendar day: it moves it on just
/// after local midnight, and again when the app returns to the foreground,
/// because a timer does not run while the phone sleeps.
///
/// A widget rather than a provider-owned timer, so the timer lives and dies
/// with the tree it serves. It adds no layout.
class TodayRollover extends ConsumerStatefulWidget {
  const TodayRollover({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<TodayRollover> createState() => _TodayRolloverState();
}

class _TodayRolloverState extends ConsumerState<TodayRollover>
    with WidgetsBindingObserver {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _arm();
  }

  /// Sets the day from the clock, if it has changed.
  void _sync() {
    final key = routineDateKey(ref.read(appClockProvider)());
    if (ref.read(todayProvider) != key) {
      ref.read(todayProvider.notifier).state = key;
    }
  }

  /// Waits for the next midnight. The extra second keeps the wake clear of
  /// the boundary itself.
  void _arm() {
    _timer?.cancel();
    final now = ref.read(appClockProvider)();
    final nextMidnight = DateTime(now.year, now.month, now.day + 1);
    _timer = Timer(
      nextMidnight.difference(now) + const Duration(seconds: 1),
      () {
        if (!mounted) return;
        _sync();
        _arm();
      },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted) return;
    _sync();
    _arm();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
