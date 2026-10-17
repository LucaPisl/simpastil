import 'dart:convert';

import '../../core/medication/medication_amount.dart';
import '../../core/medication/routine_definition.dart';

enum SetupStep {
  start,
  person,
  medication,
  routine,
  reminders,
  ready,
  complete,
}

enum SetupPurpose { onboarding, person, medication }

enum SetupSharingState { localOnly, pending }

enum SetupEffectState { notRequested, ready, unavailable }

class SetupConflict implements Exception {
  const SetupConflict();
}

class MedicationReview {
  const MedicationReview({
    this.name = '',
    this.packageStrength,
    this.form,
    this.notes,
    this.amount = const MedicationAmount.unknown(),
    this.originalDosage,
    this.legacyDosageReviewed = false,
  });
  final String name;
  final String? packageStrength;
  final String? form;
  final String? notes;
  final MedicationAmount amount;
  final String? originalDosage;
  final bool legacyDosageReviewed;

  void validateForSave() {
    if (name.trim().isEmpty) {
      throw const FormatException('Medication name is required');
    }
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'name': name,
    'packageStrength': packageStrength,
    'form': form,
    'notes': notes,
    'amount': amount.toJson(),
    'originalDosage': originalDosage,
    'legacyDosageReviewed': legacyDosageReviewed,
  };

  factory MedicationReview.fromJson(Map<String, Object?> json) {
    if (json['version'] != 1) {
      throw const FormatException('Unsupported medication review');
    }
    return MedicationReview(
      name: json['name'] as String,
      packageStrength: json['packageStrength'] as String?,
      form: json['form'] as String?,
      notes: json['notes'] as String?,
      amount: MedicationAmount.fromJson(
        Map<String, Object?>.from(json['amount'] as Map),
      ),
      originalDosage: json['originalDosage'] as String?,
      legacyDosageReviewed: json['legacyDosageReviewed'] as bool,
    );
  }
}

class SetupReview {
  const SetupReview({
    this.personName = '',
    this.avatar = '🙂',
    this.audience = 'myself',
    this.medication = const MedicationReview(),
    this.routine,
    this.routineEffectiveFrom,
  });
  final String personName;
  final String avatar;
  final String audience;
  final MedicationReview medication;
  final RoutineDefinition? routine;
  final DateTime? routineEffectiveFrom;
  Map<String, Object?> toJson() => {
    'version': 1,
    'personName': personName,
    'avatar': avatar,
    'audience': audience,
    'medication': medication.toJson(),
    if (routine != null) 'routine': routine!.toJson(),
    if (routineEffectiveFrom != null)
      'routineEffectiveFrom': routineEffectiveFrom!.toUtc().toIso8601String(),
  };
  String encode() => jsonEncode(toJson());
  factory SetupReview.decode(String encoded) {
    final json = jsonDecode(encoded) as Map;
    if (json['version'] != 1) {
      throw const FormatException('Unsupported setup review');
    }
    if ((json['routine'] == null) != (json['routineEffectiveFrom'] == null)) {
      throw const FormatException('Incomplete routine review');
    }
    return SetupReview(
      personName: json['personName'] as String,
      avatar: json['avatar'] as String,
      audience: json['audience'] as String,
      routine: json['routine'] == null
          ? null
          : RoutineDefinition.fromJson(
              Map<String, dynamic>.from(json['routine'] as Map),
            ),
      routineEffectiveFrom: json['routineEffectiveFrom'] == null
          ? null
          : DateTime.parse(json['routineEffectiveFrom'] as String).toUtc(),
      medication: MedicationReview.fromJson(
        Map<String, Object?>.from(json['medication'] as Map),
      ),
    );
  }
}

class SetupDraftData {
  const SetupDraftData({
    required this.id,
    required this.workspaceId,
    required this.authorId,
    required this.purpose,
    required this.step,
    required this.revision,
    required this.review,
    this.personId,
    this.medicationId,
  });
  final String id;
  final String workspaceId;
  final String authorId;
  final SetupPurpose purpose;
  final SetupStep step;
  final int revision;
  final SetupReview review;
  final String? personId;
  final String? medicationId;
}

class SetupSave {
  const SetupSave({
    required this.savedId,
    required this.draft,
    required this.sharing,
    this.effects = SetupEffectState.notRequested,
  });
  final String savedId;
  final SetupDraftData draft;
  final SetupSharingState sharing;
  final SetupEffectState effects;
}
