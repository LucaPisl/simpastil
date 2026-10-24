import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/features/profiles/profile_provider.dart';

import '../../helpers/protected_workspace_fixture.dart';

void main() {
  Future<void> addLocalPerson(ProtectedWorkspaceFixture fixture) async {
    final local = await fixture.access.workspaces.ensureLocal();
    final now = DateTime.now().toUtc();
    await fixture.db.profilesDao.upsert(
      ProfilesCompanion.insert(
        id: 'kept-person',
        userId: local.ownerUserId,
        name: 'Fictional person',
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  test('a connected workspace sees that local care is kept', () async {
    final fixture = await ProtectedWorkspaceFixture.create(
      ownerId: 'fictional-account',
    );
    addTearDown(fixture.db.close);
    await addLocalPerson(fixture);
    final container = await fixture.createContainer();
    addTearDown(container.dispose);
    // An unlistened provider is paused (Riverpod 3), so `.future` needs one.
    container.listen(localCareKeptProvider, (_, _) {});

    expect(await container.read(localCareKeptProvider.future), isTrue);
  });

  test('a connected workspace with no local people sees nothing', () async {
    final fixture = await ProtectedWorkspaceFixture.create(
      ownerId: 'fictional-account',
    );
    addTearDown(fixture.db.close);
    final container = await fixture.createContainer();
    addTearDown(container.dispose);
    // An unlistened provider is paused (Riverpod 3), so `.future` needs one.
    container.listen(localCareKeptProvider, (_, _) {});

    expect(await container.read(localCareKeptProvider.future), isFalse);
  });

  test('working locally never reports local care as kept apart', () async {
    final fixture = await ProtectedWorkspaceFixture.create();
    addTearDown(fixture.db.close);
    await addLocalPerson(fixture);
    final container = await fixture.createContainer();
    addTearDown(container.dispose);
    // An unlistened provider is paused (Riverpod 3), so `.future` needs one.
    container.listen(localCareKeptProvider, (_, _) {});

    expect(await container.read(localCareKeptProvider.future), isFalse);
  });
}
