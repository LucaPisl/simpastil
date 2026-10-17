import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/setup/setup_controller.dart';
import 'package:simpastil/features/setup/setup_state.dart';

import '../../helpers/protected_workspace_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'controller saves person and medication, preserving draft after invalid name',
    () async {
      final fixture = await ProtectedWorkspaceFixture.create();
      addTearDown(fixture.db.close);
      final container = await fixture.createContainer();
      addTearDown(container.dispose);
      const request = SetupRequest();
      final subscription = container.listen(
        setupControllerProvider(request),
        (_, _) {},
      );
      addTearDown(subscription.close);
      await container.read(setupControllerProvider(request).future);
      final controller = container.read(
        setupControllerProvider(request).notifier,
      );
      final person = await controller.savePerson(
        name: 'Fictional Alex',
        avatar: 'A',
      );
      expect(
        (await container.read(
          setupControllerProvider(request).future,
        )).personId,
        person.savedId,
      );
      await expectLater(
        controller.saveMedication(const MedicationReview()),
        throwsFormatException,
      );
      expect(
        (await container.read(
          setupControllerProvider(request).future,
        )).personId,
        person.savedId,
      );
      final medication = await controller.saveMedication(
        const MedicationReview(name: 'Fictional medicine'),
      );
      expect(
        (await container.read(
          setupControllerProvider(request).future,
        )).medicationId,
        medication.savedId,
      );
      expect(
        await fixture.db.schedulesDao.getByPillId(medication.savedId),
        isEmpty,
      );
    },
  );
}
