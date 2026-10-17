import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/db/reopenable_lazy_database.dart';
import 'package:simpastil/core/startup/foreground_session.dart';
import 'package:simpastil/core/startup/protection_readiness.dart';
import 'package:simpastil/core/storage/protected_database.dart';
import 'package:simpastil/core/storage/shared_preferences_provider.dart';
import 'package:simpastil/features/auth/auth_provider.dart';

class _AuthProbe extends AuthNotifier {
  _AuthProbe({this.refuseRestore = false});
  final bool refuseRestore;
  var restores = 0;

  @override
  AuthState build() => const AuthUnauthenticated();

  @override
  Future<void> restoreSession() async {
    restores++;
    if (refuseRestore) {
      throw const ProtectedStoreFailure(
        ProtectedStoreFailureCode.migrationFailed,
      );
    }
  }
}

void main() {
  test(
    'failed protection reaches the shell without reopening care for auth',
    () async {
      final auth = _AuthProbe(refuseRestore: true);
      final container = ProviderContainer(
        overrides: [
          protectionReadinessProvider.overrideWith(
            (ref) async => const ProtectionReadiness.unavailable(
              ProtectedStoreFailureCode.migrationFailed,
            ),
          ),
          authNotifierProvider.overrideWith(() => auth),
        ],
      );
      addTearDown(container.dispose);

      await restoreForegroundSession(container);

      expect(auth.restores, 0);
      expect(container.read(authNotifierProvider), isA<AuthUnauthenticated>());
      expect(
        (await container.read(protectionReadinessProvider.future)).ready,
        isFalse,
      );
    },
  );

  test(
    'verified protection restores the existing session before the shell',
    () async {
      final auth = _AuthProbe();
      final container = ProviderContainer(
        overrides: [
          protectionReadinessProvider.overrideWith(
            (ref) async => const ProtectionReadiness.ready(),
          ),
          authNotifierProvider.overrideWith(() => auth),
        ],
      );
      addTearDown(container.dispose);

      await restoreForegroundSession(container);

      expect(auth.restores, 1);
    },
  );

  test(
    'care that opens after a refusal restores the skipped session',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final auth = _AuthProbe();
      var openings = 0;
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          authNotifierProvider.overrideWith(() => auth),
          databaseProvider.overrideWith((ref) {
            final db = AppDatabase(
              ReopenableLazyDatabase(
                () async {
                  openings++;
                  if (openings == 1) {
                    throw const ProtectedStoreFailure(
                      ProtectedStoreFailureCode.busy,
                    );
                  }
                  return NativeDatabase.memory();
                },
                onReopened: () =>
                    ref.read(careReopenedProvider.notifier).state++,
              ),
            );
            ref.onDispose(db.close);
            return db;
          }),
        ],
      );
      addTearDown(container.dispose);

      restoreSessionWhenCareRecovers(container);
      await restoreForegroundSession(container);
      expect(auth.restores, 0);
      expect(
        (await container.read(protectionReadinessProvider.future)).failure,
        ProtectedStoreFailureCode.busy,
      );

      // Any screen's "Try again" reaches care through an ordinary query.
      await container.read(databaseProvider).customSelect('SELECT 1').get();
      await pumpEventQueue();

      expect(
        (await container.read(protectionReadinessProvider.future)).ready,
        isTrue,
      );
      expect(auth.restores, 1);
    },
  );
}
