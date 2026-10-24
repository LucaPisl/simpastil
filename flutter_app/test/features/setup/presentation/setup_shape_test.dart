import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/auth/token_service.dart';
import 'package:simpastil/core/server/server_config_notifier.dart';
import 'package:simpastil/features/pills/presentation/medication_identity.dart';
import 'package:simpastil/features/setup/setup_state.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/router/app_router.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../../helpers/protected_workspace_fixture.dart';

class _NoSession extends TokenService {
  @override
  Future<String?> getApiKey() async => null;
  @override
  Future<bool> hasSession() async => false;
}

class _NoServer extends ServerConfigNotifier {
  @override
  String? build() => null;
}

void main() {
  setUpAll(tzdata.initializeTimeZones);

  test('a draft keeps the picked shape, and old drafts have none', () {
    const withShape = MedicationReview(name: 'Aspirin', shape: 'diamond');
    final back = MedicationReview.fromJson(withShape.toJson());
    expect(back.shape, 'diamond');
    final legacy = Map<String, Object?>.from(withShape.toJson())
      ..remove('shape');
    expect(MedicationReview.fromJson(legacy).shape, isNull);
    expect(
      const MedicationReview(name: 'A').toJson().containsKey('shape'),
      false,
    );
  });

  for (final scale in [1.0, 1.3]) {
    testWidgets('setup offers, previews and saves the shape at $scale x', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = await ProtectedWorkspaceFixture.create();
      final container = await fixture.createContainer(
        extraOverrides: [
          tokenServiceProvider.overrideWithValue(_NoSession()),
          serverConfigProvider.overrideWith(_NoServer.new),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await fixture.db.close();
        container.dispose();
        await tester.pumpAndSettle();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: container.read(routerProvider),
            theme: AppTheme.light(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> tapKey(String key) async {
        final f = find.byKey(ValueKey(key));
        await tester.ensureVisible(f);
        await tester.pumpAndSettle();
        await tester.tap(f);
        await tester.pumpAndSettle();
      }

      await tapKey('setup-begin');
      await tester.enterText(find.byKey(const ValueKey('person-name')), 'Mara');
      await tapKey('save-person');
      await tester.enterText(
        find.byKey(const ValueKey('medication-name')),
        'Zinc',
      );
      await tester.pumpAndSettle();
      // The suggestion starts from the chosen form: liquid gives the drop.
      await tapKey('form-chip-Liquid');
      expect(find.byKey(const ValueKey('shape-suggested')), findsOneWidget);
      final picker = find.byKey(const ValueKey('shape-drop'));
      expect(picker, findsOneWidget);
      // The preview card draws the shape with the first letter live.
      final marks = tester
          .widgetList<MedicationMark>(find.byType(MedicationMark))
          .where((m) => m.shape.name == 'drop' && m.imprint == 'Z');
      expect(marks, isNotEmpty);

      await tapKey('shape-diamond');
      expect(find.byKey(const ValueKey('shape-suggested')), findsNothing);
      await tapKey('save-medication');
      final pills = await fixture.db.select(fixture.db.pills).get();
      expect(pills.single.shape, 'diamond');
      expect(tester.takeException(), isNull);
    });
  }
}
