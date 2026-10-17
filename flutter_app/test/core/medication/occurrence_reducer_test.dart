import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/occurrence_reducer.dart';

void main() {
  test('rebases take and skip intent against the fetched server head', () {
    final cases = [
      (
        MedicationState.pending,
        MedicationAction.take,
        MedicationAction.take,
        MedicationState.taken,
        -1,
      ),
      (
        MedicationState.pending,
        MedicationAction.skip,
        MedicationAction.skip,
        MedicationState.skipped,
        0,
      ),
      (
        MedicationState.taken,
        MedicationAction.take,
        MedicationAction.correct,
        MedicationState.taken,
        0,
      ),
      (
        MedicationState.taken,
        MedicationAction.skip,
        MedicationAction.correct,
        MedicationState.skipped,
        1,
      ),
      (
        MedicationState.skipped,
        MedicationAction.take,
        MedicationAction.correct,
        MedicationState.taken,
        -1,
      ),
      (
        MedicationState.skipped,
        MedicationAction.skip,
        MedicationAction.correct,
        MedicationState.skipped,
        0,
      ),
    ];

    for (final (head, intent, action, target, delta) in cases) {
      final result = rebaseMedicationIntent(
        serverState: head,
        intendedAction: intent,
      );
      expect(result.blocked, isFalse);
      expect(result.action, action);
      expect(result.toState, target);
      expect(result.inventoryDelta, delta);
    }
  });

  test('undo and correction require the exact current event head', () {
    final undo = rebaseMedicationIntent(
      serverState: MedicationState.taken,
      intendedAction: MedicationAction.undo,
      intendedState: MedicationState.pending,
      reversesEventId: 'event-head',
      headEventId: 'event-head',
    );
    expect(undo.blocked, isFalse);
    expect(undo.toState, MedicationState.pending);
    expect(undo.inventoryDelta, 1);

    final stale = rebaseMedicationIntent(
      serverState: MedicationState.taken,
      intendedAction: MedicationAction.correct,
      intendedState: MedicationState.skipped,
      reversesEventId: 'old-event',
      headEventId: 'event-head',
    );
    expect(stale.blocked, isTrue);
    expect(stale.inventoryDelta, 0);
  });

  test('the stock change of every transition through the missed state', () {
    MedicationRebaseResult rebase(
      MedicationState from,
      MedicationAction action, [
      MedicationState? to,
    ]) => rebaseMedicationIntent(
      serverState: from,
      intendedAction: action,
      intendedState: to,
      reversesEventId: 'head',
      headEventId: 'head',
    );

    // Recording the miss moves no stock.
    final miss = rebase(MedicationState.pending, MedicationAction.miss);
    expect(miss.toState, MedicationState.missed);
    expect(miss.inventoryDelta, 0);

    // A late take is a correction of the miss and uses one unit.
    final late = rebase(MedicationState.missed, MedicationAction.take);
    expect(late.action, MedicationAction.correct);
    expect(late.toState, MedicationState.taken);
    expect(late.inventoryDelta, -1);

    // Withdrawing the late take returns the unit and lands on the miss.
    final undoLate = rebase(
      MedicationState.taken,
      MedicationAction.undo,
      MedicationState.missed,
    );
    expect(undoLate.toState, MedicationState.missed);
    expect(undoLate.inventoryDelta, 1);

    // Skipping a missed dose uses nothing.
    final skip = rebase(MedicationState.missed, MedicationAction.skip);
    expect(skip.action, MedicationAction.correct);
    expect(skip.toState, MedicationState.skipped);
    expect(skip.inventoryDelta, 0);

    // Withdrawing the miss itself uses nothing.
    final undoMiss = rebase(
      MedicationState.missed,
      MedicationAction.undo,
      MedicationState.pending,
    );
    expect(undoMiss.toState, MedicationState.pending);
    expect(undoMiss.inventoryDelta, 0);

    // Taken straight to missed is never a valid correction.
    final back = rebase(
      MedicationState.taken,
      MedicationAction.correct,
      MedicationState.missed,
    );
    expect(back.blocked, isTrue);
    expect(back.reason, 'correct_to_missed');
  });

  test('missing, mismatched, or superseded occurrences fail closed', () {
    final missing = rebaseMedicationIntent(
      serverState: null,
      intendedAction: MedicationAction.take,
    );
    final superseded = rebaseMedicationIntent(
      serverState: MedicationState.pending,
      intendedAction: MedicationAction.take,
      isSuperseded: true,
    );
    final mismatched = rebaseMedicationIntent(
      serverState: MedicationState.pending,
      intendedAction: MedicationAction.take,
      identityMatches: false,
    );

    expect([
      missing.blocked,
      superseded.blocked,
      mismatched.blocked,
    ], everyElement(true));
  });
  group('shared reducer vectors', () {
    final fixture =
        jsonDecode(
              File(
                '../contracts/fixtures/occurrence-reducer-v1.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    MedicationState state(String name) => MedicationState.values.byName(name);
    MedicationAction action(String name) =>
        MedicationAction.values.byName(name);

    test('every transition row matches the server reducer', () {
      final rows = fixture['transitions'] as List<dynamic>;
      expect(rows, isNotEmpty);
      for (final row in rows) {
        final item = row as Map<String, dynamic>;
        final target = item['targetState'] as String?;
        final intended = action(item['action'] as String);
        final result = rebaseMedicationIntent(
          serverState: state(item['fromState'] as String),
          intendedAction: intended,
          intendedState: target == null ? null : state(target),
          reversesEventId: 'head',
          headEventId: 'head',
        );
        expect(result.blocked, isFalse, reason: '$item');
        expect(
          result.action,
          action(item['effectiveAction'] as String),
          reason: '$item',
        );
        expect(
          result.toState,
          state(item['toState'] as String),
          reason: '$item',
        );
        expect(result.inventoryDelta, item['inventoryDelta'], reason: '$item');
      }
    });

    test('every rejected row is blocked', () {
      final rows = fixture['rejected'] as List<dynamic>;
      expect(rows, isNotEmpty);
      for (final row in rows) {
        final item = row as Map<String, dynamic>;
        final target = item['targetState'] as String?;
        final result = rebaseMedicationIntent(
          serverState: state(item['fromState'] as String),
          intendedAction: action(item['action'] as String),
          intendedState: target == null ? null : state(target),
          reversesEventId: 'head',
          headEventId: 'head',
        );
        expect(result.blocked, isTrue, reason: '$item');
        expect(result.inventoryDelta, 0, reason: '$item');
      }
    });

    test('undo rows return to the state before the head event', () {
      final rows = fixture['undo'] as List<dynamic>;
      expect(rows, isNotEmpty);
      for (final row in rows) {
        final item = row as Map<String, dynamic>;
        final referenced = item['referenced'] as Map<String, dynamic>;
        // The Dart side derives the stock effect from the two states. A
        // reference recorded without tracked stock has a null delta and
        // restores no unit; that case is decided by the event, not here.
        if (referenced['inventoryDelta'] == null) continue;
        final result = rebaseMedicationIntent(
          serverState: state(item['fromState'] as String),
          intendedAction: MedicationAction.undo,
          intendedState: state(item['toState'] as String),
          reversesEventId: 'head',
          headEventId: 'head',
        );
        expect(result.blocked, isFalse, reason: '$item');
        expect(
          result.toState,
          state(item['toState'] as String),
          reason: '$item',
        );
        expect(result.inventoryDelta, item['inventoryDelta'], reason: '$item');
      }
    });

    test('a miss is dropped, not rebased, once another device moved it', () {
      for (final from in [
        MedicationState.taken,
        MedicationState.skipped,
        MedicationState.missed,
      ]) {
        final result = rebaseMedicationIntent(
          serverState: from,
          intendedAction: MedicationAction.miss,
        );
        expect(result.blocked, isTrue);
        expect(result.reason, 'miss_not_pending');
      }
    });
  });
}
