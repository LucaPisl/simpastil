import 'dart:convert';

import 'package:drift/drift.dart' show Value, InsertMode;
import 'package:uuid/uuid.dart';

import '../../l10n/app_localizations.dart';
import '../db/database.dart';
import '../projections/projection_command_id.dart';
import '../projections/projection_identity.dart';
import '../projections/projection_effects_gate.dart';
import '../projections/projection_registry.dart';
import '../projections/reminder_projection.dart';
import '../workspace/workspace_access_repository.dart';
import '../workspace/workspace_context.dart';

enum ReminderReadinessProblem {
  denied,
  exactUnavailable,
  platformUnavailable,
  schedulingFailed,
}

class ReminderPermissions {
  const ReminderPermissions({
    required this.notificationsAllowed,
    required this.exactAlarmsAllowed,
  });
  final bool? notificationsAllowed;
  final bool? exactAlarmsAllowed;
  bool get canSchedule =>
      notificationsAllowed == true && exactAlarmsAllowed == true;
  ReminderReadinessProblem? get problem =>
      notificationsAllowed == null || exactAlarmsAllowed == null
      ? ReminderReadinessProblem.platformUnavailable
      : notificationsAllowed == false
      ? ReminderReadinessProblem.denied
      : exactAlarmsAllowed == false
      ? ReminderReadinessProblem.exactUnavailable
      : null;
}

class ReminderTestFacts {
  const ReminderTestFacts({
    required this.testId,
    required this.readinessEpoch,
    required this.grantEpoch,
    required this.requestedAt,
    required this.permissions,
    required this.scheduled,
    required this.observed,
    this.problem,
  });
  final String testId;
  final int readinessEpoch;
  final int grantEpoch;
  final DateTime requestedAt;
  final ReminderPermissions permissions;
  final bool scheduled;
  final bool observed;
  final ReminderReadinessProblem? problem;
  Map<String, Object?> toJson() => {
    'version': 1,
    'testId': testId,
    'readinessEpoch': readinessEpoch,
    'grantEpoch': grantEpoch,
    'requestedAt': requestedAt.toUtc().toIso8601String(),
    'notificationsAllowed': permissions.notificationsAllowed,
    'exactAlarmsAllowed': permissions.exactAlarmsAllowed,
    'scheduled': scheduled,
    'observed': observed,
    'problem': problem?.name,
  };
  factory ReminderTestFacts.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1 ||
        json['testId'] is! String ||
        (json['testId'] as String).isEmpty ||
        json['readinessEpoch'] is! int ||
        json['grantEpoch'] is! int ||
        json['requestedAt'] is! String ||
        json['scheduled'] is! bool ||
        json['observed'] is! bool ||
        (json['notificationsAllowed'] != null &&
            json['notificationsAllowed'] is! bool) ||
        (json['exactAlarmsAllowed'] != null &&
            json['exactAlarmsAllowed'] is! bool)) {
      throw const FormatException('Unsupported reminder check');
    }
    return ReminderTestFacts(
      testId: json['testId'] as String,
      readinessEpoch: json['readinessEpoch'] as int,
      grantEpoch: json['grantEpoch'] as int,
      requestedAt: DateTime.parse(json['requestedAt'] as String),
      permissions: ReminderPermissions(
        notificationsAllowed: json['notificationsAllowed'] as bool?,
        exactAlarmsAllowed: json['exactAlarmsAllowed'] as bool?,
      ),
      scheduled: json['scheduled'] as bool,
      observed: json['observed'] as bool,
      problem: json['problem'] == null
          ? null
          : ReminderReadinessProblem.values.byName(json['problem'] as String),
    );
  }
  ReminderTestFacts outcome(
    ReminderPermissions permission, {
    required bool scheduled,
    bool observed = false,
    ReminderReadinessProblem? problem,
  }) => ReminderTestFacts(
    testId: testId,
    readinessEpoch: readinessEpoch,
    grantEpoch: grantEpoch,
    requestedAt: requestedAt,
    permissions: permission,
    scheduled: scheduled,
    observed: observed,
    problem: problem,
  );
}

class ReminderReadiness {
  const ReminderReadiness({required this.permissions, this.test});
  final ReminderPermissions permissions;
  final ReminderTestFacts? test;

  /// Native scheduling alone never proves the user saw a reminder.
  bool get deliveryConfirmed =>
      test?.scheduled == true && test?.observed == true;
}

class ReminderTestNotification {
  const ReminderTestNotification({
    required this.id,
    required this.testId,
    required this.scheduledAtUtc,
    required this.payload,
  });
  final int id;
  final String testId;
  final DateTime scheduledAtUtc;
  final String payload;
}

abstract interface class ReminderReadinessPlatform
    implements ReminderNotificationPlatform {
  Future<void> requestReminderAccess();
  Future<void> scheduleTest(
    ReminderTestNotification test, {
    required AppLocalizations localizations,
  });
}

class ReminderReadinessService {
  ReminderReadinessService({
    required this.database,
    required this.access,
    required this.context,
    required this.preferences,
    required this.platform,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;
  final AppDatabase database;
  final WorkspaceAccessRepository access;
  final WorkspaceContext context;
  final ProjectionRegistry preferences;
  final ReminderReadinessPlatform platform;
  final DateTime Function() _clock;
  Future<ReminderReadiness>? _inFlight;

  Future<DeviceReminderSetting> _settings() async {
    await database
        .into(database.deviceReminderSettings)
        .insert(
          DeviceReminderSettingsCompanion.insert(
            workspaceId: context.workspaceId,
          ),
          mode: InsertMode.insertOrIgnore,
        );
    return (database.select(
      database.deviceReminderSettings,
    )..where((row) => row.workspaceId.equals(context.workspaceId))).getSingle();
  }

  ReminderTestFacts? _test(DeviceReminderSetting row) {
    final raw = row.testJson;
    if (raw == null) return null;
    final test = ReminderTestFacts.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
    return test.readinessEpoch == row.readinessEpoch &&
            test.grantEpoch == context.accessEpoch
        ? test
        : null;
  }

  Future<ReminderPermissions> _permissions() async {
    await access.requireCurrent(context);
    ReminderPermissions result;
    try {
      result = ReminderPermissions(
        notificationsAllowed: await platform.hasNotificationPermission(),
        exactAlarmsAllowed: await platform.hasExactAlarmPermission(),
      );
    } on Object {
      result = const ReminderPermissions(
        notificationsAllowed: null,
        exactAlarmsAllowed: null,
      );
    }
    await access.requireCurrent(context);
    return result;
  }

  Future<ReminderReadiness> inspect() async {
    final test = await access.withGrant(
      context,
      () async => _test(await _settings()),
    );
    return ReminderReadiness(permissions: await _permissions(), test: test);
  }

  Future<ReminderReadiness> requestAccess() async {
    await access.requireCurrent(context);
    try {
      await platform.requestReminderAccess();
    } on Object {
      await access.requireCurrent(context);
      return const ReminderReadiness(
        permissions: ReminderPermissions(
          notificationsAllowed: null,
          exactAlarmsAllowed: null,
        ),
      );
    }
    return inspect();
  }

  Future<void> _save(ReminderTestFacts test) =>
      access.withGrant(context, () async {
        final row = await _settings();
        final current = _test(row);
        if (row.readinessEpoch != test.readinessEpoch ||
            test.grantEpoch != context.accessEpoch ||
            (current != null && current.testId != test.testId)) {
          throw StateError('Reminder check changed');
        }
        await (database.update(
          database.deviceReminderSettings,
        )..where((row) => row.workspaceId.equals(context.workspaceId))).write(
          DeviceReminderSettingsCompanion(
            testJson: Value(jsonEncode(test.toJson())),
          ),
        );
      });
  Future<ReminderReadiness> requestTest({
    required AppLocalizations localizations,
  }) {
    final running = _inFlight;
    if (running != null) return running;
    final future = _requestTest(localizations);
    _inFlight = future;
    future.then(
      (_) {
        if (identical(_inFlight, future)) _inFlight = null;
      },
      onError: (Object _, StackTrace _) {
        if (identical(_inFlight, future)) _inFlight = null;
      },
    );
    return future;
  }

  Future<ReminderReadiness> _requestTest(AppLocalizations localizations) async {
    final requested = await access.withGrant(context, () async {
      final row = await _settings();
      final test = ReminderTestFacts(
        testId: const Uuid().v4(),
        readinessEpoch: row.readinessEpoch,
        grantEpoch: context.accessEpoch,
        requestedAt: _clock().toUtc(),
        permissions: const ReminderPermissions(
          notificationsAllowed: null,
          exactAlarmsAllowed: null,
        ),
        scheduled: false,
        observed: false,
      );
      await (database.update(
        database.deviceReminderSettings,
      )..where((row) => row.workspaceId.equals(context.workspaceId))).write(
        DeviceReminderSettingsCompanion(
          testJson: Value(jsonEncode(test.toJson())),
        ),
      );
      return test;
    });
    final permission = await _permissions();
    var facts = requested.outcome(
      permission,
      scheduled: false,
      problem: permission.problem,
    );
    await _save(facts);
    if (!permission.canSchedule) {
      return ReminderReadiness(permissions: permission, test: facts);
    }
    final identity = ProjectionIdentity.fromContext(context);
    final projectionId = projectionCommandIdForKey(
      jsonEncode([
        'reminder-check',
        context.workspaceId,
        context.accessEpoch,
        requested.readinessEpoch,
        requested.testId,
      ]),
    );
    final id = notificationIdForProjection(projectionId);
    final payload = jsonEncode({
      ...identity.toJson(),
      'kind': 'readiness',
      'testId': requested.testId,
      'route': '/settings',
    });
    final entry = {
      ...identity.toJson(),
      'id': id,
      'projectionId': projectionId,
      'userId': context.ownerUserId,
      'sessionGeneration': context.accessEpoch,
      'kind': 'readiness',
      'testId': requested.testId,
    };
    await (access.effectsGate ?? privateProjectionEffectsGate).run(() async {
      await access.requireCurrent(context);
      await preferences.preferences.reload();
      final registry = preferences.read();
      final pending = await platform.pendingRequests();
      if (registry.containsKey(id) || pending.any((item) => item.id == id)) {
        throw StateError('Reminder check ID collision');
      }
      registry[id] = {
        ...entry,
        'publicationPending': true,
        'publicationPendingAt': DateTime.now().toUtc().toIso8601String(),
      };
      await preferences.persist(registry);
      try {
        await platform.scheduleTest(
          ReminderTestNotification(
            id: id,
            testId: requested.testId,
            scheduledAtUtc: _clock().toUtc().add(const Duration(seconds: 3)),
            payload: payload,
          ),
          localizations: localizations,
        );
        await access.requireCurrent(context);
        facts = requested.outcome(permission, scheduled: true);
        await _save(facts);
        registry[id] = entry;
        await preferences.persist(registry);
      } on Object catch (error) {
        try {
          await platform.cancel(id);
          registry.remove(id);
          await preferences.persist(registry);
        } on Object {
          /* Persisted publication intent is retried by retirement. */
        }
        if (error is WorkspaceAccessFailure) rethrow;
        facts = requested.outcome(
          permission,
          scheduled: false,
          problem: ReminderReadinessProblem.schedulingFailed,
        );
        await _save(facts);
      }
    });
    return ReminderReadiness(permissions: permission, test: facts);
  }

  Future<ReminderReadiness> confirmObserved(String testId) async {
    await access.withGrant(context, () async {
      final current = _test(await _settings());
      if (current == null || current.testId != testId || !current.scheduled) {
        throw StateError('No scheduled check to confirm');
      }
      await _save(
        current.outcome(current.permissions, scheduled: true, observed: true),
      );
    });
    return inspect();
  }

  /// Restore must invalidate device delivery evidence, even on the same phone.
  Future<void> invalidateAfterRestore() => access.withGrant(context, () async {
    final row = await _settings();
    await (database.update(
      database.deviceReminderSettings,
    )..where((row) => row.workspaceId.equals(context.workspaceId))).write(
      DeviceReminderSettingsCompanion(
        readinessEpoch: Value(row.readinessEpoch + 1),
        testJson: const Value(null),
      ),
    );
  });
}
