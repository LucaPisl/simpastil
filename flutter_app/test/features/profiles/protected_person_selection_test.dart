import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import 'package:simpastil/core/workspace/workspace_provider.dart';
import 'package:simpastil/features/profiles/profile_provider.dart';

import '../../helpers/protected_workspace_fixture.dart';
import '../../helpers/held_provider_read.dart';

class _AfterSelection extends WorkspaceAccessRepository {
  _AfterSelection(super.database)
    : super(effectsGate: SerialProjectionEffectsGate());
  bool delayNext = false;
  final committed = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> viewPerson(
    WorkspaceContext context,
    String? profileId, {
    bool everyone = false,
  }) async {
    await super.viewPerson(context, profileId, everyone: everyone);
    if (delayNext) {
      delayNext = false;
      committed.complete();
      await release.future;
    }
  }
}

Future<void> _person(AppDatabase db, String id, String owner) async {
  final now = DateTime.now().toUtc();
  await db.profilesDao.upsert(
    ProfilesCompanion.insert(
      id: id,
      userId: owner,
      name: 'Fictional $id',
      createdAt: now,
      updatedAt: now,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final primary in [false, true]) {
    for (final replacement in [false, true]) {
      test(
        'late ${primary ? 'primary' : 'viewing'} selection preserves ${replacement ? 'replacement grant' : 'another workspace'}',
        () async {
          final fixture = await ProtectedWorkspaceFixture.create(
            ownerId: 'fictional-a',
            accessFactory: _AfterSelection.new,
          );
          final access = fixture.access as _AfterSelection;
          addTearDown(fixture.db.close);
          await _person(fixture.db, 'a-first', 'fictional-a');
          await _person(fixture.db, 'a-chosen', 'fictional-a');
          await _person(fixture.db, 'a-other', 'fictional-a');
          await access.viewPerson(fixture.context, 'a-first');
          final container = await fixture.createContainer();
          addTearDown(container.dispose);
          expect(
            await container.readHeld(selectedProfileIdProvider),
            'a-first',
          );
          expect(await container.readHeld(primaryProfileIdProvider), 'a-first');
          access.delayNext = true;
          final action = primary
              ? container
                    .read(primaryProfileIdProvider.notifier)
                    .setPrimary('a-chosen')
              : container
                    .read(selectedProfileIdProvider.notifier)
                    .select('a-chosen');
          final completion = action.then<Object?>(
            (_) => null,
            onError: (Object error, StackTrace _) => error,
          );
          await access.committed.future.timeout(const Duration(seconds: 5));
          final owner = replacement ? 'fictional-a' : 'fictional-b';
          final endpoint = fixture.context.endpoint!;
          final epoch = await access.configureEndpoint(endpoint);
          await fixture.db
              .into(fixture.db.credentialSlots)
              .insert(
                CredentialSlotsCompanion.insert(
                  id: 'fictional-selection-slot-b',
                  ownerId: owner,
                  endpoint: endpoint,
                  state: 'staged',
                  createdAt: DateTime.now().toUtc(),
                ),
              );
          final active = await access.authenticate(
            ownerId: owner,
            endpoint: endpoint,
            expectedNetworkEpoch: epoch,
            sessionGeneration: 1,
            credentialId: 'fictional-selection-slot-b',
          );
          final next = active.workspace.bindingState == 'bound'
              ? (await access.contextForOwner(owner))!
              : await access.confirmOriginalServer(
                  workspaceId: active.workspace.id,
                  reviewedOriginalEndpoint: endpoint,
                  expectedNetworkEpoch: active.network.epoch,
                );
          final winner = replacement ? 'a-other' : 'b-person';
          if (!replacement) await _person(fixture.db, winner, owner);
          await access.viewPerson(next, winner);
          await container.refresh(workspaceContextProvider.future);
          expect(await container.readHeld(selectedProfileIdProvider), winner);
          expect(await container.readHeld(primaryProfileIdProvider), winner);
          access.release.complete();
          expect(await completion, isNull);
          expect(
            container.read(selectedProfileIdProvider).requireValue,
            winner,
          );
          expect(container.read(primaryProfileIdProvider).requireValue, winner);
          expect(
            (await access.workspaces.byId(next.workspaceId))!.selectedProfileId,
            winner,
          );
          await container.pump();
          expect(await container.readHeld(selectedProfileIdProvider), winner);
          expect(await container.readHeld(primaryProfileIdProvider), winner);
        },
      );
    }
  }
}
