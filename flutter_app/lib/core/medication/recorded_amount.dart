import 'dart:convert';

import '../db/database.dart';
import 'medication_amount.dart';

/// The amount recorded with [event], for display.
///
/// The device-local detail row ([detailAmountJson]) wins when it exists.
/// Without one (a dose recorded on another device, or before a fresh
/// sign-in) the event's own synced `administrationAmountJson` is used.
/// Anything missing or unreadable is [MedicationAmount.unknown].
MedicationAmount recordedAmountOf(
  OccurrenceEvent event, {
  String? detailAmountJson,
}) {
  final json = detailAmountJson ?? event.administrationAmountJson;
  if (json == null) return const MedicationAmount.unknown();
  try {
    return MedicationAmount.fromJson(
      Map<String, Object?>.from(jsonDecode(json) as Map),
    );
  } on Object {
    return const MedicationAmount.unknown();
  }
}
