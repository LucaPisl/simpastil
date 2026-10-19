import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/database.dart';
import '../protection/access_gate.dart';
import '../protection/app_lock_controller.dart';
import '../inventory/inventory_service.dart';
import '../medication/medication_command.dart';
import '../medication/medication_repository.dart';
import '../notifications/notification_service.dart';
import '../projections/projection_command_id.dart';
import '../projections/projection_identity.dart';
import '../projections/projection_effects_gate.dart';
import '../workspace/workspace_access_repository.dart';
import '../workspace/workspace_context.dart';
import '../projections/projection_reconciler.dart';
import '../session/session_generation_repository.dart';
import '../startup/time_zone_data.dart';
import '../utils/app_logger.dart';
import 'widget_snapshot.dart';

class WidgetActionPayload {
  const WidgetActionPayload({
    required this.activeUserId,
    required this.sessionGeneration,
    required this.occurrenceId,
    required this.projectionId,
    required this.action,
    this.projectionIdentity,
    this.stateVersion,
  });

  final String activeUserId;
  final int sessionGeneration;
  final String occurrenceId;
  final String projectionId;
  final MedicationAction action;
  final ProjectionIdentity? projectionIdentity;
  final int? stateVersion;

  SessionIdentity get identity => (activeUserId, sessionGeneration);
}

WidgetActionPayload? parseWidgetActionUri(Uri? uri) {
  if (uri == null ||
      uri.scheme != 'simpastil' ||
      !const {'take', 'skip'}.contains(uri.host) ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort ||
      uri.path.isNotEmpty ||
      uri.hasFragment) {
    return null;
  }
  final parameters = uri.queryParametersAll;
  final isProtected = parameters['version']?.singleOrNull == '2';
  final expectedKeys = {
    'active_user_id',
    'session_generation',
    'occurrenceId',
    'projectionId',
    if (isProtected) ...{
      'version',
      'workspaceId',
      'grantEpoch',
      'stateVersion',
    },
  };
  if (parameters.keys.toSet().difference(expectedKeys).isNotEmpty ||
      parameters.keys.toSet().length != expectedKeys.length ||
      parameters.values.any((values) => values.length != 1)) {
    return null;
  }
  final userId = parameters['active_user_id']!.single;
  final generationValue = parameters['session_generation']!.single;
  final generation = int.tryParse(generationValue);
  final occurrenceId = parameters['occurrenceId']!.single;
  final projectionId = parameters['projectionId']!.single;
  if (userId.isEmpty ||
      generation == null ||
      generation < 0 ||
      generationValue != generation.toString() ||
      occurrenceId.isEmpty ||
      projectionId.isEmpty) {
    return null;
  }
  ProjectionIdentity? identity;
  int? stateVersion;
  if (isProtected) {
    final stateText = parameters['stateVersion']!.single;
    stateVersion = int.tryParse(stateText);
    if (stateVersion == null ||
        stateVersion < 0 ||
        stateVersion.toString() != stateText) {
      return null;
    }
    final epochText = parameters['grantEpoch']!.single;
    final epoch = int.tryParse(epochText);
    if (epoch == null ||
        epoch < 1 ||
        epoch.toString() != epochText ||
        epoch != generation) {
      return null;
    }
    identity = ProjectionIdentity(
      workspaceId: parameters['workspaceId']!.single,
      ownerId: userId,
      grantEpoch: epoch,
    );
    if (identity.workspaceId.isEmpty) return null;
  }
  return WidgetActionPayload(
    activeUserId: userId,
    sessionGeneration: generation,
    occurrenceId: occurrenceId,
    projectionId: projectionId,
    action: uri.host == 'take' ? MedicationAction.take : MedicationAction.skip,
    projectionIdentity: identity,
    stateVersion: stateVersion,
  );
}

bool widgetProjectionMatchesAction(WidgetActionPayload payload) =>
    payload.projectionId ==
    widgetProjectionId(
      userId: payload.activeUserId,
      sessionGeneration: payload.sessionGeneration,
      occurrenceId: payload.occurrenceId,
      workspaceId: payload.projectionIdentity?.workspaceId,
      grantEpoch: payload.projectionIdentity?.grantEpoch,
      stateVersion: payload.stateVersion,
    );

bool widgetActionIsCurrent(
  WidgetActionPayload payload,
  SessionIdentity? activeIdentity,
) =>
    payload.identity == activeIdentity &&
    widgetProjectionMatchesAction(payload);

/// Validates a widget request before the locked app opens dose review. The
/// Take/Skip URI selects context only; it never authorizes recording here.
Future<String?> validateWidgetActionForReview(
  Uri uri, {
  required AppDatabase db,
  required WorkspaceAccessRepository access,
}) async {
  ensureTimeZoneData();
  final payload = parseWidgetActionUri(uri);
  final projection = payload?.projectionIdentity;
  final stateVersion = payload?.stateVersion;
  if (payload == null ||
      !widgetProjectionMatchesAction(payload) ||
      projection == null ||
      stateVersion == null) {
    return null;
  }

  try {
    final context = await projection.resolve(access);
    if (context == null ||
        context.ownerUserId != payload.activeUserId ||
        context.accessEpoch != payload.sessionGeneration) {
      return null;
    }
    final current =
        await MedicationRepository(
          db,
          access: access,
          context: context,
        ).isCurrentWidgetActionForReview(
          occurrenceId: payload.occurrenceId,
          projectionId: payload.projectionId,
          deliveredStateVersion: stateVersion,
        );
    if (!current) return null;
    await access.requireCurrent(context);
    return payload.occurrenceId;
  } on WorkspaceAccessFailure {
    return null;
  }
}

/// Entry point for widget taps routed through home_widget's background
/// broadcast receiver. Runs without Riverpod.
@pragma('vm:entry-point')
Future<void> widgetBackgroundCallback(Uri? uri) async {
  if (uri == null) return;
  WidgetsFlutterBinding.ensureInitialized();
  await handleWidgetAction(uri);
}

/// Dispatches a widget action URI. The background path reopens the local DB;
/// tests may inject an in-memory database.
Future<void> handleWidgetAction(
  Uri uri, {
  AppDatabase? db,
  WorkspaceAccessRepository? access,
  AccessGate? accessGate,
}) async {
  if (uri.scheme != 'simpastil') return;
  ensureTimeZoneData();
  if (uri.host == 'refresh') {
    if (uri.queryParametersAll.isEmpty && !uri.hasFragment) {
      await publishWidgetSnapshot(db: db);
    }
    return;
  }

  final payload = parseWidgetActionUri(uri);
  if (payload == null || !widgetProjectionMatchesAction(payload)) return;
  final projection = payload.projectionIdentity;
  if (projection == null) return; // Legacy displays cannot grant care access.
  final ownDb = db == null;
  final database = db ?? AppDatabase();
  try {
    final protectedAccess =
        access ??
        WorkspaceAccessRepository(
          database,
          effectsGate: privateProjectionEffectsGate,
        );
    final context = await projection.resolve(protectedAccess);
    if (context == null) return;
    final prefs = await SharedPreferences.getInstance();
    final headlessGate =
        accessGate ??
        AccessGate(AppLockPolicyStore(SharedAppLockPolicyStorage(prefs)));
    Pill? committedStock;
    final inventory = InventoryService(
      database,
      access: protectedAccess,
      context: context,
    );
    final repository = MedicationRepository(
      database,
      access: protectedAccess,
      context: context,
      onStockChanged: (pill) async => committedStock = pill,
    );
    await headlessGate.runHeadless(
      () => repository.applyDeviceAction(
        occurrenceId: payload.occurrenceId,
        projectionId: payload.projectionId,
        kind: 'widget',
        deliveredStateVersion: payload.stateVersion,
        action: payload.action,
      ),
    );
    if (committedStock != null) {
      await inventory.notifyPillStockChanged(committedStock!);
    }
    await protectedAccess.requireCurrent(context);
    await publishWidgetSnapshot(
      db: database,
      access: protectedAccess,
      projectionIdentity: projection,
    );
    await _reconcileReminders(
      db: database,
      prefs: prefs,
      generations: SessionGenerationRepository(prefs, access: protectedAccess),
      identity: projection,
    );
  } on Object catch (error) {
    AppLogger.warning(
      'WidgetAction',
      'Occurrence action unavailable: ${error.runtimeType}',
    );
  } finally {
    if (ownDb) {
      try {
        await database.close();
      } catch (_) {
        // A failed open rethrows from close(); preserve the snapshot contract.
      }
    }
  }
}

Future<void> _reconcileReminders({
  required AppDatabase db,
  required SharedPreferences prefs,
  required SessionGenerationRepository generations,
  required ProjectionIdentity identity,
}) async {
  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
  );
  await ProjectionReconciler(
    database: db,
    preferences: prefs,
    generations: generations,
    platform: NotificationService(plugin),
    platformKind: ProjectionReconciler.currentPlatformKind,
  ).reconcile(projectionIdentity: identity);
}
