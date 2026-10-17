import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:drift/drift.dart' show Value;
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/errors/app_error.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import 'package:simpastil/core/workspace/workspace_provider.dart';
import 'package:simpastil/features/profiles/profile_provider.dart';
import 'package:simpastil/features/profiles/profile_repository.dart';
import '../../helpers/protected_workspace_fixture.dart';

// ── Fakes ─────────────────────────────────────────────────────────────────────

class FakeProfileRepository implements ProfileRepository {
  Result<Profile>? createResult;
  Result<Profile>? updateResult;
  Result<void>? toggleResult;
  Result<void>? deviceRemindersResult;
  Result<bool>? deviceRemindersEnabledResult;
  Result<void>? deleteResult;

  @override
  Future<Result<Profile>> create(String name, String avatarEmoji) async =>
      createResult ?? const Err(UnknownError('createResult not set'));

  @override
  Future<Result<Profile>> update(
    String localId,
    String name,
    String avatarEmoji,
  ) async => updateResult ?? const Err(UnknownError('updateResult not set'));

  @override
  Future<Result<void>> toggleActive(String localId, bool isActive) async =>
      toggleResult ?? const Err(UnknownError('toggleResult not set'));

  @override
  Future<Result<void>> setDeviceRemindersEnabled(
    String profileId,
    bool enabled,
  ) async =>
      deviceRemindersResult ??
      const Err(UnknownError('deviceRemindersResult not set'));

  @override
  Future<Result<bool>> getDeviceRemindersEnabled(String profileId) async =>
      deviceRemindersEnabledResult ??
      const Err(UnknownError('deviceRemindersEnabledResult not set'));

  @override
  Future<Result<void>> delete(String localId) async =>
      deleteResult ?? const Err(UnknownError('deleteResult not set'));
}

class _FailingMembershipRead extends WorkspaceAccessRepository {
  _FailingMembershipRead(super.database);
  bool failRead = false;

  @override
  Future<T> withGrant<T>(
    WorkspaceContext context,
    Future<T> Function() action, {
    String? profileId,
  }) {
    if (failRead) return Future.error(StateError('Synthetic read failure'));
    return super.withGrant(context, action, profileId: profileId);
  }
}

// ── Helper ────────────────────────────────────────────────────────────────────

Future<ProviderContainer> _makeContainer({
  String? userId,
  FakeProfileRepository? fakeRepo,
  AppDatabase? database,
}) async {
  final fixture = await ProtectedWorkspaceFixture.create(
    ownerId: userId,
    database: database,
  );
  if (database == null) addTearDown(fixture.db.close);
  final now = DateTime.now().toUtc();
  for (final id in ['profile-xyz', 'some-id', 'p-persist']) {
    await fixture.db.profilesDao.upsert(
      ProfilesCompanion.insert(
        id: id,
        userId: fixture.context.ownerUserId,
        name: 'Fictional person $id',
        createdAt: now,
        updatedAt: now,
      ),
    );
  }
  final container = await fixture.createContainer(
    extraOverrides: [
      if (fakeRepo != null)
        profileRepositoryProvider.overrideWithValue(fakeRepo),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  test(
    'membership recovers identical data after a guarded read error',
    () async {
      final db = AppDatabase.forTesting();
      addTearDown(db.close);
      final access = _FailingMembershipRead(db);
      final context = await access.currentContext();
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          workspaceAccessRepositoryProvider.overrideWithValue(access),
          workspaceContextProvider.overrideWith((_) => Stream.value(context)),
        ],
      );
      addTearDown(container.dispose);
      final failed = Completer<void>();
      final recovered = Completer<void>();
      final subscription = container.listen(profileMembershipProvider, (
        _,
        value,
      ) {
        if (value.hasError && !failed.isCompleted) failed.complete();
        if (failed.isCompleted &&
            value.asData != null &&
            !recovered.isCompleted) {
          recovered.complete();
        }
      });
      addTearDown(subscription.close);
      expect(await container.read(profileMembershipProvider.future), isEmpty);
      access.failRead = true;
      db.refreshExternalChanges();
      await failed.future.timeout(const Duration(seconds: 2));
      access.failRead = false;
      db.refreshExternalChanges();
      await recovered.future.timeout(const Duration(seconds: 2));
      expect(container.read(profileMembershipProvider).requireValue, isEmpty);
    },
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // ── personFirstSeenProvider ───────────────────────────────────────────────

  group('personFirstSeenProvider', () {
    test(
      'maps the owner\'s non-deleted people to their first-seen instant',
      () async {
        final container = await _makeContainer();
        final db = container.read(databaseProvider);
        final context = container.read(workspaceContextProvider).requireValue;

        await db.customStatement(
          'UPDATE person_first_seen SET first_seen_at = 1760000000 '
          "WHERE profile_id = 'profile-xyz'",
        );
        await db.profilesDao.softDelete('some-id');
        // Another account's person on this device is never exposed.
        await db.usersDao.upsert(
          UsersCompanion.insert(
            id: 'other-owner',
            email: 'other@example.test',
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
        await db.profilesDao.upsert(
          ProfilesCompanion.insert(
            id: 'foreign-person',
            userId: 'other-owner',
            name: 'Fictional stranger',
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        final seen = await container.read(personFirstSeenProvider.future);
        expect(seen.keys.toSet(), {'profile-xyz', 'p-persist'});
        expect(
          seen['profile-xyz'],
          DateTime.fromMillisecondsSinceEpoch(1760000000 * 1000),
        );
        expect(context.ownerUserId, isNot('other-owner'));
      },
    );
  });

  // ── currentUserIdProvider ─────────────────────────────────────────────────

  group('currentUserIdProvider', () {
    test('returns ownerId from the current protected account grant', () async {
      final container = await _makeContainer(userId: 'user-abc');

      expect(container.read(currentUserIdProvider), 'user-abc');
    });

    test(
      'standalone care supplies its local bridge without authentication',
      () async {
        final container = await _makeContainer();
        expect(container.read(currentUserIdProvider), startsWith('local:'));
      },
    );

    test(
      'retained previous owner is unavailable until context refresh finishes',
      () async {
        final container = await _makeContainer();
        final owner = container.read(currentUserIdProvider);
        final refreshing = container.refresh(workspaceContextProvider);
        expect(refreshing.hasValue, isTrue);
        expect(refreshing.isLoading, isTrue);
        expect(
          () => container.read(currentUserIdProvider),
          throwsA(isA<WorkspaceAccessFailure>()),
        );
        await container.read(workspaceContextProvider.future);
        expect(container.read(currentUserIdProvider), owner);
      },
    );

    test(
      'preserves protected unavailability instead of inventing an owner',
      () async {
        final container = await _makeContainer();
        final context = container.read(workspaceContextProvider).requireValue;
        final db = container.read(databaseProvider);
        await (db.update(db.workspaceGrants)
              ..where((row) => row.workspaceId.equals(context.workspaceId)))
            .write(const WorkspaceGrantsCompanion(isGranted: Value(false)));
        await expectLater(
          container.refresh(workspaceContextProvider.future),
          throwsA(isA<WorkspaceAccessFailure>()),
        );

        expect(
          () => container.read(currentUserIdProvider),
          throwsA(isA<WorkspaceAccessFailure>()),
        );
        expect(
          (await db.select(db.workspaceGrants).get()).single.isGranted,
          isFalse,
        );
        expect(
          (await db.select(db.careWorkspaces).get()).single.currentAuthorId,
          context.authorId,
        );
        expect(
          await db.profilesDao.getByUserId(context.ownerUserId),
          hasLength(3),
        );
      },
    );
  });

  // ── selectedProfileIdProvider ─────────────────────────────────────────────

  group('profile workspace streams', () {
    test(
      'pill count refreshes when pills change without profile writes',
      () async {
        final container = await _makeContainer();
        final db = container.read(databaseProvider);
        final updated = Completer<void>();
        final subscription = container.listen(profileListProvider, (_, next) {
          final count = next.valueOrNull
              ?.firstWhere((person) => person.profile.id == 'profile-xyz')
              .pillCount;
          if (count == 1 && !updated.isCompleted) updated.complete();
        });
        addTearDown(subscription.close);
        await container.read(profileListProvider.future);

        final now = DateTime.now().toUtc();
        await db.pillsDao.upsert(
          PillsCompanion.insert(
            id: 'pill-count-refresh',
            profileId: 'profile-xyz',
            name: 'Fictional pill',
            createdAt: now,
            updatedAt: now,
          ),
        );

        await updated.future.timeout(const Duration(seconds: 5));
        expect(
          (await container.read(profileListProvider.future))
              .singleWhere((person) => person.profile.id == 'profile-xyz')
              .pillCount,
          1,
        );
      },
    );

    test(
      'pill count refreshes do not reload selected or primary person',
      () async {
        final container = await _makeContainer();
        final db = container.read(databaseProvider);
        await container.read(selectedProfileIdProvider.future);
        await container
            .read(selectedProfileIdProvider.notifier)
            .select('profile-xyz');
        await container.read(primaryProfileIdProvider.future);
        await container.pump();

        final selectedStates = <AsyncValue<String?>>[];
        final selectedSubscription = container.listen(
          selectedProfileIdProvider,
          (_, next) => selectedStates.add(next),
          fireImmediately: true,
        );
        addTearDown(selectedSubscription.close);
        final primaryStates = <AsyncValue<String?>>[];
        final primarySubscription = container.listen(
          primaryProfileIdProvider,
          (_, next) => primaryStates.add(next),
          fireImmediately: true,
        );
        addTearDown(primarySubscription.close);
        await container.pump();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await container.pump();
        selectedStates.clear();
        primaryStates.clear();

        final countUpdated = Completer<void>();
        final countSubscription = container.listen(profileListProvider, (
          _,
          next,
        ) {
          final count = next.valueOrNull
              ?.firstWhere((person) => person.profile.id == 'profile-xyz')
              .pillCount;
          if (count == 1 && !countUpdated.isCompleted) countUpdated.complete();
        });
        addTearDown(countSubscription.close);

        final now = DateTime.now().toUtc();
        await db.pillsDao.upsert(
          PillsCompanion.insert(
            id: 'pill-count-selection-refresh',
            profileId: 'profile-xyz',
            name: 'Fictional pill',
            createdAt: now,
            updatedAt: now,
          ),
        );

        await countUpdated.future.timeout(const Duration(seconds: 5));
        await container.pump();

        expect(
          selectedStates.any((state) => state.isLoading),
          isFalse,
          reason: 'Selected states included loading: $selectedStates',
        );
        expect(
          primaryStates.any((state) => state.isLoading),
          isFalse,
          reason: 'Primary states included loading: $primaryStates',
        );
        expect(
          await container.read(selectedProfileIdProvider.future),
          'profile-xyz',
        );
        expect(
          await container.read(primaryProfileIdProvider.future),
          'profile-xyz',
        );
      },
    );

    test(
      'credential-pointer and installation-state writes do not restart care streams',
      () async {
        final container = await _makeContainer(userId: 'owner-stream');
        final db = container.read(databaseProvider);
        final access = container.read(workspaceAccessRepositoryProvider);
        final context = await container.read(workspaceContextProvider.future);
        final now = DateTime.now().toUtc();
        await db.pillsDao.upsert(
          PillsCompanion.insert(
            id: 'pill-stream',
            profileId: 'profile-xyz',
            name: 'Fictional pill',
            createdAt: now,
            updatedAt: now,
          ),
        );
        final provider = pillsForProfileProvider('profile-xyz');
        var dataEmissions = 0;
        var accessContextEmissions = 0;
        final firstContext = Completer<void>();
        final accessContextSubscription = access.watchContext().listen((_) {
          accessContextEmissions++;
          if (!firstContext.isCompleted) firstContext.complete();
        });
        addTearDown(accessContextSubscription.cancel);
        await firstContext.future;
        var contextEmissions = 0;
        final contextSubscription = container.listen(workspaceContextProvider, (
          _,
          next,
        ) {
          if (next.hasValue) contextEmissions++;
        }, fireImmediately: true);
        addTearDown(contextSubscription.close);
        final subscription = container.listen(provider, (_, next) {
          if (next.hasValue) dataEmissions++;
        });
        addTearDown(subscription.close);
        await container.read(provider.future);
        await container.pump();
        final baseline = dataEmissions;
        final accessContextBaseline = accessContextEmissions;
        final contextBaseline = contextEmissions;
        expect(baseline, greaterThan(0));
        expect(contextBaseline, greaterThan(0));

        const replacementCredentialId = 'replacement-test-credential';
        await db
            .into(db.credentialSlots)
            .insert(
              CredentialSlotsCompanion.insert(
                id: replacementCredentialId,
                ownerId: context.ownerUserId,
                endpoint: context.endpoint!,
                state: 'published',
                createdAt: now,
              ),
            );
        await (db.update(
          db.workspaceDeviceStates,
        )..where((row) => row.id.equals('device'))).write(
          const WorkspaceDeviceStatesCompanion(
            networkCredentialId: Value(replacementCredentialId),
          ),
        );
        await container.pump();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(accessContextEmissions, accessContextBaseline);
        expect(contextEmissions, contextBaseline);
        expect(dataEmissions, baseline);

        final deviceState = await access.workspaces.deviceState();
        await (db.update(
          db.workspaceDeviceStates,
        )..where((row) => row.id.equals('device'))).write(
          WorkspaceDeviceStatesCompanion(
            installationEpoch: Value(deviceState.installationEpoch + 1),
          ),
        );
        await container.pump();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(accessContextEmissions, accessContextBaseline);
        expect(contextEmissions, contextBaseline);
        expect(dataEmissions, baseline);
      },
    );

    test(
      'protected selection changes propagate without changing authority context',
      () async {
        final container = await _makeContainer(userId: 'owner-selection');
        final access = container.read(workspaceAccessRepositoryProvider);
        final context = await container.read(workspaceContextProvider.future);
        final selected = Completer<ProtectedWorkspaceSelection>();
        final everyone = Completer<ProtectedWorkspaceSelection>();
        final selectionSubscription = container.listen(
          protectedWorkspaceSelectionProvider,
          (_, next) {
            final value = next.valueOrNull;
            if (value?.selectedProfileId == 'some-id' &&
                !selected.isCompleted) {
              selected.complete(value!);
            }
            if (value?.viewEveryone == true && !everyone.isCompleted) {
              everyone.complete(value!);
            }
          },
        );
        addTearDown(selectionSubscription.close);
        final selectedProfile = Completer<String?>();
        final selectedSubscription = container.listen(
          selectedProfileIdProvider,
          (_, next) {
            if (next.valueOrNull == 'some-id' && !selectedProfile.isCompleted) {
              selectedProfile.complete(next.valueOrNull);
            }
          },
        );
        addTearDown(selectedSubscription.close);
        await container.read(protectedWorkspaceSelectionProvider.future);
        await container.read(selectedProfileIdProvider.future);

        await access.viewPerson(context, 'some-id');
        expect(
          (await selected.future.timeout(
            const Duration(seconds: 5),
          )).viewEveryone,
          isFalse,
        );
        expect(
          await selectedProfile.future.timeout(const Duration(seconds: 5)),
          'some-id',
        );

        await access.viewPerson(context, null, everyone: true);
        final everyoneSelection = await everyone.future.timeout(
          const Duration(seconds: 5),
        );
        expect(everyoneSelection.selectedProfileId, isNull);
        expect(await container.read(selectedProfileIdProvider.future), isNull);
      },
    );
  });

  group('selectedProfileIdProvider', () {
    test(
      'deleted selected person becomes Everyone without invalidation',
      () async {
        final container = await _makeContainer();
        final db = container.read(databaseProvider);
        final access = container.read(workspaceAccessRepositoryProvider);
        final context = container.read(workspaceContextProvider).requireValue;
        await container.read(profileListProvider.future);
        await container.read(selectedProfileIdProvider.future);
        await container
            .read(selectedProfileIdProvider.notifier)
            .select('profile-xyz');
        expect(
          await container.read(selectedProfileIdProvider.future),
          'profile-xyz',
        );
        await container.pump();
        final deleted = Completer<void>();
        final subscription = container.listen(profileListProvider, (_, next) {
          final people = next.asData?.value;
          if (people != null &&
              !people.any((person) => person.profile.id == 'profile-xyz') &&
              !deleted.isCompleted) {
            deleted.complete();
          }
        });
        addTearDown(subscription.close);

        await access.withGrant(
          context,
          () => db.profilesDao.softDelete('profile-xyz'),
        );
        await deleted.future.timeout(const Duration(seconds: 5));
        await container.pump();

        expect(await container.read(selectedProfileIdProvider.future), isNull);
        expect(
          (await container.read(
            profileListProvider.future,
          )).map((person) => person.profile.id),
          unorderedEquals(['some-id', 'p-persist']),
        );
        final stored = await access.workspaces.byId(context.workspaceId);
        // Resolving an invalid display selection does not rewrite durable state.
        expect(stored!.selectedProfileId, 'profile-xyz');
      },
    );

    test('returns null when no preference is stored', () async {
      final container = await _makeContainer(userId: 'u1');

      final value = await container.read(selectedProfileIdProvider.future);

      expect(value, isNull);
    });

    test('select() persists and updates state', () async {
      final container = await _makeContainer(userId: 'u1');

      // Wait for initial load
      await container.read(selectedProfileIdProvider.future);

      await container
          .read(selectedProfileIdProvider.notifier)
          .select('profile-xyz');

      final value = await container.read(selectedProfileIdProvider.future);
      expect(value, 'profile-xyz');
      final access = container.read(workspaceAccessRepositoryProvider);
      expect(
        (await access.workspaces.byId(
          (await access.currentContext()).workspaceId,
        ))!.selectedProfileId,
        'profile-xyz',
      );
    });

    test('select(null) clears the selection', () async {
      final container = await _makeContainer(userId: 'u1');
      await container.read(selectedProfileIdProvider.future);
      await container
          .read(selectedProfileIdProvider.notifier)
          .select('some-id');

      await container.read(selectedProfileIdProvider.notifier).select(null);
      final value = await container.read(selectedProfileIdProvider.future);

      expect(value, isNull);
      final access = container.read(workspaceAccessRepositoryProvider);
      expect(
        (await access.workspaces.byId(
          (await access.currentContext()).workspaceId,
        ))!.viewEveryone,
        isTrue,
      );
    });

    test('persists across separate notifier reads (same container)', () async {
      final container = await _makeContainer(userId: 'u1');
      await container.read(selectedProfileIdProvider.future);
      await container
          .read(selectedProfileIdProvider.notifier)
          .select('p-persist');

      // A new provider container reopens the same protected selection.
      final container2 = await _makeContainer(
        userId: 'u1',
        database: container.read(databaseProvider),
      );
      final value = await container2.read(selectedProfileIdProvider.future);

      expect(value, 'p-persist');
    });
  });
}
