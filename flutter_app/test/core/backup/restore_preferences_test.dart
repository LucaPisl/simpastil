import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/backup/restore_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/storage/portable_preference_writer.dart';
import '../../helpers/protected_workspace_fixture.dart';

void main() {
  test(
    'ordinary user choice waits for restore and survives completion',
    () async {
      final f = await ProtectedWorkspaceFixture.create(
        initialPreferences: {'app_locale': 'en'},
      );
      addTearDown(f.db.close);
      final gate = SerialProjectionEffectsGate(),
          writer = PortablePreferenceWriter(f.preferences, gate: gate);
      Future<bool>? competing;
      final service = RestorePreferencesService(
        database: f.db,
        preferences: f.preferences,
        effectsGate: gate,
        writePreference: (key, value) async {
          competing = writer.write('app_locale', 'en');
          await Future<void>.delayed(Duration.zero);
          return f.preferences.setString(key, value as String);
        },
      );
      await f.db.transaction(() async {
        await f.db
            .into(f.db.importReceipts)
            .insert(
              ImportReceiptsCompanion.insert(
                id: 'fictional-concurrent',
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
        await service.stage(
          id: 'fictional-concurrent',
          receiptId: 'fictional-concurrent',
          recoveryGeneration: 'generation-fictional',
          before: portablePreferenceSnapshot(f.preferences),
          after: const {'app_locale': 'ro'},
        );
      });
      expect(await service.reconcile(), PreferenceRestoreState.complete);
      expect(await competing, isTrue);
      expect(f.preferences.getString('app_locale'), 'en');
      await writer.writeIfAbsent('app_locale', 'ro');
      expect(f.preferences.getString('app_locale'), 'en');
    },
  );
  Future<ProtectedWorkspaceFixture> target() =>
      ProtectedWorkspaceFixture.create(
        initialPreferences: {
          'app_locale': 'en',
          'app_font_size': 1.0,
          'server_url': 'https://fictional.test',
        },
      );
  Future<void> stage(
    ProtectedWorkspaceFixture f,
    RestorePreferencesService service,
  ) => f.db.transaction(() async {
    await f.db
        .into(f.db.importReceipts)
        .insert(
          ImportReceiptsCompanion.insert(
            id: 'fictional-receipt',
            workspaceId: f.context.workspaceId,
            sourceDigest: 'fictional',
            sourceDocumentId: 'fictional-source',
            sourceCapturedAt: DateTime.utc(2026, 10, 1),
            mode: 'full',
            selectedProfileIdsJson: '[]',
            identityMapJson: '{}',
            appliedAt: DateTime.utc(2026, 10, 1),
          ),
        );
    await service.stage(
      id: 'fictional-intent',
      receiptId: 'fictional-receipt',
      recoveryGeneration: 'generation-fictional',
      before: portablePreferenceSnapshot(f.preferences),
      after: const {'app_locale': 'ro', 'high_contrast_enabled': true},
    );
  });
  test(
    'failed preference write leaves care receipt and resumes checked remaining work after restart',
    () async {
      final f = await target();
      addTearDown(f.db.close);
      var writes = 0;
      final first = RestorePreferencesService(
        database: f.db,
        preferences: f.preferences,
        effectsGate: SerialProjectionEffectsGate(),
        writePreference: (key, value) async {
          if (++writes == 3) return false;
          if (value == null) return f.preferences.remove(key);
          return f.preferences.setString(key, value as String);
        },
      );
      await stage(f, first);
      expect(await first.reconcile(), PreferenceRestoreState.pending);
      expect(await f.db.select(f.db.importReceipts).get(), hasLength(1));
      expect(f.preferences.getString('app_locale'), 'ro');
      final next = RestorePreferencesService(
        database: f.db,
        preferences: f.preferences,
        effectsGate: SerialProjectionEffectsGate(),
      );
      expect(await next.reconcile(), PreferenceRestoreState.complete);
      expect(f.preferences.getString('app_locale'), 'ro');
      expect(f.preferences.containsKey('app_font_size'), isFalse);
      expect(f.preferences.getBool('high_contrast_enabled'), isTrue);
      expect(f.preferences.getString('server_url'), 'https://fictional.test');
      expect(
        (await f.db.select(f.db.deviceRestoreIntents).get()).single.state,
        'completed',
      );
      await f.preferences.setString('app_locale', 'en');
      expect(await next.reconcile(), PreferenceRestoreState.none);
      expect(f.preferences.getString('app_locale'), 'en');
    },
  );
  test(
    'changed preference requires renewed review without overwriting the change',
    () async {
      final f = await target();
      addTearDown(f.db.close);
      final service = RestorePreferencesService(
        database: f.db,
        preferences: f.preferences,
        effectsGate: SerialProjectionEffectsGate(),
      );
      await stage(f, service);
      await f.preferences.setDouble('app_font_size', 1.5);
      expect(await service.reconcile(), PreferenceRestoreState.needsReview);
      expect(f.preferences.getDouble('app_font_size'), 1.5);
      expect(f.preferences.getString('app_locale'), 'en');
      expect(
        (await f.db.select(f.db.deviceRestoreIntents).get()).single.state,
        'conflict',
      );
    },
  );
  test(
    'preference activation intent rolls back with the care transaction',
    () async {
      final f = await target();
      addTearDown(f.db.close);
      final service = RestorePreferencesService(
        database: f.db,
        preferences: f.preferences,
        effectsGate: SerialProjectionEffectsGate(),
      );
      await expectLater(
        f.db.transaction(() async {
          await stage(f, service);
          throw StateError('controlled commit failure');
        }),
        throwsStateError,
      );
      expect(await f.db.select(f.db.deviceRestoreIntents).get(), isEmpty);
      expect(await f.db.select(f.db.importReceipts).get(), isEmpty);
      expect(f.preferences.getString('app_locale'), 'en');
    },
  );
}
