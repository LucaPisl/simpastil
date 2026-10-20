import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'workspace_provider.dart';

/// Keeps the connection scope awake for as long as the app is mounted.
///
/// Riverpod 3 pauses a provider nothing listens to, and a paused stream
/// provider stops following the database. The API clients are built from the
/// device state it carries, so asleep it keeps the state from before a
/// sign-in or sign-out and the next client has no session: Verify key refuses,
/// the device name cannot be saved and the first sync never starts. This sits
/// above the lock and every page, so it never pauses.
class ConnectionScopeKeeper extends ConsumerWidget {
  const ConnectionScopeKeeper({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(connectionDeviceStateProvider, (_, _) {}, onError: (_, _) {});
    ref.listen(networkCapabilityProvider, (_, _) {}, onError: (_, _) {});
    return child;
  }
}
