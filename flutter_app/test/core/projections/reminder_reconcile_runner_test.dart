import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/projections/projection_reconciler.dart';
import 'package:simpastil/core/projections/reminder_id_ledger.dart';
import 'package:simpastil/core/projections/reminder_reconcile_runner.dart';

void main() {
  const ok = ReconcileAllResult(ready: true);
  const busy = ReconcileAllResult(ready: true, busy: true);

  test('concurrent triggers coalesce into one run plus one rerun', () async {
    final gates = <Completer<ReconcileAllResult>>[];
    final refreshes = <bool>[];
    final runner = ReminderReconcileRunner(
      pass: ({locale, refreshActiveActions = false, buildKey}) {
        refreshes.add(refreshActiveActions);
        final gate = Completer<ReconcileAllResult>();
        gates.add(gate);
        return gate.future;
      },
    );

    final first = runner.run();
    final queued = [
      runner.run(),
      runner.run(refreshActiveActions: true),
      runner.run(),
    ];
    await Future<void>.delayed(Duration.zero);
    expect(gates, hasLength(1));

    gates.single.complete(ok);
    expect(await first, ok);
    await Future<void>.delayed(Duration.zero);
    expect(gates, hasLength(2));
    gates.last.complete(ok);
    expect(await Future.wait(queued), everyElement(ok));
    // The rerun carries the strongest request of everything it absorbed.
    expect(refreshes, [false, true]);
    expect(runner.passesStarted, 2);
  });

  test('a request queued during an unhealthy pass skips the backoff', () async {
    final gates = <Completer<ReconcileAllResult>>[];
    final waits = <Duration>[];
    final runner = ReminderReconcileRunner(
      pass: ({locale, refreshActiveActions = false, buildKey}) {
        final gate = Completer<ReconcileAllResult>();
        gates.add(gate);
        return gate.future;
      },
      delay: (d) {
        waits.add(d);
        return Completer<void>().future;
      },
    );
    final first = runner.run();
    final queued = runner.run();
    gates.single.complete(busy);
    await first;
    await Future<void>.delayed(Duration.zero);
    expect(waits, isEmpty);
    expect(gates, hasLength(2));
    gates.last.complete(ok);
    expect(await queued, ok);
  });

  test('a busy result is retried with bounded backoff', () async {
    var calls = 0;
    final waits = <Duration>[];
    final runner = ReminderReconcileRunner(
      pass: ({locale, refreshActiveActions = false, buildKey}) async =>
          ++calls < 3 ? busy : ok,
      delay: (d) async => waits.add(d),
    );
    expect(await runner.run(), busy, reason: 'callers get the first result');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(calls, 3);
    expect(waits, reminderRetryDelays.take(2));
  });

  test('retries stop at the bound and a throwing pass is contained', () async {
    var calls = 0;
    final runner = ReminderReconcileRunner(
      pass: ({locale, refreshActiveActions = false, buildKey}) async {
        calls++;
        throw StateError('boom');
      },
      delay: (_) async {},
    );
    final result = await runner.run();
    expect(result.healthy, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(calls, reminderRetryDelays.length + 1);
  });

  test('a request during a backoff becomes the retry', () async {
    var calls = 0;
    final sleeping = Completer<void>();
    final runner = ReminderReconcileRunner(
      pass: ({locale, refreshActiveActions = false, buildKey}) async =>
          ++calls == 1 ? busy : ok,
      delay: (_) => sleeping.future,
    );
    await runner.run();
    await Future<void>.delayed(Duration.zero);
    expect(await runner.run(), ok);
    expect(calls, 2);
    sleeping.complete();
  });

  group('id ledger', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('keeps the first time and bounds its size', () async {
      final ledger = ReminderIdLedger(await SharedPreferences.getInstance());
      final t0 = DateTime.utc(2026, 1, 1);
      await ledger.record([1, 2], t0);
      await ledger.record([2, 3], t0.add(const Duration(hours: 1)));
      expect(ledger.read()[2], t0);
      expect(ledger.read()[3], t0.add(const Duration(hours: 1)));
      await ledger.record(
        List.generate(reminderIdLedgerLimit + 10, (i) => 100 + i),
        t0.add(const Duration(hours: 2)),
      );
      expect(ledger.read(), hasLength(reminderIdLedgerLimit));
      expect(ledger.read().containsKey(1), isFalse);
    });

    test('a malformed ledger reads as empty', () async {
      SharedPreferences.setMockInitialValues({reminderIdLedgerKey: '{nope'});
      final ledger = ReminderIdLedger(await SharedPreferences.getInstance());
      expect(ledger.read(), isEmpty);
    });
  });
}
