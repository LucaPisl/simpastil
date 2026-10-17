import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/backup/restore_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/startup/protection_readiness.dart';

import '../../helpers/protected_workspace_fixture.dart';

void main() {
  Future<ProtectedWorkspaceFixture> pending() async {
    final f = await ProtectedWorkspaceFixture.create(
      initialPreferences: {'app_locale': 'en'},
    );
    addTearDown(f.db.close);
    await f.db
        .into(f.db.importReceipts)
        .insert(
          ImportReceiptsCompanion.insert(
            id: 'fictional-pending-startup',
            workspaceId: f.context.workspaceId,
            sourceDigest: 'fictional',
            sourceDocumentId: 'fictional',
            sourceCapturedAt: DateTime.utc(2026, 10, 1),
            mode: 'full',
            selectedProfileIdsJson: '[]',
            identityMapJson: '{}',
            appliedAt: DateTime.utc(2026, 10, 1),
          ),
        );
    await RestorePreferencesService(
      database: f.db,
      preferences: f.preferences,
      effectsGate: SerialProjectionEffectsGate(),
    ).stage(
      id: 'fictional-pending-startup',
      receiptId: 'fictional-pending-startup',
      recoveryGeneration: 'fictional-generation',
      before: portablePreferenceSnapshot(f.preferences),
      after: const {'app_locale': 'ro'},
    );
    return f;
  }

  test(
    'startup preference failure keeps care ready and retries on the next startup',
    () async {
      final f = await pending();
      final failing = ProviderContainer(
        overrides: [
          ...f.overrides,
          restorePreferencesServiceProvider.overrideWithValue(
            RestorePreferencesService(
              database: f.db,
              preferences: f.preferences,
              effectsGate: SerialProjectionEffectsGate(),
              writePreference: (_, _) async => false,
            ),
          ),
        ],
      );
      final readiness = await failing.read(protectionReadinessProvider.future);
      expect(readiness.ready, isTrue);
      expect(readiness.preferenceRestore, PreferenceRestoreState.pending);
      expect(f.preferences.getString('app_locale'), 'en');
      await f.access.requireCurrent(f.context);
      failing.dispose();
      final retry = ProviderContainer(overrides: f.overrides);
      addTearDown(retry.dispose);
      expect(
        (await retry.read(
          protectionReadinessProvider.future,
        )).preferenceRestore,
        PreferenceRestoreState.complete,
      );
      expect(f.preferences.getString('app_locale'), 'ro');
      expect(await f.db.select(f.db.importReceipts).get(), hasLength(1));
    },
  );
  test(
    'startup preserves a changed preference and reports renewed review separately',
    () async {
      final f = await pending();
      await f.preferences.setString('app_locale', 'de');
      final container = ProviderContainer(overrides: f.overrides);
      addTearDown(container.dispose);
      final readiness = await container.read(
        protectionReadinessProvider.future,
      );
      expect(readiness.ready, isTrue);
      expect(readiness.preferenceRestore, PreferenceRestoreState.needsReview);
      expect(f.preferences.getString('app_locale'), 'de');
      expect(
        (await f.db.select(f.db.deviceRestoreIntents).get()).single.state,
        'conflict',
      );
      await f.access.requireCurrent(f.context);
    },
  );
  test(
    'startup resumes committed preference intent before becoming ready',
    () async {
      final fixture = await ProtectedWorkspaceFixture.create(
        initialPreferences: {'app_locale': 'en'},
      );
      addTearDown(fixture.db.close);
      final preferences = RestorePreferencesService(
        database: fixture.db,
        preferences: fixture.preferences,
        effectsGate: SerialProjectionEffectsGate(),
      );
      await fixture.db.transaction(() async {
        await fixture.db
            .into(fixture.db.importReceipts)
            .insert(
              ImportReceiptsCompanion.insert(
                id: 'fictional-startup',
                workspaceId: fixture.context.workspaceId,
                sourceDigest: 'fictional',
                sourceDocumentId: 'fictional',
                sourceCapturedAt: DateTime.utc(2026, 10, 1),
                mode: 'full',
                selectedProfileIdsJson: '[]',
                identityMapJson: '{}',
                appliedAt: DateTime.utc(2026, 10, 1),
              ),
            );
        await preferences.stage(
          id: 'fictional-startup',
          receiptId: 'fictional-startup',
          recoveryGeneration: 'fictional-generation',
          before: portablePreferenceSnapshot(fixture.preferences),
          after: const {'app_locale': 'ro'},
        );
      });
      final container = ProviderContainer(overrides: fixture.overrides);
      addTearDown(container.dispose);
      final readiness = await container.read(
        protectionReadinessProvider.future,
      );
      expect(readiness.ready, isTrue);
      expect(readiness.preferenceRestore, PreferenceRestoreState.complete);
      expect(fixture.preferences.getString('app_locale'), 'ro');
      expect(
        (await fixture.db.select(fixture.db.deviceRestoreIntents).get())
            .single
            .state,
        'completed',
      );
      expect(
        await fixture.db.select(fixture.db.importReceipts).get(),
        hasLength(1),
      );
      await fixture.access.requireCurrent(fixture.context);
    },
  );
}
