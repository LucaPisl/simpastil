import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart';

import '../../core/db/database.dart';
import '../../core/projections/projection_reconciler.dart';
import '../../core/projections/projection_identity.dart';
import '../../core/sync/pending_operation_repository.dart';
import '../../core/workspace/workspace_provider.dart';
import '../../core/workspace/workspace_context.dart';
import '../../core/workspace/workspace_access_repository.dart';
import 'profile_repository.dart';

// ── ProfileWithCount ──────────────────────────────────────────────────────────

/// A profile combined with its local non-deleted pill count.
typedef ProfileWithCount = ({Profile profile, int pillCount});

// ── currentUserIdProvider ─────────────────────────────────────────────────────

/// Compatibility principal for existing care APIs. Local use has no network
/// login; authorization comes from the protected workspace capability.
final currentUserIdProvider = Provider<String>((ref) {
  return _readyContext(ref.watch(workspaceContextProvider)).ownerUserId;
});

WorkspaceContext _readyContext(AsyncValue<WorkspaceContext> available) {
  if (available.hasError) {
    Error.throwWithStackTrace(available.error!, available.stackTrace!);
  }
  if (available.isLoading || available.asData == null) {
    throw const WorkspaceAccessFailure(WorkspaceAccessFailureCode.unavailable);
  }
  return available.asData!.value;
}

bool _sameContext(WorkspaceContext a, WorkspaceContext b) => a == b;

Future<bool> _ownsSelectionCompletion({
  required ProviderContainer container,
  required bool Function() ownsNotifier,
  required WorkspaceAccessRepository access,
  required WorkspaceContext context,
  required String? profileId,
}) async {
  bool current() =>
      ownsNotifier() &&
      _sameContext(
        _readyContext(container.read(workspaceContextProvider)),
        context,
      );
  try {
    if (!current()) return false;
    final matching = await access.withGrant(
      context,
      () async =>
          (await access.workspaces.byId(
            context.workspaceId,
          ))?.selectedProfileId ==
          profileId,
    );
    return matching && current();
  } on Object {
    // The durable selection already committed. Unavailable/disposed display
    // state cannot publish an old person or turn that save into a failure.
    return false;
  }
}

// ── profileListProvider ───────────────────────────────────────────────────────

/// Streams protected profile membership without depending on pill-count
/// changes. Selection providers use this so a medication edit does not briefly
/// invalidate the selected person while the count aggregate refreshes.
final profileMembershipProvider = StreamProvider<List<Profile>>((ref) async* {
  final contextFuture = ref.watch(workspaceContextProvider.future);
  final db = ref.watch(databaseProvider);
  final access = ref.watch(workspaceAccessRepositoryProvider);
  final context = await contextFuture;
  final query = db.select(db.profiles)
    ..where(
      (profile) =>
          profile.userId.equals(context.ownerUserId) &
          profile.isDeleted.equals(false),
    )
    ..orderBy([(profile) => OrderingTerm.asc(profile.name)]);
  // A foreground database refresh also rereads unchanged membership. Publishing
  // an equal list would restart selected-person providers and dispose Today’s
  // card/form state. Authorization is still checked on every reread, and a new
  // workspace context creates a new stream (including same-owner grant changes).
  List<Profile>? previous;
  yield* query
      .watch()
      .asyncMap((_) => access.withGrant(context, query.get))
      .transform(
        StreamTransformer<List<Profile>, List<Profile>>.fromHandlers(
          handleData: (profiles, sink) {
            if (!listEquals(previous, profiles)) {
              previous = profiles;
              sink.add(profiles);
            }
          },
          handleError: (error, stack, sink) {
            // Recovery must publish even when the rows match the last success.
            previous = null;
            sink.addError(error, stack);
          },
        ),
      );
});

/// Streams all non-deleted profiles for the current user and their local pill
/// counts in one grouped query. Both tables participate in invalidation.
final profileListProvider = StreamProvider<List<ProfileWithCount>>((
  ref,
) async* {
  final contextFuture = ref.watch(workspaceContextProvider.future);
  final db = ref.watch(databaseProvider);
  final access = ref.watch(workspaceAccessRepositoryProvider);
  final context = await contextFuture;
  final pillCount = db.pills.id.count();
  final query =
      db.select(db.profiles).join([
          leftOuterJoin(
            db.pills,
            db.pills.profileId.equalsExp(db.profiles.id) &
                db.pills.isDeleted.equals(false),
          ),
        ])
        ..addColumns([pillCount])
        ..where(
          db.profiles.userId.equals(context.ownerUserId) &
              db.profiles.isDeleted.equals(false),
        )
        ..groupBy([db.profiles.id])
        ..orderBy([OrderingTerm.asc(db.profiles.name)]);
  yield* query.watch().asyncMap(
    (_) => access.withGrant(context, () async {
      final rows = await query.get();
      return [
        for (final row in rows)
          (
            profile: row.readTable(db.profiles),
            pillCount: row.read(pillCount) ?? 0,
          ),
      ];
    }),
  );
});

/// When THIS PHONE first knew each non-deleted person (profile id -> instant).
///
/// Device-local and never synced. History uses it to tell a day this phone
/// never saw from a day with nothing planned. Callers convert the instant to a
/// local calendar day.
final personFirstSeenProvider = StreamProvider<Map<String, DateTime>>((
  ref,
) async* {
  final contextFuture = ref.watch(workspaceContextProvider.future);
  final db = ref.watch(databaseProvider);
  final access = ref.watch(workspaceAccessRepositoryProvider);
  final context = await contextFuture;
  final query =
      db.select(db.profiles).join([
        innerJoin(
          db.personFirstSeen,
          db.personFirstSeen.profileId.equalsExp(db.profiles.id),
        ),
      ])..where(
        db.profiles.userId.equals(context.ownerUserId) &
            db.profiles.isDeleted.equals(false),
      );
  yield* query.watch().asyncMap(
    (_) => access.withGrant(context, () async {
      final rows = await query.get();
      return {
        for (final row in rows)
          row.readTable(db.profiles).id: row
              .readTable(db.personFirstSeen)
              .firstSeenAt,
      };
    }),
  );
});

/// Snapshot of currently enabled profiles (`isActive == true`).
final enabledProfilesProvider = Provider<List<ProfileWithCount>>((ref) {
  final profiles = ref.watch(profileListProvider).value ?? const [];
  return profiles.where((p) => p.profile.isActive).toList(growable: false);
});

/// IDs of currently enabled profiles.
final enabledProfileIdsProvider = Provider<List<String>>((ref) {
  final enabled = ref.watch(enabledProfilesProvider);
  return enabled.map((p) => p.profile.id).toList(growable: false);
});

// ── selectedProfileIdProvider ─────────────────────────────────────────────────

/// The profile ID currently selected as editing focus for profile-scoped views.
///
/// Stored in the protected workspace; old preferences are adopted once after
/// membership verification. Null together with viewEveryone means Everyone.
class SelectedProfileNotifier extends AsyncNotifier<String?> {
  int _selectionEpoch = 0;
  @override
  Future<String?> build() async {
    final selectionFuture = ref.watch(
      protectedWorkspaceSelectionProvider.future,
    );
    final profilesFuture = ref.watch(profileMembershipProvider.future);
    final selection = await selectionFuture;
    final profiles = await profilesFuture;
    final selected = selection.viewEveryone
        ? null
        : selection.selectedProfileId;
    return profiles.any((person) => person.id == selected) ? selected : null;
  }

  Future<void> select(String? profileId) async {
    final container = ref.container;
    final epoch = ++_selectionEpoch;
    final context = _readyContext(ref.read(workspaceContextProvider));
    final access = ref.read(workspaceAccessRepositoryProvider);
    await access.viewPerson(context, profileId, everyone: profileId == null);
    if (await _ownsSelectionCompletion(
      container: container,
      ownsNotifier: () =>
          identical(container.read(selectedProfileIdProvider.notifier), this) &&
          epoch == _selectionEpoch,
      access: access,
      context: context,
      profileId: profileId,
    )) {
      state = AsyncData(profileId);
    }
  }
}

final selectedProfileIdProvider =
    AsyncNotifierProvider<SelectedProfileNotifier, String?>(
      SelectedProfileNotifier.new,
    );

// ── primaryProfileIdProvider ─────────────────────────────────────────────────

/// The profile used for dashboard greeting and default context.
///
/// Uses the same protected person selection as other care views.
class PrimaryProfileNotifier extends AsyncNotifier<String?> {
  int _selectionEpoch = 0;
  @override
  Future<String?> build() async {
    final selectedFuture = ref.watch(selectedProfileIdProvider.future);
    final profilesFuture = ref.watch(profileMembershipProvider.future);
    final selected = await selectedFuture;
    final profiles = await profilesFuture;
    if (profiles.any((person) => person.id == selected)) {
      return selected;
    }
    return profiles.firstOrNull?.id;
  }

  Future<void> setPrimary(String? profileId) async {
    final container = ref.container;
    final epoch = ++_selectionEpoch;
    final context = _readyContext(ref.read(workspaceContextProvider));
    final access = ref.read(workspaceAccessRepositoryProvider);
    final selection = ref.read(selectedProfileIdProvider.notifier);
    await selection.select(profileId);
    if (await _ownsSelectionCompletion(
      container: container,
      ownsNotifier: () =>
          identical(container.read(primaryProfileIdProvider.notifier), this) &&
          epoch == _selectionEpoch,
      access: access,
      context: context,
      profileId: profileId,
    )) {
      state = AsyncData(profileId);
    }
  }
}

final primaryProfileIdProvider =
    AsyncNotifierProvider<PrimaryProfileNotifier, String?>(
      PrimaryProfileNotifier.new,
    );

/// Resolved primary profile display name.
final primaryProfileNameProvider = Provider<String?>((ref) {
  final primaryId = ref.watch(primaryProfileIdProvider).value;
  final profiles = ref.watch(profileListProvider).value ?? const [];
  if (profiles.isEmpty) return null;

  if (primaryId != null) {
    for (final p in profiles) {
      if (p.profile.id == primaryId) return p.profile.name;
    }
  }

  for (final p in profiles) {
    if (p.profile.isActive) return p.profile.name;
  }
  return profiles.first.profile.name;
});

// ── pillsForProfileProvider ───────────────────────────────────────────────────

/// Streams all non-deleted pills (with their schedules) for a given profile ID,
/// ordered by name. Used by the pills overview bottom sheet.
final pillsForProfileProvider =
    StreamProvider.family<
      List<({Pill pill, List<Schedule> schedules})>,
      String
    >((ref, profileId) async* {
      final contextFuture = ref.watch(workspaceContextProvider.future);
      final db = ref.watch(databaseProvider);
      final access = ref.watch(workspaceAccessRepositoryProvider);
      final context = await contextFuture;
      await access.withGrant(context, () async {}, profileId: profileId);
      yield* db.pillsDao
          .watchWithSchedulesByProfileIds([profileId])
          .asyncMap(
            (_) => access.withGrant(
              context,
              () => db.pillsDao.getWithSchedulesByProfileIds([profileId]),
              profileId: profileId,
            ),
          );
    });

// ── pillCountByProfileProvider ────────────────────────────────────────────────

/// Reactively streams the non-deleted pill count for a given profile ID.
final pillCountByProfileProvider = StreamProvider.family<int, String>((
  ref,
  profileId,
) async* {
  final contextFuture = ref.watch(workspaceContextProvider.future);
  final db = ref.watch(databaseProvider);
  final access = ref.watch(workspaceAccessRepositoryProvider);
  final context = await contextFuture;
  await access.withGrant(context, () async {}, profileId: profileId);
  yield* db.pillsDao
      .watchCountByProfileId(profileId)
      .asyncMap(
        (_) => access.withGrant(
          context,
          () => db.pillsDao.countByProfileId(profileId),
          profileId: profileId,
        ),
      );
});

// ── profileRepositoryProvider ─────────────────────────────────────────────────

final profileRepositoryProvider = Provider<ProfileRepository>((ref) {
  final context = ref.watch(workspaceContextProvider).requireValue;
  final identity = ProjectionIdentity.fromContext(context);
  final reconciler = ref.read(projectionReconcilerProvider);
  return ProfileRepositoryImpl(
    dao: ref.watch(databaseProvider).profilesDao,
    pendingOperations: ref.watch(pendingOperationRepositoryProvider),
    userId: ref.watch(currentUserIdProvider),
    context: context,
    access: ref.watch(workspaceAccessRepositoryProvider),
    reconcileProjections: () async {
      await reconciler.reconcile(projectionIdentity: identity);
    },
  );
});
