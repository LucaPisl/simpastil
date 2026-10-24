import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database.dart';
import '../../core/medication/medication_look.dart';
import '../../core/medication/medication_shape.dart';
import '../../core/workspace/workspace_provider.dart';

export '../../core/medication/medication_look.dart';

/// The medications of the current account as the look rules read them.
final medicationLookRowsProvider = StreamProvider<List<MedicationLookRow>>((
  ref,
) async* {
  final db = ref.watch(databaseProvider);
  final access = ref.watch(workspaceAccessRepositoryProvider);
  final context = await ref.watch(workspaceContextProvider.future);
  final query =
      db.select(db.pills).join([
        innerJoin(db.profiles, db.profiles.id.equalsExp(db.pills.profileId)),
        leftOuterJoin(
          db.medicationDetails,
          db.medicationDetails.pillId.equalsExp(db.pills.id),
        ),
      ])..where(
        db.profiles.userId.equals(context.ownerUserId) &
            db.profiles.isDeleted.equals(false) &
            db.pills.isDeleted.equals(false),
      );
  yield* query.watch().asyncMap(
    (rows) => access.withGrant(
      context,
      () async => [
        for (final row in rows)
          (
            id: row.readTable(db.pills).id,
            personId: row.readTable(db.pills).profileId,
            name: row.readTable(db.pills).name,
            shape: row.readTable(db.pills).shape,
            form: row.readTableOrNull(db.medicationDetails)?.form,
          ),
      ],
    ),
  );
});

/// The look of every medication of the current account, by medication id.
///
/// Drawing a mark asks this rather than each screen working the shape and the
/// imprint out for itself, so a medication looks the same on Today, History,
/// the medicine page and the widget snapshot.
final medicationLooksProvider = StreamProvider<Map<String, MedicationLook>>((
  ref,
) async* {
  // Watching the future reruns this whenever the medications change.
  yield buildMedicationLooks(
    await ref.watch(medicationLookRowsProvider.future),
  );
});

/// The other medications of [personId] (everything but [exceptPillId]) with
/// the shape each is drawn with: what the shape picker suggests from and
/// warns about.
final personMedicationsProvider =
    Provider.family<
      List<({String name, MedicationShape shape})>,
      ({String personId, String? exceptPillId})
    >((ref, key) {
      final rows = ref.watch(medicationLookRowsProvider).value ?? const [];
      return [
        for (final r in rows)
          if (r.personId == key.personId && r.id != key.exceptPillId)
            (name: r.name, shape: effectiveMedicationShape(r.shape, r.form)),
      ];
    });
