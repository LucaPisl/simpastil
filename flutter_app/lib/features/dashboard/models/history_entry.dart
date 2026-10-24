import '../../../core/medication/care_recording.dart';
import '../../../core/medication/medication_amount.dart';

/// Planned, actual and recorded facts remain distinct, including corrections.
class HistoryEntry {
  const HistoryEntry({
    required this.doseLogId,
    required this.pillName,
    this.dosage,
    required this.scheduledAt,
    this.takenAt,
    required this.status,
    this.occurrenceState,
    this.note,
    required this.profileName,
    required this.scheduleId,
    this.occurrenceId,
    this.source = 'legacy',
    this.provenance = 'exact',
    bool? actualTimeKnown,
    this.plannedLocalDate,
    this.plannedLocalTime,
    this.personId,
    this.timeZone,
    this.stateVersion = 0,
    this.recordedAt,
    this.authorId,
    this.authorName,
    this.amount = const MedicationAmount.unknown(),
    this.plannedAmount = const MedicationAmount.unknown(),
    this.pillId,
    this.pillColor,
    this.auditEvents = const [],
    this.takenLate = false,
  }) : actualTimeKnown = actualTimeKnown ?? takenAt != null;

  final String doseLogId;
  final String pillName;
  final String? dosage;
  final DateTime? scheduledAt;
  final DateTime? takenAt;
  final String status;

  /// Stored care outcome. The adherence status may infer a past missing entry.
  final String? occurrenceState;
  String get recordedState => occurrenceState ?? status;
  final String? note;
  final String profileName;
  final String scheduleId;
  final String? occurrenceId;
  final String source;
  final String provenance;
  final bool actualTimeKnown;
  final String? plannedLocalDate;
  final String? plannedLocalTime;
  final String? personId;
  final String? timeZone;
  final int stateVersion;
  final DateTime? recordedAt;
  final String? authorId;
  final String? authorName;
  final MedicationAmount amount;

  /// The amount the routine planned, when the occurrence recorded it.
  final MedicationAmount plannedAmount;

  /// The medication's id and own color, for its mark. The color is null when
  /// none was set or the medication is no longer on this device.
  final String? pillId;
  final String? pillColor;
  final List<CareEventFacts> auditEvents;

  /// Taken after the dose had been recorded as missed.
  final bool takenLate;
}
