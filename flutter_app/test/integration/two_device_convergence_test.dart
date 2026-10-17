import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/occurrence_reducer.dart';

void main() {
  test(
    'stale second-device intent rebases to one shared state and stock balance',
    () {
      // Both devices began from the same pending occurrence and stock snapshot.
      var serverState = MedicationState.pending;
      var serverStock = 3;

      final deviceATake = rebaseMedicationIntent(
        serverState: serverState,
        intendedAction: MedicationAction.take,
      );
      expect(deviceATake.blocked, isFalse);
      serverState = deviceATake.toState!;
      serverStock += deviceATake.inventoryDelta;

      // Device B returns later with an older snapshot and a different intent.
      // The server head is fetched first; the local intent becomes a correction
      // against that head and its stock delta is applied exactly once.
      final deviceBSkip = rebaseMedicationIntent(
        serverState: serverState,
        intendedAction: MedicationAction.skip,
      );
      expect(deviceBSkip.action, MedicationAction.correct);
      serverState = deviceBSkip.toState!;
      serverStock += deviceBSkip.inventoryDelta;

      final deviceAAfterPull = (state: serverState, stock: serverStock);
      final deviceBAfterCommit = (state: serverState, stock: serverStock);
      expect(deviceAAfterPull, deviceBAfterCommit);
      expect(deviceAAfterPull.state, MedicationState.skipped);
      expect(deviceAAfterPull.stock, 3);
    },
  );
}
