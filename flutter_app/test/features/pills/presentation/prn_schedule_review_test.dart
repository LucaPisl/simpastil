import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/sync/pending_operation_repository.dart';
import 'package:simpastil/features/pills/presentation/add_edit_schedule_sheet.dart';
import 'package:simpastil/features/pills/schedule_provider.dart';
import 'package:simpastil/features/pills/schedule_repository.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../../helpers/care_recording_fixture.dart';
import '../../../helpers/review_rendering.dart';
import 'package:simpastil/shared/theme/app_theme.dart';

class _ConflictAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      '{"error":{"code":"CONFLICT_STALE_UPDATE"}}',
      409,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A server-quarantined schedule has already-synchronized ancestors. The setup
/// helper initially queues their creation; acknowledge those synthetic receipts
/// rather than leaving impossible pending parents behind manually synced rows.
Future<CareRecordingFixture> _reviewFixture() async {
  final f = await CareRecordingFixture.create(connected: true);
  final pending = PendingOperationRepository(f.db);
  for (final operation in await f.db.pendingOperationsDao.getForUser(
    f.workspace.context.ownerUserId,
  )) {
    expect(await f.db.pendingOperationsDao.getEffects(operation.id), isEmpty);
    await f.db.pendingOperationsDao.transitionState(
      operationId: operation.id,
      from: 'queued',
      to: 'sending',
    );
    expect(
      await pending.commitWithMatchingReceipt(
        operationId: operation.id,
        acknowledgedMutationId: operation.mutationId,
      ),
      isTrue,
    );
  }
  await f.db.profilesDao.markSynced(f.person.id, f.person.id, revision: 1);
  await f.db.pillsDao.markSynced(f.pill.id, f.pill.id, revision: 1);
  return f;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await loadReviewFonts();
  });
  for (final (locale, verifyInvalidDays) in const [
    ('en', false),
    ('ro', false),
    ('en', true),
    ('ro', true),
  ]) {
    testWidgets('timed repair $locale: weekdays=$verifyInvalidDays', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(412, 914));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final f = await _reviewFixture();
      final db = f.db;
      final scheduleId = f.occurrence.scheduleId!;
      const issueId = '10000000-0000-4000-8000-000000000004';
      await (db.update(db.pills)..where((p) => p.id.equals(f.pill.id))).write(
        PillsCompanion(
          isPrn: const Value(false),
          syncStatus: const Value('synced'),
          serverId: Value(f.pill.id),
        ),
      );
      final now = DateTime.utc(2026, 10, 6);
      await db.migrationIssuesDao.record(
        MigrationIssuesCompanion.insert(
          id: issueId,
          userId: f.workspace.context.ownerUserId,
          entityType: 'schedules',
          entityId: scheduleId,
          issueCode: 'schedule_timezone_review_required',
          snapshotJson: '{}',
          serverId: const Value(issueId),
          createdAt: now,
          updatedAt: now,
        ),
      );
      final adapter = _ConflictAdapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid'))
        ..httpClientAdapter = adapter;
      final repository = ScheduleRepositoryImpl(
        schedulesDao: db.schedulesDao,
        pillsDao: db.pillsDao,
        profilesDao: db.profilesDao,
        ledgerDao: db.medicationLedgerDao,
        migrationIssuesDao: db.migrationIssuesDao,
        pendingOperations: PendingOperationRepository(db),
        dio: dio,
        reconcileProjections: () async {},
      );
      addTearDown(() async {
        dio.close();
        await db.close();
      });

      Future<void> openSheet(
        Schedule schedule, {
        bool repair = true,
        String? repairIssueCode = 'schedule_timezone_review_required',
      }) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              scheduleRepositoryProvider.overrideWithValue(repository),
            ],
            child: MaterialApp(
              locale: Locale(locale),
              theme: reviewRenderingTheme(
                locale == 'ro' ? AppTheme.dark() : AppTheme.light(),
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(locale == 'ro' ? 2 : 1),
                  disableAnimations: locale == 'ro',
                ),
                child: child!,
              ),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showAddEditScheduleSheet(
                      context: context,
                      pillId: f.pill.id,
                      schedule: schedule,
                      repairIssueId: repair ? issueId : null,
                      repairIssueRevision: repair ? 1 : null,
                      repairIssueCode: repair ? repairIssueCode : null,
                    ),
                    child: const Text('Open review'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open review'));
        await tester.pumpAndSettle();
      }

      await (db.update(
        db.schedules,
      )..where((s) => s.id.equals(scheduleId))).write(
        SchedulesCompanion(
          hour: const Value(8),
          minute: const Value(45),
          frequency: const Value('custom'),
          frequencyDays: const Value('[4,2]'),
          isActive: const Value(false),
          timeZone: const Value('Europe/Bucharest'),
          syncStatus: const Value('synced'),
          serverId: Value(scheduleId),
        ),
      );
      final schedule = (await db.schedulesDao.getById(scheduleId))!;
      await openSheet(schedule);
      final summary = find.byKey(const ValueKey('schedule-repair-summary'));
      expect(summary, findsOneWidget);
      final time = find.text(locale == 'ro' ? 'Ora: 08:45' : 'Time: 8:45 AM');
      expect(find.descendant(of: summary, matching: time), findsOneWidget);
      expect(
        find.ancestor(of: time, matching: find.byType(InkWell)),
        findsNothing,
      );
      expect(
        find.descendant(
          of: summary,
          matching: find.text(
            '${locale == 'ro' ? 'Frecvență' : 'Frequency'}: '
            '${locale == 'ro' ? 'Zile specifice · Mar, Joi' : 'Specific days · Tue, Thu'}',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: summary,
          matching: find.text(locale == 'ro' ? 'în pauză' : 'paused'),
        ),
        findsOneWidget,
      );
      expect(find.byType(Switch), findsNothing);
      expect(find.byType(SegmentedButton<bool>), findsNothing);
      expect(find.byIcon(Icons.edit_outlined), findsNothing);
      expect(
        find.widgetWithText(
          OutlinedButton,
          locale == 'ro' ? 'București, România' : 'Bucharest, Romania',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Europe/'), findsNothing);
      expect(adapter.requests, isEmpty);

      // Verify one save round-trip, including the exact schedule identity,
      // saved minutes, selected weekdays, status, and canonical zone.
      if (locale == 'en' && !verifyInvalidDays) {
        final save = find.widgetWithText(FilledButton, 'Save');
        await tester.ensureVisible(save);
        await tester.pumpAndSettle();
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(adapter.requests, hasLength(1));
        expect(
          adapter.requests.single.path,
          endsWith('/schedules/$scheduleId/repair'),
        );
        final body = adapter.requests.single.data as Map;
        expect(body['schedule'], {
          'hour': 8,
          'minute': 45,
          'frequency': 'custom',
          'frequencyDays': [2, 4],
          'isActive': false,
          'timeZone': 'Europe/Bucharest',
        });
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      // Ordinary schedule edits retain their editable controls.
      await openSheet(
        (await db.schedulesDao.getById(scheduleId))!,
        repair: false,
      );
      expect(
        find.byKey(const ValueKey('schedule-repair-summary')),
        findsNothing,
      );
      expect(find.byType(Switch), findsOneWidget);
      expect(find.byType(SegmentedButton<bool>), findsOneWidget);
      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      // Each server review uses an independent fixture. An already rejected
      // frozen request must never be replaced by changing its issue document.
      if (!verifyInvalidDays) return;

      // A different quarantined schedule issue repairs recurrence days. It
      // must keep the saved time, status, and zone while exposing only the
      // controls needed to replace invalid weekday values.
      await (db.update(db.schedules)..where((s) => s.id.equals(scheduleId)))
          .write(const SchedulesCompanion(frequencyDays: Value('[0,8]')));
      await (db.update(
        db.migrationIssues,
      )..where((i) => i.id.equals(issueId))).write(
        const MigrationIssuesCompanion(
          issueCode: Value('invalid_schedule_frequency_days'),
        ),
      );
      final invalidDaysSchedule = (await db.schedulesDao.getById(scheduleId))!;
      adapter.requests.clear();
      await openSheet(
        invalidDaysSchedule,
        repairIssueCode: 'invalid_schedule_frequency_days',
      );
      final frequencyRepairSummary = find.byKey(
        const ValueKey('schedule-repair-summary'),
      );
      expect(frequencyRepairSummary, findsOneWidget);
      final repairLabels = AppLocalizations.of(
        tester.element(frequencyRepairSummary),
      );
      expect(
        find.descendant(
          of: frequencyRepairSummary,
          matching: find.text(
            '${repairLabels.schedules_timeLabel}: '
            '${locale == 'ro' ? '08:45' : '8:45 AM'}',
          ),
        ),
        findsOneWidget,
      );
      expect(find.byType(Switch), findsNothing);
      expect(find.byKey(const ValueKey('schedule-repair-zone')), findsNothing);
      expect(find.byType(SegmentedButton<bool>), findsOneWidget);
      expect(find.textContaining('Europe/'), findsNothing);
      final labels = AppLocalizations.of(
        tester.element(find.byType(SegmentedButton<bool>)),
      );
      final monday = find.text(labels.schedules_dayMon);
      final wednesday = find.text(labels.schedules_dayWed);
      await tester.ensureVisible(monday);
      await tester.tap(monday);
      await tester.ensureVisible(wednesday);
      await tester.tap(wednesday);
      await tester.pumpAndSettle();
      if (locale == 'en') {
        final save = find.widgetWithText(FilledButton, 'Save');
        await tester.ensureVisible(save);
        await tester.pumpAndSettle();
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(adapter.requests, hasLength(1));
        expect(
          adapter.requests.single.path,
          endsWith('/schedules/$scheduleId/repair'),
        );
        final body = adapter.requests.single.data as Map;
        expect(body['schedule'], {
          'hour': 8,
          'minute': 45,
          'frequency': 'custom',
          'frequencyDays': [1, 3],
          'isActive': false,
          'timeZone': 'Europe/Bucharest',
        });
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }

  for (final accessible in [false, true]) {
    testWidgets(
      'PRN repair preserves as-needed semantics and explains stale review accessible=$accessible',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(412, 914));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final f = await _reviewFixture();
        final db = f.db;
        final scheduleId = f.occurrence.scheduleId!;
        const issueId = '10000000-0000-4000-8000-000000000004';
        await (db.update(
          db.schedules,
        )..where((s) => s.id.equals(scheduleId))).write(
          SchedulesCompanion(
            frequency: Value(accessible ? 'invalid-legacy' : 'prn'),
            isActive: Value(!accessible),
            syncStatus: const Value('synced'),
            serverId: Value(scheduleId),
          ),
        );
        await (db.update(db.pills)..where((p) => p.id.equals(f.pill.id))).write(
          PillsCompanion(
            isPrn: const Value(true),
            syncStatus: const Value('synced'),
            serverId: Value(f.pill.id),
          ),
        );
        final schedule = (await db.schedulesDao.getById(scheduleId))!;
        final now = DateTime.utc(2026, 10, 6);
        await db.migrationIssuesDao.record(
          MigrationIssuesCompanion.insert(
            id: issueId,
            userId: f.workspace.context.ownerUserId,
            entityType: 'schedules',
            entityId: scheduleId,
            issueCode: 'schedule_timezone_review_required',
            snapshotJson: '{}',
            serverId: const Value(issueId),
            createdAt: now,
            updatedAt: now,
          ),
        );
        final adapter = _ConflictAdapter();
        final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid'))
          ..httpClientAdapter = adapter;
        final repository = ScheduleRepositoryImpl(
          schedulesDao: db.schedulesDao,
          pillsDao: db.pillsDao,
          profilesDao: db.profilesDao,
          ledgerDao: db.medicationLedgerDao,
          migrationIssuesDao: db.migrationIssuesDao,
          pendingOperations: PendingOperationRepository(db),
          dio: dio,
          reconcileProjections: () async {},
        );
        addTearDown(() async {
          dio.close();
          await db.close();
        });
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              scheduleRepositoryProvider.overrideWithValue(repository),
            ],
            child: MaterialApp(
              locale: Locale(accessible ? 'ro' : 'en'),
              theme: reviewRenderingTheme(
                accessible ? AppTheme.dark() : AppTheme.light(),
              ),
              builder: (context, child) => RepaintBoundary(
                key: reviewCaptureKey,
                child: MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(accessible ? 2 : 1),
                    disableAnimations: accessible,
                  ),
                  child: child!,
                ),
              ),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showAddEditScheduleSheet(
                      context: context,
                      pillId: f.pill.id,
                      pillIsPrn: true,
                      schedule: schedule,
                      repairIssueId: issueId,
                      repairIssueRevision: 1,
                      repairIssueCode: 'schedule_timezone_review_required',
                    ),
                    child: const Text('Open review'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open review'));
        await tester.pumpAndSettle();
        expect(find.byType(SegmentedButton<bool>), findsNothing);
        expect(find.text('09:00'), findsNothing);
        expect(
          find.text(accessible ? 'La nevoie' : 'As needed'),
          findsOneWidget,
        );
        final zoneControl = find.byKey(const ValueKey('schedule-repair-zone'));
        final initialLabel = accessible
            ? 'Timpul universal coordonat'
            : 'Coordinated Universal Time';
        expect(zoneControl, findsOneWidget);
        expect(
          find.widgetWithText(OutlinedButton, initialLabel),
          findsOneWidget,
        );
        expect(find.byType(TextField), findsNothing);
        await tester.ensureVisible(zoneControl);
        await tester.tap(zoneControl);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'London');
        await tester.pumpAndSettle();
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(
          find.widgetWithText(OutlinedButton, initialLabel),
          findsOneWidget,
        );
        expect(adapter.requests, isEmpty);

        await tester.tap(zoneControl);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(TextField),
          accessible ? 'Bucuresti' : 'Bucharest',
        );
        await tester.pumpAndSettle();
        final selectedLabel = accessible
            ? 'București, România'
            : 'Bucharest, Romania';
        await tester.tap(find.widgetWithText(ListTile, selectedLabel));
        await tester.pumpAndSettle();
        expect(
          find.widgetWithText(OutlinedButton, selectedLabel),
          findsOneWidget,
        );
        expect(find.textContaining('Europe/'), findsNothing);
        expect(adapter.requests, isEmpty);
        await captureReview(
          tester,
          accessible ? 'prn-review-ro-dark-large' : 'prn-review-light',
        );
        await tester.scrollUntilVisible(
          find.text(accessible ? 'Salvează' : 'Save'),
          180,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.pumpAndSettle();
        await captureReview(
          tester,
          accessible ? 'prn-review-ro-dark-large-save' : 'prn-review-save',
        );
        await tester.tap(find.text(accessible ? 'Salvează' : 'Save'));
        await tester.pumpAndSettle();
        expect(adapter.requests, hasLength(1));
        final body = adapter.requests.single.data as Map;
        expect(body['schedule'], {
          'hour': 9,
          'minute': 0,
          'frequency': 'prn',
          'frequencyDays': null,
          'isActive': !accessible,
          'timeZone': 'Europe/Bucharest',
        });
        expect(
          find.text(
            accessible
                ? 'Această revizuire s-a modificat sau nu mai este pregătită. Sincronizează, apoi deschide-o din nou.'
                : 'This review changed or is no longer ready. Sync, then open it again.',
          ),
          findsOneWidget,
        );
        await tester.ensureVisible(
          find.textContaining(
            accessible ? 'Această revizuire' : 'This review changed',
          ),
        );
        await tester.pumpAndSettle();
        await captureReview(
          tester,
          accessible ? 'prn-review-ro-dark-large-error' : 'prn-review-error',
        );
        expect(
          find.descendant(
            of: find.byType(DraggableScrollableSheet),
            matching: find.textContaining(
              accessible ? 'Această revizuire' : 'This review changed',
            ),
          ),
          findsOneWidget,
        );
        await tester.runAsync(() async {
          expect(await db.schedulesDao.getById(scheduleId), schedule);
          expect(
            (await db.migrationIssuesDao.getById(issueId))!.resolutionState,
            'unresolved',
          );
        });
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }
}
