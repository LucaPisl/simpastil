import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/storage/portable_preference_writer.dart';
import 'package:simpastil/core/storage/shared_preferences_provider.dart';
import 'package:simpastil/features/profiles/profile_provider.dart';
import 'package:simpastil/features/settings/presentation/people_settings_section.dart';
import 'package:simpastil/features/settings/presentation/settings_overview.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/widgets/person_avatar.dart';
import 'package:simpastil/shared/widgets/status_chip.dart';

class _OpenGate implements ProjectionEffectsGate {
  @override
  Future<T> run<T>(Future<T> Function() action) => action();
}

class _Primary extends PrimaryProfileNotifier {
  @override
  Future<String?> build() async => 'p1';
}

Profile _profile(String id, String name, {bool active = true}) => Profile(
  id: id,
  userId: 'u1',
  name: name,
  avatarEmoji: '🙂',
  isActive: active,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  serverId: null,
  revision: 1,
  syncStatus: 'pending',
  lastSyncAt: null,
  isDeleted: false,
);

void main() {
  testWidgets('people settings use grouped cards with faces and chips', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final people = [
      (profile: _profile('p1', 'Casey'), pillCount: 2),
      (profile: _profile('p2', 'Robin', active: false), pillCount: 0),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          profileListProvider.overrideWith((_) => Stream.value(people)),
          primaryProfileIdProvider.overrideWith(_Primary.new),
          currentUserIdProvider.overrideWithValue('u1'),
          sharedPreferencesProvider.overrideWithValue(prefs),
        ],
        child: MaterialApp(
          // The app theme makes filled buttons full width; keep it so the
          // name field layout is exercised as on a phone.
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const PeopleSettingsSection(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SettingsGroup), findsNWidgets(4));
    expect(find.text('Add and manage'), findsOneWidget);
    expect(find.text('Remove'), findsOneWidget);
    expect(find.byType(PersonAvatar), findsNWidgets(4));
    expect(find.byType(PersonAvatarStack), findsOneWidget);
    expect(find.byType(StatusChip), findsNWidgets(2));
    expect(find.byKey(const ValueKey('people-delete-row')), findsOneWidget);
  });

  testWidgets('Recorded by picks each option and saves a custom name', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          profileListProvider.overrideWith(
            (_) => Stream.value([
              (profile: _profile('p1', 'Casey'), pillCount: 0),
            ]),
          ),
          primaryProfileIdProvider.overrideWith(_Primary.new),
          currentUserIdProvider.overrideWithValue('u1'),
          sharedPreferencesProvider.overrideWithValue(prefs),
          portablePreferenceGateProvider.overrideWithValue(_OpenGate()),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: PeopleSettingsSection(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final list = find.byType(Scrollable).first;
    Future<void> tapKey(String key) async {
      await tester.scrollUntilVisible(
        find.byKey(ValueKey(key)),
        200,
        scrollable: list,
      );
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
    }

    expect(
      find.text(
        'Applies to doses recorded from now on.',
        findRichText: false,
        skipOffstage: false,
      ),
      findsNothing,
    );
    await tapKey('recorded-by-person');
    expect(prefs.getString('recorded_by_mode_u1'), 'personTakingIt');
    expect(
      find.textContaining(
        'even if someone else recorded it',
        skipOffstage: false,
      ),
      findsOneWidget,
    );

    await tapKey('recorded-by-custom');
    expect(prefs.getString('recorded_by_mode_u1'), 'custom');
    await tester.enterText(
      find.byKey(const ValueKey('recorded-by-name')),
      '  Nurse Kim ',
    );
    await tapKey('recorded-by-save');
    expect(prefs.getString('recorded_by_name_u1'), 'Nurse Kim');

    await tapKey('recorded-by-primary');
    expect(prefs.getString('recorded_by_mode_u1'), 'primaryProfile');
    expect(find.byKey(const ValueKey('recorded-by-name')), findsNothing);
  });
}
