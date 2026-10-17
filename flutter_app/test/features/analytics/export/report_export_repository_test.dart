import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/medication_command.dart';
import 'package:simpastil/core/medication/medication_repository.dart';
import 'package:simpastil/features/analytics/export/export_service.dart';
import 'package:simpastil/features/analytics/export/report_export_repository.dart';
import 'package:simpastil/l10n/app_localizations_en.dart';
import 'package:timezone/data/latest.dart' as tz;

import '../../../helpers/care_recording_fixture.dart';

void main() {
  setUpAll(tz.initializeTimeZones);
  Future<void> exercise({bool revoke = false, bool failShare = false}) async {
    final f = await CareRecordingFixture.create();
    addTearDown(f.db.close);
    final directory = await Directory.systemTemp.createTemp(
      'fictional-report-',
    );
    addTearDown(() => directory.delete(recursive: true));
    await MedicationRepository(
      f.db,
      access: f.workspace.access,
      context: f.workspace.context,
    ).apply(
      userId: f.workspace.context.ownerUserId,
      occurrenceId: f.occurrence.id,
      action: MedicationAction.take,
      actualTimeKnown: false,
      commandIdOverride: '40000000-0000-4000-8000-000000000001',
    );
    final original = (await f.db.select(f.db.occurrenceEvents).get()).single;
    final repository = ReportExportRepository(
      database: f.db,
      access: f.workspace.access,
      context: f.workspace.context,
      outputDirectory: directory,
    );
    var dispatched = 0;
    Future<void> action() => repository.exportAndShare(
      personId: f.person.id,
      profileName: f.person.name,
      from: DateTime(2026, 9, 30),
      to: DateTime(2026, 9, 30, 23, 59),
      format: ExportFormat.csv,
      l: AppLocalizationsEn(),
      beforeDisclosure: revoke
          ? () async {
              await f.db.customStatement(
                'UPDATE workspace_grants SET epoch=epoch+1',
              );
            }
          : null,
      share: (paths) async {
        dispatched++;
        expect(paths, hasLength(1));
        expect(File(paths.single).parent.path, directory.path);
        expect(
          await File(paths.single).readAsString(),
          contains('Fictional recorded medication'),
        );
        if (failShare) {
          throw StateError('private-path-and-care-must-not-reach-UI');
        }
      },
    );
    if (revoke || failShare) {
      await expectLater(action(), throwsA(isA<ReportExportFailure>()));
    } else {
      await action();
    }
    expect(dispatched, revoke ? 0 : 1);
    expect(await directory.list().toList(), isEmpty);
    expect((await f.db.select(f.db.occurrenceEvents).get()).single, original);
    expect(
      (await f.db.medicationLedgerDao.getOccurrenceById(
        f.occurrence.id,
      ))!.state,
      'taken',
    );
  }

  test(
    'private report dispatch preserves recorded care and removes its working file',
    () => exercise(),
  );
  test(
    'revoked report cannot leave the app and its clear working file is removed',
    () => exercise(revoke: true),
  );
  test(
    'failed sharing removes the private report and exposes only a safe failure',
    () => exercise(failShare: true),
  );
}
