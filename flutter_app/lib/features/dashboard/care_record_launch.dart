import 'package:flutter/material.dart';

import '../../core/medication/care_recording.dart';
import '../../core/medication/medication_amount.dart';
import '../../core/medication/medication_command.dart';
import 'care_record_form.dart';

/// Opens the review form for one occurrence, either to take it at another
/// time or to skip it (or, for an already recorded dose, to correct it).
///
/// Every "Other time", "Taken at another time", "Skip" and "Correct" on Today
/// and in Dose details goes through here, so they all use the same
/// [CareRecordForm] and the same `service.prepare` call. Nothing is written
/// until the person reviews and saves in the form.
Future<void> openCareRecordForm(
  BuildContext context, {
  required CareRecordingService service,
  required String personId,
  required String personName,
  required String medicationName,
  required String occurrenceId,
  required String localDate,
  required String state,
  required int stateVersion,
  required MedicationAmount amount,
  DateTime? initialActualAt,
  String? initialNote,
  bool skip = false,
}) {
  // A missed dose is recorded like a pending one: taking or skipping it
  // settles the miss, the repository writes the correction.
  final recorded = state != 'pending' && state != 'missed';
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => CareRecordForm(
        service: service,
        personName: personName,
        medicationName: medicationName,
        localDate: localDate,
        amount: amount,
        initialState: skip ? MedicationState.skipped : MedicationState.taken,
        correction: recorded,
        initialActualAt: initialActualAt,
        initialNote: initialNote,
        prepare: (v) => service.prepare(
          personId: personId,
          occurrenceId: occurrenceId,
          expectedStateVersion: stateVersion,
          action: recorded
              ? MedicationAction.correct
              : v.state == MedicationState.skipped
              ? MedicationAction.skip
              : MedicationAction.take,
          targetState: recorded ? v.state : null,
          amount: v.amount,
          actualAt: v.actualAt,
          actualTimeKnown: v.actualTimeKnown,
          note: v.note,
        ),
      ),
    ),
  );
}
