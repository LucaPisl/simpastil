import 'package:simpastil/core/inventory/exact_stock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/features/analytics/stock_changes.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

final _day = DateTime(2026, 10, 15);

/// Built from local clock times, so the tests hold in any time zone.
DateTime _at(int day, int hour, [int minute = 0]) =>
    DateTime(2026, 10, day, hour, minute).toUtc();

InventoryEvent _event(
  String id,
  String kind,
  int delta,
  DateTime at, {
  String pillId = 'ficat',
  String? provenanceJson,
  int? serverSequence,
}) => InventoryEvent(
  id: id,
  userId: 'u',
  pillId: pillId,
  commandId: 'c-$id',
  kind: kind,
  delta: '$delta',
  origin: 'native',
  provenanceJson: provenanceJson,
  serverSequence: serverSequence,
  recordedAt: at,
);

final _ficat = (
  name: 'Pastila ficat',
  color: '#E57373',
  profileId: 'luca',
  currentStock: ExactStock.fromInt(46),
);

List<(String, int, int)> _summary(List<StockChange> changes) => [
  for (final c in changes) (c.eventId, c.before.floor, c.after.floor),
];

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('stockChangesForDay', () {
    test('reads a dose as the stock before and after it', () {
      final changes = stockChangesForDay(
        day: _day,
        events: [
          _event('open', 'opening', 50, _at(1, 9)),
          _event('d1', 'dose', -1, _at(14, 9)),
          _event('d2', 'dose', -1, _at(15, 22, 35)),
          _event('d3', 'dose', -2, _at(16, 8)),
        ],
        // 50 - 1 - 1 - 2 = 46 after the last event.
        pills: {'ficat': _ficat},
      );
      expect(_summary(changes), [('d2', 49, 48)]);
      expect(changes.single.pillName, 'Pastila ficat');
      expect(changes.single.kind, 'dose');
      expect(changes.single.at, _at(15, 22, 35).toLocal());
    });

    test(
      'walks back from the current stock when the ledger has no opening',
      () {
        final changes = stockChangesForDay(
          day: _day,
          events: [
            _event('d1', 'dose', -1, _at(15, 8)),
            _event('d2', 'dose', -1, _at(15, 20)),
          ],
          pills: {'ficat': _ficat},
        );
        // The newest first; the ledger ends at the current stock, 46.
        expect(_summary(changes), [('d2', 47, 46), ('d1', 48, 47)]);
      },
    );

    test('counts forward from the ledger when stock is not tracked', () {
      final changes = stockChangesForDay(
        day: _day,
        events: [
          _event('open', 'opening', 30, _at(1, 9)),
          _event('r', 'refill', 20, _at(15, 10)),
        ],
        pills: {
          'ficat': (
            name: 'Pastila ficat',
            color: null,
            profileId: 'luca',
            currentStock: null,
          ),
        },
      );
      expect(_summary(changes), [('r', 30, 50)]);
      expect(changes.single.kind, 'refill');
    });

    test('shows refills, corrections and undone doses, never the opening', () {
      final changes = stockChangesForDay(
        day: _day,
        events: [
          _event('open', 'opening', 15, _at(15, 7)),
          _event('d', 'dose', -1, _at(15, 8)),
          _event('u', 'dose_reversal', 1, _at(15, 9)),
          _event('r', 'refill', 30, _at(15, 10)),
          _event('c', 'correction', -4, _at(15, 11)),
        ],
        pills: {'ficat': _ficat}, // 15 - 1 + 1 + 30 - 4 = 41, mirror says 46
      );
      expect(changes.map((c) => c.kind), [
        'correction',
        'refill',
        'dose_reversal',
        'dose',
      ]);
      // The newest change always ends at the pill's current stock.
      expect(changes.first.after, ExactStock.fromInt(46));
      expect(changes.first.before, ExactStock.fromInt(50));
    });

    test('orders changes of several medications newest first', () {
      final changes = stockChangesForDay(
        day: _day,
        events: [
          _event('a', 'dose', -1, _at(15, 8)),
          _event('b', 'dose', -1, _at(15, 21), pillId: 'fevarin'),
          _event('c', 'dose', -1, _at(15, 12)),
        ],
        pills: {
          'ficat': _ficat,
          'fevarin': (
            name: 'Fevarin',
            color: null,
            profileId: 'luca',
            currentStock: ExactStock.fromInt(9),
          ),
        },
      );
      expect(changes.map((c) => c.eventId), ['b', 'c', 'a']);
      expect(changes.first.pillName, 'Fevarin');
      expect(changes.first.before, ExactStock.fromInt(10));
    });

    test('leaves out medications that are not in view', () {
      final changes = stockChangesForDay(
        day: _day,
        events: [
          _event('a', 'dose', -1, _at(15, 8)),
          _event('b', 'dose', -1, _at(15, 9), pillId: 'gone'),
        ],
        pills: {'ficat': _ficat},
      );
      expect(changes.map((c) => c.eventId), ['a']);
    });

    test('leaves out doses already folded into an opening count', () {
      final changes = stockChangesForDay(
        day: _day,
        events: [
          _event(
            'folded',
            'dose',
            -1,
            _at(15, 7),
            provenanceJson: '{"foldedIntoOpening":"m-1"}',
          ),
          _event('d', 'dose', -1, _at(15, 8)),
        ],
        pills: {'ficat': _ficat},
      );
      expect(_summary(changes), [('d', 47, 46)]);
    });

    test('is empty on a day without changes', () {
      expect(
        stockChangesForDay(
          day: _day,
          events: [_event('a', 'dose', -1, _at(14, 23, 59))],
          pills: {'ficat': _ficat},
        ),
        isEmpty,
      );
      expect(stockChangesForDay(day: _day, events: [], pills: {}), isEmpty);
    });

    test('uses the local day an event was recorded, midnight to midnight', () {
      final changes = stockChangesForDay(
        day: _day,
        events: [
          _event('before', 'dose', -1, _at(14, 23, 59)),
          _event('first', 'dose', -1, _at(15, 0, 0)),
          _event('last', 'dose', -1, _at(15, 23, 59)),
          _event('after', 'dose', -1, _at(16, 0, 0)),
        ],
        pills: {'ficat': _ficat},
      );
      expect(changes.map((c) => c.eventId), ['last', 'first']);
    });

    test('keeps two events at one instant in the server order', () {
      final at = _at(15, 8);
      final changes = stockChangesForDay(
        day: _day,
        events: [
          _event('b', 'dose', -1, at, serverSequence: 2),
          _event('a', 'dose', -1, at, serverSequence: 1),
        ],
        pills: {'ficat': _ficat},
      );
      expect(changes.map((c) => (c.eventId, c.before, c.after)).toSet(), {
        ('a', ExactStock.fromInt(48), ExactStock.fromInt(47)),
        ('b', ExactStock.fromInt(47), ExactStock.fromInt(46)),
      });
    });
  });
}
