import 'package:timezone/timezone.dart' as tz;
import 'medication_amount.dart';

enum RoutineKind { daily, weekdays, interval, prn }

/// Stable identity represents one reviewed time slot, independently of its clock time.
class RoutineTime {
  const RoutineTime({
    required this.slotId,
    required this.hour,
    required this.minute,
  });
  final String slotId;
  final int hour;
  final int minute;
  String get localTime =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}:00';
  Map<String, Object> toJson() => {
    'slotId': slotId,
    'hour': hour,
    'minute': minute,
  };
  factory RoutineTime.fromJson(Map<String, dynamic> value) => RoutineTime(
    slotId: value['slotId'] as String,
    hour: value['hour'] as int,
    minute: value['minute'] as int,
  );
}

DateTime parseRoutineDate(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    throw ArgumentError.value(value, 'localDate');
  }
  final parts = value.split('-').map(int.parse).toList();
  final date = DateTime.utc(parts[0], parts[1], parts[2]);
  if (parts[0] == 0 || routineDateKey(date) != value) {
    throw ArgumentError.value(value, 'localDate');
  }
  return date;
}

String routineDateKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

class RoutineDefinition {
  RoutineDefinition({
    required this.kind,
    required this.timeZone,
    required List<RoutineTime> times,
    List<int> weekdays = const [],
    this.everyDays,
    this.anchorDate,
    this.startDate,
    this.endDate,
    this.amount = const MedicationAmount.unknown(),
  }) : times = List.unmodifiable(
         [...times]..sort((a, b) => a.localTime.compareTo(b.localTime)),
       ),
       weekdays = List.unmodifiable([...weekdays]..sort()) {
    tz.getLocation(timeZone);
    if (!RegExp(r'^[A-Za-z0-9_+/-]{1,128}$').hasMatch(timeZone) ||
        (kind == RoutineKind.prn ? times.isNotEmpty : times.isEmpty) ||
        times.any(
          (t) =>
              t.slotId.isEmpty ||
              t.slotId.length > 128 ||
              t.hour < 0 ||
              t.hour > 23 ||
              t.minute < 0 ||
              t.minute > 59,
        ) ||
        times.map((t) => t.localTime).toSet().length != times.length ||
        times.map((t) => t.slotId).toSet().length != times.length ||
        weekdays.any((d) => d < 1 || d > 7) ||
        weekdays.toSet().length != weekdays.length ||
        (kind == RoutineKind.weekdays
            ? weekdays.isEmpty
            : weekdays.isNotEmpty) ||
        (kind == RoutineKind.interval
            ? everyDays == null || everyDays! < 1 || anchorDate == null
            : everyDays != null || anchorDate != null)) {
      throw ArgumentError('Invalid reviewed routine');
    }
    if (anchorDate != null) parseRoutineDate(anchorDate!);
    if (startDate != null) parseRoutineDate(startDate!);
    if (endDate != null) parseRoutineDate(endDate!);
    if (startDate != null &&
        endDate != null &&
        startDate!.compareTo(endDate!) > 0) {
      throw ArgumentError('Routine end is before its start');
    }
  }
  final RoutineKind kind;
  final String timeZone;
  final List<RoutineTime> times;
  final List<int> weekdays;
  final int? everyDays;
  final String? anchorDate;
  final String? startDate;
  final String? endDate;
  final MedicationAmount amount;
  bool isWithinDates(DateTime date) {
    final key = routineDateKey(date);
    return (startDate == null || key.compareTo(startDate!) >= 0) &&
        (endDate == null || key.compareTo(endDate!) <= 0);
  }

  bool includes(DateTime date) {
    if (!isWithinDates(date)) return false;
    return switch (kind) {
      RoutineKind.daily => true,
      RoutineKind.weekdays => weekdays.contains(date.weekday),
      RoutineKind.interval =>
        !date.isBefore(parseRoutineDate(anchorDate!)) &&
            date.difference(parseRoutineDate(anchorDate!)).inDays %
                    everyDays! ==
                0,
      RoutineKind.prn => false,
    };
  }

  Map<String, Object?> toJson() => {
    'version': 2,
    'kind': kind.name,
    'timeZone': timeZone,
    'times': times.map((t) => t.toJson()).toList(),
    'weekdays': weekdays,
    'everyDays': everyDays,
    'anchorDate': anchorDate,
    'startDate': startDate,
    'endDate': endDate,
    'amount': amount.toJson(),
  };
  factory RoutineDefinition.fromJson(Map<String, dynamic> value) {
    if (value['version'] != 2) {
      throw const FormatException('Unsupported local routine');
    }
    return RoutineDefinition(
      kind: RoutineKind.values.byName(value['kind'] as String),
      timeZone: value['timeZone'] as String,
      times: (value['times'] as List)
          .map((v) => RoutineTime.fromJson(Map<String, dynamic>.from(v as Map)))
          .toList(),
      weekdays: (value['weekdays'] as List).cast<int>(),
      everyDays: value['everyDays'] as int?,
      anchorDate: value['anchorDate'] as String?,
      startDate: value['startDate'] as String?,
      endDate: value['endDate'] as String?,
      amount: MedicationAmount.fromJson(
        Map<String, Object?>.from(value['amount'] as Map),
      ),
    );
  }
}
