import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:simpastil/core/api/api_client.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/storage/shared_preferences_provider.dart';
import 'package:simpastil/core/sync/auto_sync_service.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import 'package:simpastil/core/workspace/workspace_provider.dart';
import 'package:simpastil/features/move/move_plan.dart';
import 'package:simpastil/features/move/move_providers.dart';
import 'package:simpastil/features/move/presentation/move_care_screen.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../helpers/care_recording_fixture.dart';
import '../../helpers/protected_workspace_fixture.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);

  // Riverpod 3 pauses a provider nobody listens to. The Move service is read
  // once from a button handler, so the screen must hold it for the whole run
  // or the move stops before it starts.
  testWidgets('the move runs to the end from the screen', (tester) async {
    late CareRecordingFixture fixture;
    late MovePreview preview;
    late WorkspaceContext connected;
    await tester.runAsync(() async {
      fixture = await CareRecordingFixture.create();
      final local =
          await (fixture.db.select(fixture.db.careWorkspaces)..where(
                (w) => w.id.equals(fixture.workspace.context.workspaceId),
              ))
              .getSingle();
      final plan = await readMovePlan(fixture.db, local);
      connected = (await ProtectedWorkspaceFixture.create(
        ownerId: '20000000-0000-4000-8000-000000000001',
        database: fixture.db,
        preferences: fixture.workspace.preferences,
      )).context;
      final now = DateTime.utc(2026, 10, 1);
      preview = MovePreview(
        local: local,
        plan: plan,
        duplicates: {
          fixture.person.id: Profile(
            id: 'account-alex',
            userId: connected.ownerUserId,
            name: fixture.person.name,
            avatarEmoji: '',
            isActive: true,
            createdAt: now,
            updatedAt: now,
            revision: 1,
            syncStatus: 'synced',
            isDeleted: false,
          ),
        },
        serverGap: null,
      );
    });
    addTearDown(fixture.db.close);

    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const MoveCareScreen()),
        GoRoute(path: '/backups', builder: (_, _) => const _SavedBackup()),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          movePreviewProvider.overrideWith((_) async => preview),
          databaseProvider.overrideWithValue(fixture.db),
          workspaceAccessRepositoryProvider.overrideWithValue(
            fixture.workspace.access,
          ),
          workspaceContextProvider.overrideWith((_) => Stream.value(connected)),
          apiClientProvider.overrideWithValue(_Client(Dio())),
          autoSyncServiceProvider.overrideWithValue(_Sync()),
          sharedPreferencesProvider.overrideWithValue(
            fixture.workspace.preferences,
          ),
        ],
        child: MaterialApp.router(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Skipping the only person leaves nothing to send, so the run needs no
    // server and reaches the end only if the service stays alive.
    await tester.ensureVisible(find.text('Skip this person'));
    await tester.tap(find.text('Skip this person'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('move-start')),
      200,
    );
    await tester.tap(find.byKey(const ValueKey('move-start')));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();

    expect(find.text('Your care is on your account'), findsOne);
  });
}

/// Stands in for the backup screen: the backup is saved, so the move goes on.
class _SavedBackup extends StatefulWidget {
  const _SavedBackup();

  @override
  State<_SavedBackup> createState() => _SavedBackupState();
}

class _SavedBackupState extends State<_SavedBackup> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => context.pop(true));
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _Client extends Mock implements ApiClient {
  _Client(this.dio);
  @override
  final Dio dio;
}

class _Sync extends Mock implements AutoSyncService {
  @override
  Future<void> syncNow(String userId, {int? generation}) async {}
}
