import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/capabilities_client.dart';
import 'package:simpastil/core/sync/ledger_mode_hint.dart';
import 'package:simpastil/features/schedules/presentation/routine_presentation.dart';
import 'package:simpastil/l10n/app_localizations.dart';

Schedule _schedule({
  String frequency = 'daily',
  String? days,
  int? everyDays,
  String? anchorDate,
  String? startDate,
  String? endDate,
}) => Schedule(
  id: 's',
  pillId: 'p',
  hour: 9,
  minute: 0,
  frequency: frequency,
  frequencyDays: days,
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

Future<(String, List<String>)> _labels(
  WidgetTester tester,
  Schedule schedule,
  Locale locale,
) async {
  late String pattern;
  late List<String> lines;
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) {
          pattern = connectedSchedulePatternLabel(context, schedule);
          lines = connectedScheduleDateLines(context, schedule);
          return const SizedBox();
        },
      ),
    ),
  );
  return (pattern, lines);
}

void main() {
  testWidgets('an interval shows how often and the day it counts from', (
    tester,
  ) async {
    final (pattern, lines) = await _labels(
      tester,
      _schedule(
        frequency: 'interval',
        everyDays: 3,
        anchorDate: '2026-10-01',
        endDate: '2026-12-31',
      ),
      const Locale('en'),
    );
    expect(pattern, 'Every 3 calendar days');
    expect(lines, hasLength(2));
    expect(lines.first, startsWith('Count from · '));
    expect(lines.last, startsWith('Last day (included) · '));
  });

  testWidgets('daily and weekday schedules show their pattern, no dates', (
    tester,
  ) async {
    final daily = await _labels(tester, _schedule(), const Locale('en'));
    expect(daily.$1, 'Every day');
    expect(daily.$2, isEmpty);
    final custom = await _labels(
      tester,
      _schedule(frequency: 'custom', days: '[1,3]'),
      const Locale('en'),
    );
    expect(custom.$1, 'Mon, Wed');
  });

  testWidgets('the summary reads in Romanian too', (tester) async {
    final (pattern, lines) = await _labels(
      tester,
      _schedule(startDate: '2026-10-01'),
      const Locale('ro'),
    );
    expect(pattern, isNotEmpty);
    expect(lines.single, startsWith('Prima zi · '));
  });

  test(
    'the schedule-windows hint follows the last capability answer',
    () async {
      SharedPreferences.setMockInitialValues({});
      expect(await LedgerModeHint.readScheduleWindows(), isFalse);
      await LedgerModeHint.record(
        const CapabilitySnapshot.present(
          ServerCapabilities(
            medicationLedgerActive: false,
            minimumClientBuild: 1,
            serverRelease: 'r',
            scheduleWindows: true,
          ),
        ),
        server: await LedgerModeHint.configuredServer(),
      );
      expect(await LedgerModeHint.readScheduleWindows(), isTrue);
      await LedgerModeHint.record(
        const CapabilitySnapshot.absent(),
        server: await LedgerModeHint.configuredServer(),
      );
      expect(await LedgerModeHint.readScheduleWindows(), isFalse);
    },
  );
}
