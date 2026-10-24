import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/errors/app_error.dart';
import 'package:simpastil/features/auth/auth_provider.dart';
import 'package:simpastil/features/profiles/presentation/add_edit_profile_sheet.dart';
import 'package:simpastil/features/profiles/profile_provider.dart';
import 'package:simpastil/features/profiles/profile_repository.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';

// ── Fake ─────────────────────────────────────────────────────────────────────

class _FakeProfileRepository implements ProfileRepository {
  Result<Profile>? createResult;
  String? lastCreatedName;
  String? lastCreatedEmoji;

  @override
  Future<Result<Profile>> create(
    String name,
    String avatarEmoji, {
    String? id,
  }) async {
    lastCreatedName = name;
    lastCreatedEmoji = avatarEmoji;
    return createResult ?? const Err(UnknownError('not set'));
  }

  @override
  Future<Result<Profile>> update(
    String localId,
    String name,
    String avatarEmoji,
  ) async => const Err(UnknownError('not set'));

  @override
  Future<Result<void>> toggleActive(String localId, bool isActive) async =>
      const Err(UnknownError('not set'));

  @override
  Future<Result<bool>> getDeviceRemindersEnabled(String profileId) async =>
      const Err(UnknownError('not set'));

  @override
  Future<Result<void>> setDeviceRemindersEnabled(
    String profileId,
    bool enabled,
  ) async => const Err(UnknownError('not set'));

  @override
  Future<Result<void>> delete(String localId) async =>
      const Err(UnknownError('not set'));
}

// ── Helper ────────────────────────────────────────────────────────────────────

Profile _fakeProfile() => Profile(
  id: 'local-id',
  userId: 'u1',
  name: 'Test',
  avatarEmoji: '👤',
  isActive: true,
  createdAt: DateTime.now(),
  updatedAt: DateTime.now(),
  serverId: null,
  revision: 1,
  syncStatus: 'pending',
  lastSyncAt: null,
  isDeleted: false,
);

Widget _wrap(Widget child, {_FakeProfileRepository? repo}) {
  return ProviderScope(
    overrides: [
      if (repo != null) profileRepositoryProvider.overrideWithValue(repo),
      authNotifierProvider.overrideWith(() => _StubAuthNotifier()),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: AppTheme.light(),
      home: Scaffold(body: Builder(builder: (ctx) => child)),
    ),
  );
}

class _StubAuthNotifier extends AuthNotifier {
  @override
  AuthState build() => const AuthAuthenticated('u1');
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('shows name field and emoji grid', (tester) async {
    await tester.pumpWidget(
      _wrap(
        TextButton(
          onPressed: () => showAddEditProfileSheet(
            context: tester.element(find.byType(TextButton)),
          ),
          child: const Text('Open'),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.byType(TextFormField), findsOneWidget);
    expect(find.text('👤'), findsWidgets);
  });

  testWidgets('Save button is disabled when name is empty', (tester) async {
    await tester.pumpWidget(
      _wrap(
        TextButton(
          onPressed: () => showAddEditProfileSheet(
            context: tester.element(find.byType(TextButton)),
          ),
          child: const Text('Open'),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    // Name field is empty — tapping Save should not call create.
    final repo = _FakeProfileRepository()..createResult = Ok(_fakeProfile());
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save').first);
    await tester.tap(find.widgetWithText(FilledButton, 'Save').first);
    await tester.pumpAndSettle();

    expect(repo.lastCreatedName, isNull);
  });

  testWidgets('entering a name and tapping Save calls create', (tester) async {
    final repo = _FakeProfileRepository()..createResult = Ok(_fakeProfile());

    await tester.pumpWidget(
      _wrap(
        TextButton(
          onPressed: () => showAddEditProfileSheet(
            context: tester.element(find.byType(TextButton)),
          ),
          child: const Text('Open'),
        ),
        repo: repo,
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField), 'Alice');
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save').first);
    await tester.tap(find.widgetWithText(FilledButton, 'Save').first);
    await tester.pumpAndSettle();

    expect(repo.lastCreatedName, 'Alice');
  });
}
