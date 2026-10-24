import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/backup/backup_file_access.dart';
import 'package:simpastil/core/backup/backup_inventory.dart';
import 'package:simpastil/core/backup/backup_manifest.dart';
import 'package:simpastil/core/backup/backup_service.dart';
import 'package:simpastil/core/backup/import_service.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:timezone/data/latest_all.dart' as tz;

import '../../helpers/care_recording_fixture.dart';
import '../../helpers/protected_workspace_fixture.dart';

const _bytes = '/9j/4AAQSkZJRgABAQ==';

Future<CheckedBackup> _backupOf(
  CareRecordingFixture source,
) async => CheckedBackup(
  BackupDocument(
    id: 'fictional-photo-backup',
    capturedAt: DateTime.utc(2026, 10, 1),
    sourceSchema: 25,
    scope: BackupScope.full,
    tables: {
      for (final name in BackupInventory.portableTableNamesFor(25))
        name:
            (await source.db
                    .customSelect(
                      'SELECT ${BackupInventory.portableColumns(name, schema: 25).map((c) => '"$c"').join(',')} FROM "$name"',
                    )
                    .get())
                .map((r) => r.data)
                .toList(),
    },
    preferences: const {},
  ),
  const BackupFileLocation('fictional-chosen-source', 'Care.simpbak'),
  DateTime.utc(2026, 10, 1),
  passwordProtected: true,
);

void main() {
  setUp(tz.initializeTimeZones);

  test('a restored medication brings its photo, to be sent again', () async {
    final source = await CareRecordingFixture.create();
    final target = await ProtectedWorkspaceFixture.create();
    addTearDown(source.db.close);
    addTearDown(target.db.close);
    await source.db
        .into(source.db.medicationPhotos)
        .insert(
          MedicationPhotosCompanion.insert(
            pillId: source.pill.id,
            bytesBase64: const Value(_bytes),
            sha256: 'd' * 64,
            revision: const Value(3),
            syncStatus: const Value('synced'),
          ),
        );
    final service = ImportService(
      database: target.db,
      access: target.access,
      preferences: target.preferences,
      context: target.context,
    );
    await service.apply(
      await service.preview(
        await _backupOf(source),
        ImportSelection.profiles({source.person.id}),
      ),
    );
    final photo =
        (await target.db.select(target.db.medicationPhotos).get()).single;
    expect(photo.pillId, source.pill.id);
    expect(photo.bytesBase64, _bytes);
    expect(photo.sha256, 'd' * 64);
    // The destination has not confirmed what the account holds.
    expect(photo.syncStatus, 'pending');
  });
}
