import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/occurrence_reducer.dart';

void main() {
  group('bridge rollout rebase', () {
    test('adopts a lost-response take without applying inventory twice', () {
      final reconciled = rebaseMedicationIntent(
        serverState: MedicationState.taken,
        intendedAction: MedicationAction.take,
      );

      expect(reconciled.blocked, isFalse);
      expect(reconciled.toState, MedicationState.taken);
      expect(reconciled.inventoryDelta, 0);
    });

    test('blocks a correction when the acknowledged event head changed', () {
      final reconciled = rebaseMedicationIntent(
        serverState: MedicationState.taken,
        intendedAction: MedicationAction.undo,
        intendedState: MedicationState.pending,
        reversesEventId: 'old-head',
        headEventId: 'new-head',
      );

      expect(reconciled.blocked, isTrue);
      expect(reconciled.reason, 'event_head_changed');
    });

    test(
      'blocks missing or mismatched occurrence identity rather than guessing',
      () {
        final missing = rebaseMedicationIntent(
          serverState: null,
          intendedAction: MedicationAction.take,
        );
        final mismatched = rebaseMedicationIntent(
          serverState: MedicationState.pending,
          intendedAction: MedicationAction.take,
          identityMatches: false,
        );

        expect(missing.blocked, isTrue);
        expect(missing.reason, 'occurrence_missing');
        expect(mismatched.blocked, isTrue);
        expect(mismatched.reason, 'occurrence_identity_mismatch');
      },
    );
  });
}
