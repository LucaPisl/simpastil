import 'package:uuid/uuid.dart';

/// Occurrence states the ledger can hold. `missed` is recorded by the
/// automatic miss command (or pulled from another device): a due dose the
/// owner never marked, written to history once its grace window passed.
enum MedicationState { pending, taken, skipped, missed }

/// Ledger actions. `miss` moves one pending occurrence to `missed` with no
/// stock effect; a missed dose can later become taken (late) or skipped, and
/// every transition can be undone.
enum MedicationAction { take, skip, miss, undo, correct }

/// Immutable user intent for one exact occurrence.
class MedicationCommand {
  const MedicationCommand({
    required this.commandId,
    required this.userId,
    required this.occurrenceId,
    required this.occurrenceKey,
    required this.action,
    required this.baseVersion,
    required this.actualTimeKnown,
    this.targetState,
    this.reversesEventId,
    this.rebasesCommandId,
    this.actualAt,
    this.note,
  });

  final String commandId;
  final String userId;
  final String occurrenceId;
  final String occurrenceKey;
  final MedicationAction action;
  final MedicationState? targetState;
  final String? reversesEventId;
  final String? rebasesCommandId;
  final DateTime? actualAt;
  final bool actualTimeKnown;
  final String? note;
  final int baseVersion;

  Map<String, Object?> toWire() => {
    'commandId': commandId,
    'occurrenceId': occurrenceId,
    'occurrenceKey': occurrenceKey,
    'baseVersion': '$baseVersion',
    'action': action.name,
    if (targetState != null) 'targetState': targetState!.name,
    'reversesEventId': reversesEventId,
    'rebasesCommandId': rebasesCommandId,
    'actualAt': actualAt?.toUtc().toIso8601String(),
    'actualTimeKnown': actualTimeKnown,
    'note': note,
  };

  static const _uuid = Uuid();

  static String newCommandId() => _uuid.v4();
}
