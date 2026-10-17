import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/storage/recovery_copy_service.dart';
import 'package:simpastil/core/storage/storage_inventory_service.dart';
import 'package:simpastil/features/settings/presentation/storage_settings_screen.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/widgets/status_chip.dart';

void main() {
  testWidgets(
    'unknown storage and absent recovery are never reported as checked zero',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storageSettingsSnapshotProvider.overrideWith(
              (_) async => const StorageSettingsSnapshot(
                StorageInventory({
                  StorageCategory.care: null,
                  StorageCategory.recovery: 0,
                }),
                RecoveryCopyCheck(RecoveryCopyState.absent),
                RecoveryCopyCheck(RecoveryCopyState.absent),
              ),
            ),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: StorageSettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Not available'), findsWidgets);
      expect(find.text('No recovery copy yet'), findsOneWidget);
      expect(find.text('Checked recovery copy'), findsNothing);
      expect(find.text('Clean safe temporary files'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'read failure preserves unavailable state and Retry at large Romanian text',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storageSettingsSnapshotProvider.overrideWith(
              (_) async => throw StateError('unreadable'),
            ),
          ],
          child: MaterialApp(
            locale: const Locale('ro'),
            theme: ThemeData.dark(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: const StorageSettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text(
          'Aceste detalii sunt temporar indisponibile. Datele sunt păstrate.',
        ),
        200,
      );
      expect(
        find.text(
          'Aceste detalii sunt temporar indisponibile. Datele sunt păstrate.',
        ),
        findsOneWidget,
      );
      expect(find.text('Încă nu există o copie de recuperare'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  test('only a checked recovery copy reads as good', () {
    expect(recoveryTone(RecoveryCopyState.checked), StatusTone.good);
    expect(recoveryTone(RecoveryCopyState.absent), StatusTone.neutral);
    expect(recoveryTone(RecoveryCopyState.unavailable), StatusTone.problem);
  });

  testWidgets('recovery states carry accurate chips and unknown sizes no bar', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageSettingsSnapshotProvider.overrideWith(
            (_) async => const StorageSettingsSnapshot(
              StorageInventory({
                StorageCategory.care: null,
                StorageCategory.recovery: 2048,
              }),
              RecoveryCopyCheck(RecoveryCopyState.unavailable),
              RecoveryCopyCheck(RecoveryCopyState.absent),
            ),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: StorageSettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Not checked'), findsOneWidget);
    expect(find.text('Checked'), findsNothing);
    // Only the one known category size draws a share bar.
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });
}
