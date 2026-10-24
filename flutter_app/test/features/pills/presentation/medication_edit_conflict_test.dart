import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/medication_detail_provider.dart';
import 'package:simpastil/features/pills/presentation/medication_edit.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../../helpers/care_recording_fixture.dart';
import '../../../helpers/held_provider_read.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  testWidgets('Save works again after a conflict, keeping the typed edits', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(412, 915)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final f = await CareRecordingFixture.create();
    final container = await f.workspace.createContainer();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await f.db.close();
      container.dispose();
      await tester.pumpAndSettle();
    });
    final repository = await container.readHeld(
      medicationDetailRepositoryProvider,
    );
    final detail = await repository.load(f.pill.id);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: AppTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    showMedicationReview(context, detail, repository),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('edit-medication-name')),
      'Renamed here',
    );

    // Care changes elsewhere while the sheet is open.
    await (f.db.update(f.db.pills)..where((p) => p.id.equals(f.pill.id))).write(
      const PillsCompanion(notes: Value('changed elsewhere')),
    );

    final save = find.byKey(const ValueKey('save-medication-review'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Care changed during this review'),
      findsOneWidget,
    );
    // The typed choice is still there.
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('edit-medication-name')))
          .controller!
          .text,
      'Renamed here',
    );

    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Care changed during this review'),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('save-medication-review')), findsNothing);
    final saved = await repository.load(f.pill.id);
    expect(saved.pill.name, 'Renamed here');
  });
}
