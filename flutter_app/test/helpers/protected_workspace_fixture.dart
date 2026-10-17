import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/storage/shared_preferences_provider.dart';
import 'package:simpastil/core/storage/portable_preference_writer.dart';
import 'package:simpastil/core/workspace/workspace_access_repository.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';
import 'package:simpastil/core/workspace/workspace_provider.dart';

/// Fictional in-memory care with actual protected authorization. No HTTP,
/// platform credential reads or production database opening are involved.
class ProtectedWorkspaceFixture {
  ProtectedWorkspaceFixture._(
    this.db,
    this.access,
    this.context,
    this.preferences,
  );

  final AppDatabase db;
  final WorkspaceAccessRepository access;
  final WorkspaceContext context;
  final SharedPreferences preferences;

  static Future<ProtectedWorkspaceFixture> create({
    String? ownerId,
    Map<String, Object> initialPreferences = const {},
    SharedPreferences? preferences,
    AppDatabase? database,
    WorkspaceAccessRepository Function(AppDatabase)? accessFactory,
  }) async {
    if (preferences == null) {
      SharedPreferences.setMockInitialValues(initialPreferences);
      preferences = await SharedPreferences.getInstance();
    }
    final db = database ?? AppDatabase.forTesting();
    final access =
        accessFactory?.call(db) ??
        WorkspaceAccessRepository(
          db,
          effectsGate: SerialProjectionEffectsGate(),
        );
    WorkspaceContext context;
    if (ownerId == null) {
      context = await access.currentContext();
    } else {
      final existing = await access.contextForOwner(ownerId);
      if (existing != null) {
        context = existing;
      } else {
        const endpoint = 'https://fictional-workspace.test/care';
        final epoch = await access.configureEndpoint(endpoint);
        final slot = 'fictional-test-slot-${const Uuid().v4()}';
        await db
            .into(db.credentialSlots)
            .insert(
              CredentialSlotsCompanion.insert(
                id: slot,
                ownerId: ownerId,
                endpoint: endpoint,
                state: 'staged',
                createdAt: DateTime.now().toUtc(),
              ),
            );
        final active = await access.authenticate(
          ownerId: ownerId,
          endpoint: endpoint,
          expectedNetworkEpoch: epoch,
          sessionGeneration: 1,
          credentialId: slot,
        );
        context = active.workspace.bindingState == 'bound'
            ? (await access.contextForOwner(ownerId))!
            : await access.confirmOriginalServer(
                workspaceId: active.workspace.id,
                reviewedOriginalEndpoint: endpoint,
                expectedNetworkEpoch: active.network.epoch,
              );
      }
    }
    return ProtectedWorkspaceFixture._(db, access, context, preferences);
  }

  List<Override> get overrides => [
    databaseProvider.overrideWithValue(db),
    workspaceAccessRepositoryProvider.overrideWithValue(access),
    sharedPreferencesProvider.overrideWithValue(preferences),
    portablePreferenceGateProvider.overrideWithValue(
      SerialProjectionEffectsGate(),
    ),
  ];

  Future<ProviderContainer> createContainer({
    List<Override> extraOverrides = const [],
  }) async {
    final container = ProviderContainer(
      overrides: [...overrides, ...extraOverrides],
    );
    await container.read(workspaceContextProvider.future);
    return container;
  }
}
