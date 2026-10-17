import 'occurrence_materializer.dart';
import 'routine_definition.dart';
import 'package:timezone/timezone.dart' as tz;

class RoutinePlannedEntry {
  const RoutinePlannedEntry({
    required this.slot,
    required this.localDate,
    required this.timeZone,
    required this.plannedAt,
  });
  final RoutineTime slot;
  final String localDate;
  final String timeZone;
  final DateTime plannedAt;
  String get localTime => slot.localTime;
}

/// Preview and persisted local entries use this same calendar engine.
class RoutineEngine {
  /// A read-only next entry uses the same calendar inclusion and DST resolver
  /// as preview/materialization, without scanning an arbitrary time horizon.
  RoutinePlannedEntry? next({
    required RoutineDefinition definition,
    required String fromLocalDate,
    required DateTime notBefore,
    DateTime? before,
  }) {
    if (definition.kind == RoutineKind.prn) return null;
    var date = parseRoutineDate(fromLocalDate);
    final localBoundary = tz.TZDateTime.from(
      notBefore,
      tz.getLocation(definition.timeZone),
    );
    final boundaryDate = DateTime.utc(
      localBoundary.year,
      localBoundary.month,
      localBoundary.day,
    );
    if (date.isBefore(boundaryDate)) date = boundaryDate;
    if (definition.startDate case final start?) {
      final startDate = parseRoutineDate(start);
      if (date.isBefore(startDate)) date = startDate;
    }
    if (definition.kind == RoutineKind.interval) {
      final anchor = parseRoutineDate(definition.anchorDate!);
      if (date.isBefore(anchor)) date = anchor;
      final remainder = date.difference(anchor).inDays % definition.everyDays!;
      if (remainder != 0) {
        date = date.add(Duration(days: definition.everyDays! - remainder));
      }
    }
    final end = definition.endDate == null
        ? null
        : parseRoutineDate(definition.endDate!);
    while (end == null || !date.isAfter(end)) {
      if (before != null) {
        final midnight = OccurrenceMaterializer.resolveReviewedLocalTime(
          localDate: routineDateKey(date),
          hour: 0,
          minute: 0,
          timeZone: definition.timeZone,
        );
        if (!midnight.isBefore(before)) return null;
      }
      final entries =
          preview(
              definition: definition,
              fromLocalDate: routineDateKey(date),
              throughLocalDate: routineDateKey(date),
            ).where((entry) => !entry.plannedAt.isBefore(notBefore)).toList()
            ..sort((a, b) => a.plannedAt.compareTo(b.plannedAt));
      for (final entry in entries) {
        if (before == null || entry.plannedAt.isBefore(before)) return entry;
      }
      date = date.add(
        Duration(
          days: definition.kind == RoutineKind.interval
              ? definition.everyDays!
              : 1,
        ),
      );
    }
    return null;
  }

  List<RoutinePlannedEntry> preview({
    required RoutineDefinition definition,
    required String fromLocalDate,
    required String throughLocalDate,
  }) {
    final from = parseRoutineDate(fromLocalDate);
    final through = parseRoutineDate(throughLocalDate);
    final result = <RoutinePlannedEntry>[];
    for (
      var date = from;
      !date.isAfter(through);
      date = DateTime.utc(date.year, date.month, date.day + 1)
    ) {
      if (!definition.includes(date)) continue;
      for (final slot in definition.times) {
        result.add(
          RoutinePlannedEntry(
            slot: slot,
            localDate: routineDateKey(date),
            timeZone: definition.timeZone,
            plannedAt: OccurrenceMaterializer.resolveReviewedLocalTime(
              localDate: routineDateKey(date),
              hour: slot.hour,
              minute: slot.minute,
              timeZone: definition.timeZone,
            ),
          ),
        );
      }
    }
    return List.unmodifiable(result);
  }
}
