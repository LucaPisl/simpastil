import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:ui' show Locale;

import 'package:drift/drift.dart' show BooleanExpressionOperators, Variable;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/database.dart';
import 'stock_reading.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/app_localizations_en.dart';
import '../notifications/notification_plugin.dart';
import '../notifications/reminder_copy.dart';
import '../notifications/reminder_preferences.dart';
import '../notifications/notification_service.dart';
import '../projections/projection_command_id.dart';
import '../projections/projection_effects_gate.dart';
import '../projections/projection_identity.dart';
import '../projections/projection_registry.dart';
import '../projections/reminder_projection.dart';
import '../utils/app_logger.dart';
import '../workspace/workspace_access_repository.dart';
import '../workspace/workspace_context.dart';

abstract interface class StockNotificationPlatform {
  Future<void> initialize();
  Future<List<PlatformReminderRequest>> pendingRequests();
  Future<void> show({
    required int id,
    required ReminderCopy copy,
    required String payload,
  });
  Future<void> cancel(int id);
}

class NativeStockNotificationPlatform implements StockNotificationPlatform {
  NotificationService? _notificationsInstance;
  NotificationService get _notifications =>
      _notificationsInstance ??= NotificationService();
  @override
  Future<void> initialize() => _notifications.initialize();
  @override
  Future<List<PlatformReminderRequest>> pendingRequests() =>
      _notifications.pendingRequests();
  @override
  Future<void> cancel(int id) => _notifications.cancel(id);
  @override
  Future<void> show({
    required int id,
    required ReminderCopy copy,
    required String payload,
  }) => notificationsPlugin.show(
    id: id,
    title: copy.title,
    body: copy.body,
    notificationDetails: const NotificationDetails(
      android: AndroidNotificationDetails(
        'low_stock_reminders',
        'Low Stock Alerts',
        channelDescription: 'Alerts when a pill is running low on stock',
        importance: Importance.high,
        priority: Priority.high,
        playSound: true,
        icon: reminderSmallIcon,
        color: reminderAccent,
        visibility: NotificationVisibility.private,
      ),
    ),
    payload: payload,
  );
}

/// A stock scan captures one protected workspace when this service is created.
/// Mutation callers pass their already captured context. UI startup scans may
/// deliberately capture the currently viewed workspace, never every account.
class InventoryService {
  InventoryService(
    this._db, {
    WorkspaceAccessRepository? access,
    WorkspaceContext? context,
    ProjectionEffectsGate? effectsGate,
    StockNotificationPlatform? platform,
    SharedPreferences? preferences,
  }) : _access =
           access ??
           WorkspaceAccessRepository(
             _db,
             effectsGate: privateProjectionEffectsGate,
           ),
       _platform = platform ?? NativeStockNotificationPlatform(),
       _preferences = preferences {
    _context = context == null
        ? _access.currentContext()
        : Future.value(context);
    _gate = effectsGate ?? _access.effectsGate ?? privateProjectionEffectsGate;
  }

  final AppDatabase _db;
  final WorkspaceAccessRepository _access;
  final StockNotificationPlatform _platform;
  final SharedPreferences? _preferences;
  late final Future<WorkspaceContext> _context;
  late final ProjectionEffectsGate _gate;

  static String firedKey(String workspaceId, String pillId) =>
      'low_stock_fired_v2.$workspaceId.$pillId';

  Future<Pill?> _readPill(WorkspaceContext context, String id) =>
      _access.withGrant(context, () async {
        final pill = await _db.pillsDao.getById(id);
        if (pill == null) return null;
        await _access.workspaces.requirePerson(
          context.ownerUserId,
          pill.profileId,
        );
        return pill;
      });

  Future<ReviewedStockBalance?> _readBalance(
    WorkspaceContext context,
    String pillId,
  ) => _access.withGrant(
    context,
    () =>
        (_db.select(_db.reviewedStockBalances)..where(
              (b) =>
                  b.workspaceId.equals(context.workspaceId) &
                  b.pillId.equals(pillId),
            ))
            .getSingleOrNull(),
  );

  Future<void> notifyPillStockChanged(Pill hint) async {
    final context = await _context;
    await _checkPill(context, hint.id);
  }

  Future<void> checkAllPillsStock() async {
    try {
      final context = await _context;
      final pills = await _access.withGrant(context, () async {
        final rows = await _db
            .customSelect(
              'SELECT p.* FROM pills p JOIN profiles r ON r.id=p.profile_id WHERE r.user_id=? AND r.is_deleted=0 AND p.is_deleted=0',
              variables: [Variable<String>(context.ownerUserId)],
              readsFrom: {_db.pills, _db.profiles},
            )
            .get();
        return rows.map((row) => _db.pills.map(row.data)).toList();
      });
      for (final pill in pills) {
        await _checkPill(context, pill.id);
      }
    } on Object catch (error) {
      AppLogger.warning(
        'InventoryService',
        'Stock alert scan unavailable: ${error.runtimeType}',
      );
    }
  }

  Future<void> clearFiredIfAboveThreshold(String pillId) async {
    final context = await _context;
    await _checkPill(context, pillId, allowShow: false);
  }

  Future<void> _checkPill(
    WorkspaceContext context,
    String pillId, {
    bool allowShow = true,
  }) => _gate.run(() async {
    final prefs = _preferences ?? await SharedPreferences.getInstance();
    await prefs.reload();
    final pill = await _readPill(context, pillId);
    if (pill == null || pill.isDeleted || pill.lowStockThreshold == null) {
      return;
    }
    // The same count every screen shows: the balance doses lower first.
    final detail = await (_db.select(
      _db.medicationDetails,
    )..where((d) => d.pillId.equals(pill.id))).getSingleOrNull();
    final stock = readStock(
      pill,
      await _readBalance(context, pill.id),
      amountPerUse: amountOfDetailRow(detail),
    )?.whole;
    if (stock == null) return;
    final identity = ProjectionIdentity.fromContext(context);
    final registryStore = ProjectionRegistry(prefs);
    final registry = registryStore.read();
    final fired = firedKey(context.workspaceId, pill.id);
    if (stock > pill.lowStockThreshold!) {
      // A refill resets the threshold cycle independently of login epoch.
      await _access.requireCurrent(context);
      final saved = await prefs.remove(fired);
      if (!saved && prefs.containsKey(fired)) {
        throw StateError('Could not reset stock alert cycle');
      }
      final legacyKey = 'low_stock_fired_${pill.id}';
      final legacyRemoved = await prefs.remove(legacyKey);
      if (!legacyRemoved && prefs.containsKey(legacyKey)) {
        throw StateError('Could not reset retained stock alert cycle');
      }
      await _platform.initialize();
      final pending = {
        for (final item in await _platform.pendingRequests()) item.id: item,
      };
      for (final entry in registry.entries.toList()) {
        if (entry.value['kind'] != 'lowStock' ||
            entry.value['pillId'] != pill.id ||
            !identity.owns(entry.value)) {
          continue;
        }
        await _access.requireCurrent(context);
        final actual = pending[entry.key];
        if (actual == null ||
            _payloadProjectionId(actual.payload) ==
                entry.value['projectionId']) {
          await _platform.cancel(entry.key);
        }
        registry.remove(entry.key);
        await registryStore.persist(registry);
      }
      return;
    }
    if (!allowShow || prefs.getBool(fired) == true) return;
    // This proven pill's old suppression hint grants no care authority.
    if (prefs.getBool('low_stock_fired_${pill.id}') == true) {
      if (!await prefs.setBool(fired, true)) {
        throw StateError('Could not retain stock alert cycle');
      }
      return;
    }
    final projectionId = projectionCommandIdForKey(
      jsonEncode([
        2,
        context.workspaceId,
        context.accessEpoch,
        context.ownerUserId,
        pill.id,
        'lowStock',
      ]),
    );
    final id = notificationIdForProjection(projectionId);
    final entry = <String, Object?>{
      'id': id,
      'kind': 'lowStock',
      ...identity.toJson(),
      'pillId': pill.id,
      'projectionId': projectionId,
      'sessionGeneration': context.accessEpoch,
    };
    await _platform.initialize();
    final pending = {
      for (final item in await _platform.pendingRequests()) item.id: item,
    };
    if ((registry[id] != null &&
            registry[id]!['projectionId'] != projectionId) ||
        (pending[id] != null &&
            _payloadProjectionId(pending[id]!.payload) != projectionId)) {
      throw StateError('Notification projection ID collision');
    }
    if (await _readPill(context, pill.id) != pill) return;
    registry[id] = {
      ...entry,
      'publicationPending': true,
      'publicationPendingAt': DateTime.now().toUtc().toIso8601String(),
    };
    await registryStore.persist(registry);
    final fullDetails = (await ReminderPreferencesRepository(
      database: _db,
      access: _access,
      context: context,
    ).load()).fullDetails;
    final copy = lowStockReminderCopy(
      await _localizations(prefs),
      fullDetails: fullDetails,
      pillName: pill.name,
      dosesLeft: stock,
    );
    await _platform.show(id: id, copy: copy, payload: jsonEncode(entry));
    Pill? after;
    try {
      after = await _readPill(context, pill.id);
    } on WorkspaceAccessFailure {
      await _platform.cancel(id);
      registry.remove(id);
      await registryStore.persist(registry);
      rethrow;
    }
    if (after != pill) {
      await _platform.cancel(id);
      registry.remove(id);
      await registryStore.persist(registry);
      return;
    }
    registry[id] = entry;
    await registryStore.persist(registry);
    if (!await prefs.setBool(fired, true)) {
      throw StateError('Could not persist stock alert cycle');
    }
  });

  Future<AppLocalizations> _localizations(SharedPreferences prefs) async {
    final code = prefs.getString('app_locale');
    final locale = code == null || code.isEmpty
        ? Locale(Platform.localeName.split('_').first)
        : Locale(code);
    try {
      return lookupAppLocalizations(locale);
    } on Object {
      // Unsupported locales fall back to English.
      return AppLocalizationsEn();
    }
  }

  String? _payloadProjectionId(String? raw) {
    if (raw == null) return null;
    try {
      final value = jsonDecode(raw);
      return value is Map && value['projectionId'] is String
          ? value['projectionId'] as String
          : null;
    } on FormatException {
      return null;
    }
  }
}
