import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/backup/backup_codec.dart';
import 'package:simpastil/core/backup/backup_file_access.dart';
import 'package:simpastil/core/backup/backup_import_session.dart';
import 'package:simpastil/core/backup/backup_manifest.dart';
import 'package:simpastil/core/backup/backup_service.dart';
import 'package:simpastil/core/backup/import_service.dart';
import 'package:timezone/data/latest.dart' as tz;

import '../../helpers/care_recording_fixture.dart';
import '../../helpers/protected_workspace_fixture.dart';

class _Document implements BackupFileAccess {
  _Document(this.bytes);
  Uint8List bytes;
  @override
  Future<BackupFileLocation?> chooseOpen() async =>
      const BackupFileLocation('fictional-document', 'Care.simpbak');
  @override
  Future<BackupFileLocation?> chooseSave(String suggestedName) async => null;
  @override
  Future<Uint8List> read(BackupFileLocation location) async =>
      Uint8List.fromList(bytes);
  @override
  Future<void> write(BackupFileLocation location, Uint8List bytes) async =>
      throw UnimplementedError();
}

void main() {
  setUp(tz.initializeTimeZones);
  test(
    'selected activation reopens its chosen document and refuses changed bytes',
    () async {
      final source = await CareRecordingFixture.create();
      final target = await ProtectedWorkspaceFixture.create();
      addTearDown(source.db.close);
      addTearDown(target.db.close);
      final capture = BackupService(
        database: source.db,
        access: source.workspace.access,
        preferences: source.workspace.preferences,
        files: const AndroidBackupFileAccess(),
      );
      final document = (await capture.captureFull()).document;
      final files = _Document(
        await const BackupCodec().encode(document, allowClear: true),
      );
      final backup = BackupService(
        database: target.db,
        access: target.access,
        preferences: target.preferences,
        files: files,
      );
      final session = await BackupImportSession.open(
        backup: backup,
        source: (await backup.selectSource())!,
        buildImport: (_, recheck) async => ImportService(
          database: target.db,
          access: target.access,
          preferences: target.preferences,
          context: target.context,
          sourceRecheck: recheck,
        ),
      );
      addTearDown(session.close);
      final plan = await session.preview(
        ImportSelection.profiles({source.person.id}),
      );
      files.bytes[files.bytes.length - 1] ^= 1;
      await expectLater(
        session.apply(plan),
        throwsA(
          isA<BackupFailure>().having(
            (e) => e.code,
            'code',
            BackupFailureCode.sourceChanged,
          ),
        ),
      );
      expect(await target.db.select(target.db.profiles).get(), isEmpty);
      expect(await target.db.select(target.db.importReceipts).get(), isEmpty);
      await target.access.requireCurrent(target.context);
    },
  );
}
