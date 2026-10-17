import 'care_recording.dart';

class DoseSelectionResult {
  DoseSelectionResult(
    Map<String, CareRecordingReceipt> saved,
    Map<String, Object> failed,
  ) : saved = Map.unmodifiable(saved),
      failed = Map.unmodifiable(failed);
  final Map<String, CareRecordingReceipt> saved;
  final Map<String, Object> failed;
  bool get isComplete => failed.isEmpty;
}

/// A frozen review of exact entries for one person and date. Reordering the
/// screen or adding another due entry never changes this selection.
class DoseSelectionController {
  DoseSelectionController({
    required this.service,
    required this.personId,
    required this.localDate,
  });
  final CareRecordingService service;
  final String personId;
  final String localDate;
  final _selected = <String, PreparedCareIntent>{};
  final _saved = <String, CareRecordingReceipt>{};
  Future<DoseSelectionResult>? _running;
  List<String> get selectedIds => List.unmodifiable(_selected.keys);
  List<String> get pendingIds =>
      List.unmodifiable(_selected.keys.where((id) => !_saved.containsKey(id)));
  bool get isBusy => _running != null;
  void select(PreparedCareIntent intent) {
    if (isBusy || _saved.isNotEmpty) {
      throw StateError('Finish this reviewed selection first');
    }
    if (intent.personId != personId) {
      throw ArgumentError('A batch records only one person');
    }
    if (intent.localDate != localDate) {
      throw ArgumentError('A batch records only its reviewed date');
    }
    _selected.putIfAbsent(intent.occurrenceId, () => intent);
  }

  void deselect(String occurrenceId) {
    if (isBusy || _saved.isNotEmpty) {
      throw StateError('Finish this reviewed selection first');
    }
    _selected.remove(occurrenceId);
  }

  Future<DoseSelectionResult> commit({
    required String reviewedLocalDate,
  }) async {
    if (reviewedLocalDate != localDate) {
      throw ArgumentError('Review the selected date again');
    }
    final running = _running;
    if (running != null) return running;
    final task = _commit();
    _running = task;
    try {
      return await task;
    } finally {
      _running = null;
    }
  }

  Future<DoseSelectionResult> _commit() async {
    final failures = <String, Object>{};
    for (final intent in _selected.values) {
      if (_saved.containsKey(intent.occurrenceId)) continue;
      try {
        _saved[intent.occurrenceId] = await service.commit(intent);
      } on Object catch (error) {
        failures[intent.occurrenceId] = error;
      }
    }
    return DoseSelectionResult(_saved, failures);
  }
}
