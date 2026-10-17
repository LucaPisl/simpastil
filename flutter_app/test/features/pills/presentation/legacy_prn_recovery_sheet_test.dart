import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/errors/app_error.dart';
import 'package:simpastil/features/pills/presentation/add_edit_schedule_sheet.dart';
import 'package:simpastil/features/pills/schedule_provider.dart';
import 'package:simpastil/features/pills/schedule_repository.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

class _Schedules implements ScheduleRepository {
  final recoveries = <(String, String)>[];

  @override
  Future<Result<Schedule>> recoverLegacyPrn({
    required String localId,
    required String timeZone,
  }) async {
    recoveries.add((localId, timeZone));
    return const Err(ConflictError());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(() {
    tzdata.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Europe/Bucharest'));
  });

  testWidgets('restoration requires enabling and submits the reviewed place', (
    tester,
  ) async {
    final repository = _Schedules();
    final now = DateTime.utc(2026, 10, 7);
    final schedule = Schedule(
      id: '10000000-0000-4000-8000-000000000001',
      pillId: '10000000-0000-4000-8000-000000000002',
      hour: 0,
      minute: 0,
      frequency: 'prn',
      frequencyDays: null,
      isActive: false,
      timeZone: null,
      timeZoneStatus: 'legacy_unknown',
      createdAt: now,
      updatedAt: now,
      serverId: null,
      revision: 1,
      syncStatus: 'pending',
      lastSyncAt: null,
      isDeleted: false,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [scheduleRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAddEditScheduleSheet(
                  context: context,
                  pillId: schedule.pillId,
                  pillIsPrn: true,
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
    expect(find.text('Restore as-needed routine'), findsOneWidget);
    expect(find.text('Bucharest, Romania'), findsOneWidget);
    expect(find.text('Time zone for as-needed recording'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(repository.recoveries, isEmpty);
    await tester.ensureVisible(find.byType(Switch));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(FilledButton));
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(repository.recoveries, [(schedule.id, 'Europe/Bucharest')]);
    expect(
      find.text(
        'This review changed or is no longer ready. Sync, then open it again.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
