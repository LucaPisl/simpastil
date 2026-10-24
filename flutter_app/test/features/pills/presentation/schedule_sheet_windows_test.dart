import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/errors/app_error.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/core/medication/schedule_window.dart';
import 'package:simpastil/features/pills/presentation/add_edit_schedule_sheet.dart';
import 'package:simpastil/features/pills/schedule_provider.dart';
import 'package:simpastil/features/pills/schedule_repository.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

class _Recording implements ScheduleRepository {
  final created =
      <({String frequency, List<int>? days, ScheduleWindow window})>[];
  final updated = <({String frequency, ScheduleWindow window})>[];

  @override
  Future<Result<Schedule>> create({
    required String pillId,
    required int hour,
    required int minute,
    required String frequency,
    List<int>? frequencyDays,
    bool isActive = true,
    String? id,
    ScheduleWindow window = const ScheduleWindow(),
    String? timeZone,
  }) async {
    created.add((frequency: frequency, days: frequencyDays, window: window));
    return const Err(UnknownError());
  }

  @override
  Future<Result<Schedule>> update(
    String localId, {
    required int hour,
    required int minute,
    required String frequency,
    List<int>? frequencyDays,
    required bool isActive,
    ScheduleWindow window = const ScheduleWindow(),
  }) async {
    updated.add((frequency: frequency, window: window));
    return const Err(UnknownError());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

Schedule _schedule({
  String frequency = 'interval',
  int? everyDays = 3,
  String? anchorDate = '2026-10-01',
  String? startDate,
  String? endDate = '2026-12-31',
}) => Schedule(
  id: 'schedule-1',
  pillId: 'pill-1',
  hour: 9,
  minute: 0,
  frequency: frequency,
  frequencyDays: null,
  isActive: true,
  isDeleted: false,
  syncStatus: 'synced',
  revision: 1,
  timeZone: 'Europe/Bucharest',
  timeZoneStatus: 'known',
  createdAt: DateTime.utc(2026, 10, 1),
  updatedAt: DateTime.utc(2026, 10, 1),
  everyDays: everyDays,
  anchorDate: anchorDate,
  startDate: startDate,
  endDate: endDate,
);

Future<_Recording> _open(
  WidgetTester tester, {
  required bool supported,
  Schedule? schedule,
  Locale locale = const Locale('en'),
  bool dark = false,
  double textScale = 1.0,
  Size size = const Size(412, 914),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final repo = _Recording();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        scheduleRepositoryProvider.overrideWithValue(repo),
        scheduleWindowsSupportedProvider.overrideWith((ref) => supported),
      ],
      child: MaterialApp(
        theme: dark ? AppTheme.dark() : AppTheme.light(),
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAddEditScheduleSheet(
                context: context,
                pillId: 'pill-1',
                schedule: schedule,
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
  return repo;
}

Future<void> _save(WidgetTester tester, String label) async {
  final save = find.widgetWithText(FilledButton, label);
  await tester.ensureVisible(save);
  await tester.tap(save);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() {
    tzdata.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Europe/Bucharest'));
  });

  testWidgets('hides interval and dates when the server lacks the capability', (
    tester,
  ) async {
    final repo = await _open(tester, supported: false);
    expect(find.text('Every few days'), findsNothing);
    expect(find.byKey(const ValueKey('schedule-start-date')), findsNothing);
    expect(find.byKey(const ValueKey('schedule-end-date')), findsNothing);
    expect(find.byType(SegmentedButton<bool>), findsOneWidget);
    await _save(tester, 'Save');
    expect(repo.created.single.frequency, 'daily');
    expect(repo.created.single.window.isSet, isFalse);
  });

  testWidgets('every few days sends the interval and its first day', (
    tester,
  ) async {
    final repo = await _open(tester, supported: true);
    await tester.tap(find.byKey(const ValueKey('schedule-repeat-interval')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('schedule-every-days')),
      '3',
    );
    await _save(tester, 'Save');
    final call = repo.created.single;
    expect(call.frequency, 'interval');
    expect(call.days, isNull);
    expect(call.window.everyDays, 3);
    expect(call.window.anchorDate, routineDateKey(DateTime.now()));
    expect(call.window.startDate, isNull);
    expect(call.window.endDate, isNull);
  });

  testWidgets('an interval needs a whole number of days', (tester) async {
    final repo = await _open(tester, supported: true);
    await tester.tap(find.byKey(const ValueKey('schedule-repeat-interval')));
    await tester.pumpAndSettle();
    await _save(tester, 'Save');
    expect(repo.created, isEmpty);
    expect(find.text('Enter a whole number from 1 to 36500.'), findsWidgets);
    await tester.enterText(
      find.byKey(const ValueKey('schedule-every-days')),
      '36501',
    );
    await _save(tester, 'Save');
    expect(repo.created, isEmpty);
  });

  testWidgets('a start date can be set and removed on a daily schedule', (
    tester,
  ) async {
    final repo = await _open(tester, supported: true);
    await tester.ensureVisible(
      find.byKey(const ValueKey('schedule-start-date')),
    );
    await tester.tap(find.byKey(const ValueKey('schedule-start-date')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('schedule-start-date-clear')), findsOne);
    await _save(tester, 'Save');
    expect(repo.created.single.frequency, 'daily');
    expect(
      repo.created.single.window.startDate,
      routineDateKey(DateTime.now()),
    );
    expect(repo.created.single.window.everyDays, isNull);

    await tester.ensureVisible(
      find.byKey(const ValueKey('schedule-start-date-clear')),
    );
    await tester.tap(find.byKey(const ValueKey('schedule-start-date-clear')));
    await tester.pumpAndSettle();
    await _save(tester, 'Save');
    expect(repo.created.last.window.isSet, isFalse);
  });

  testWidgets('an existing interval keeps its fields and stays editable', (
    tester,
  ) async {
    // Capability unknown: a schedule that already carries a window still
    // shows it, so saving never silently drops it.
    final repo = await _open(tester, supported: false, schedule: _schedule());
    expect(find.byKey(const ValueKey('schedule-every-days')), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    await _save(tester, 'Save');
    final call = repo.updated.single;
    expect(call.frequency, 'interval');
    expect(call.window.everyDays, 3);
    expect(call.window.anchorDate, '2026-10-01');
    expect(call.window.endDate, '2026-12-31');
  });

  for (final dark in [false, true]) {
    for (final scale in [1.0, 1.3]) {
      for (final size in [const Size(360, 740), const Size(1024, 768)]) {
        testWidgets(
          'renders without overflow (dark $dark, scale $scale, ${size.width.toInt()}dp, Romanian)',
          (tester) async {
            await _open(
              tester,
              supported: true,
              schedule: _schedule(startDate: '2026-10-01'),
              locale: const Locale('ro'),
              dark: dark,
              textScale: scale,
              size: size,
            );
            expect(tester.takeException(), isNull);
            for (final key in const [
              'schedule-repeat-interval',
              'schedule-start-date',
              'schedule-end-date',
              'schedule-anchor-date',
            ]) {
              final finder = find.byKey(ValueKey(key));
              await tester.ensureVisible(finder);
              await tester.pumpAndSettle();
              expect(
                tester.getSize(finder).height,
                greaterThanOrEqualTo(47.9),
                reason: key,
              );
            }
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
