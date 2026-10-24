import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/errors/app_error.dart';
import 'package:simpastil/features/auth/auth_provider.dart';
import 'package:simpastil/features/profiles/presentation/profiles_screen.dart';
import 'package:simpastil/features/profiles/profile_provider.dart';
import 'package:simpastil/features/profiles/profile_repository.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:simpastil/shared/widgets/status_chip.dart';

import '../../../helpers/protected_workspace_fixture.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

Profile _fakeProfile({
  String id = 'p1',
  String name = 'Alice',
  String emoji = '👤',
  bool isActive = true,
}) => Profile(
  id: id,
  userId: 'u1',
  name: name,
  avatarEmoji: emoji,
  isActive: isActive,
  createdAt: DateTime.now(),
  updatedAt: DateTime.now(),
  serverId: null,
  revision: 1,
  syncStatus: 'pending',
  lastSyncAt: null,
  isDeleted: false,
);

class _FakeRepo implements ProfileRepository {
  Result<void>? deleteResult;

  @override
  Future<Result<Profile>> create(
    String name,
    String avatarEmoji, {
    String? id,
  }) async => const Err(UnknownError());

  @override
  Future<Result<Profile>> update(
    String localId,
    String name,
    String avatarEmoji,
  ) async => const Err(UnknownError());

  @override
  Future<Result<void>> toggleActive(String localId, bool isActive) async =>
      const Ok(null);

  @override
  Future<Result<bool>> getDeviceRemindersEnabled(String profileId) async =>
      const Ok(false);

  @override
  Future<Result<void>> setDeviceRemindersEnabled(
    String profileId,
    bool enabled,
  ) async => const Ok(null);

  @override
  Future<Result<void>> delete(String localId) async =>
      deleteResult ?? const Ok(null);
}

Future<Widget> _wrap(
  WidgetTester tester,
  Widget child, {
  List<ProfileWithCount> profiles = const [],
  _FakeRepo? repo,
}) async {
  final fixture = await ProtectedWorkspaceFixture.create(ownerId: 'u1');
  final container = await fixture.createContainer(
    extraOverrides: [
      profileListProvider.overrideWith((_) => Stream.value(profiles)),
      selectedProfileIdProvider.overrideWith(() => _FakeSelectedNotifier()),
      for (final item in profiles)
        pillCountByProfileProvider(
          item.profile.id,
        ).overrideWith((_) => Stream.value(item.pillCount)),
      if (repo != null) profileRepositoryProvider.overrideWithValue(repo),
      authNotifierProvider.overrideWith(() => _FakeAuthNotifier()),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await fixture.db.close();
    container.dispose();
    await tester.pumpAndSettle();
  });
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: AppTheme.light(),
      home: child,
    ),
  );
}

class _FakeSelectedNotifier extends SelectedProfileNotifier {
  @override
  Future<String?> build() async => null;

  @override
  Future<void> select(String? id) async => state = AsyncData(id);
}

class _FakeAuthNotifier extends AuthNotifier {
  @override
  AuthState build() => const AuthAuthenticated('u1');
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('shows empty state when there are no profiles', (tester) async {
    await tester.pumpWidget(await _wrap(tester, const ProfilesScreen()));
    await tester.pumpAndSettle();

    expect(find.text('No profiles yet'), findsOneWidget);
  });

  testWidgets('shows each profile once, the one in focus as a card', (
    tester,
  ) async {
    final profiles = [
      (profile: _fakeProfile(id: 'p1', name: 'Alice'), pillCount: 3),
      (profile: _fakeProfile(id: 'p2', name: 'Bob'), pillCount: 0),
    ];
    await tester.pumpWidget(
      await _wrap(tester, const ProfilesScreen(), profiles: profiles),
    );
    await tester.pumpAndSettle();

    // One list: each person appears once, whoever is not in focus as a row.
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('3 medications'), findsOneWidget);
    expect(find.byKey(const ValueKey('person-card-slot-p1')), findsOneWidget);
    expect(find.byKey(const ValueKey('person-row-slot-p2')), findsOneWidget);
  });

  testWidgets('add-person entry is visible', (tester) async {
    await tester.pumpWidget(await _wrap(tester, const ProfilesScreen()));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Add profile'), findsOneWidget);
  });

  testWidgets('inactive profile card is visually muted', (tester) async {
    final profiles = [
      (
        profile: _fakeProfile(id: 'p1', name: 'Inactive', isActive: false),
        pillCount: 0,
      ),
    ];
    await tester.pumpWidget(
      await _wrap(tester, const ProfilesScreen(), profiles: profiles),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('connected-people-management')));
    await tester.pumpAndSettle();
    // Connected management retains the inactive control and visual treatment.
    expect(
      tester
          .widget<AnimatedOpacity>(find.byType(AnimatedOpacity).first)
          .opacity,
      0.55,
    );
  });

  test('dose outcomes map to calm tones', () {
    expect(personDoseTone('taken'), StatusTone.good);
    expect(personDoseTone('missed'), StatusTone.attention);
    expect(personDoseTone('skipped'), StatusTone.neutral);
    expect(personDoseTone('pending'), StatusTone.working);
  });
}
