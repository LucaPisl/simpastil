import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/db/database.dart';
import '../../core/projections/projection_command_id.dart';
import '../../core/sync/sync_review_repository.dart';
import '../../core/workspace/workspace_provider.dart';

export '../../core/sync/sync_review_repository.dart'
    show
        LocalDoseReviewContext,
        MigrationIssueKind,
        MigrationIssueSummary,
        RetainedSyncInformation,
        projectMigrationIssues;

/// Stored migration issues of the current account, from the shared review
/// repository.
final migrationIssuesProvider = StreamProvider<List<MigrationIssueSummary>>((
  ref,
) async* {
  final contextFuture = ref.watch(workspaceContextProvider.future);
  final db = ref.watch(databaseProvider);
  final access = ref.watch(workspaceAccessRepositoryProvider);
  final context = await contextFuture;
  yield* SyncReviewRepository(
    database: db,
    access: access,
    context: context,
  ).watchIssues();
});

enum MedicationIssueDisposition { keepServerState, applySavedChange }

class MigrationIssueResolutionRepository {
  const MigrationIssueResolutionRepository(this._dio);

  final Dio _dio;

  /// Submits a revision-bound choice. Local state is never cleared here; only
  /// the later account-component revision-2 payload resolves the stored card.
  Future<void> resolveMedicationIssue(
    MigrationIssueSummary issue,
    MedicationIssueDisposition disposition,
  ) async {
    if (!issue.canKeepServerState ||
        (disposition == MedicationIssueDisposition.applySavedChange &&
            !issue.canApplySavedChange)) {
      throw StateError('This medication review cannot be resolved safely.');
    }
    final resolution = switch (disposition) {
      MedicationIssueDisposition.keepServerState => 'keep_server_state',
      MedicationIssueDisposition.applySavedChange => 'apply_residual',
    };
    final key = 'migration-issue-review-v1:${issue.id}:${issue.revision}';
    final response = await _dio.post<dynamic>(
      '/medication/legacy-split/reconcile',
      data: {
        'operation': 'resolve',
        'issueId': issue.id,
        'commandId': projectionCommandIdForKey('$key:command:$resolution'),
        'commandBundleId': projectionCommandIdForKey('$key:bundle:$resolution'),
        'transactionCorrelationId': projectionCommandIdForKey(
          '$key:correlation:$resolution',
        ),
        'baseIssueRevision': '${issue.revision}',
        'resolution': resolution,
      },
    );
    final body = response.data;
    if (body is! Map<String, dynamic> ||
        body['issueId'] != issue.id ||
        body['resolution'] != resolution) {
      throw const FormatException('Medication review receipt mismatch.');
    }
  }
}

final migrationIssueResolutionRepositoryProvider =
    Provider<MigrationIssueResolutionRepository>((ref) {
      return MigrationIssueResolutionRepository(
        ref.watch(apiClientProvider).dio,
      );
    });
