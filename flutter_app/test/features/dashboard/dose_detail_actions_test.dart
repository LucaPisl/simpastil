import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/care_provider.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/medication/medication_repository.dart';
import 'package:simpastil/features/dashboard/dose_detail_screen.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../../helpers/care_recording_fixture.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);

  testWidgets('a pending dose offers Taken now, Taken at another time and '
      'Skipped, and Taken now records at once', (tester) async {
    final f = await CareRecordingFixture.create();
    final container = await f.workspace.createContainer();
    _teardown(tester, f, container);
    await _mount(
      tester,
      container,
      DoseDetailScreen(occurrenceId: f.occurrence.id),
    );

    expect(find.text('Taken now'), findsOneWidget);
    expect(find.text('Taken at another time'), findsOneWidget);
    expect(find.text('Skipped'), findsOneWidget);
    // The old single "Record a dose" entry point is gone.
    expect(find.text('Record a dose'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('dose-taken-now')));
    await _settle(tester);
    final events = await _read(
      tester,
      f.db.select(f.db.occurrenceEvents).get(),
    );
    expect(events, hasLength(1));
    expect(events.single.action, 'take');
    expect(events.single.actualTimeKnown, isTrue);
    final row = await _read(
      tester,
      f.db.medicationLedgerDao.getOccurrenceById(f.occurrence.id),
    );
    expect(row!.state, 'taken');
    // Recorded: the page now offers Correct and Undo instead.
    expect(find.text('Taken now'), findsNothing);
    expect(find.text('Correct this record'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Skipped opens the review form on Skipped and writes nothing '
      'until it is saved', (tester) async {
    final f = await CareRecordingFixture.create();
    final container = await f.workspace.createContainer();
    _teardown(tester, f, container);
    await _mount(
      tester,
      container,
      DoseDetailScreen(occurrenceId: f.occurrence.id),
    );

    await tester.tap(find.byKey(const ValueKey('dose-skipped')));
    await _settle(tester);
    expect(find.text('Review this record'), findsOneWidget);
    expect(
      await _read(tester, f.db.select(f.db.occurrenceEvents).get()),
      isEmpty,
    );
    await tester.tap(find.text('Review this record'));
    await _settle(tester);
    await tester.tap(find.text('Save record'));
    await _settle(tester);
    final events = await _read(
      tester,
      f.db.select(f.db.occurrenceEvents).get(),
    );
    expect(events.single.action, 'skip');
    expect(tester.takeException(), isNull);
  });

  testWidgets('After taking shows the count left only when stock is tracked', (
    tester,
  ) async {
    final tracked = await CareRecordingFixture.create(legacyStock: 4);
    final container = await tracked.workspace.createContainer();
    _teardown(tester, tracked, container);
    await _mount(
      tester,
      container,
      DoseDetailScreen(occurrenceId: tracked.occurrence.id),
    );
    expect(find.text('After taking'), findsOneWidget);
    expect(find.text('3 left'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no After taking tile without a stock count', (tester) async {
    final f = await CareRecordingFixture.create();
    final container = await f.workspace.createContainer();
    _teardown(tester, f, container);
    await _mount(
      tester,
      container,
      DoseDetailScreen(occurrenceId: f.occurrence.id),
    );
    expect(find.text('After taking'), findsNothing);
    expect(find.text('Amount per use'), findsWidgets);
    expect(find.text('Status'), findsOneWidget);
    expect(find.text('Not recorded'), findsWidgets);
  });

  testWidgets('Previous mornings lists the earlier occurrences of the slot '
      'with what was recorded', (tester) async {
    final f = await CareRecordingFixture.create();
    Future<void> earlier(String id, String date, String state) =>
        f.db.medicationLedgerDao.upsertOccurrence(
          f.occurrence
              .toCompanion(false)
              .copyWith(
                id: Value(id),
                occurrenceKey: Value('scheduled:v1:$id'),
                plannedLocalDate: Value(date),
                plannedAt: Value(
                  DateTime.utc(2026, 9, int.parse(date.substring(8)), 9),
                ),
                state: Value(state),
              ),
        );
    await earlier(
      '20000000-0000-4000-8000-000000000001',
      '2026-09-27',
      'taken',
    );
    await earlier(
      '20000000-0000-4000-8000-000000000002',
      '2026-09-28',
      'skipped',
    );
    await earlier(
      '20000000-0000-4000-8000-000000000003',
      '2026-09-29',
      'pending',
    );
    final container = await f.workspace.createContainer();
    _teardown(tester, f, container);
    await _mount(
      tester,
      container,
      DoseDetailScreen(occurrenceId: f.occurrence.id),
    );

    expect(find.text('Previous mornings'), findsOneWidget);
    expect(find.text('1 of 3'), findsOneWidget);
    final list = find.byKey(const ValueKey('dose-previous-slots'));
    expect(
      find.descendant(of: list, matching: find.text('Skipped')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: list, matching: find.text('Not recorded')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the side panel shows the same body under a header with a '
      'close control', (tester) async {
    final f = await CareRecordingFixture.create(legacyStock: 4);
    final container = await f.workspace.createContainer();
    _teardown(tester, f, container);
    var closed = 0;
    await _mount(
      tester,
      container,
      Scaffold(
        body: SizedBox(
          width: 640,
          child: DoseDetailPanel(
            occurrenceId: f.occurrence.id,
            onClose: () => closed++,
          ),
        ),
      ),
    );
    expect(find.text('Dose details'), findsOneWidget);
    expect(find.text('Taken now'), findsOneWidget);
    expect(find.text('3 left'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dose-details-close')));
    await tester.pump();
    expect(closed, 1);
    expect(tester.takeException(), isNull);
  });

  group('a refused record is prepared again on the next try', () {
    testWidgets('Taken now', (tester) async {
      final f = await CareRecordingFixture.create();
      final service = await _refusingService(f, refuse: 1);
      final container = await f.workspace.createContainer(
        extraOverrides: [
          careRecordingServiceProvider.overrideWith((ref) async => service),
        ],
      );
      _teardown(tester, f, container);
      await _mount(
        tester,
        container,
        DoseDetailScreen(occurrenceId: f.occurrence.id),
      );

      await tester.tap(find.byKey(const ValueKey('dose-taken-now')));
      await _settle(tester);
      // The dose moved on before the first command was committed.
      expect(service.refused, hasLength(1));
      expect(
        await _read(tester, f.db.select(f.db.occurrenceEvents).get()),
        isEmpty,
      );

      // Replaying the refused command would be refused again; the retry
      // prepares a fresh one and records the dose.
      await tester.tap(find.byKey(const ValueKey('dose-taken-now')));
      await _settle(tester);
      final events = await _read(
        tester,
        f.db.select(f.db.occurrenceEvents).get(),
      );
      expect(events, hasLength(1));
      expect(events.single.action, 'take');
      expect(find.text('Undo'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Undo', (tester) async {
      final f = await CareRecordingFixture.create();
      final service = await _refusingService(f, refuse: 0);
      final container = await f.workspace.createContainer(
        extraOverrides: [
          careRecordingServiceProvider.overrideWith((ref) async => service),
        ],
      );
      _teardown(tester, f, container);
      await _mount(
        tester,
        container,
        DoseDetailScreen(occurrenceId: f.occurrence.id),
      );
      await tester.tap(find.byKey(const ValueKey('dose-taken-now')));
      await _settle(tester);
      expect(find.text('Undo'), findsOneWidget);

      service.refuseNext = 1;
      await tester.tap(find.text('Undo'));
      await _settle(tester);
      expect(service.refused, hasLength(1));
      expect(find.text('Undo'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await _settle(tester);
      final row = await _read(
        tester,
        f.db.medicationLedgerDao.getOccurrenceById(f.occurrence.id),
      );
      expect(row!.state, 'pending');
      expect(find.byKey(const ValueKey('dose-taken-now')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

/// A care service whose next commits are refused as stale, the way a dose that
/// changed after it was prepared is. A refused command stays refused.
class _RefusingCareService extends CareRecordingService {
  _RefusingCareService(CareRecordingService base, this.refuseNext)
    : super(
        database: base.database,
        access: base.access,
        context: base.context,
      );

  int refuseNext;
  final refused = <String>{};

  @override
  Future<CareRecordingReceipt> commit(PreparedCareIntent intent) async {
    if (refuseNext > 0) {
      refuseNext--;
      refused.add(intent.commandId);
    }
    if (refused.contains(intent.commandId)) {
      throw const MedicationCommandBlocked('occurrence_head_changed');
    }
    return super.commit(intent);
  }
}

Future<_RefusingCareService> _refusingService(
  CareRecordingFixture f, {
  required int refuse,
}) async {
  final container = await f.workspace.createContainer();
  final base = await container.read(careRecordingServiceProvider.future);
  container.dispose();
  return _RefusingCareService(base, refuse);
}

void _teardown(
  WidgetTester tester,
  CareRecordingFixture f,
  ProviderContainer container,
) {
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await f.db.close();
    container.dispose();
    await tester.pumpAndSettle();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

Future<void> _mount(
  WidgetTester tester,
  ProviderContainer container,
  Widget home,
) async {
  tester.view.physicalSize = const Size(800, 1800);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: home,
      ),
    ),
  );
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
}

Future<T> _read<T>(WidgetTester tester, Future<T> future) async {
  var done = false;
  T? value;
  Object? error;
  future.then(
    (v) {
      value = v;
      done = true;
    },
    onError: (Object e) {
      error = e;
      done = true;
    },
  );
  for (var i = 0; i < 200 && !done; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  if (!done) throw StateError('Query did not settle');
  if (error != null) throw error!;
  return value as T;
}
