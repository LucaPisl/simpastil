import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/medication/medication_detail_provider.dart';
import 'package:simpastil/core/medication/medication_detail_repository.dart';
import 'package:simpastil/core/workspace/workspace_provider.dart';
import 'package:simpastil/features/dashboard/today_side/coming_up.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../../../helpers/care_recording_fixture.dart';

/// A connected dose names no amount, so Coming up shows the reviewed amount
/// per use, as Today does.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  Future<List<ComingUpDose>> comingUp({MedicationAmount? reviewed}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final f = await CareRecordingFixture.create(
      connected: true,
      legacyStock: 30,
      preferences: prefs,
    );
    addTearDown(f.db.close);
    if (reviewed != null) {
      await f.db
          .into(f.db.medicationDetails)
          .insertOnConflictUpdate(
            MedicationDetailsCompanion.insert(
              pillId: f.pill.id,
              amountJson: jsonEncode(reviewed.toJson()),
            ),
          );
    }
    final repository = MedicationDetailRepository(
      database: f.db,
      access: f.workspace.access,
      context: f.workspace.context,
    );
    final detail = await repository.load(f.pill.id);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(f.db),
        workspaceAccessRepositoryProvider.overrideWithValue(f.workspace.access),
        workspaceContextProvider.overrideWith(
          (ref) => Stream.value(f.workspace.context),
        ),
        medicationListProvider.overrideWith((ref) => Stream.value([detail])),
      ],
    );
    addTearDown(container.dispose);
    // Keep the auto-disposed provider alive while it loads.
    final subscription = container.listen(
      comingUpProvider('2026-09-29'),
      (_, _) {},
    );
    addTearDown(subscription.close);
    return container.read(comingUpProvider('2026-09-29').future);
  }

  test('a connected dose shows the reviewed amount per use', () async {
    final doses = await comingUp(
      reviewed: MedicationAmount.known('1/2', 'tablets'),
    );
    expect(doses.single.amount.quantityText, '1/2');
    expect(doses.single.amount.unit, 'tablets');
  });

  test('without a reviewed amount it stays unknown', () async {
    final doses = await comingUp();
    expect(doses.single.amount.isUnknown, isTrue);
  });
}
