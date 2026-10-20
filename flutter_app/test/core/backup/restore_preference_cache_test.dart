import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/backup/backup_providers.dart';
import 'package:simpastil/core/backup/restore_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/storage/appearance_preferences.dart';
import 'package:simpastil/core/theme/theme_provider.dart';

import '../../helpers/protected_workspace_fixture.dart';
import '../../helpers/held_provider_read.dart';

void main() {
  test(
    'restore replaces prewarmed appearance cache and later edits preserve restored roles',
    () async {
      final old = AppearancePreferences(mode: AppearanceMode.light);
      final restored = AppearancePreferences(
        mode: AppearanceMode.dark,
        lightColors: {AppearanceColorRole.primary: 0xff335577},
        darkColors: {AppearanceColorRole.primary: 0xffddbb99},
      );
      final f = await ProtectedWorkspaceFixture.create(
        initialPreferences: {
          SharedAppearancePreferenceStorage.key: jsonEncode(old.toJson()),
        },
      );
      addTearDown(f.db.close);
      final container = ProviderContainer(
        overrides: [
          ...f.overrides,
          appearanceProjectionRefreshProvider.overrideWithValue(() async {}),
        ],
      );
      addTearDown(container.dispose);
      expect(
        (await container.readHeld(appearanceNotifierProvider)).mode,
        AppearanceMode.light,
      );
      await f.db
          .into(f.db.importReceipts)
          .insert(
            ImportReceiptsCompanion.insert(
              id: 'fictional-cache-restore',
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
      final service = RestorePreferencesService(
        database: f.db,
        preferences: f.preferences,
        effectsGate: SerialProjectionEffectsGate(),
      );
      await service.stage(
        id: 'fictional-cache-restore',
        receiptId: 'fictional-cache-restore',
        recoveryGeneration: 'fictional',
        before: portablePreferenceSnapshot(f.preferences),
        after: {
          SharedAppearancePreferenceStorage.key: jsonEncode(restored.toJson()),
        },
      );
      expect(await service.reconcile(), PreferenceRestoreState.complete);
      await container.read(refreshRestoredPreferenceCachesProvider)(f.context);
      final actual = await container.readHeld(appearanceNotifierProvider);
      expect(actual.mode, AppearanceMode.dark);
      expect(actual.lightColors, restored.lightColors);
      expect(actual.darkColors, restored.darkColors);
      await container
          .read(appearanceNotifierProvider.notifier)
          .change((value) => value.copyWith(highContrast: true));
      final persisted = AppearancePreferences.fromJson(
        jsonDecode(
              f.preferences.getString(SharedAppearancePreferenceStorage.key)!,
            )
            as Map<String, Object?>,
      );
      expect(persisted.highContrast, isTrue);
      expect(persisted.lightColors, restored.lightColors);
      expect(persisted.darkColors, restored.darkColors);
      expect(persisted.mode, AppearanceMode.dark);
    },
  );
}
