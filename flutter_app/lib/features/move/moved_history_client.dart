import 'package:dio/dio.dart';

import 'move_ids.dart';
import 'move_plan.dart';

/// The server's answer for one copied dose.
class MovedOccurrence {
  const MovedOccurrence({
    required this.occurrenceId,
    required this.occurrenceKey,
    required this.stateVersion,
    required this.created,
  });

  /// The id the server keeps: the requested one, or the id of a dose it had
  /// already planned for the same slot and day.
  final String occurrenceId;
  final String occurrenceKey;
  final int stateVersion;
  final bool created;

  /// Reads one answer entry. The server sends `stateVersion` as a decimal
  /// string (it is a bigint column); a number is accepted too.
  factory MovedOccurrence.fromJson(Map<String, dynamic> entry) {
    final version = entry['stateVersion'];
    final parsed = version is int ? version : int.tryParse('$version');
    if (parsed == null) {
      throw const FormatException('Unexpected moved-history answer');
    }
    return MovedOccurrence(
      occurrenceId: entry['occurrenceId'] as String,
      occurrenceKey: entry['occurrenceKey'] as String,
      stateVersion: parsed,
      created: entry['created'] as bool,
    );
  }
}

/// Sends past scheduled doses to `POST /medication/moved-history`. The server
/// writes each dose under its schedule as it was planned and records nothing
/// about it; the Move records each dose's state afterwards with ordinary
/// commands. Replaying a request returns the same answer.
class MovedHistoryClient {
  MovedHistoryClient(this._dio);

  final Dio _dio;

  /// The most doses one request may carry.
  static const maxItems = 200;

  Future<List<MovedOccurrence>> send({
    required String scheduleId,
    required List<MoveHistoryItem> items,
    required MoveIds ids,
  }) async {
    if (items.isEmpty || items.length > maxItems) {
      throw ArgumentError.value(items.length, 'items');
    }
    final response = await _dio.post<Map<String, dynamic>>(
      '/medication/moved-history',
      data: {
        'scheduleId': scheduleId,
        'items': [
          for (final item in items)
            {
              'occurrenceId': ids.occurrence(item.occurrence.id),
              'plannedLocalDate': item.occurrence.plannedLocalDate,
              'plannedLocalTime': item.plannedLocalTime,
              'timeZone': item.occurrence.timeZone,
              'routine': item.routine.toJson(),
            },
        ],
      },
    );
    final raw = response.data?['items'];
    if (raw is! List || raw.length != items.length) {
      throw const FormatException('Unexpected moved-history answer');
    }
    return [
      for (final entry in raw.cast<Map<String, dynamic>>())
        MovedOccurrence.fromJson(entry),
    ];
  }
}
