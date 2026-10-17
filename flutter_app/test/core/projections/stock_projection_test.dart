import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/inventory/inventory_service.dart';
import 'package:simpastil/core/projections/projection_command_id.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/projections/projection_identity.dart';
import 'package:simpastil/core/projections/projection_reconciler.dart';
import 'package:simpastil/core/projections/projection_registry.dart';
import 'package:simpastil/core/notifications/reminder_copy.dart';
import 'package:simpastil/core/projections/reminder_projection.dart';
import 'package:simpastil/core/session/session_generation_repository.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import 'package:simpastil/l10n/app_localizations.dart';

class _Platform
    implements StockNotificationPlatform, ReminderNotificationPlatform {
  final pending = <int, PlatformReminderRequest>{};
  final shown = <String>[];
  ReminderCopy? lastCopy;
  final cancelled = <int>[];
  Completer<void>? showStarted;
  Completer<void>? showGate;
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> hasNotificationPermission() async => true;
  @override
  Future<bool> hasExactAlarmPermission() async => true;
  @override
  Future<List<PlatformReminderRequest>> pendingRequests() async =>
      pending.values.toList();
  @override
  Future<void> show({
    required int id,
    required ReminderCopy copy,
    required String payload,
  }) async {
    final pillId = (jsonDecode(payload) as Map)['pillId'] as String;
    lastCopy = copy;
    if (showStarted != null && !showStarted!.isCompleted) {
      showStarted!.complete();
    }
    await showGate?.future;
    shown.add(pillId);
    pending[id] = PlatformReminderRequest(
      id: id,
      title: 'Stock',
      body: 'Care',
      payload: payload,
    );
  }

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
    pending.remove(id);
  }

  @override
  Future<void> cancelAll() async {
    cancelled.addAll(pending.keys);
    pending.clear();
  }

  @override
  Future<void> schedule(
    ReminderProjection reminder, {
    required AppLocalizations localizations,
  }) async {
    pending[reminder.notificationId] = PlatformReminderRequest(
      id: reminder.notificationId,
      title: reminder.title,
      body: reminder.body,
      payload: reminder.payload,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late WorkspaceAccessRepository access;
  late WorkspaceContext account;
  late WorkspaceContext local;
  late SharedPreferences prefs;
  late _Platform platform;
  const endpoint = 'https://fictional.test/care';

  Future<WorkspaceContext> authenticate(String slot, int generation) async {
    await db
        .into(db.credentialSlots)
        .insert(
          CredentialSlotsCompanion.insert(
            id: slot,
            ownerId: 'fictional-account',
            endpoint: endpoint,
            state: 'staged',
            createdAt: DateTime.now(),
          ),
        );
    await access.authenticate(
      ownerId: 'fictional-account',
      endpoint: endpoint,
      expectedNetworkEpoch:
          (await access.workspaces.deviceState()).networkEpoch,
      sessionGeneration: generation,
      credentialId: slot,
    );
    return (await access.contextForOwner('fictional-account'))!;
  }

  InventoryService service(WorkspaceContext context) => InventoryService(
    db,
    access: access,
    context: context,
    platform: platform,
    preferences: prefs,
  );
  Future<Pill> pill(String id) async => (await db.pillsDao.getById(id))!;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting();
    access = WorkspaceAccessRepository(
      db,
      effectsGate: SerialProjectionEffectsGate(),
    );
    await access.configureEndpoint(endpoint);
    account = await authenticate('fictional-slot-a', 1);
    final workspace = await access.workspaces.ensureLocal();
    local = (await access.contextForOwner(workspace.ownerUserId))!;
    platform = _Platform();
    final now = DateTime.now();
    for (final item in [('account', account), ('local', local)]) {
      await db.profilesDao.upsert(
        ProfilesCompanion.insert(
          id: '${item.$1}-person',
          userId: item.$2.ownerUserId,
          name: 'Fictional person',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await db.pillsDao.upsert(
        PillsCompanion.insert(
          id: '${item.$1}-pill',
          profileId: '${item.$1}-person',
          name: 'Fictional medication',
          currentStock: const Value(3),
          lowStockThreshold: const Value(5),
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
  });
  tearDown(() => db.close());

  test(
    'stock scans and hints are confined to the captured workspace',
    () async {
      await service(account).checkAllPillsStock();
      expect(platform.shown, ['account-pill']);
      await expectLater(
        service(account).notifyPillStockChanged(await pill('local-pill')),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
      expect(
        prefs.getBool(
          InventoryService.firedKey(local.workspaceId, 'local-pill'),
        ),
        isNull,
      );
    },
  );

  test(
    'separate services suppress duplicate alerts during the same threshold cycle',
    () async {
      final hint = await pill('account-pill');
      await Future.wait([
        service(account).notifyPillStockChanged(hint),
        service(account).notifyPillStockChanged(hint),
      ]);
      expect(platform.shown, ['account-pill']);
      expect(ProjectionRegistry(prefs).read(), hasLength(1));
      expect(
        prefs.getBool(InventoryService.firedKey(account.workspaceId, hint.id)),
        isTrue,
      );
    },
  );

  test(
    'revocation during notification display removes its stale result and preserves local alerts',
    () async {
      await service(local).notifyPillStockChanged(await pill('local-pill'));
      final localId = platform.pending.keys.single;
      platform.showStarted = Completer<void>();
      platform.showGate = Completer<void>();
      final run = service(
        account,
      ).notifyPillStockChanged(await pill('account-pill'));
      final assertion = expectLater(
        run,
        throwsA(isA<WorkspaceAccessFailure>()),
      );
      await platform.showStarted!.future;
      try {
        await access.revokeNetwork().timeout(const Duration(seconds: 1));
      } finally {
        platform.showGate!.complete();
      }
      await assertion;
      expect(platform.pending.keys, [localId]);
      expect(
        prefs.getBool(
          InventoryService.firedKey(account.workspaceId, 'account-pill'),
        ),
        isNull,
      );
      expect(
        ProjectionRegistry(prefs).read().values.single['userId'],
        local.ownerUserId,
      );
    },
  );

  test(
    'refill clears the owned alert and a subsequent threshold crossing fires once',
    () async {
      final inventory = service(account);
      await inventory.notifyPillStockChanged(await pill('account-pill'));
      await db.customUpdate(
        "UPDATE pills SET current_stock=9 WHERE id='account-pill'",
        updates: {db.pills},
      );
      await inventory.clearFiredIfAboveThreshold('account-pill');
      expect(platform.pending, isEmpty);
      expect(
        prefs.getBool(
          InventoryService.firedKey(account.workspaceId, 'account-pill'),
        ),
        isNull,
      );
      await db.customUpdate(
        "UPDATE pills SET current_stock=3 WHERE id='account-pill'",
        updates: {db.pills},
      );
      await inventory.notifyPillStockChanged(await pill('account-pill'));
      await inventory.notifyPillStockChanged(await pill('account-pill'));
      expect(platform.shown, ['account-pill', 'account-pill']);
    },
  );

  test(
    'retirement preserves local stock alerts and login does not invent a threshold crossing',
    () async {
      await service(account).notifyPillStockChanged(await pill('account-pill'));
      await service(local).notifyPillStockChanged(await pill('local-pill'));
      final retired = ProjectionIdentity.fromContext(account);
      await access.revokeNetwork();
      final reconciler = ProjectionReconciler(
        database: db,
        preferences: prefs,
        generations: SessionGenerationRepository(prefs, access: access),
        platform: platform,
        platformKind: ReminderPlatformKind.android,
      );
      await reconciler.retire(retired);
      expect(platform.pending, hasLength(1));
      expect(
        ProjectionIdentity.fromJson(
          jsonDecode(platform.pending.values.single.payload!),
        ),
        ProjectionIdentity.fromContext(local),
      );
      final restored = await authenticate('fictional-slot-restored', 2);
      await service(
        restored,
      ).notifyPillStockChanged(await pill('account-pill'));
      expect(platform.shown.where((id) => id == 'account-pill'), hasLength(1));
      expect(
        prefs.getBool(
          InventoryService.firedKey(account.workspaceId, 'account-pill'),
        ),
        isTrue,
      );
    },
  );

  test(
    'an ID reserved by another notification kind cannot be overwritten',
    () async {
      final projectionId = projectionCommandIdForKey(
        jsonEncode([
          2,
          account.workspaceId,
          account.accessEpoch,
          account.ownerUserId,
          'account-pill',
          'lowStock',
        ]),
      );
      final id = notificationIdForProjection(projectionId);
      final foreign = <String, Object?>{
        'id': id,
        'kind': 'reminder',
        ...ProjectionIdentity.fromContext(local).toJson(),
        'sessionGeneration': local.accessEpoch,
        'occurrenceId': 'fictional-local-occurrence',
        'projectionId': 'fictional-local-reservation',
      };
      await ProjectionRegistry(prefs).persist({id: foreign});
      platform.pending[id] = PlatformReminderRequest(
        id: id,
        title: 'Local',
        body: 'Care',
        payload: jsonEncode(foreign),
      );
      await expectLater(
        service(account).notifyPillStockChanged(await pill('account-pill')),
        throwsStateError,
      );
      expect(platform.shown, isEmpty);
      expect(ProjectionRegistry(prefs).read()[id], foreign);
      expect(platform.cancelled, isEmpty);
    },
  );

  test(
    'a refill during display cannot leave an obsolete low-stock alert',
    () async {
      platform.showStarted = Completer<void>();
      platform.showGate = Completer<void>();
      final run = service(
        account,
      ).notifyPillStockChanged(await pill('account-pill'));
      await platform.showStarted!.future;
      try {
        await db.customUpdate(
          "UPDATE pills SET current_stock=9 WHERE id='account-pill'",
          updates: {db.pills},
        );
      } finally {
        platform.showGate!.complete();
      }
      await run;
      expect(platform.pending, isEmpty);
      expect(ProjectionRegistry(prefs).read(), isEmpty);
      expect(
        prefs.getBool(
          InventoryService.firedKey(account.workspaceId, 'account-pill'),
        ),
        isNull,
      );
    },
  );
}
