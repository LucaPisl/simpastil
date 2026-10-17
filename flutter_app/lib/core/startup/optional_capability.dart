import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';

enum OptionalCapabilityPhase { initializing, ready, degraded }

class OptionalCapabilityStatus {
  const OptionalCapabilityStatus({
    required this.id,
    required this.label,
    required this.phase,
    this.failureType,
  });

  final String id;
  final String label;
  final OptionalCapabilityPhase phase;
  final String? failureType;
}

class OptionalCapabilityState {
  const OptionalCapabilityState([this.capabilities = const {}]);

  final Map<String, OptionalCapabilityStatus> capabilities;

  List<OptionalCapabilityStatus> get degraded => capabilities.values
      .where((status) => status.phase == OptionalCapabilityPhase.degraded)
      .toList(growable: false);

  bool isReady(String id) =>
      capabilities[id]?.phase == OptionalCapabilityPhase.ready;

  OptionalCapabilityState withStatus(OptionalCapabilityStatus status) {
    return OptionalCapabilityState(
      Map.unmodifiable({...capabilities, status.id: status}),
    );
  }
}

typedef OptionalCapabilityOperation = Future<void> Function();

class OptionalCapabilityNotifier extends Notifier<OptionalCapabilityState> {
  final Map<String, ({String label, OptionalCapabilityOperation operation})>
  _operations = {};
  final Map<String, _PendingCapability> _inFlight = {};
  bool _disposed = false;

  @override
  OptionalCapabilityState build() {
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
      _inFlight.clear();
      _operations.clear();
    });
    return const OptionalCapabilityState();
  }

  Future<void> initialize({
    required String id,
    required String label,
    required OptionalCapabilityOperation operation,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    _operations[id] = (label: label, operation: operation);
    var attempt = _inFlight[id];
    final shouldStart = attempt == null;
    if (attempt == null) {
      attempt = _PendingCapability(label: label, operation: operation);
      // Publish the slot before invoking user code so synchronous failures and
      // reentrant initialize/retry calls join the same operation.
      _inFlight[id] = attempt;
    } else {
      attempt.label = label;
    }

    if (!_disposed) {
      state = state.withStatus(
        OptionalCapabilityStatus(
          id: id,
          label: label,
          phase: OptionalCapabilityPhase.initializing,
        ),
      );
    }
    if (shouldStart) unawaited(_runOperation(id, attempt));

    try {
      await attempt.settled.future.timeout(timeout);
    } on TimeoutException catch (error) {
      // A caller's deadline only changes the visible state. The operation
      // continues, and its completion can still recover the capability.
      if (!_disposed &&
          identical(_inFlight[id], attempt) &&
          !attempt.isSettled) {
        state = state.withStatus(
          OptionalCapabilityStatus(
            id: id,
            label: attempt.label,
            phase: OptionalCapabilityPhase.degraded,
            failureType: error.runtimeType.toString(),
          ),
        );
      }
    }
  }

  Future<void> _runOperation(String id, _PendingCapability attempt) async {
    var succeeded = false;
    String? failureType;
    try {
      await Future<void>.sync(attempt.operation);
      succeeded = true;
    } catch (error) {
      // Consume late failures too: the caller may already have timed out.
      failureType = error.runtimeType.toString();
    }

    try {
      if (!_disposed && identical(_inFlight[id], attempt)) {
        attempt.isSettled = true;
        _inFlight.remove(id);
        state = state.withStatus(
          OptionalCapabilityStatus(
            id: id,
            label: attempt.label,
            phase: succeeded
                ? OptionalCapabilityPhase.ready
                : OptionalCapabilityPhase.degraded,
            failureType: failureType,
          ),
        );
      }
    } finally {
      attempt.isSettled = true;
      if (!attempt.settled.isCompleted) attempt.settled.complete();
    }
  }

  Future<void> retry(String id) async {
    final operation = _operations[id];
    if (operation == null) return;
    await initialize(
      id: id,
      label: operation.label,
      operation: operation.operation,
    );
  }
}

class _PendingCapability {
  _PendingCapability({required this.label, required this.operation});

  String label;
  final OptionalCapabilityOperation operation;
  final Completer<void> settled = Completer<void>();
  bool isSettled = false;
}

final optionalCapabilityProvider =
    NotifierProvider<OptionalCapabilityNotifier, OptionalCapabilityState>(
      OptionalCapabilityNotifier.new,
    );

class OptionalCapabilityBanner extends ConsumerWidget {
  const OptionalCapabilityBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final degraded = ref.watch(optionalCapabilityProvider).degraded;
    if (degraded.isEmpty) return const SizedBox.shrink();
    final notifier = ref.read(optionalCapabilityProvider.notifier);

    return Material(
      color: Theme.of(context).colorScheme.errorContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            children: [
              for (final capability in degraded)
                Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded),
                    const SizedBox(width: 12),
                    Expanded(child: Text(capability.label)),
                    TextButton(
                      onPressed: () => unawaited(notifier.retry(capability.id)),
                      child: Text(AppLocalizations.of(context).shared_retry),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
