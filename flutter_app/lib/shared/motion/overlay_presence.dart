import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Whether a dialog, bottom sheet or menu is open above the app's screens.
///
/// Today lives in a nested shell navigator, so `ModalRoute.isCurrentOf` stays
/// true there while a dialog or bottom sheet sits on the root navigator. This
/// observer is attached to the root navigator and tells ambient motion to rest
/// while anything is on top, so nothing drifts or breathes behind it.
class OverlayPresenceObserver extends NavigatorObserver {
  OverlayPresenceObserver();

  final ValueNotifier<bool> _open = ValueNotifier(false);
  final Set<Route<dynamic>> _above = {};

  /// True while any popup route (dialog, sheet, menu) is open.
  ValueListenable<bool> get open => _open;

  void _update() => _open.value = _above.isNotEmpty;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // Pages replace each other as the user navigates; only popups sit over a
    // screen that is still current.
    if (route is PopupRoute) _above.add(route);
    _update();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _above.remove(route);
    _update();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _above.remove(route);
    _update();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final wasAbove = oldRoute != null && _above.remove(oldRoute);
    if (newRoute is PopupRoute && wasAbove) _above.add(newRoute);
    _update();
  }

  void dispose() => _open.dispose();
}
