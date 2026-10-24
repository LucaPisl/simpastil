import 'dart:convert';

import '../db/database.dart';

/// Names who gave a dose that is being copied, in place of whoever is signed
/// in now. A Move uses it so a past dose never gets the mover's name: [name]
/// is the original author's, or null when the original named nobody, in which
/// case nothing is shared.
class RecordedByOverride {
  const RecordedByOverride(this.name);
  final String? name;
}

/// The name a dose was recorded under, snapshotted when it was recorded and
/// shared with the account's other devices (wire `recordedBy`).
///
/// It is display-only: it identifies no account and no device. [name] is null
/// when a person recorded the dose but no name could be resolved; the absence
/// of a [RecordedBy] altogether means the author is unknown.
class RecordedBy {
  const RecordedBy(this.name);

  static const version = 1;
  static const maxNameLength = 100;

  final String? name;

  /// The wire object, always carrying the version.
  Map<String, Object?> toWire() => {'version': version, 'name': name};

  /// The stored form of a pulled name (`occurrence_events.recorded_by_json`).
  String toStoredJson() => jsonEncode(toWire());

  /// Reads a wire or stored object. Anything this build cannot read (an
  /// unknown version, a wrong shape, an extra key, an untrimmed or overlong
  /// name) is no author at all: a display label never fails a pull.
  static RecordedBy? fromWire(Object? raw) {
    if (raw is! Map || raw.length != 2) return null;
    if (raw['version'] != version || !raw.containsKey('name')) return null;
    final name = raw['name'];
    if (name == null) return const RecordedBy(null);
    if (name is! String ||
        name.isEmpty ||
        name != name.trim() ||
        name.length > maxNameLength) {
      return null;
    }
    return RecordedBy(name);
  }

  static RecordedBy? fromStoredJson(String? json) {
    if (json == null) return null;
    try {
      return fromWire(jsonDecode(json));
    } on FormatException {
      return null;
    }
  }

  /// The trimmed snapshot to send for a resolved name: at most
  /// [maxNameLength] characters, or null when nothing usable is left.
  static String? snapshotName(String? resolved) {
    final trimmed = resolved?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed.length <= maxNameLength
        ? trimmed
        : trimmed.substring(0, maxNameLength).trim();
  }

  @override
  bool operator ==(Object other) => other is RecordedBy && other.name == name;

  @override
  int get hashCode => name.hashCode;
}

/// What a pulled event says about its author, shared by every reader so a
/// device that did not record the dose shows the same facts.
extension OccurrenceEventRecordedBy on OccurrenceEvent {
  RecordedBy? get recordedBy => RecordedBy.fromStoredJson(recordedByJson);
}
