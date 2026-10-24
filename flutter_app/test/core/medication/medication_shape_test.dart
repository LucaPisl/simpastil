import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/medication_shape.dart';

ImprintSubject _s(String id, String name, MedicationShape shape) =>
    (id: id, name: name, shape: shape);

void main() {
  group('wire names', () {
    test('the nine names round-trip and an unknown one reads as none', () {
      expect(MedicationShape.values, hasLength(9));
      for (final shape in MedicationShape.values) {
        expect(MedicationShape.fromWire(shape.wire), shape);
      }
      expect(MedicationShape.fromWire('hexagon'), isNull);
      expect(MedicationShape.fromWire(null), isNull);
    });
  });

  group('suggestion', () {
    test(
      'starts from the form: tablet round, capsule capsule, liquid drop',
      () {
        expect(suggestMedicationShape(form: 'Tablet'), MedicationShape.round);
        expect(
          suggestMedicationShape(form: 'capsule'),
          MedicationShape.capsule,
        );
        expect(suggestMedicationShape(form: 'Syrup'), MedicationShape.drop);
        expect(suggestMedicationShape(form: 'Drops'), MedicationShape.drop);
        expect(
          suggestMedicationShape(form: 'comprimat'),
          MedicationShape.round,
        );
      },
    );

    test('skips a shape the person already uses', () {
      final next = suggestMedicationShape(
        form: 'Tablet',
        used: [MedicationShape.round],
      );
      expect(next, isNot(MedicationShape.round));
      expect(next, MedicationShape.oval);
    });

    test('walks on until it finds an unused one, then gives the form back', () {
      final used = <MedicationShape>[];
      final picked = <MedicationShape>[];
      for (var i = 0; i < MedicationShape.values.length; i++) {
        final next = suggestMedicationShape(form: 'Tablet', used: used);
        picked.add(next);
        used.add(next);
      }
      expect(picked.toSet(), hasLength(9));
      expect(
        suggestMedicationShape(form: 'Tablet', used: MedicationShape.values),
        MedicationShape.round,
      );
    });
  });

  group('imprint', () {
    test('is the first letter, upper-cased, skipping punctuation', () {
      expect(imprintInitial('magnefar'), 'M');
      expect(imprintInitial('  (b12) complex'), 'B');
      expect(imprintInitial('Ștefan'), 'Ș');
      expect(imprintInitial('12 mg'), '1');
      expect(imprintInitial('...'), '');
    });

    test('two letters only when shape and first letter are both shared', () {
      final imprints = medicationImprints([
        _s('a', 'Magnefar', MedicationShape.round),
        _s('b', 'Metformin', MedicationShape.round),
        _s('c', 'Mucosolvan', MedicationShape.drop),
        _s('d', 'Nurofen', MedicationShape.round),
      ]);
      expect(imprints['a'], 'Ma');
      expect(imprints['b'], 'Me');
      expect(imprints['c'], 'M');
      expect(imprints['d'], 'N');
    });

    test('a one-letter name keeps its single letter, an empty one none', () {
      final imprints = medicationImprints([
        _s('a', 'X', MedicationShape.round),
        _s('b', 'Xanax', MedicationShape.round),
        _s('c', '', MedicationShape.round),
      ]);
      expect(imprints['a'], 'X');
      expect(imprints['b'], 'Xa');
      expect(imprints['c'], '');
    });

    test('imprintAmong gives a new name two letters beside a collision', () {
      final others = [(name: 'Magnefar', shape: MedicationShape.round)];
      expect(
        imprintAmong(
          name: 'Metformin',
          shape: MedicationShape.round,
          others: others,
        ),
        'Me',
      );
      expect(
        imprintAmong(
          name: 'Metformin',
          shape: MedicationShape.oval,
          others: others,
        ),
        'M',
      );
    });
  });

  group('collision', () {
    final others = [
      (name: 'Magnefar', shape: MedicationShape.round),
      (name: 'Nurofen', shape: MedicationShape.oval),
    ];

    test('names the medication sharing both shape and first letter', () {
      expect(
        collidingMedicationName(
          name: 'metformin',
          shape: MedicationShape.round,
          others: others,
        ),
        'Magnefar',
      );
      expect(
        imprintCollides(
          name: 'metformin',
          shape: MedicationShape.round,
          others: others,
        ),
        isTrue,
      );
    });

    test('is none for another shape, another letter or no letter', () {
      for (final (name, shape) in [
        ('Metformin', MedicationShape.drop),
        ('Paracetamol', MedicationShape.round),
        ('', MedicationShape.round),
      ]) {
        expect(
          collidingMedicationName(name: name, shape: shape, others: others),
          isNull,
        );
      }
    });
  });
}
