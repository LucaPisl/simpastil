import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/router/app_router.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import '../../../helpers/protected_workspace_fixture.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  testWidgets('finish later on the person step leaves setup', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final f = await ProtectedWorkspaceFixture.create();
    final container = await f.createContainer();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await f.db.close();
      container.dispose();
      await tester.pumpAndSettle();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: container.read(routerProvider),
          theme: AppTheme.light(),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final begin = find.byKey(const ValueKey('setup-begin'));
    await tester.ensureVisible(begin);
    await tester.tap(begin);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('person-name')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('person-name')),
      'Fictional Mara',
    );
    final later = find.text('Save and finish later');
    await tester.ensureVisible(later);
    await tester.tap(later);
    await tester.pumpAndSettle();
    // Not looped back into the same step: the start screen is shown.
    expect(find.byKey(const ValueKey('person-name')), findsNothing);
    expect(find.byKey(const ValueKey('setup-start')), findsOneWidget);
    // What was typed is kept for when setup resumes.
    await tester.ensureVisible(begin);
    await tester.tap(begin);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextFormField>(find.byKey(const ValueKey('person-name')))
          .controller!
          .text,
      'Fictional Mara',
    );
  });
}
