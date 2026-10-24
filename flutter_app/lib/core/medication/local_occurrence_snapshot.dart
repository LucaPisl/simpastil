import 'medication_amount.dart';
import 'routine_definition.dart';
import 'occurrence_materializer.dart';

/// Additive local snapshot. The connected v1 format and identity remain unchanged.
class LocalOccurrenceSnapshot extends ScheduleSnapshotV1 {
  LocalOccurrenceSnapshot({
    required super.pillName,
    required super.dosage,
    required super.hour,
    required super.minute,
    required super.timeZone,
    required super.profileId,
    required super.profileName,
    required this.workspaceId,
    required this.ownerUserId,
    required this.routineId,
    required this.routineRevision,
    required this.slotId,
    required this.amount,
    required this.routineDefinition,
  }) : super(frequency: 'local-v2', frequencyDays: null);
  final String workspaceId;
  final String ownerUserId;
  final String routineId;
  final int routineRevision;
  final String slotId;
  final MedicationAmount amount;
  final RoutineDefinition routineDefinition;
  @override
  Map<String, dynamic> toJson() => {
    ...super.toJson(),
    'version': 2,
    'workspaceId': workspaceId,
    'ownerUserId': ownerUserId,
    'routineId': routineId,
    'routineRevision': routineRevision,
    'slotId': slotId,
    'amount': amount.toJson(),
    'routineDefinition': routineDefinition.toJson(),
  };
  factory LocalOccurrenceSnapshot.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 2 ||
        json['frequency'] != 'local-v2' ||
        json['routineRevision'] is! int ||
        (json['routineRevision'] as int) < 1) {
      throw const FormatException('Invalid local occurrence snapshot');
    }
    return LocalOccurrenceSnapshot(
      pillName: json['pillName'] as String,
      dosage: json['dosage'] as String?,
      hour: json['hour'] as int,
      minute: json['minute'] as int,
      timeZone: json['timeZone'] as String,
      profileId: json['profileId'] as String,
      profileName: json['profileName'] as String,
      workspaceId: json['workspaceId'] as String,
      ownerUserId: json['ownerUserId'] as String,
      routineId: json['routineId'] as String,
      routineRevision: json['routineRevision'] as int,
      slotId: json['slotId'] as String,
      amount: MedicationAmount.fromJson(
        Map<String, Object?>.from(json['amount'] as Map),
      ),
      routineDefinition: RoutineDefinition.fromJson(
        Map<String, dynamic>.from(json['routineDefinition'] as Map),
      ),
    );
  }
}

ScheduleSnapshotV1 decodeScheduleSnapshot(Map<String, dynamic> value) =>
    switch (value['version']) {
      1 => ScheduleSnapshotV1.fromJson(value),
      2 => LocalOccurrenceSnapshot.fromJson(value),
      3 => ScheduleSnapshotV3.fromJson(value),
      _ => throw const FormatException('Unsupported occurrence snapshot'),
    };
bool snapshotOwns(
  ScheduleSnapshotV1 snapshot,
  String ownerId, [
  String? workspaceId,
]) =>
    snapshot is! LocalOccurrenceSnapshot ||
    (snapshot.ownerUserId == ownerId &&
        (workspaceId == null || snapshot.workspaceId == workspaceId));
