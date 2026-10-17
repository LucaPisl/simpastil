import 'dart:convert';

import '../db/database.dart';

/// A device-private proof authorizes retirement only. It never resolves a
/// workspace, grants read access or accepts a recording action.
class RestoreProjectionRetirement {
  const RestoreProjectionRetirement(
    this.workspaceId,
    this.ownerId,
    this.ceiling,
  );
  final String workspaceId, ownerId;
  final int ceiling;

  Map<String, Object> toJson() => {
    'version': 1,
    'workspaceId': workspaceId,
    'ownerId': ownerId,
    'retiredEpochCeiling': ceiling,
  };

  static List<RestoreProjectionRetirement> decode(String source) {
    final values = jsonDecode(source);
    if (values is! List) {
      throw const FormatException('Invalid retirement proof');
    }
    return [for (final value in values) _decode(value)];
  }

  static RestoreProjectionRetirement _decode(Object? value) {
    if (value is! Map ||
        value['version'] != 1 ||
        value['workspaceId'] is! String ||
        value['ownerId'] is! String ||
        (value['workspaceId'] as String).isEmpty ||
        (value['ownerId'] as String).isEmpty ||
        value['retiredEpochCeiling'] is! int ||
        (value['retiredEpochCeiling'] as int) < 1) {
      throw const FormatException('Invalid retirement proof');
    }
    return RestoreProjectionRetirement(
      value['workspaceId'] as String,
      value['ownerId'] as String,
      value['retiredEpochCeiling'] as int,
    );
  }

  static Future<List<RestoreProjectionRetirement>> unfinished(
    AppDatabase database,
  ) async => [
    for (final intent in await (database.select(
      database.deviceRestoreIntents,
    )..where((r) => r.projectionsCompleted.equals(false))).get())
      ...decode(intent.retiredProjectionsJson),
  ];

  static List<RestoreProjectionRetirement> combine(
    Iterable<RestoreProjectionRetirement> values,
  ) {
    final result = <String, RestoreProjectionRetirement>{};
    for (final value in values) {
      final key = jsonEncode([value.workspaceId, value.ownerId]);
      if ((result[key]?.ceiling ?? 0) < value.ceiling) result[key] = value;
    }
    return result.values.toList();
  }
}
