import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import 'package:simpastil/core/workspace/workspace_provider.dart';
import 'package:simpastil/features/dashboard/as_needed/as_needed_controller.dart';
import 'package:simpastil/features/dashboard/as_needed/as_needed_option.dart';
import 'package:simpastil/features/dashboard/as_needed/as_needed_summary.dart';

class _Option extends Fake implements AsNeededOption {
  @override
  String get pillId => 'pill-1';
  @override
  bool get needsReview => false;
}

void main() {
  late AsNeededController controller;
  late List<DateTime?> asked;
  late Completer<bool>? answer;
  late String day;

  Future<void> host(WidgetTester tester) async {
    asked = [];
    answer = null;
    // A dose just taken puts one more at the daily maximum right now.
    final now = DateTime.now();
    final summary = AsNeededSummary(
      pillId: 'pill-1',
      doses: [
        AsNeededDose(
          occurrenceId: 'o1',
          pillId: 'pill-1',
          day: DateTime(now.year, now.month, now.day),
          takenAt: now.subtract(const Duration(minutes: 1)),
          amount: MedicationAmount.known('1', 'tablet'),
          note: null,
        ),
      ],
      today: DateTime(now.year, now.month, now.day),
      stock: null,
      maxPer24h: 1,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          asNeededSummariesProvider.overrideWith(
            (ref) => Stream.value({'pill-1': summary}),
          ),
          // Never resolves, so a recording that passes the limit check stops
          // there and returns false.
          workspaceContextProvider.overrideWith(
            (ref) => StreamController<WorkspaceContext>().stream,
          ),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            ref.watch(asNeededSummariesProvider);
            controller = AsNeededController(
              ref: ref,
              localDate: () => day,
              canFeel: () => false,
              onUndoStockUnchanged: () {},
              confirmOverLimit: (option, state) {
                asked.add(DateTime.now());
                answer = Completer<bool>();
                return answer!.future;
              },
            );
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a past day with no known time is not judged at now', (
    tester,
  ) async {
    day = routineDateKey(DateTime.now().subtract(const Duration(days: 3)));
    await host(tester);
    final ok = await controller.record(
      _Option(),
      amount: MedicationAmount.known('1', 'tablet'),
      at: null,
    );
    expect(ok, isFalse);
    expect(asked, isEmpty);
    expect(controller.declinedOverLimit, isFalse);
  });

  testWidgets('today with no time is still judged at now', (tester) async {
    day = routineDateKey(DateTime.now());
    await host(tester);
    final first = controller.record(
      _Option(),
      amount: MedicationAmount.known('1', 'tablet'),
      at: null,
    );
    await tester.pump();
    expect(asked, hasLength(1));
    answer!.complete(false);
    expect(await first, isFalse);
    expect(controller.declinedOverLimit, isTrue);
  });

  testWidgets('a second record while the warning is open does nothing', (
    tester,
  ) async {
    day = routineDateKey(DateTime.now());
    await host(tester);
    final first = controller.record(
      _Option(),
      amount: MedicationAmount.known('1', 'tablet'),
      at: null,
    );
    await tester.pump();
    final second = await controller.record(
      _Option(),
      amount: MedicationAmount.known('1', 'tablet'),
      at: null,
    );
    expect(second, isFalse);
    // Ignored because the first is still open: not a save that failed.
    expect(controller.ignoredWhileBusy, isTrue);
    expect(controller.declinedOverLimit, isFalse);
    expect(asked, hasLength(1), reason: 'no second dialog');
    answer!.complete(false);
    expect(await first, isFalse);
    // After the dialog closes a new attempt asks again.
    final third = controller.record(
      _Option(),
      amount: MedicationAmount.known('1', 'tablet'),
      at: null,
    );
    await tester.pump();
    expect(asked, hasLength(2));
    answer!.complete(false);
    await third;
  });

  testWidgets('a throw while the limit warning is open releases the guard', (
    tester,
  ) async {
    day = routineDateKey(DateTime.now());
    await host(tester);
    final first = controller.record(
      _Option(),
      amount: MedicationAmount.known('1', 'tablet'),
      at: null,
    );
    await tester.pump();
    answer!.completeError(StateError('dialog failed'));
    await expectLater(first, throwsStateError);
    expect(controller.ignoredWhileBusy, isFalse);
    // The next attempt is not locked out: it asks again.
    final next = controller.record(
      _Option(),
      amount: MedicationAmount.known('1', 'tablet'),
      at: null,
    );
    await tester.pump();
    expect(asked, hasLength(2));
    expect(controller.ignoredWhileBusy, isFalse);
    answer!.complete(false);
    await next;
  });
}
