import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/auth_provider.dart';
import '../utils/app_logger.dart';
import 'protection_readiness.dart';

Future<void> restoreForegroundSession(ProviderContainer container) async {
  final readiness = await container.read(protectionReadinessProvider.future);
  // Let the existing recovery shell render without reopening refused care.
  if (!readiness.ready) return;
  await container.read(authNotifierProvider.notifier).restoreSession();
}

/// Startup skips the session while care is refused. When care opens later in
/// the same run (any "Try again"), readiness turns ready and the session that
/// startup skipped is restored then.
ProviderSubscription<AsyncValue<ProtectionReadiness>>
restoreSessionWhenCareRecovers(ProviderContainer container) {
  var refused = false;
  return container.listen(protectionReadinessProvider, (previous, next) {
    final readiness = next.valueOrNull;
    if (readiness == null) return;
    if (!readiness.ready) {
      refused = true;
    } else if (refused) {
      refused = false;
      unawaited(
        container
            .read(authNotifierProvider.notifier)
            .restoreSession()
            .catchError((Object error) {
              AppLogger.warning(
                'Startup',
                'Session restoration deferred: ${error.runtimeType}',
              );
            }),
      );
    }
  }, fireImmediately: true);
}
