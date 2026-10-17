import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/pills/presentation/add_edit_schedule_sheet.dart';
import 'package:simpastil/features/pills/schedule_provider.dart';
import 'package:simpastil/features/pills/schedule_repository.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

class _Throwing implements ScheduleRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('repository failure');
}

void main() {
  setUpAll(() {
    tzdata.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Europe/Bucharest'));
  });

  testWidgets('a throwing repository shows a message and frees Save', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(412, 914));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [scheduleRepositoryProvider.overrideWithValue(_Throwing())],
        child: MaterialApp(
          theme: AppTheme.light(),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAddEditScheduleSheet(
                  context: context,
                  pillId: 'fictional-pill',
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final save = find.widgetWithText(FilledButton, 'Save');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
