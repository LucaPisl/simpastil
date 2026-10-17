import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'app_motion.dart';

/// Opt-in gate for the only loop-like motion in the app (the halo breath).
///
/// Defaults to off: without an [AmbientMotion] ancestor, [AmbientMotion.of]
/// returns false, so widget tests never see ambient motion. Even when
/// enabled it reports false under reduced motion / accessible navigation,
/// while the app is not resumed, and inside a muted [TickerMode] (offstage
/// branches).
class AmbientMotion extends StatefulWidget {
  const AmbientMotion({
    super.key,
    required this.enabled,
    required this.child,
    this.overlayOpen,
  });

  final bool enabled;

  /// True while a dialog, sheet or page covers the app's screens. Ambient
  /// motion rests then, as it does when the app is backgrounded.
  final ValueListenable<bool>? overlayOpen;
  final Widget child;

  static bool of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_AmbientMotionScope>();
    if (scope == null || !scope.active) return false;
    return TickerMode.valuesOf(context).enabled && !AppMotion.quiet(context);
  }

  @override
  State<AmbientMotion> createState() => _AmbientMotionState();
}

class _AmbientMotionState extends State<AmbientMotion>
    with WidgetsBindingObserver {
  late AppLifecycleState _lifecycle =
      WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.overlayOpen?.addListener(_overlayChanged);
  }

  @override
  void didUpdateWidget(AmbientMotion old) {
    super.didUpdateWidget(old);
    if (old.overlayOpen != widget.overlayOpen) {
      old.overlayOpen?.removeListener(_overlayChanged);
      widget.overlayOpen?.addListener(_overlayChanged);
    }
  }

  @override
  void dispose() {
    widget.overlayOpen?.removeListener(_overlayChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _overlayChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == _lifecycle) return;
    setState(() => _lifecycle = state);
  }

  @override
  Widget build(BuildContext context) => _AmbientMotionScope(
    active:
        widget.enabled &&
        _lifecycle == AppLifecycleState.resumed &&
        !(widget.overlayOpen?.value ?? false),
    child: widget.child,
  );
}

class _AmbientMotionScope extends InheritedWidget {
  const _AmbientMotionScope({required this.active, required super.child});

  final bool active;

  @override
  bool updateShouldNotify(_AmbientMotionScope oldWidget) =>
      active != oldWidget.active;
}
