import 'medication_command.dart';

export 'medication_command.dart' show MedicationAction, MedicationState;

class MedicationRebaseResult {
  const MedicationRebaseResult._({
    required this.blocked,
    required this.action,
    required this.toState,
    required this.inventoryDelta,
    this.reason,
  });

  const MedicationRebaseResult.blocked(String reason)
    : this._(
        blocked: true,
        action: null,
        toState: null,
        inventoryDelta: 0,
        reason: reason,
      );

  const MedicationRebaseResult.applied({
    required MedicationAction action,
    required MedicationState toState,
    required int inventoryDelta,
  }) : this._(
         blocked: false,
         action: action,
         toState: toState,
         inventoryDelta: inventoryDelta,
       );

  final bool blocked;
  final MedicationAction? action;
  final MedicationState? toState;
  final int inventoryDelta;
  final String? reason;
}

/// Re-expresses immutable local intent against a fetched, exact server head.
MedicationRebaseResult rebaseMedicationIntent({
  required MedicationState? serverState,
  required MedicationAction intendedAction,
  MedicationState? intendedState,
  String? reversesEventId,
  String? headEventId,
  bool isSuperseded = false,
  bool identityMatches = true,
}) {
  if (serverState == null) {
    return const MedicationRebaseResult.blocked('occurrence_missing');
  }
  if (isSuperseded) {
    return const MedicationRebaseResult.blocked('occurrence_superseded');
  }
  if (!identityMatches) {
    return const MedicationRebaseResult.blocked('occurrence_identity_mismatch');
  }

  if (intendedAction == MedicationAction.miss) {
    // A miss is only ever recorded against a pending occurrence. If another
    // device already moved it, the automatic command is dropped, not rebased.
    return serverState == MedicationState.pending
        ? const MedicationRebaseResult.applied(
            action: MedicationAction.miss,
            toState: MedicationState.missed,
            inventoryDelta: 0,
          )
        : const MedicationRebaseResult.blocked('miss_not_pending');
  }

  if (intendedAction == MedicationAction.take ||
      intendedAction == MedicationAction.skip) {
    final target = intendedAction == MedicationAction.take
        ? MedicationState.taken
        : MedicationState.skipped;
    final action = serverState == MedicationState.pending
        ? intendedAction
        : MedicationAction.correct;
    return MedicationRebaseResult.applied(
      action: action,
      toState: target,
      inventoryDelta: _stockDelta(serverState, target),
    );
  }

  if (intendedState == null) {
    return const MedicationRebaseResult.blocked('target_state_missing');
  }
  if (intendedAction == MedicationAction.correct &&
      intendedState == MedicationState.missed) {
    return const MedicationRebaseResult.blocked('correct_to_missed');
  }
  if (reversesEventId == null ||
      headEventId == null ||
      reversesEventId != headEventId) {
    return const MedicationRebaseResult.blocked('event_head_changed');
  }
  return MedicationRebaseResult.applied(
    action: intendedAction,
    toState: intendedState,
    inventoryDelta: _stockDelta(serverState, intendedState),
  );
}

int _stockDelta(MedicationState from, MedicationState to) {
  final wasTaken = from == MedicationState.taken;
  final willBeTaken = to == MedicationState.taken;
  if (wasTaken == willBeTaken) return 0;
  return willBeTaken ? -1 : 1;
}
