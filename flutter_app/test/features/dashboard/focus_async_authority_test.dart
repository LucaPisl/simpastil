import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_provider.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/core/workspace/workspace_provider.dart';
import 'package:simpastil/features/dashboard/focus_deck.dart';
import 'package:simpastil/features/dashboard/selected_date_provider.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import '../../helpers/care_recording_fixture.dart';
import '../../helpers/window_view.dart';

class _ServiceGate {
  final requested = Completer<void>();
  final result = Completer<CareRecordingService>();
  late CareRecordingService service;

  Future<CareRecordingService> load() {
    if (!requested.isCompleted) requested.complete();
    return result.future;
  }

  void release() {
    if (!result.isCompleted) result.complete(service);
  }
}

class _AfterSaveGate {
  final reached = Completer<void>();
  final release = Completer<void>();

  Future<void> wait() async {
    if (!reached.isCompleted) reached.complete();
    await release.future;
  }
}

class _FocusPrnHarness {
  _FocusPrnHarness(this.fixture, this.container, this.serviceGate);

  final CareRecordingFixture fixture;
  final ProviderContainer container;
  final _ServiceGate serviceGate;
}

Future<_FocusPrnHarness> _mountFocusPrn(
  WidgetTester tester, {
  _AfterSaveGate? afterSave,
}) async {
  final fixture = await CareRecordingFixture.create(connected: true);
  await (fixture.db.update(fixture.db.pills)
        ..where((row) => row.id.equals(fixture.pill.id)))
      .write(const PillsCompanion(isPrn: Value(true)));
  await (fixture.db.update(
    fixture.db.schedules,
  )..where((row) => row.pillId.equals(fixture.pill.id))).write(
    const SchedulesCompanion(
      frequency: Value('prn'),
      timeZone: Value('UTC'),
      timeZoneStatus: Value('known'),
    ),
  );
  final gate = _ServiceGate()
    ..service = CareRecordingService(
      database: fixture.db,
      access: fixture.workspace.access,
      context: fixture.workspace.context,
      afterCareSave: afterSave?.wait,
    );
  final container = await fixture.workspace.createContainer(
    extraOverrides: [
      careRecordingServiceProvider.overrideWith((_) => gate.load()),
    ],
  );
  container.read(selectedDateProvider.notifier).select(DateTime(2026, 9, 30));
  useWindow(tester, const Size(412, 914));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    gate.release();
    container.dispose();
    await tester.pump(const Duration(milliseconds: 1));
    await fixture.db.close();
    await tester.pumpAndSettle();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: AppTheme.light(),
        home: const FocusTodayScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final action = find.byKey(ValueKey('as-needed-card-${fixture.pill.id}'));
  await tester.scrollUntilVisible(
    action,
    220,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  expect(action.hitTestable(), findsOneWidget);
  return _FocusPrnHarness(fixture, container, gate);
}

/// Holds the as-needed card long enough to record, then lets go.
Future<void> _holdCard(WidgetTester tester, _FocusPrnHarness harness) async {
  final gesture = await tester.startGesture(
    tester.getCenter(
      find.byKey(ValueKey('as-needed-card-${harness.fixture.pill.id}')),
    ),
  );
  await tester.pump(); // the ticker's first frame has zero elapsed time
  await tester.pump(const Duration(milliseconds: 900));
  await gesture.up();
  await tester.pump();
}

Future<void> _replaceSameOwnerGrant(_FocusPrnHarness harness) async {
  final fixture = harness.fixture;
  final access = fixture.workspace.access;
  const endpoint = 'https://fictional-workspace.test/care';
  final epoch = await access.configureEndpoint(endpoint);
  await fixture.db
      .into(fixture.db.credentialSlots)
      .insert(
        CredentialSlotsCompanion.insert(
          id: 'fictional-focus-replacement-slot',
          ownerId: fixture.workspace.context.ownerUserId,
          endpoint: endpoint,
          state: 'staged',
          createdAt: DateTime.now().toUtc(),
        ),
      );
  final next = await access.authenticate(
    ownerId: fixture.workspace.context.ownerUserId,
    endpoint: endpoint,
    expectedNetworkEpoch: epoch,
    sessionGeneration: 1,
    credentialId: 'fictional-focus-replacement-slot',
  );
  if (next.workspace.bindingState != 'bound') {
    await access.confirmOriginalServer(
      workspaceId: next.workspace.id,
      reviewedOriginalEndpoint: endpoint,
      expectedNetworkEpoch: next.network.epoch,
    );
  }
  final updated = Completer<void>();
  final subscription = harness.container.listen(workspaceContextProvider, (
    _,
    value,
  ) {
    final context = value.asData?.value;
    if (context != null &&
        context.ownerUserId == fixture.workspace.context.ownerUserId &&
        context.networkEpoch == next.network.epoch &&
        !updated.isCompleted) {
      updated.complete();
    }
  }, fireImmediately: true);
  await updated.future.timeout(const Duration(seconds: 5));
  subscription.close();
}

Future<void> _pumpUntil(WidgetTester tester, Future<void> future) async {
  var complete = false;
  Object? failure;
  StackTrace? stack;
  future.then(
    (_) => complete = true,
    onError: (Object error, StackTrace trace) {
      failure = error;
      stack = trace;
      complete = true;
    },
  );
  for (var i = 0; i < 200 && !complete; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(complete, isTrue, reason: 'The gated operation should finish');
  if (failure != null) Error.throwWithStackTrace(failure!, stack!);
}

Future<T> _read<T>(WidgetTester tester, Future<T> future) async {
  var complete = false;
  T? value;
  Object? failure;
  future.then(
    (result) {
      value = result;
      complete = true;
    },
    onError: (Object error) {
      failure = error;
      complete = true;
    },
  );
  for (var i = 0; i < 200 && !complete; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(complete, isTrue, reason: 'The database query should finish');
  if (failure != null) throw failure!;
  return value as T;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  testWidgets('current delayed PRN authority records the held dose', (
    tester,
  ) async {
    final harness = await _mountFocusPrn(tester);
    await _holdCard(tester, harness);
    await _pumpUntil(tester, harness.serviceGate.requested.future);
    harness.serviceGate.release();
    await tester.pumpAndSettle();
    expect(
      await _read(
        tester,
        harness.fixture.db.select(harness.fixture.db.occurrenceEvents).get(),
      ),
      hasLength(1),
    );
  });

  for (final transition in ['same-owner grant', 'day change', 'unmount']) {
    testWidgets('delayed PRN action stops after $transition', (tester) async {
      final harness = await _mountFocusPrn(tester);
      await _holdCard(tester, harness);
      await _pumpUntil(tester, harness.serviceGate.requested.future);

      if (transition == 'same-owner grant') {
        await _pumpUntil(tester, _replaceSameOwnerGrant(harness));
      } else if (transition == 'day change') {
        harness.container
            .read(selectedDateProvider.notifier)
            .select(DateTime(2026, 9, 29));
        await tester.pumpAndSettle();
      } else {
        await tester.pumpWidget(const SizedBox.shrink());
      }

      harness.serviceGate.release();
      await tester.pumpAndSettle();
      expect(
        await _read(
          tester,
          harness.fixture.db.select(harness.fixture.db.occurrenceEvents).get(),
        ),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'unmounted PRN card keeps committed care without stale feedback',
    (tester) async {
      final saved = _AfterSaveGate();
      final harness = await _mountFocusPrn(tester, afterSave: saved);
      harness.serviceGate.release();
      await _holdCard(tester, harness);
      await _pumpUntil(tester, saved.reached.future);
      final events = await _read(
        tester,
        harness.fixture.db.select(harness.fixture.db.occurrenceEvents).get(),
      );
      expect(events, hasLength(1));
      expect(events.single.action, 'take');

      await tester.pumpWidget(const SizedBox.shrink());
      saved.release.complete();
      await tester.pumpAndSettle();
      expect(
        await _read(
          tester,
          harness.fixture.db.select(harness.fixture.db.occurrenceEvents).get(),
        ),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
