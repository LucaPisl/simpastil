import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'app_router.dart';

/// One-slot hook for an embedded screen with internal steps (first-run setup
/// inside Today). It runs when system Back reaches the shell, after every sheet,
/// dialog and pushed page has already closed. Returns true when it handled
/// Back.
final shellBackInterceptorProvider = StateProvider<bool Function()?>(
  (ref) => null,
);

/// True when this page is the only one in its navigator, which is how a page
/// opened with `go()` (notification, widget, sign-in flow) is reached. Back
/// there must not close the app.
bool isOnlyPage(BuildContext context) =>
    ModalRoute.of(context)?.isFirst ?? true;

/// Sends the person Today instead of out of the app.
void leaveToToday(BuildContext context) => context.go(AppPaths.home);

/// Wraps a root-level page so that Back falls back to Today when the page was
/// opened with `go()` and has nothing beneath it. When something is beneath,
/// Back is an ordinary pop. Pages with their own step-back or saving guards
/// apply the same rule through [isOnlyPage] and [leaveToToday] instead, so two
/// scopes never act on one Back.
class HomeFallbackPop extends StatelessWidget {
  const HomeFallbackPop({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !isOnlyPage(context),
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) leaveToToday(context);
    },
    child: child,
  );
}
