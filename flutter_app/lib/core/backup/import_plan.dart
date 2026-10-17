import '../workspace/workspace_context.dart';

enum ImportMode { selected, full }

enum ImportFailureCode {
  invalidSelection,
  staleTarget,
  staleAccess,
  invalidSource,
  commitFailed,
  recoveryUnavailable,
}

class ImportFailure implements Exception {
  const ImportFailure(this.code);
  final ImportFailureCode code;
  @override
  String toString() => 'ImportFailure(${code.name})';
}

class ImportSelection {
  ImportSelection.profiles(Set<String> ids)
    : mode = ImportMode.selected,
      profileIds = Set.unmodifiable(ids);
  const ImportSelection.full() : mode = ImportMode.full, profileIds = const {};
  final ImportMode mode;
  final Set<String> profileIds;
}

enum ImportPersonOutcome {
  added,
  merged,
  unchanged,
  needsReview,
  locked,
  replaced,
}

class ImportReplacementWorkspaceReview {
  ImportReplacementWorkspaceReview({
    required this.workspaceId,
    required this.ownerId,
    required this.connected,
    required Map<String, int> tableCounts,
    Map<String, int> operationStates = const {},
    Map<String, int> effectStates = const {},
  }) : tableCounts = Map.unmodifiable(tableCounts),
       operationStates = Map.unmodifiable(operationStates),
       effectStates = Map.unmodifiable(effectStates);
  final String workspaceId, ownerId;
  final bool connected;

  /// Counts of retained target work moved into the checked recovery copy.
  /// Aggregate SQL counts do not expose or materialize original command bodies.
  final Map<String, int> tableCounts;
  final Map<String, int> operationStates, effectStates;
}

class ImportWorkspaceReview {
  const ImportWorkspaceReview({
    required this.workspaceId,
    required this.ownerId,
    required this.connected,
    required this.rows,
    required this.retainedRows,
  });
  final String workspaceId, ownerId;
  final bool connected;
  final int rows, retainedRows;
}

class ImportPreferenceChange {
  const ImportPreferenceChange(this.key, this.before, this.after);
  final String key;
  final Object? before, after;
}

enum ImportDoseState { pending, taken, skipped, missed }

class ImportDoseContext {
  const ImportDoseContext({
    required this.personName,
    required this.medicationName,
    required this.localDate,
    required this.localTime,
    required this.state,
  });
  final String personName, medicationName, localDate;
  final String? localTime;
  final ImportDoseState state;
}

class ImportDoseConflict {
  const ImportDoseConflict({required this.local, required this.imported});
  final ImportDoseContext local, imported;
}

class ImportPerson {
  const ImportPerson(
    this.id,
    this.name, {
    required this.connected,
    required this.outcome,
    required this.addedRows,
    required this.conflictingRows,
    required this.retainedRows,
    required this.detachedHistoryRows,
    this.connectedEvidenceOnly = false,
  });
  final String id, name;
  final bool connected;

  /// Connected originals are account-scoped evidence. Only a current pull can
  /// establish live shared state; import never acknowledges archived history.
  final bool connectedEvidenceOnly;
  final ImportPersonOutcome outcome;
  final int addedRows, conflictingRows, retainedRows, detachedHistoryRows;
}

class ImportOwnershipTranslation {
  const ImportOwnershipTranslation({
    required this.sourceWorkspaceId,
    required this.sourceOwnerId,
    required this.targetWorkspaceId,
    required this.targetOwnerId,
  });
  final String sourceWorkspaceId,
      sourceOwnerId,
      targetWorkspaceId,
      targetOwnerId;
}

class ImportPreservation {
  const ImportPreservation({
    required this.exactOriginalsRetained,
    required this.historicalAuthorshipRetained,
    required this.pendingWorkIsolated,
    required this.targetAuthorPreserved,
    required this.targetPreferencesPreserved,
  });
  final bool exactOriginalsRetained,
      historicalAuthorshipRetained,
      pendingWorkIsolated,
      targetAuthorPreserved,
      targetPreferencesPreserved;
}

/// A review is immutable and only the service that produced it can apply it.
class ImportPlan {
  ImportPlan({
    required this.sourceDigest,
    required this.sourceCapturedAt,
    required this.mode,
    required this.target,
    required List<ImportPerson> people,
    required List<ImportOwnershipTranslation> ownershipTranslations,
    required this.preservation,
    required this.additions,
    required this.identical,
    required this.conflicts,
    required this.retainedWork,
    required this.alreadyApplied,
    List<ImportPerson> affectedPeople = const [],
    List<ImportWorkspaceReview> workspaces = const [],
    List<ImportReplacementWorkspaceReview> replacedWorkspaces = const [],
    Map<String, int> unattributedTargetCounts = const {},
    List<ImportPreferenceChange> preferenceChanges = const [],
    List<ImportDoseConflict> doseConflicts = const [],
  }) : people = List.unmodifiable(people),
       affectedPeople = List.unmodifiable(affectedPeople),
       doseConflicts = List.unmodifiable(doseConflicts),
       workspaces = List.unmodifiable(workspaces),
       replacedWorkspaces = List.unmodifiable(replacedWorkspaces),
       unattributedTargetCounts = Map.unmodifiable(unattributedTargetCounts),
       preferenceChanges = List.unmodifiable(preferenceChanges),
       ownershipTranslations = List.unmodifiable(ownershipTranslations);
  final String sourceDigest;
  final DateTime sourceCapturedAt;
  final ImportMode mode;
  final WorkspaceContext target;
  final List<ImportPerson> people;
  final List<ImportPerson> affectedPeople;
  final List<ImportDoseConflict> doseConflicts;
  final List<ImportWorkspaceReview> workspaces;
  final List<ImportReplacementWorkspaceReview> replacedWorkspaces;
  final Map<String, int> unattributedTargetCounts;
  final List<ImportPreferenceChange> preferenceChanges;
  final List<ImportOwnershipTranslation> ownershipTranslations;
  final ImportPreservation preservation;
  final int additions, identical, conflicts, retainedWork;
  final bool alreadyApplied;
}

class ImportResult {
  const ImportResult({
    required this.added,
    required this.conflicts,
    required this.retainedWork,
    required this.alreadyApplied,
    this.recoveryChecked = false,
    this.preferences = ImportPreferenceState.unchanged,
    this.projectionsPending = false,
  });
  final int added, conflicts, retainedWork;
  final bool alreadyApplied;
  final bool recoveryChecked, projectionsPending;
  final ImportPreferenceState preferences;
}

enum ImportPreferenceState { unchanged, pending, needsReview, completed }
