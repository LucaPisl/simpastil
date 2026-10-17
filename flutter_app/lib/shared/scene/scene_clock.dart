import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _sceneTimeDefine = String.fromEnvironment('SIMPASTIL_SCENE_TIME');

/// Parses "HH:MM" into today's date at that time; null when malformed.
DateTime? parseSceneTime(String value, DateTime base) {
  final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(value.trim());
  if (match == null) return null;
  final h = int.parse(match.group(1)!), m = int.parse(match.group(2)!);
  if (h > 23 || m > 59) return null;
  return DateTime(base.year, base.month, base.day, h, m);
}

/// The clock the sky follows. Override in tests or with
/// `--dart-define=SIMPASTIL_SCENE_TIME=HH:MM`.
final sceneClockProvider = Provider<DateTime Function()>((ref) {
  return () {
    final real = DateTime.now();
    if (_sceneTimeDefine.isEmpty) return real;
    return parseSceneTime(_sceneTimeDefine, real) ?? real;
  };
});

/// Rebuilds [builder] once per minute, aligned to the minute boundary. The
/// timer is cancelled while the app is not resumed or the subtree is offstage
/// ([TickerMode] false), and the sky catches up on the next resume.
class SceneClock extends ConsumerStatefulWidget {
  const SceneClock({super.key, required this.builder});

  final Widget Function(BuildContext context, DateTime now) builder;

  @override
  ConsumerState<SceneClock> createState() => _SceneClockState();
}

class _SceneClockState extends ConsumerState<SceneClock>
    with WidgetsBindingObserver {
  Timer? _timer;
  late DateTime _now;
  bool _resumed = true;
  bool _active = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resumed =
        (WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed) ==
        AppLifecycleState.resumed;
    _now = ref.read(sceneClockProvider)();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _active = TickerMode.valuesOf(context).enabled;
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    _sync();
  }

  void _sync() {
    _timer?.cancel();
    _timer = null;
    if (!_resumed || !_active) return;
    final fresh = ref.read(sceneClockProvider)();
    if (!_sameMinute(fresh, _now)) {
      // Catching up must not happen inside a build phase.
      _now = fresh;
      if (mounted && context.mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() {});
        });
      }
    }
    final wait = Duration(
      milliseconds: 60000 - (fresh.second * 1000 + fresh.millisecond) + 20,
    );
    _timer = Timer(wait, _tick);
  }

  void _tick() {
    if (!mounted) return;
    setState(() => _now = ref.read(sceneClockProvider)());
    _sync();
  }

  static bool _sameMinute(DateTime a, DateTime b) =>
      a.year == b.year &&
      a.month == b.month &&
      a.day == b.day &&
      a.hour == b.hour &&
      a.minute == b.minute;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _now);
}
