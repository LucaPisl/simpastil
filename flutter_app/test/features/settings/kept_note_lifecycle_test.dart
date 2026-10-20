import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/sync_recovery_service.dart';
import 'package:simpastil/core/sync/sync_status_notifier.dart';
import 'package:simpastil/features/profiles/profile_provider.dart';
import 'package:simpastil/features/settings/migration_issue_provider.dart';
import 'package:simpastil/features/settings/presentation/sync_diagnostics_sheet.dart';
import 'package:simpastil/features/settings/presentation/sync_recovery_screen.dart';

import '../../helpers/protected_workspace_fixture.dart';

/// A kept note holds the Sync page on "Review needed" and its entry on "1 kept
/// note to review" until a person dismisses it in Fix sync problems. Once they
/// do, both follow the database on their own.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'dismissing a kept note clears the count and the review headline',
    () async {
      final fixture = await ProtectedWorkspaceFixture.create();
      final owner = fixture.context.ownerUserId;
      final now = DateTime.utc(2026, 10, 9);
      await fixture.db.migrationIssuesDao.record(
        MigrationIssuesCompanion.insert(
          id: 'kept-note',
          userId: owner,
          entityType: 'unknown',
          entityId: 'record-1',
          issueCode: 'sync_item_needs_review',
          snapshotJson: '{}',
          createdAt: now,
          updatedAt: now,
        ),
      );
      final service = SyncRecoveryService(
        db: fixture.db,
        flush: (_) async {},
        pull: (_) async => true,
        write: <T>(_, action) => fixture.db.transaction(action),
      );
      final container = ProviderContainer(
        retry: (_, _) => null,
        overrides: [
          ...fixture.overrides,
          currentUserIdProvider.overrideWithValue(owner),
          syncRecoveryServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await fixture.db.close();
      });

      final counts = <int>[];
      final reviews = <int>[];
      container.listen<AsyncValue<int>>(keptNotesCountProvider, (_, next) {
        final value = next.asData?.value;
        if (value != null) counts.add(value);
      }, fireImmediately: true);
      container.listen<AsyncValue<List<MigrationIssueSummary>>>(
        migrationIssuesProvider,
        (_, next) {
          final value = next.asData?.value;
          if (value != null) {
            reviews.add(value.where((i) => i.asksForReview).length);
          }
        },
        fireImmediately: true,
      );

      Future<void> until(bool Function() done) async {
        final end = DateTime.now().add(const Duration(seconds: 5));
        while (!done() && DateTime.now().isBefore(end)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }

      await until(() => counts.isNotEmpty && reviews.isNotEmpty);
      expect(counts.last, 1);
      expect(reviews.last, 1);
      expect(
        syncHeadlineState(
          container.read(syncStatusProvider),
          reviewCount: reviews.last,
        ),
        SyncHeadlineState.needsReview,
      );

      expect((await service.dismissNote(owner, 'kept-note')).ok, isTrue);

      await until(() => counts.last == 0 && reviews.last == 0);
      expect(counts.last, 0);
      expect(reviews.last, 0);
      expect(
        syncHeadlineState(
          container.read(syncStatusProvider),
          reviewCount: reviews.last,
        ),
        isNot(SyncHeadlineState.needsReview),
      );
    },
  );
}
