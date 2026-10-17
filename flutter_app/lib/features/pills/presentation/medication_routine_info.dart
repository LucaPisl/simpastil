import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/medication/medication_detail_repository.dart';
import '../../../core/medication/routine_definition.dart';
import '../../../core/medication/routine_repository.dart';

/// The routine in force for a local medication, or the next one when none
/// has started; null when the medication has no readable routine.
RoutineDefinition? currentRoutineOf(MedicationCareDetail detail) {
  if (detail.routineVersions.isEmpty) return null;
  final now = DateTime.now().toUtc();
  final version =
      detail.routineVersions
          .where((v) => !v.effectiveFrom.isAfter(now))
          .lastOrNull ??
      detail.routineVersions.last;
  try {
    return RoutineDefinition.fromJson(
      jsonDecode(version.definitionJson) as Map<String, dynamic>,
    );
  } on Object {
    return null;
  }
}

/// The times of day a medication is planned, earliest first: from its local
/// routine, or from the active schedules of a connected one.
List<TimeOfDay> plannedTimesOf(
  MedicationCareDetail detail, {
  required bool local,
}) {
  if (detail.pill.isPrn) return const [];
  if (local) {
    return [
      for (final t in currentRoutineOf(detail)?.times ?? const <RoutineTime>[])
        TimeOfDay(hour: t.hour, minute: t.minute),
    ];
  }
  final times = [
    for (final s in detail.schedules)
      if (s.isActive && !s.isDeleted) TimeOfDay(hour: s.hour, minute: s.minute),
  ]..sort((a, b) => (a.hour * 60 + a.minute).compareTo(b.hour * 60 + b.minute));
  return times;
}
