import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/sync/sync_review_repository.dart';

MigrationIssueSummary _issue({required bool server}) => MigrationIssueSummary(
  id: 'i',
  entityId: 'e',
  issueCode: 'CONFLICT_REVISION',
  revision: 1,
  resolutionState: 'unresolved',
  kind: MigrationIssueKind.other,
  createdAt: DateTime.utc(2026, 10, 14),
  isServerIssue: server,
);

void main() {
  test('only an issue a person can act on holds the headline on review', () {
    // A kept note from this phone is dismissable on Fix sync problems.
    expect(_issue(server: false).asksForReview, isTrue);
    // A server-sent issue with no choices anywhere is reference only.
    expect(_issue(server: true).asksForReview, isFalse);
  });
}
