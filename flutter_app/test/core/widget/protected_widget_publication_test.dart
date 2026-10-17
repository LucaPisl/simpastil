import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/projections/projection_identity.dart';
import 'package:simpastil/core/widget/protected_widget_publisher.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/storage/preference_keys.dart';
import 'package:simpastil/core/storage/appearance_preferences.dart';
import 'package:simpastil/core/widget/widget_snapshot.dart';

class _Platform implements WidgetProjectionPlatform {
  final values = <String, Object?>{};
  final writes = <String>[];
  int refreshes = 0;
  bool failNextRefresh = false;
  Completer<void>? refreshStarted;
  Completer<void>? refreshRelease;
  String? blockKey;
  Completer<void>? started;
  Completer<void>? release;
  @override
  Future<String?> read(String key) async => values[key] as String?;
  @override
  Future<void> save(String key, Object? value) async {
    if (key == blockKey) {
      blockKey = null;
      started!.complete();
      await release!.future;
    }
    writes.add(key);
    values[key] = value;
  }

  @override
  Future<void> refresh() async {
    refreshes++;
    if (failNextRefresh) {
      failNextRefresh = false;
      throw StateError('fictional native refresh interruption');
    }
    if (refreshStarted != null && !refreshStarted!.isCompleted) {
      refreshStarted!.complete();
      await refreshRelease!.future;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'late account A publication cannot invalidate account B widget',
    () async {
      SharedPreferences.setMockInitialValues({
        kCurrentUserIdKey: 'fictional-b',
        kActiveUserIdKey: 'fictional-b',
        kSessionGenerationKey: 9,
      });
      final db = AppDatabase.forTesting();
      addTearDown(db.close);
      final writes = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('home_widget'), (
            call,
          ) async {
            if (call.method == 'saveWidgetData') {
              writes.add((call.arguments as Map)['id'] as String);
            }
            return true;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(const MethodChannel('home_widget'), null),
      );
      await publishWidgetSnapshot(db: db, identity: ('fictional-a', 4));
      expect(
        writes,
        isEmpty,
        reason: 'A must be rejected before blanking B ownership markers',
      );
    },
  );
  group('protected widget effects', () {
    late AppDatabase db;
    late WorkspaceAccessRepository access;
    late SerialProjectionEffectsGate gate;
    late WorkspaceContext account;
    late WorkspaceContext local;
    late _Platform platform;
    var revision = 0;
    Future<WorkspaceContext> authenticate(String slot, int generation) async {
      const endpoint = 'https://fictional.test/care';
      await db
          .into(db.credentialSlots)
          .insert(
            CredentialSlotsCompanion.insert(
              id: slot,
              ownerId: 'fictional-a',
              endpoint: endpoint,
              state: 'staged',
              createdAt: DateTime.now(),
            ),
          );
      await access.authenticate(
        ownerId: 'fictional-a',
        endpoint: endpoint,
        expectedNetworkEpoch:
            (await access.workspaces.deviceState()).networkEpoch,
        sessionGeneration: generation,
        credentialId: slot,
      );
      return (await access.contextForOwner('fictional-a'))!;
    }

    Future<Map<String, dynamic>> build(WorkspaceContext context) =>
        access.withGrant(
          context,
          () async => {
            'projectionIdentity': ProjectionIdentity.fromContext(
              context,
            ).toJson(),
            'authenticated': true,
            'active_user_id': context.ownerUserId,
            'session_generation': context.accessEpoch,
            'day': '2026-09-30',
            'doses': [revision],
          },
        );
    ProtectedWidgetPublisher publisher() => ProtectedWidgetPublisher(
      access: access,
      effectsGate: gate,
      platform: platform,
      build: build,
    );
    setUp(() async {
      db = AppDatabase.forTesting();
      gate = SerialProjectionEffectsGate();
      access = WorkspaceAccessRepository(db, effectsGate: gate);
      local = await access.currentContext();
      await access.configureEndpoint('https://fictional.test/care');
      account = await authenticate('fictional-slot-1', 1);
      platform = _Platform();
      revision = 0;
    });
    tearDown(() => db.close());
    test('T11 widget appearance follows the durable Apply document', () async {
      SharedPreferences.setMockInitialValues({kAppThemeModeKey: 'dark'});
      final prefs = await SharedPreferences.getInstance();
      final appearance = AppearancePreferencesRepository(
        SharedAppearancePreferenceStorage(
          prefs,
          gate: SerialProjectionEffectsGate(),
        ),
      );
      expect((await appearance.load()).mode, AppearanceMode.dark);
      await appearance.save(AppearancePreferences(mode: AppearanceMode.light));
      await access.viewWorkspace(local);
      final identity = ProjectionIdentity.fromContext(local);
      await publishWidgetSnapshot(
        db: db,
        access: access,
        effectsGate: gate,
        projectionIdentity: identity,
        platform: platform,
      );
      expect(platform.values[kAppThemeModeKey], 'light');
      expect(prefs.getString(kAppThemeModeKey), 'dark');
      expect(
        identity.owns(
          (jsonDecode(platform.values[kTodayDosesKey] as String)
              as Map)['projectionIdentity'],
        ),
        true,
      );
    });
    test('T11 widget appearance retains legacy mode before Apply', () async {
      SharedPreferences.setMockInitialValues({kAppThemeModeKey: 'dark'});
      final prefs = await SharedPreferences.getInstance();
      await access.viewWorkspace(local);
      await publishWidgetSnapshot(
        db: db,
        access: access,
        effectsGate: gate,
        projectionIdentity: ProjectionIdentity.fromContext(local),
        platform: platform,
      );
      expect(platform.values[kAppThemeModeKey], 'dark');
      expect(prefs.getString(SharedAppearancePreferenceStorage.key), isNull);
    });
    test(
      'T11 widget appearance corruption preserves care publication and evidence',
      () async {
        SharedPreferences.setMockInitialValues({
          kAppThemeModeKey: 'dark',
          SharedAppearancePreferenceStorage.key: '{broken',
        });
        final prefs = await SharedPreferences.getInstance();
        await access.viewWorkspace(local);
        await publishWidgetSnapshot(
          db: db,
          access: access,
          effectsGate: gate,
          projectionIdentity: ProjectionIdentity.fromContext(local),
          platform: platform,
        );
        expect(platform.values[kAppThemeModeKey], 'system');
        expect(platform.values[kTodayDosesKey], isNotNull);
        expect(platform.refreshes, 1);
        expect(
          prefs.getString(SharedAppearancePreferenceStorage.key),
          '{broken',
        );
      },
    );
    test(
      'restart retries native clearing after retirement refresh fails',
      () async {
        await publisher().publish(ProjectionIdentity.fromContext(account));
        await access.revokeNetwork();
        platform.failNextRefresh = true;
        await expectLater(publisher().retireUnavailable(), throwsStateError);
        expect(platform.values[kTodayDosesKey], isNull);
        expect(platform.values[widgetProjectionIdentityKey], isNull);
        final refreshes = platform.refreshes;
        await publisher().retireUnavailable();
        expect(platform.refreshes, refreshes + 1);
        expect(platform.values[kTodayDosesKey], isNull);
      },
    );
    test(
      'retry of interrupted retirement refresh preserves a newer local body',
      () async {
        await publisher().publish(ProjectionIdentity.fromContext(account));
        await access.revokeNetwork();
        platform.failNextRefresh = true;
        await expectLater(publisher().retireUnavailable(), throwsStateError);
        await access.viewWorkspace(local);
        platform.failNextRefresh = true;
        final identity = ProjectionIdentity.fromContext(local);
        await expectLater(publisher().publish(identity), throwsStateError);
        final body = platform.values[kTodayDosesKey];
        final refreshes = platform.refreshes;
        await publisher().retireUnavailable();
        expect(platform.refreshes, refreshes + 1);
        expect(platform.values[kTodayDosesKey], body);
        expect(
          ProjectionIdentity.fromJson(
            jsonDecode(platform.values[widgetProjectionIdentityKey] as String),
          ),
          identity,
        );
      },
    );
    test(
      'restart sweeps revoked body but keeps an active local widget',
      () async {
        final identity = ProjectionIdentity.fromContext(account);
        await publisher().publish(identity);
        await access.revokeNetwork();
        await publisher().retireUnavailable();
        expect(platform.values[widgetProjectionIdentityKey], isNull);
        expect(platform.values[kTodayDosesKey], isNull);
        await access.viewWorkspace(local);
        final localIdentity = ProjectionIdentity.fromContext(local);
        await publisher().publish(localIdentity);
        final writes = platform.writes.length;
        await publisher().retireUnavailable();
        expect(platform.writes.length, writes);
        expect(
          ProjectionIdentity.fromJson(
            jsonDecode(platform.values[widgetProjectionIdentityKey] as String),
          ),
          localIdentity,
        );
      },
    );
    test(
      'restart finds an interrupted revoked widget publication in its body',
      () async {
        final identity = ProjectionIdentity.fromContext(account);
        platform.values[kTodayDosesKey] = jsonEncode(await build(account));
        await access.revokeNetwork();
        await publisher().retireUnavailable();
        expect(platform.values[kTodayDosesKey], isNull);
        expect(await identity.resolve(access), isNull);
      },
    );
    test(
      'restart preserves malformed, unknown and future widget ownership',
      () async {
        for (final marker in [
          '{',
          jsonEncode({'version': 3}),
          jsonEncode({
            ...ProjectionIdentity.fromContext(account).toJson(),
            'grantEpoch': account.accessEpoch + 1,
          }),
          jsonEncode({
            'version': 2,
            'workspaceId': 'missing',
            'userId': 'unknown',
            'grantEpoch': 1,
          }),
        ]) {
          platform.values[widgetProjectionIdentityKey] = marker;
          platform.values[kTodayDosesKey] = 'retained-body';
          final writes = platform.writes.length;
          await expectLater(
            publisher().retireUnavailable(),
            throwsFormatException,
          );
          expect(platform.values[widgetProjectionIdentityKey], marker);
          expect(platform.values[kTodayDosesKey], 'retained-body');
          expect(platform.writes.length, writes);
        }
      },
    );
    test(
      'publishes full grant marker and keeps established native keys',
      () async {
        final id = ProjectionIdentity.fromContext(account);
        await publisher().publish(id, themeMode: 'dark');
        expect(
          ProjectionIdentity.fromJson(
            jsonDecode(platform.values[widgetProjectionIdentityKey] as String),
          ),
          id,
        );
        expect(platform.values[kActiveUserIdKey], account.ownerUserId);
        expect(platform.values[kSessionGenerationKey], account.accessEpoch);
        expect(platform.values[kSnapshotDayKey], '2026-09-30');
        expect(platform.values[kAppThemeModeKey], 'dark');
        expect(platform.refreshes, 1);
      },
    );
    test(
      'revoked queued publication leaves independently published local widget intact',
      () async {
        final entered = Completer<void>();
        final release = Completer<void>();
        final blocking = gate.run(() async {
          entered.complete();
          await release.future;
        });
        await entered.future;
        final old = publisher().publish(
          ProjectionIdentity.fromContext(account),
        );
        await access.revokeNetwork();
        final localBody = jsonEncode(await build(local));
        final localMarker = jsonEncode(
          ProjectionIdentity.fromContext(local).toJson(),
        );
        platform.values.addAll({
          widgetProjectionIdentityKey: localMarker,
          kTodayDosesKey: localBody,
          kActiveUserIdKey: local.ownerUserId,
        });
        release.complete();
        await blocking;
        await old;
        expect(platform.writes, isEmpty);
        expect(platform.values[kTodayDosesKey], localBody);
      },
    );
    test('revocation during OS write clears only partial result', () async {
      platform.blockKey = kTodayDosesKey;
      platform.started = Completer<void>();
      platform.release = Completer<void>();
      final publishing = publisher().publish(
        ProjectionIdentity.fromContext(account),
      );
      await platform.started!.future;
      await access.revokeNetwork();
      platform.release!.complete();
      await publishing;
      expect(platform.values[widgetProjectionIdentityKey], isNull);
      expect(platform.values[kTodayDosesKey], isNull);
      expect(platform.values[kActiveUserIdKey], isNull);
    });
    test('care edit during OS write prevents stale publication', () async {
      platform.blockKey = kTodayDosesKey;
      platform.started = Completer<void>();
      platform.release = Completer<void>();
      final publishing = publisher().publish(
        ProjectionIdentity.fromContext(account),
      );
      await platform.started!.future;
      await access.withGrant(account, () async {
        revision++;
      });
      platform.release!.complete();
      await publishing;
      expect(platform.values[widgetProjectionIdentityKey], isNull);
      expect(platform.values[kTodayDosesKey], isNull);
    });
    test('late retire preserves a newer grant for the same account', () async {
      final old = ProjectionIdentity.fromContext(account);
      await access.revokeNetwork();
      final next = await authenticate('fictional-slot-2', 2);
      final nextId = ProjectionIdentity.fromContext(next);
      await publisher().publish(nextId);
      final content = platform.values[kTodayDosesKey];
      final writes = platform.writes.length;
      await publisher().retire(old);
      expect(platform.values[kTodayDosesKey], content);
      expect(platform.writes.length, writes);
    });
    test(
      'retire removes its interrupted body while preserving unrecognized ownership',
      () async {
        final id = ProjectionIdentity.fromContext(account);
        platform.values[kTodayDosesKey] = jsonEncode(await build(account));
        await access.revokeNetwork();
        await publisher().retire(id);
        expect(platform.values[kTodayDosesKey], isNull);
        platform.values[widgetProjectionIdentityKey] = '{"version":99}';
        platform.values[kTodayDosesKey] = 'retained-unrecognized';
        final writes = platform.writes.length;
        await publisher().retire(id);
        expect(platform.writes.length, writes);
        expect(platform.values[kTodayDosesKey], 'retained-unrecognized');
      },
    );
    test(
      'restored widget is removed if revoked during native refresh',
      () async {
        final id = ProjectionIdentity.fromContext(account);
        await publisher().publish(id);
        revision = 1;
        platform.blockKey = kTodayDosesKey;
        platform.started = Completer<void>();
        platform.release = Completer<void>();
        final publishing = publisher().publish(id);
        await platform.started!.future;
        revision = 0; // The previously published body is current again.
        platform.refreshStarted = Completer<void>();
        platform.refreshRelease = Completer<void>();
        platform.release!.complete();
        await platform.refreshStarted!.future;
        await access.revokeNetwork();
        platform.refreshRelease!.complete();
        await publishing;
        expect(platform.values[widgetProjectionIdentityKey], isNull);
        expect(platform.values[kTodayDosesKey], isNull);
      },
    );
    test('future marker is retained and refuses replacement', () async {
      platform.values[widgetProjectionIdentityKey] = '{"version":99}';
      await expectLater(
        publisher().publish(ProjectionIdentity.fromContext(account)),
        throwsFormatException,
      );
      expect(platform.writes, isEmpty);
      expect(platform.values[widgetProjectionIdentityKey], '{"version":99}');
    });
  });
}
