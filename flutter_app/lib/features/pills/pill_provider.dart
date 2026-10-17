import '../../core/storage/portable_preference_writer.dart';
import 'package:collection/collection.dart'; // for firstWhereOrNull
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/db/database.dart';
import '../../core/projections/projection_reconciler.dart';
import '../../core/projections/projection_identity.dart';
import '../../core/storage/preference_keys.dart';
import '../../core/sync/pending_operation_repository.dart';
import '../../core/workspace/workspace_access_repository.dart';
import '../../core/workspace/workspace_context.dart';
import '../../core/workspace/workspace_provider.dart';
import '../profiles/profile_provider.dart';
import 'pill_repository.dart';

// ── PillWithSchedules ─────────────────────────────────────────────────────────

/// A pill combined with a snapshot of its non-deleted schedules.
typedef PillWithSchedules = ({Pill pill, List<Schedule> schedules});

// ── pillsWithSchedulesProvider ────────────────────────────────────────────────

/// Streams all non-deleted pills (with their schedules) for the currently-
/// selected profile.  Returns an empty list when no profile is selected.
///
/// The pill list reacts to DB changes. Schedule data is re-fetched on each
/// pill-list emission (point-in-time snapshot per pill list change).
final pillsWithSchedulesProvider = StreamProvider<List<PillWithSchedules>>((
  ref,
) async* {
  final profileFuture = ref.watch(selectedProfileIdProvider.future);
  final contextFuture = ref.watch(workspaceContextProvider.future);
  final db = ref.watch(databaseProvider);
  final access = ref.watch(workspaceAccessRepositoryProvider);
  final context = await contextFuture;
  final profileId = await profileFuture;
  if (profileId == null) {
    await access.requireCurrent(context);
    yield const <PillWithSchedules>[];
    return;
  }
  yield* _watchCarePills(db, access, context, [profileId]);
});

/// Streams pills+schedules for every currently enabled profile.
///
/// Used by dashboard/schedules so active profile toggles immediately affect
/// what is displayed.
final enabledPillsWithSchedulesProvider =
    StreamProvider<List<PillWithSchedules>>((ref) async* {
      final profileIds = ref.watch(enabledProfileIdsProvider);
      final contextFuture = ref.watch(workspaceContextProvider.future);
      final access = ref.watch(workspaceAccessRepositoryProvider);
      final db = ref.watch(databaseProvider);
      final context = await contextFuture;
      if (profileIds.isEmpty) {
        await access.requireCurrent(context);
        yield const <PillWithSchedules>[];
        return;
      }
      yield* _watchCarePills(db, access, context, profileIds);
    });

Stream<List<PillWithSchedules>> _watchCarePills(
  AppDatabase db,
  WorkspaceAccessRepository access,
  WorkspaceContext context,
  List<String> profileIds,
) => db.pillsDao
    .watchWithSchedulesByProfileIds(profileIds)
    .asyncMap(
      (_) => access.withGrant(context, () async {
        for (final profileId in profileIds) {
          await access.requireCurrent(context, profileId: profileId);
        }
        return db.pillsDao.getWithSchedulesByProfileIds(profileIds);
      }),
    );

// ── pillRepositoryProvider ────────────────────────────────────────────────────

final pillRepositoryProvider = Provider<PillRepository>((ref) {
  final db = ref.watch(databaseProvider);
  final context = ref.watch(workspaceContextProvider).requireValue;
  final identity = ProjectionIdentity.fromContext(context);
  final reconciler = ref.read(projectionReconcilerProvider);
  return PillRepositoryImpl(
    db: db,
    dao: db.pillsDao,
    profilesDao: db.profilesDao,
    schedulesDao: db.schedulesDao,
    pendingOperations: ref.watch(pendingOperationRepositoryProvider),
    reconcileProjections: () async {
      await reconciler.reconcile(projectionIdentity: identity);
    },
  );
});

// ── PropagableField ───────────────────────────────────────────────────────────

/// The fields on a [Pill] that can be propagated to sibling pills on edit.
enum PropagableField { name, dosage, notes, color }

// ── SiblingDetectionMode ──────────────────────────────────────────────────────

/// Controls how the edit sheet detects sibling pills (copies of the same
/// medication in other profiles).
enum SiblingDetectionMode {
  /// Sibling if LOWER(name) and dosage both match. Default.
  nameAndDosage,

  /// Sibling if LOWER(name) matches (dosage ignored).
  nameOnly,

  /// No auto-detection — always show the full profile multi-select in edit mode.
  perPill,
}

// ── siblingDetectionModeProvider ─────────────────────────────────────────────

class SiblingDetectionNotifier extends Notifier<SiblingDetectionMode> {
  static const _kDefault = SiblingDetectionMode.nameAndDosage;
  static String _key(String userId) => 'sibling_detection_mode_$userId';

  @override
  SiblingDetectionMode build() {
    final userId = ref.watch(currentUserIdProvider);
    // Guard against disposal before the async load completes.
    var mounted = true;
    ref.onDispose(() => mounted = false);
    // Load persisted value asynchronously; default is used until it resolves.
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      final stored = prefs.getString(_key(userId));
      if (stored == null) return;
      final parsed = SiblingDetectionMode.values.firstWhereOrNull(
        (m) => m.name == stored,
      );
      if (parsed != null && state != parsed) state = parsed;
    });
    return _kDefault;
  }

  Future<void> setMode(SiblingDetectionMode mode) async {
    state = mode;
    final userId = ref.read(currentUserIdProvider);
    final prefs = await SharedPreferences.getInstance();
    await PortablePreferenceWriter(
      prefs,
      gate: ref.read(portablePreferenceGateProvider),
    ).write(_key(userId), mode.name);
  }
}

final siblingDetectionModeProvider =
    NotifierProvider<SiblingDetectionNotifier, SiblingDetectionMode>(
      SiblingDetectionNotifier.new,
    );

// ── PrnInStatsNotifier ──────────────────────────────────────────────────────

class PrnInStatsNotifier extends Notifier<bool> {
  @override
  bool build() {
    final userId = ref.watch(currentUserIdProvider);
    var mounted = true;
    ref.onDispose(() => mounted = false);
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      final stored = prefs.getBool(prnInStatsPreferenceKey(userId));
      if (stored != null && state != stored) state = stored;
    });
    return false;
  }

  Future<void> toggle(bool value) async {
    state = value;
    final userId = ref.read(currentUserIdProvider);
    final prefs = await SharedPreferences.getInstance();
    await PortablePreferenceWriter(
      prefs,
      gate: ref.read(portablePreferenceGateProvider),
    ).write(prnInStatsPreferenceKey(userId), value);
  }
}

final prnInStatsProvider = NotifierProvider<PrnInStatsNotifier, bool>(
  PrnInStatsNotifier.new,
);

// ── PrnInWidgetNotifier ─────────────────────────────────────────────────────

class PrnInWidgetNotifier extends Notifier<bool> {
  @override
  bool build() {
    final userId = ref.watch(currentUserIdProvider);
    var mounted = true;
    ref.onDispose(() => mounted = false);
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      final stored = prefs.getBool(prnInWidgetPreferenceKey(userId));
      if (stored != null && state != stored) state = stored;
    });
    return false;
  }

  Future<void> toggle(bool value) async {
    state = value;
    final userId = ref.read(currentUserIdProvider);
    final prefs = await SharedPreferences.getInstance();
    await PortablePreferenceWriter(
      prefs,
      gate: ref.read(portablePreferenceGateProvider),
    ).write(prnInWidgetPreferenceKey(userId), value);
  }
}

final prnInWidgetProvider = NotifierProvider<PrnInWidgetNotifier, bool>(
  PrnInWidgetNotifier.new,
);
