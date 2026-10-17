import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';

const _endpoint = 'https://fictional.test/care';
const _owner = 'fictional-account';

void main() {
  late AppDatabase db;
  late WorkspaceAccessRepository access;

  setUp(() async {
    db = AppDatabase.forTesting();
    access = WorkspaceAccessRepository(db);
    // Care retained for an account that has neither a users row nor a workspace
    // (the shape the shipped build left behind).
    await db.customStatement('PRAGMA foreign_keys = OFF');
    await db.customInsert(
      "INSERT INTO profiles (id, user_id, name, created_at, updated_at) VALUES ('p-1', ?, 'Fictional', 1760000000, 1760000000)",
      variables: [const Variable<String>(_owner)],
    );
  });
  tearDown(() => db.close());

  Future<AuthenticatedWorkspace> signIn() async {
    final transition = await access.configureEndpoint(_endpoint);
    await db
        .into(db.credentialSlots)
        .insert(
          CredentialSlotsCompanion.insert(
            id: 'fictional-slot',
            ownerId: _owner,
            endpoint: _endpoint,
            state: 'staged',
            createdAt: DateTime.now().toUtc(),
          ),
        );
    return access.authenticate(
      ownerId: _owner,
      endpoint: _endpoint,
      expectedNetworkEpoch: transition,
      sessionGeneration: 1,
      credentialId: 'fictional-slot',
    );
  }

  test(
    'retained rows without a users row still require origin review',
    () async {
      final active = await signIn();

      expect(active.workspace.bindingState, 'unresolved');
      expect(active.workspace.endpoint, isNull);
      expect(active.workspace.legacyViewerMigrated, isFalse);
      expect(
        await access.contextForOwner(_owner),
        isNull,
        reason: 'not granted',
      );
    },
  );

  test(
    'review binds the original server and then selects the person',
    () async {
      final active = await signIn();
      final context = await access.confirmOriginalServer(
        workspaceId: active.workspace.id,
        reviewedOriginalEndpoint: _endpoint,
        expectedNetworkEpoch: active.network.epoch,
      );
      expect(
        (await access.workspaces.byId(active.workspace.id))!.bindingState,
        'bound',
      );

      await access.adoptLegacySelection(context);
      final workspace = (await access.workspaces.byId(active.workspace.id))!;
      expect(workspace.selectedProfileId, 'p-1');
      expect(workspace.legacyViewerMigrated, isTrue);
    },
  );

  test('an owner with no retained rows is still bound at sign-in', () async {
    await db.customStatement('DELETE FROM profiles');
    final active = await signIn();
    expect(active.workspace.bindingState, 'bound');
    expect(active.workspace.endpoint, _endpoint);
  });
}
