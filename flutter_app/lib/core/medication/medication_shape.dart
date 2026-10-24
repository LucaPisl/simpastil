/// The silhouette a medication is drawn with, beside its colour, so the two
/// can tell a pill apart when colour alone cannot (colour-blind users, grey
/// screens, a small mark).
///
/// The names are the wire names: the server stores exactly these nine and the
/// sync payload carries them as plain strings, so never rename one.
enum MedicationShape {
  round,
  caplet,
  oval,
  softgel,
  capsule,
  triangle,
  square,
  diamond,
  drop;

  /// The name stored in the database and sent to the server.
  String get wire => name;

  /// The shape named by [raw], or null when it is missing or not one this
  /// build knows (a newer server may add shapes). A reader maps null to the
  /// shape it derives from the medication's form; it never rejects a pull
  /// over one.
  static MedicationShape? fromWire(String? raw) {
    if (raw == null) return null;
    for (final shape in values) {
      if (shape.name == raw) return shape;
    }
    return null;
  }
}

/// Reads a free-text form ("Tablet", "Syrup", "comprimat", ...) into the shape
/// a medication without a picked one is drawn with: tablets are round, liquids
/// and drops are a drop, and anything unrecognised stays a capsule.
MedicationShape deriveMedicationShape(String? form) {
  final f = (form ?? '').toLowerCase();
  const tablets = ['tablet', 'pill', 'comprimat', 'pastil', 'drajeu'];
  const drops = [
    'drop',
    'syrup',
    'liquid',
    'solution',
    'sirop',
    'pic',
    'solu',
    'lichid',
  ];
  if (tablets.any(f.contains)) return MedicationShape.round;
  if (drops.any(f.contains)) return MedicationShape.drop;
  return MedicationShape.capsule;
}

/// The order a new medication tries shapes in, starting from the one its form
/// implies. Close relatives come first so a second tablet is a caplet or an
/// oval rather than a drop.
const Map<MedicationShape, List<MedicationShape>> _suggestionOrder = {
  MedicationShape.round: [
    MedicationShape.round,
    MedicationShape.oval,
    MedicationShape.caplet,
    MedicationShape.square,
    MedicationShape.diamond,
    MedicationShape.triangle,
    MedicationShape.softgel,
    MedicationShape.capsule,
    MedicationShape.drop,
  ],
  MedicationShape.capsule: [
    MedicationShape.capsule,
    MedicationShape.softgel,
    MedicationShape.caplet,
    MedicationShape.oval,
    MedicationShape.round,
    MedicationShape.square,
    MedicationShape.diamond,
    MedicationShape.triangle,
    MedicationShape.drop,
  ],
  MedicationShape.drop: [
    MedicationShape.drop,
    MedicationShape.softgel,
    MedicationShape.round,
    MedicationShape.oval,
    MedicationShape.triangle,
    MedicationShape.diamond,
    MedicationShape.square,
    MedicationShape.caplet,
    MedicationShape.capsule,
  ],
};

/// The shape to propose for a new medication of [form]: the one the form
/// implies (tablet is round, capsule is a capsule, liquid or drops is a
/// drop), or, when the person already has a medication drawn that way, the
/// nearest shape none of their [used] medications has. When every shape is
/// taken the form's own comes back, since two alike is better than none.
MedicationShape suggestMedicationShape({
  String? form,
  Iterable<MedicationShape> used = const [],
}) {
  final base = deriveMedicationShape(form);
  final taken = used.toSet();
  for (final candidate in _suggestionOrder[base]!) {
    if (!taken.contains(candidate)) return candidate;
  }
  return base;
}

/// What the imprint rule needs to know about one medication of a person.
typedef ImprintSubject = ({String id, String name, MedicationShape shape});

/// The first letter (or digit) of [name], upper-cased, or an empty string when
/// the name has none. Punctuation and spaces in front of it are skipped.
String imprintInitial(String name) {
  final runes = _significant(name);
  return runes.isEmpty ? '' : String.fromCharCode(runes.first).toUpperCase();
}

List<int> _significant(String name) => [
  for (final rune in name.runes)
    if (_isLetterOrDigit(rune)) rune,
];

// A letter in any script, or a digit: anything the upper/lower mapping or a
// decimal digit can describe. Spaces, punctuation and symbols are skipped.
bool _isLetterOrDigit(int rune) {
  final c = String.fromCharCode(rune);
  return c.toLowerCase() != c.toUpperCase() || (rune >= 0x30 && rune <= 0x39);
}

/// The imprint of each medication of ONE person, by id.
///
/// A medication is imprinted with the first letter of its name. When two of
/// the person's medications share both the shape and that letter (a round
/// "Magnefar" and a round "Metformin"), the letter no longer tells them apart,
/// so each of them shows two letters instead, the first capitalised and the
/// second as written in lower case ("Ma" and "Me"). Medications that differ in
/// shape or in first letter keep the single letter. Two letters that are still
/// alike (the same name twice) stay alike; the picker warns about that before
/// it happens.
///
/// A name with no letter or digit has no imprint (an empty string).
Map<String, String> medicationImprints(Iterable<ImprintSubject> subjects) {
  final all = subjects.toList();
  final crowd = <(MedicationShape, String), int>{};
  for (final s in all) {
    final initial = imprintInitial(s.name);
    if (initial.isEmpty) continue;
    crowd.update((s.shape, initial), (n) => n + 1, ifAbsent: () => 1);
  }
  return {
    for (final s in all)
      s.id: _imprintOf(
        s.name,
        collides: (crowd[(s.shape, imprintInitial(s.name))] ?? 0) > 1,
      ),
  };
}

String _imprintOf(String name, {required bool collides}) {
  final runes = _significant(name);
  if (runes.isEmpty) return '';
  final first = String.fromCharCode(runes.first).toUpperCase();
  if (!collides || runes.length < 2) return first;
  return '$first${String.fromCharCode(runes[1]).toLowerCase()}';
}

/// Whether a medication named [name] drawn as [shape] would share its shape
/// and first letter with one of the person's [others]: what the picker warns
/// about.
bool imprintCollides({
  required String name,
  required MedicationShape shape,
  required Iterable<({String name, MedicationShape shape})> others,
}) {
  final initial = imprintInitial(name);
  if (initial.isEmpty) return false;
  return others.any(
    (o) => o.shape == shape && imprintInitial(o.name) == initial,
  );
}

/// The name of the first of [others] that shares [shape] and the first letter
/// of [name], or null when none does.
String? collidingMedicationName({
  required String name,
  required MedicationShape shape,
  required Iterable<({String name, MedicationShape shape})> others,
}) {
  final initial = imprintInitial(name);
  if (initial.isEmpty) return null;
  for (final o in others) {
    if (o.shape == shape && imprintInitial(o.name) == initial) return o.name;
  }
  return null;
}

/// The imprint a medication named [name] drawn as [shape] would get beside
/// the person's [others]: one letter, or two when one of them collides.
String imprintAmong({
  required String name,
  required MedicationShape shape,
  required Iterable<({String name, MedicationShape shape})> others,
}) {
  const me = '\u0000me';
  return medicationImprints([
        for (final (i, o) in others.indexed)
          (id: '$i', name: o.name, shape: o.shape),
        (id: me, name: name, shape: shape),
      ])[me] ??
      '';
}
