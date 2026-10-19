import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';
import 'package:simpastil/features/pills/pill_provider.dart';
import 'package:simpastil/features/pills/pill_repository.dart';
import 'package:simpastil/features/pills/presentation/medication_identity.dart';
import 'package:simpastil/shared/router/app_router.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../../helpers/care_recording_fixture.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  testWidgets(
    'a medication card flies into its detail page on the first frame',
    (tester) async {
      // The flight is the phone's: tablet windows keep the list in place.
      tester.view
        ..physicalSize = const Size(412, 915)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final f = await CareRecordingFixture.create();
      final container = await f.workspace.createContainer(
        extraOverrides: [
          pillRepositoryProvider.overrideWithValue(
            PillRepositoryImpl(
              db: f.db,
              dao: f.db.pillsDao,
              profilesDao: f.db.profilesDao,
              schedulesDao: f.db.schedulesDao,
              pendingOperations: PendingOperationRepository(
                f.db,
                access: f.workspace.access,
                context: f.workspace.context,
              ),
              reconcileProjections: () async {},
            ),
          ),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await f.db.close();
        container.dispose();
        await tester.pumpAndSettle();
      });
      final router = container.read(routerProvider)..go('/pills');
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: router,
            theme: AppTheme.light(),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('medication-${f.pill.id}')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 160));
      // The page has its plate at once (from the list), so the mark is in
      // flight between the card's size and the plate's.
      final sizes = [
        for (final e in find.byType(MedicationMark).evaluate())
          (e.renderObject! as RenderBox).size.longestSide,
      ];
      expect(sizes.where((s) => s > 60 && s < 102), isNotEmpty);
      await tester.pumpAndSettle();
      // Landed, the plate's mark can be picked up.
      final mark = find.byType(MedicationMark);
      final home = tester.getCenter(mark);
      final gesture = await tester.startGesture(home);
      await gesture.moveBy(const Offset(30, -20));
      await gesture.moveBy(const Offset(30, -20));
      await tester.pump();
      expect(tester.getCenter(mark), isNot(home));
      await gesture.up();
      await tester.pumpAndSettle();
    },
  );
}
