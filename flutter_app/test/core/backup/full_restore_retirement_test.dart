import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simpastil/core/backup/backup_providers.dart';
import 'package:simpastil/core/backup/backup_file_access.dart';
import 'package:simpastil/core/backup/backup_service.dart';
import 'package:simpastil/core/backup/import_service.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/projections/projection_identity.dart';
import 'package:simpastil/core/projections/projection_reconciler.dart';
import 'package:simpastil/core/projections/reminder_projection.dart';
import 'package:simpastil/core/session/session_generation_repository.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:simpastil/core/storage/preference_keys.dart';
import 'package:simpastil/core/widget/protected_widget_publisher.dart';

import '../../helpers/protected_restore_fixture.dart';
import '../../helpers/protected_workspace_fixture.dart';

class _Widget implements WidgetProjectionPlatform {
  final values = <String, Object?>{};
  bool failRefresh = false;
  @override
  Future<String?> read(String key) async => values[key] as String?;
  @override
  Future<void> save(String key, Object? value) async {
    values[key] = value;
  }

  @override
  Future<void> refresh() async {
    if (failRefresh) throw StateError('Controlled widget refresh failure');
  }
}

class _Notifications implements ReminderNotificationPlatform {
  final pending = <int, PlatformReminderRequest>{};
  final cancelled = <int>[];
  final scheduled = <ReminderProjection>[];
  @override
  Future<bool> hasNotificationPermission() async => true;
  @override
  Future<bool> hasExactAlarmPermission() async => true;
  @override
  Future<void> initialize() async {}
  @override
  Future<List<PlatformReminderRequest>> pendingRequests() async =>
      pending.values.toList();
  @override
  Future<void> schedule(
    ReminderProjection value, {
    required AppLocalizations localizations,
  }) async {
    scheduled.add(value);
  }

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
    pending.remove(id);
  }

  @override
  Future<void> cancelAll() async {
    pending.clear();
  }
}

void main() {
  setUp(tz.initializeTimeZones);
  test(
    'replacement retires removed workspace current and older effects across another replacement',
    () async {
      final f = await ProtectedRestoreFixture.create();
      addTearDown(f.close);
      final target = f.workspace;
      final old = await ProtectedWorkspaceFixture.create(
        ownerId: 'fictional-retired-account',
        database: target.db,
        preferences: target.preferences,
        accessFactory: (_) => target.access,
      );
      final older = ProjectionIdentity.fromContext(old.context);
      await target.access.revokeNetwork();
      final renewed = await ProtectedWorkspaceFixture.create(
        ownerId: old.context.ownerUserId,
        database: target.db,
        preferences: target.preferences,
        accessFactory: (_) => target.access,
      );
      final current = ProjectionIdentity.fromContext(renewed.context);
      expect(current.grantEpoch, greaterThan(older.grantEpoch));
      final source = await ProtectedWorkspaceFixture.create();
      addTearDown(source.db.close);
      Future<CheckedBackup> checked() async => CheckedBackup(
        (await BackupService(
          database: source.db,
          access: source.access,
          preferences: source.preferences,
          files: const AndroidBackupFileAccess(),
        ).captureFull()).document,
        const BackupFileLocation('fictional', 'Care.simpbak'),
        DateTime.utc(2026, 10, 1),
        passwordProtected: true,
      );
      final service = f.service();
      await service.apply(
        await service.preview(await checked(), const ImportSelection.full()),
      );
      expect(await target.access.workspaces.byId(current.workspaceId), isNull);
      expect(await current.resolve(target.access), isNull);
      expect(await current.retirementRequired(target.access), isTrue);
      expect(await older.retirementRequired(target.access), isTrue);
      await expectLater(
        const ProjectionIdentity(
          workspaceId: 'fictional-unrelated',
          ownerId: 'fictional-retired-account',
          grantEpoch: 1,
        ).retirementRequired(target.access),
        throwsFormatException,
      );
      final fresh = await target.access.currentContext();
      final freshIdentity = ProjectionIdentity.fromContext(fresh);
      expect(await freshIdentity.retirementRequired(target.access), isFalse);

      final widget = _Widget();
      widget.values[widgetProjectionIdentityKey] = jsonEncode(older.toJson());
      widget.values[kTodayDosesKey] = jsonEncode({
        'projectionIdentity': older.toJson(),
        'day': '2026-10-01',
        'doses': [],
      });
      final publisher = ProtectedWidgetPublisher(
        access: target.access,
        effectsGate: SerialProjectionEffectsGate(),
        platform: widget,
        build: (context) async => {
          'projectionIdentity': ProjectionIdentity.fromContext(
            context,
          ).toJson(),
          'day': '2026-10-01',
          'doses': [],
        },
      );
      await publisher.retireUnavailable();
      expect(widget.values[widgetProjectionIdentityKey], isNull);
      await publisher.publish(freshIdentity);
      final validBody = widget.values[kTodayDosesKey];
      await publisher.retireUnavailable();
      expect(widget.values[kTodayDosesKey], validBody);
      expect(
        ProjectionIdentity.fromJson(
          jsonDecode(widget.values[widgetProjectionIdentityKey] as String),
        ),
        freshIdentity,
      );

      await source.preferences.setString('app_locale', 'ro');
      final next = f.service(context: fresh);
      await next.apply(
        await next.preview(await checked(), const ImportSelection.full()),
      );
      expect(await current.retirementRequired(target.access), isTrue);
      expect(await older.retirementRequired(target.access), isTrue);
      expect(await current.resolve(target.access), isNull);
      final notifications = _Notifications();
      notifications.pending[55] = PlatformReminderRequest(
        id: 55,
        title: 'Fictional previous reminder',
        body: 'Fictional previous care',
        payload: jsonEncode(older.toJson()),
      );
      widget.failRefresh = true;
      final gate = SerialProjectionEffectsGate();
      final container = ProviderContainer(
        overrides: [
          ...target.overrides,
          backupProjectionEffectsGateProvider.overrideWithValue(gate),
          backupWidgetPlatformProvider.overrideWithValue(widget),
          projectionReconcilerProvider.overrideWithValue(
            ProjectionReconciler(
              database: target.db,
              preferences: target.preferences,
              generations: SessionGenerationRepository(
                target.preferences,
                access: target.access,
              ),
              platform: notifications,
              platformKind: ReminderPlatformKind.android,
              effectsGate: gate,
              clock: () => DateTime.utc(2026, 10, 1),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final retry = container.read(retryRestoreProjectionsProvider);
      expect(await retry(), isFalse);
      expect(
        (await target.db.select(target.db.deviceRestoreIntents).get())
            .single
            .projectionsCompleted,
        isFalse,
      );
      expect(await older.retirementRequired(target.access), isTrue);
      widget.failRefresh = false;
      expect(await retry(), isTrue);
      expect(notifications.cancelled, [55]);
      expect(notifications.scheduled, isEmpty);
      expect(
        (await target.db.select(target.db.deviceRestoreIntents).get())
            .single
            .projectionsCompleted,
        isTrue,
      );
      expect(await current.resolve(target.access), isNull);
    },
  );
}
