import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/medication_shape.dart';
import 'package:simpastil/features/pills/medication_look_provider.dart';

MedicationLookRow _row(
  String id,
  String name, {
  String person = 'p1',
  String? shape,
  String? form,
}) => (id: id, personId: person, name: name, shape: shape, form: form);

void main() {
  test(
    'a picked shape wins, a missing or unknown one falls back to the form',
    () {
      expect(
        effectiveMedicationShape('triangle', 'Tablet'),
        MedicationShape.triangle,
      );
      expect(effectiveMedicationShape(null, 'Tablet'), MedicationShape.round);
      expect(
        effectiveMedicationShape('hexagon', 'Syrup'),
        MedicationShape.drop,
      );
      expect(effectiveMedicationShape(null, null), MedicationShape.capsule);
    },
  );

  test('imprints are worked out per person', () {
    final looks = buildMedicationLooks([
      _row('a', 'Magnefar', shape: 'round'),
      _row('b', 'Metformin', shape: 'round'),
      // The same shape and letter on another person's shelf is no collision.
      _row('c', 'Magnesium', person: 'p2', shape: 'round'),
    ]);
    expect(looks['a']!.imprint, 'Ma');
    expect(looks['b']!.imprint, 'Me');
    expect(looks['c']!.imprint, 'M');
    expect(looks['a']!.shape, MedicationShape.round);
  });

  test('a medication without a picked shape is drawn from its form', () {
    final looks = buildMedicationLooks([
      _row('a', 'Aspirin', form: 'Tablet'),
      _row('b', 'Aerius', form: 'Syrup'),
    ]);
    expect(looks['a']!.shape, MedicationShape.round);
    expect(looks['b']!.shape, MedicationShape.drop);
    expect(looks['a']!.imprint, 'A');
  });
}
