import '../db/database.dart';
import 'legacy_split_identity.dart';

export 'legacy_split_identity.dart';

/// Ordered local receipts for the dose/inventory calls used by old servers.
class LegacySplitCheckpoint {
  const LegacySplitCheckpoint({required this.operation, required this.effects});

  final PendingOperation operation;
  final List<PendingOperationEffect> effects;

  bool get hasRetainedProgress => effects.any(
    (effect) =>
        effect.state != 'queued' &&
        !_isTerminalReviewMarker(effect.safeResultFingerprint),
  );

  bool get isReconciliationRecorded =>
      effects.isNotEmpty &&
      effects.every(
        (effect) =>
            effect.safeResultFingerprint?.startsWith(
              LegacySplitIdentity.recordedMarkerPrefix,
            ) ??
            false,
      );

  bool get isLocalReviewRequired =>
      effects.isNotEmpty &&
      effects.every(
        (effect) =>
            effect.safeResultFingerprint?.startsWith(
              'local-review-required:',
            ) ??
            false,
      );

  bool get hasUncertainEffect => effects.any(
    (effect) => effect.state == 'uncertain' || effect.state == 'sending',
  );

  bool get isComplete =>
      effects.isNotEmpty &&
      effects.every((effect) => effect.state == 'acknowledged');

  static bool _isTerminalReviewMarker(String? value) =>
      value?.startsWith(LegacySplitIdentity.recordedMarkerPrefix) == true ||
      value?.startsWith('local-review-required:') == true;

  /// Returns only the first non-acknowledged checkpoint, and only if it has
  /// never entered an uncertain state. Later effects cannot overtake it.
  PendingOperationEffect? get nextEffect {
    for (final effect in effects) {
      if (effect.state == 'acknowledged') continue;
      return effect.state == 'queued' ? effect : null;
    }
    return null;
  }

  static Future<LegacySplitCheckpoint?> load(
    AppDatabase db,
    String operationId,
  ) async {
    final operation = await db.pendingOperationsDao.getById(operationId);
    if (operation == null) return null;
    return LegacySplitCheckpoint(
      operation: operation,
      effects: await db.pendingOperationsDao.getEffects(operationId),
    );
  }
}
