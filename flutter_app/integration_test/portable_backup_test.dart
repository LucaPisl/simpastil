import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:simpastil/core/backup/backup_codec.dart';
import 'package:simpastil/core/backup/backup_file_access.dart';
import 'package:simpastil/core/backup/backup_manifest.dart';
import 'package:simpastil/core/backup/backup_service.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/startup/protection_readiness.dart';
import 'package:simpastil/core/storage/shared_preferences_provider.dart';
import 'package:simpastil/core/workspace/workspace_provider.dart';
import 'package:simpastil/main.dart' as app;

/// Run with flutter run on the owned fictional-care emulator only.
/// Never use flutter test here: its uninstall would erase the retained fixture.
/// An operator completes the real Android SAVE/OPEN/CANCEL document pickers.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('actual SAF save, exact reopen and cancelled choice preserve care', (
    tester,
  ) async {
    expect(
      Platform.isAndroid && const bool.fromEnvironment('SIMPASTIL_BACKUP_TEST'),
      isTrue,
    );
    await app.main();
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(app.SimpastilRuntime)),
    );
    await tester.runAsync(() async {
      expect(
        (await container.read(protectionReadinessProvider.future)).ready,
        isTrue,
      );
      await container.read(workspaceContextProvider.future);
      final db = container.read(databaseProvider);
      Future<String> fingerprint() async => sha256
          .convert(
            utf8.encode(
              jsonEncode({
                for (final table in db.allTables)
                  table.actualTableName:
                      (await db
                              .customSelect(
                                'SELECT * FROM "${table.actualTableName}" ORDER BY rowid',
                              )
                              .get())
                          .map((row) => row.data)
                          .toList(),
              }),
            ),
          )
          .toString();
      const files = AndroidBackupFileAccess();
      final backups = BackupService(
        database: db,
        access: container.read(workspaceAccessRepositoryProvider),
        preferences: container.read(sharedPreferencesProvider),
        files: files,
      );
      final before = await fingerprint();
      final captured = await backups.captureFull();
      expect(captured.document.tables['profiles'], isNotEmpty);
      debugPrint('PORTABLE_BACKUP_PICKER_SAVE');
      const password = 'Fictional backup test password';
      final saved = await backups.save(captured, password: password);
      expect(saved.status, BackupSaveStatus.savedChecked);
      expect(saved.checkedAt, isNotNull);
      debugPrint(
        'PORTABLE_BACKUP_SAVED_CHECKED ${saved.location!.displayName}',
      );
      debugPrint('PORTABLE_BACKUP_PICKER_OPEN');
      final opened = await files.chooseOpen();
      expect(opened, isNotNull);
      final bytes = await files.read(opened!);
      const codec = BackupCodec();
      expect(codec.isPasswordProtected(bytes), isTrue);
      expect(
        (await codec.decode(bytes, password: password)).toJson(),
        captured.document.toJson(),
      );
      await expectLater(
        codec.decode(bytes, password: 'Wrong fictional password'),
        throwsA(
          isA<BackupFailure>().having(
            (e) => e.code,
            'code',
            BackupFailureCode.passwordOrIntegrity,
          ),
        ),
      );
      expect(await fingerprint(), before);
      debugPrint('PORTABLE_BACKUP_PICKER_CANCEL');
      final cancelled = await backups.save(captured, allowClear: true);
      expect(cancelled.status, BackupSaveStatus.cancelled);
      expect(await fingerprint(), before);
      debugPrint(
        'PORTABLE_BACKUP_NATIVE_ACCEPTED saved-checked selected-source wrong-password cancel unchanged-care',
      );
    });
  }, timeout: const Timeout(Duration(minutes: 10)));
}
