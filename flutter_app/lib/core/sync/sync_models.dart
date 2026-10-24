enum SyncComponent {
  account,
  accountSettings,
  stable,
  medicationBridge,
  medication,
}

enum SyncComponentStatus { succeeded, partiallySynced, failed, blocked }

enum SyncRunStatus { succeeded, partiallySynced, failed }

class SyncComponentOutcome {
  const SyncComponentOutcome._(
    this.status, {
    this.safeErrorCode,
    this.safeCorrelationId,
    this.httpStatusCode,
    this.completedAt,
    this.duration,
    this.retryCount,
  });

  const SyncComponentOutcome.succeeded({
    String? safeCorrelationId,
    int? httpStatusCode,
    DateTime? completedAt,
    Duration? duration,
    int? retryCount,
  }) : this._(
         SyncComponentStatus.succeeded,
         safeCorrelationId: safeCorrelationId,
         httpStatusCode: httpStatusCode,
         completedAt: completedAt,
         duration: duration,
         retryCount: retryCount,
       );

  const SyncComponentOutcome.partiallySynced({
    String? safeErrorCode,
    String? safeCorrelationId,
    int? httpStatusCode,
    DateTime? completedAt,
    Duration? duration,
    int? retryCount,
  }) : this._(
         SyncComponentStatus.partiallySynced,
         safeErrorCode: safeErrorCode,
         safeCorrelationId: safeCorrelationId,
         httpStatusCode: httpStatusCode,
         completedAt: completedAt,
         duration: duration,
         retryCount: retryCount,
       );

  const SyncComponentOutcome.failed({
    String? safeErrorCode,
    String? safeCorrelationId,
    int? httpStatusCode,
    DateTime? completedAt,
    Duration? duration,
    int? retryCount,
  }) : this._(
         SyncComponentStatus.failed,
         safeErrorCode: safeErrorCode,
         safeCorrelationId: safeCorrelationId,
         httpStatusCode: httpStatusCode,
         completedAt: completedAt,
         duration: duration,
         retryCount: retryCount,
       );

  const SyncComponentOutcome.blocked({
    String? safeErrorCode,
    String? safeCorrelationId,
    int? httpStatusCode,
    DateTime? completedAt,
    Duration? duration,
    int? retryCount,
  }) : this._(
         SyncComponentStatus.blocked,
         safeErrorCode: safeErrorCode,
         safeCorrelationId: safeCorrelationId,
         httpStatusCode: httpStatusCode,
         completedAt: completedAt,
         duration: duration,
         retryCount: retryCount,
       );

  final SyncComponentStatus status;
  final String? safeErrorCode;
  final String? safeCorrelationId;
  final int? httpStatusCode;
  final DateTime? completedAt;
  final Duration? duration;
  final int? retryCount;

  SyncComponentOutcome withTiming({
    required DateTime completedAt,
    required Duration duration,
  }) => SyncComponentOutcome._(
    status,
    safeErrorCode: safeErrorCode,
    safeCorrelationId: safeCorrelationId,
    httpStatusCode: httpStatusCode,
    completedAt: completedAt,
    duration: duration,
    retryCount: retryCount,
  );

  bool get allowsDependents => status == SyncComponentStatus.succeeded;
}

typedef SyncStageRunner = Future<SyncComponentOutcome> Function();

class SyncStage {
  const SyncStage({
    required this.id,
    required this.component,
    required this.contractVersion,
    required this.run,
    this.dependsOn = const [],
  });

  final String id;
  final SyncComponent component;
  final int contractVersion;
  final SyncStageRunner run;
  final List<String> dependsOn;
}

class SyncStageResult {
  const SyncStageResult({required this.stageId, required this.outcome});

  final String stageId;
  final SyncComponentOutcome outcome;
}

class SyncRunResult {
  const SyncRunResult(this.stages);

  final List<SyncStageResult> stages;

  static SyncRunResult combine({SyncRunResult? flush, SyncRunResult? pull}) =>
      SyncRunResult([
        if (flush != null)
          ...flush.stages.map(
            (stage) => SyncStageResult(
              stageId: 'flush.${stage.stageId}',
              outcome: stage.outcome,
            ),
          ),
        if (pull != null)
          ...pull.stages.map(
            (stage) => SyncStageResult(
              stageId: 'pull.${stage.stageId}',
              outcome: stage.outcome,
            ),
          ),
      ]);

  SyncComponentOutcome? forStage(String id) {
    for (final stage in stages) {
      if (stage.stageId == id) return stage.outcome;
    }
    return null;
  }

  SyncRunStatus get status {
    if (stages.isEmpty ||
        stages.every(
          (stage) => stage.outcome.status == SyncComponentStatus.succeeded,
        )) {
      return SyncRunStatus.succeeded;
    }
    if (stages.every(
      (stage) =>
          stage.outcome.status == SyncComponentStatus.failed ||
          stage.outcome.status == SyncComponentStatus.blocked,
    )) {
      return SyncRunStatus.failed;
    }
    return SyncRunStatus.partiallySynced;
  }
}

/// Mutually exclusive tally of the unsent local changes.
///
/// A change is counted once, in the first matching bucket: [blocked],
/// [conflict], [stranded] (waiting behind a blocked or conflicting change it
/// depends on, so it cannot go out until a person acts), [retrying]
/// (a transient failure, backing off) or [queued] (waiting or being sent).
///
/// [awaitingLedger] is kept apart: stock counts that stay on the phone by
/// design until the server turns the medication ledger on. They are not
/// pending work, so they are not part of [automatic], [total] or [isSettled].
class SyncOperationCounts {
  const SyncOperationCounts({
    this.queued = 0,
    this.retrying = 0,
    this.blocked = 0,
    this.conflict = 0,
    this.stranded = 0,
    this.awaitingLedger = 0,
  });

  static const none = SyncOperationCounts();

  final int queued;
  final int retrying;
  final int blocked;
  final int conflict;
  final int stranded;

  /// Stock changes held for the server's ledger (bridge mode); see above.
  final int awaitingLedger;

  /// Changes that will go out by themselves (possibly after a backoff).
  int get automatic => queued + retrying;

  /// Changes that need a person: they will never go out on their own.
  int get needsAttention => blocked + conflict + stranded;

  int get total => automatic + needsAttention;

  /// True only when nothing is left unsent in any state.
  bool get isSettled => total == 0;

  @override
  bool operator ==(Object other) =>
      other is SyncOperationCounts &&
      other.queued == queued &&
      other.retrying == retrying &&
      other.blocked == blocked &&
      other.conflict == conflict &&
      other.stranded == stranded &&
      other.awaitingLedger == awaitingLedger;

  @override
  int get hashCode => Object.hash(
    queued,
    retrying,
    blocked,
    conflict,
    stranded,
    awaitingLedger,
  );

  @override
  String toString() =>
      'SyncOperationCounts(queued: $queued, retrying: $retrying, blocked: '
      '$blocked, conflict: $conflict, stranded: $stranded, awaitingLedger: '
      '$awaitingLedger)';
}
