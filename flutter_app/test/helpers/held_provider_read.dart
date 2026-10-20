import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

/// Reads an async provider's first settled value from a bare container.
///
/// Riverpod 3 pauses a provider nobody listens to, and a paused stream or
/// database-backed provider never produces a value, so awaiting its `.future`
/// from a container without widgets can hang. This keeps a listener on the
/// provider until the container is disposed, as a mounted screen would.
extension HeldProviderRead on ProviderContainer {
  Future<T> readHeld<T>(ProviderListenable<AsyncValue<T>> provider) {
    final settled = Completer<T>();
    void settle(AsyncValue<T> value) {
      if (settled.isCompleted || value.isLoading) return;
      if (value.hasError) {
        settled.completeError(value.error!, value.stackTrace);
      } else {
        settled.complete(value.requireValue);
      }
    }

    listen<AsyncValue<T>>(
      provider,
      (_, next) => settle(next),
      fireImmediately: true,
    );
    return settled.future;
  }
}
