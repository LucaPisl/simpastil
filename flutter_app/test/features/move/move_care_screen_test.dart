import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/features/move/move_care_service.dart';
import 'package:simpastil/features/move/move_plan.dart';
import 'package:simpastil/features/move/move_providers.dart';
import 'package:simpastil/features/move/presentation/move_care_screen.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../helpers/care_recording_fixture.dart';
import '../../helpers/window_view.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);

  late MovePreview preview;

  setUp(() async {
    final fixture = await CareRecordingFixture.create();
    await fixture.recordMiss();
    final local =
        await (fixture.db.select(
              fixture.db.careWorkspaces,
            )..where((w) => w.id.equals(fixture.workspace.context.workspaceId)))
            .getSingle();
    final plan = await readMovePlan(
      fixture.db,
      local,
      now: DateTime.utc(2026, 10, 1, 12),
    );
    final now = DateTime.utc(2026, 10, 1);
    preview = MovePreview(
      local: local,
      plan: plan,
      duplicates: {
        fixture.person.id: Profile(
          id: 'account-alex',
          userId: 'account-owner',
          name: 'Fictional Alex',
          avatarEmoji: '',
          isActive: true,
          createdAt: now,
          updatedAt: now,
          revision: 1,
          syncStatus: 'synced',
          isDeleted: false,
        ),
      },
      serverGap: null,
    );
    addTearDown(fixture.db.close);
  });

  Future<void> pump(
    WidgetTester tester,
    MovePreview preview, {
    Size size = const Size(390, 844),
    double textScale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    useWindow(tester, size);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [movePreviewProvider.overrideWith((_) async => preview)],
        child: MaterialApp(
          theme: brightness == Brightness.light
              ? AppTheme.light()
              : AppTheme.dark(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const MoveCareScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<FilledButton> start(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('move-start')),
      200,
    );
    return tester.widget<FilledButton>(
      find.descendant(
        of: find.byKey(const ValueKey('move-start')),
        matching: find.byType(FilledButton),
      ),
    );
  }

  testWidgets('a likely duplicate needs a choice before the move starts', (
    tester,
  ) async {
    await pump(tester, preview);

    expect(
      find.text('Fictional Alex may already be on your account'),
      findsOne,
    );
    expect(find.text('1 recorded dose since Sep 30, 2026'), findsOne);
    expect((await start(tester)).onPressed, isNull);

    await tester.ensureVisible(find.text('Skip this person'));
    await tester.tap(find.text('Skip this person'));
    await tester.pumpAndSettle();

    expect((await start(tester)).onPressed, isNotNull);
    expect(find.text('Skipped, stays on this phone'), findsOne);
  });

  testWidgets('a server that cannot hold the care blocks the move', (
    tester,
  ) async {
    await pump(
      tester,
      MovePreview(
        local: preview.local,
        plan: preview.plan,
        duplicates: const {},
        serverGap: MoveFailureCode.serverNeedsUpdate,
      ),
    );

    expect(
      find.text(
        'Your server needs an update before this care can move. '
        'Nothing has changed.',
      ),
      findsOne,
    );
    expect(find.byKey(const ValueKey('move-start')), findsNothing);
  });

  for (final (name, size) in [
    ('phone', const Size(360, 780)),
    ('tablet', const Size(1280, 800)),
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('lays out on a $name in ${brightness.name} at 1.3x text', (
        tester,
      ) async {
        await pump(
          tester,
          preview,
          size: size,
          textScale: 1.3,
          brightness: brightness,
        );
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('move-start')),
          200,
        );
        expect(tester.takeException(), isNull);
        expect(find.text('Keep both'), findsOne);
      });
    }
  }
}
