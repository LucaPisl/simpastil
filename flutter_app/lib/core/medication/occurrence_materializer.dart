import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:timezone/timezone.dart' as tz;

/// Immutable schedule context captured by each scheduled occurrence.
class ScheduleSnapshotV1 {
  ScheduleSnapshotV1({
    required this.pillName,
    required this.dosage,
    required this.frequency,
    required List<int>? frequencyDays,
    required this.hour,
    required this.minute,
    required this.timeZone,
    required this.profileId,
    required this.profileName,
  }) : frequencyDays = frequencyDays == null
           ? null
           : List.unmodifiable([...frequencyDays]..sort());

  final String pillName;
  final String? dosage;
  final String frequency;
  final List<int>? frequencyDays;
  final int? hour;
  final int? minute;
  final String timeZone;
  final String profileId;
  final String profileName;

  Map<String, dynamic> toJson() => {
    'version': 1,
    'pillName': pillName,
    'dosage': dosage,
    'frequency': frequency,
    'frequencyDays': frequencyDays,
    'hour': hour,
    'minute': minute,
    'timeZone': timeZone,
    'profileId': profileId,
    'profileName': profileName,
  };

  factory ScheduleSnapshotV1.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) {
      throw const FormatException('Unsupported schedule snapshot version');
    }
    final rawDays = json['frequencyDays'];
    return ScheduleSnapshotV1(
      pillName: json['pillName'] as String,
      dosage: json['dosage'] as String?,
      frequency: json['frequency'] as String,
      frequencyDays: rawDays == null ? null : (rawDays as List).cast<int>(),
      hour: json['hour'] as int?,
      minute: json['minute'] as int?,
      timeZone: json['timeZone'] as String,
      profileId: json['profileId'] as String,
      profileName: json['profileName'] as String,
    );
  }
}

/// Minimum schedule data needed to deterministically produce occurrences.
/// [timeZone] must be an explicitly stored IANA zone; it is never inferred
/// from a UTC timestamp or the process's current local zone.
class ScheduledOccurrenceSource {
  const ScheduledOccurrenceSource({
    required this.userId,
    required this.id,
    required this.scheduleRevision,
    required this.pillId,
    required this.pillName,
    required this.dosage,
    required this.frequency,
    required this.frequencyDays,
    required this.hour,
    required this.minute,
    required this.timeZone,
    required this.profileId,
    required this.profileName,
    this.isActive = true,
    this.deletedAt,
  });

  final String userId;
  final String id;
  final String scheduleRevision;
  final String pillId;
  final String pillName;
  final String? dosage;
  final String frequency;
  final List<int>? frequencyDays;
  final int hour;
  final int minute;
  final String timeZone;
  final String profileId;
  final String profileName;
  final bool isActive;
  final DateTime? deletedAt;
}

class MaterializedOccurrence {
  const MaterializedOccurrence({
    required this.occurrenceKey,
    required this.scheduleRevision,
    required this.plannedLocalDate,
    required this.plannedLocalTime,
    required this.timeZone,
    required this.plannedAt,
    required this.scheduleSnapshot,
  });

  final String occurrenceKey;
  final String scheduleRevision;
  final String plannedLocalDate;
  final String plannedLocalTime;
  final String timeZone;
  final DateTime plannedAt;
  final ScheduleSnapshotV1 scheduleSnapshot;
}

/// Dart implementation of the shared occurrence-materializer-v1 contract.
class OccurrenceMaterializer {
  static const _uuidPattern =
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$';
  static const _maxRevision = 9223372036854775807;
  static const _hourMs = Duration.millisecondsPerHour;

  List<MaterializedOccurrence> materialize({
    required ScheduledOccurrenceSource source,
    required String fromLocalDate,
    required String throughLocalDate,
  }) {
    if (!source.isActive ||
        source.deletedAt != null ||
        source.frequency == 'prn') {
      return const [];
    }

    final start = _parseLocalDate(fromLocalDate);
    final end = _parseLocalDate(throughLocalDate);
    if (end.isBefore(start)) return const [];
    _canonicalUuid(source.userId, 'userId');
    _canonicalUuid(source.id, 'scheduleId');
    _canonicalRevision(source.scheduleRevision);
    final localTime = _canonicalLocalTime(source.hour, source.minute);
    final location = _location(source.timeZone);
    final days = _validatedDays(source.frequency, source.frequencyDays);

    final snapshot = ScheduleSnapshotV1(
      pillName: source.pillName,
      dosage: source.dosage,
      frequency: source.frequency,
      frequencyDays: source.frequencyDays,
      hour: source.hour,
      minute: source.minute,
      timeZone: source.timeZone,
      profileId: source.profileId,
      profileName: source.profileName,
    );
    final result = <MaterializedOccurrence>[];
    for (var date = start; !date.isAfter(end); date = _addLocalDays(date, 1)) {
      if (source.frequency != 'daily' && !days.contains(date.weekday)) continue;
      final localDate = _formatLocalDate(date);
      final plannedAt = _resolveLocalPlannedInstant(
        date,
        source.hour,
        source.minute,
        location,
      );
      result.add(
        MaterializedOccurrence(
          occurrenceKey: _scheduledOccurrenceKey(
            userId: source.userId,
            scheduleId: source.id,
            scheduleRevision: source.scheduleRevision,
            intendedLocalDate: localDate,
            intendedLocalTime: localTime,
            timeZone: source.timeZone,
            resolvedInstant: plannedAt,
          ),
          scheduleRevision: source.scheduleRevision,
          plannedLocalDate: localDate,
          plannedLocalTime: '$localTime:00',
          timeZone: source.timeZone,
          plannedAt: plannedAt,
          scheduleSnapshot: snapshot,
        ),
      );
    }
    return List.unmodifiable(result);
  }

  /// Uses the established v1 DST rule without imposing a connected owner identity.
  static DateTime resolveReviewedLocalTime({
    required String localDate,
    required int hour,
    required int minute,
    required String timeZone,
  }) {
    _canonicalLocalTime(hour, minute);
    return _resolveLocalPlannedInstant(
      _parseLocalDate(localDate),
      hour,
      minute,
      _location(timeZone),
    );
  }

  String prnOccurrenceKey(String occurrenceId) =>
      'prn:${_canonicalUuid(occurrenceId, 'occurrenceId')}';

  /// Only future, untouched rows may be superseded by a schedule revision.
  bool canSupersede({
    required DateTime plannedAt,
    required int stateVersion,
    required bool hasOccurrenceEvent,
    required DateTime now,
  }) => plannedAt.isAfter(now) && stateVersion == 0 && !hasOccurrenceEvent;

  static String _scheduledOccurrenceKey({
    required String userId,
    required String scheduleId,
    required String scheduleRevision,
    required String intendedLocalDate,
    required String intendedLocalTime,
    required String timeZone,
    required DateTime resolvedInstant,
  }) {
    _canonicalUuid(userId, 'userId');
    _canonicalUuid(scheduleId, 'scheduleId');
    _canonicalRevision(scheduleRevision);
    _parseLocalDate(intendedLocalDate);
    if (!RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d$').hasMatch(intendedLocalTime)) {
      throw ArgumentError.value(intendedLocalTime, 'intendedLocalTime');
    }
    _location(timeZone);
    final canonical = [
      'simpastil-occurrence-key-v1',
      userId.toLowerCase(),
      scheduleId.toLowerCase(),
      scheduleRevision,
      intendedLocalDate,
      intendedLocalTime,
      timeZone,
      resolvedInstant.toUtc().toIso8601String(),
    ].join('\n');
    final digest = sha256.convert(utf8.encode(canonical));
    return 'scheduled:v1:$digest';
  }

  static DateTime _parseLocalDate(String value) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
      throw ArgumentError.value(value, 'localDate', 'Expected YYYY-MM-DD');
    }
    final parts = value.split('-').map(int.parse).toList(growable: false);
    final date = DateTime.utc(parts[0], parts[1], parts[2]);
    if (parts[0] == 0 || _formatLocalDate(date) != value) {
      throw ArgumentError.value(value, 'localDate', 'Invalid Gregorian date');
    }
    return date;
  }

  static DateTime _addLocalDays(DateTime date, int amount) =>
      DateTime.utc(date.year, date.month, date.day + amount);

  static String _formatLocalDate(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  static String _canonicalLocalTime(int hour, int minute) {
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
      throw RangeError('Scheduled local time is outside the supported day');
    }
    return '${hour.toString().padLeft(2, '0')}:'
        '${minute.toString().padLeft(2, '0')}';
  }

  static String _canonicalUuid(String value, String field) {
    if (!RegExp(_uuidPattern, caseSensitive: false).hasMatch(value)) {
      throw ArgumentError.value(value, field, 'Must be a UUID');
    }
    return value.toLowerCase();
  }

  static void _canonicalRevision(String value) {
    if (!RegExp(r'^[1-9]\d{0,18}$').hasMatch(value) ||
        BigInt.parse(value) > BigInt.from(_maxRevision)) {
      throw ArgumentError.value(value, 'scheduleRevision');
    }
  }

  static tz.Location _location(String name) {
    if (!RegExp(r'^[A-Za-z0-9_+/-]{1,128}$').hasMatch(name)) {
      throw ArgumentError.value(name, 'timeZone', 'Must be an IANA identifier');
    }
    try {
      return tz.getLocation(name);
    } on Object {
      throw ArgumentError.value(
        name,
        'timeZone',
        'Unsupported IANA identifier',
      );
    }
  }

  static List<int> _validatedDays(String frequency, List<int>? input) {
    if (!const {'daily', 'weekly', 'custom'}.contains(frequency)) {
      throw ArgumentError.value(frequency, 'frequency');
    }
    if (input != null &&
        (input.any((day) => day < 1 || day > 7) ||
            input.toSet().length != input.length)) {
      throw ArgumentError.value(input, 'frequencyDays');
    }
    if (frequency == 'daily' && input != null) {
      throw ArgumentError.value(input, 'frequencyDays', 'Daily requires null');
    }
    if (frequency == 'weekly' && (input == null || input.length != 1)) {
      throw ArgumentError.value(
        input,
        'frequencyDays',
        'Weekly requires one day',
      );
    }
    if (frequency == 'custom' && (input == null || input.isEmpty)) {
      throw ArgumentError.value(input, 'frequencyDays', 'Custom requires days');
    }
    if (input == null) return const [];
    final sorted = [...input]..sort();
    return sorted;
  }

  static DateTime _resolveLocalPlannedInstant(
    DateTime date,
    int hour,
    int minute,
    tz.Location location,
  ) {
    final intended = DateTime.utc(
      date.year,
      date.month,
      date.day,
      hour,
      minute,
    );
    final intendedEpoch = intended.millisecondsSinceEpoch;
    final offsets = <int>{};
    final samples = <({int instant, int offset})>[];
    for (
      var instant = intendedEpoch - 48 * _hourMs;
      instant <= intendedEpoch + 48 * _hourMs;
      instant += 3 * _hourMs
    ) {
      final offset = _offsetAt(instant, location);
      samples.add((instant: instant, offset: offset));
      offsets.add(offset);
    }

    final candidates =
        offsets
            .map((offset) => intendedEpoch - offset)
            .where(
              (candidate) => _sameLocalMinute(candidate, intended, location),
            )
            .toList()
          ..sort();
    if (candidates.isNotEmpty) {
      return DateTime.fromMillisecondsSinceEpoch(candidates.first, isUtc: true);
    }

    for (var index = 1; index < samples.length; index++) {
      final before = samples[index - 1];
      final after = samples[index];
      if (after.offset <= before.offset) continue;
      var low = before.instant;
      var high = after.instant;
      while (high - low > 1000) {
        final middle = ((low + high) ~/ 2000) * 1000;
        if (_offsetAt(middle, location) == before.offset) {
          low = middle;
        } else {
          high = middle;
        }
      }
      final transition = high;
      final oldLocalEnd = transition + before.offset;
      final newLocalStart = transition + after.offset;
      if (intendedEpoch >= oldLocalEnd && intendedEpoch < newLocalStart) {
        return DateTime.fromMillisecondsSinceEpoch(transition, isUtc: true);
      }
    }
    throw RangeError('Could not resolve local time in ${location.name}');
  }

  static int _offsetAt(int instant, tz.Location location) {
    final local = tz.TZDateTime.from(
      DateTime.fromMillisecondsSinceEpoch(instant, isUtc: true),
      location,
    );
    final localTimeline = DateTime.utc(
      local.year,
      local.month,
      local.day,
      local.hour,
      local.minute,
      local.second,
    ).millisecondsSinceEpoch;
    final secondAligned = (instant ~/ 1000) * 1000;
    return localTimeline - secondAligned;
  }

  static bool _sameLocalMinute(
    int instant,
    DateTime intended,
    tz.Location location,
  ) {
    final local = tz.TZDateTime.from(
      DateTime.fromMillisecondsSinceEpoch(instant, isUtc: true),
      location,
    );
    return local.year == intended.year &&
        local.month == intended.month &&
        local.day == intended.day &&
        local.hour == intended.hour &&
        local.minute == intended.minute;
  }
}
