import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/diagnostics/diagnostic_event.dart';
import 'package:simpastil/core/diagnostics/diagnostics_recorder.dart';
import 'package:simpastil/core/diagnostics/report/data_report_source.dart';
import 'package:simpastil/core/diagnostics/report/diagnostic_report.dart';
import 'package:simpastil/core/diagnostics/report/report_collector.dart';

void main() {
  late Directory dir;
  late DiagnosticsRecorder recorder;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('simpastil-collect-');
    recorder = DiagnosticsRecorder(directory: () async => dir);
  });
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  final now = DateTime.utc(2026, 10, 18, 14, 37);

  group('collectReport', () {
    test('puts every readable source into its section', () async {
      await recorder.record(
        DiagnosticEvent(
          kind: DiagnosticKind.appStarted,
          at: DateTime.utc(2026, 10, 18, 13),
        ),
      );
      final report = await collectReport(
        ReportSources(
          app: () async => ReportApp(version: '1.0.0', build: 3),
          device: () async => ReportDevice(maker: 'samsung'),
          permissions: () async =>
              const ReportPermissions(notifications: ReportPermission.allowed),
          data: () async => const ReportData(profiles: 1),
          sync: () async => ReportSync(connected: false),
          capabilities: () async => [],
          lastStop: () async => 'EXIT_CRASH',
        ),
        recorder: recorder,
        now: now,
      );
      expect(report.app!.version, '1.0.0');
      expect(report.device!.maker, 'samsung');
      expect(report.permissions!.notifications, ReportPermission.allowed);
      expect(report.data!.profiles, 1);
      expect(report.sync!.connected, isFalse);
      expect(report.capabilities, isEmpty);
      expect(report.lastStop, 'EXIT_CRASH');
      expect(report.events, hasLength(1));
      expect(report.createdAt, now);
    });

    test(
      'a source that throws leaves only its own section unavailable',
      () async {
        final report = await collectReport(
          ReportSources(
            app: () async => throw StateError('Aspirin 100mg'),
            device: () async => ReportDevice(maker: 'samsung'),
          ),
          recorder: recorder,
          now: now,
        );
        expect(report.app, isNull);
        expect(report.device!.maker, 'samsung');
        final text = report.toText();
        expect(text, contains('[app]\nstate: unavailable'));
        expect(text, isNot(contains('Aspirin')));
      },
    );

    test('a source that never answers is given up on', () async {
      final stuck = Completer<ReportData?>();
      final report = await collectReport(
        ReportSources(
          data: () => stuck.future,
          device: () async => ReportDevice(maker: 'samsung'),
        ),
        recorder: recorder,
        now: now,
        timeout: const Duration(milliseconds: 50),
      );
      expect(report.data, isNull);
      expect(report.device, isNotNull);
    });

    test('with no sources at all it is still a whole report', () async {
      final report = await collectReport(
        const ReportSources(),
        recorder: recorder,
        now: now,
      );
      expect(report.toText(), contains('[last-stop]\nreason: none-recorded'));
    });

    test('merge lets the second set of sources win', () async {
      final merged = ReportSources(
        app: () async => ReportApp(version: '1.0.0'),
        device: () async => ReportDevice(maker: 'first'),
      ).merge(ReportSources(device: () async => ReportDevice(maker: 'second')));
      expect((await merged.device!())!.maker, 'second');
      expect((await merged.app!())!.version, '1.0.0');
    });
  });

  group('readDataFacts', () {
    late AppDatabase db;

    setUp(() => db = AppDatabase(NativeDatabase.memory()));
    tearDown(() async => db.close());

    Future<void> seed({required int pills, int deleted = 0}) async {
      await db
          .into(db.users)
          .insert(
            UsersCompanion.insert(
              id: 'u1',
              email: 'u1@test.com',
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
            ),
          );
      await db
          .into(db.profiles)
          .insert(
            ProfilesCompanion.insert(
              id: 'p1',
              userId: 'u1',
              name: 'Canary Person',
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
            ),
          );
      for (var i = 0; i < pills + deleted; i++) {
        await db.pillsDao.upsert(
          PillsCompanion.insert(
            id: 'pill$i',
            profileId: 'p1',
            name: 'Canary Medicine $i',
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            isDeleted: Value(i >= pills),
          ),
        );
      }
    }

    test('counts what is stored and skips what was deleted', () async {
      await seed(pills: 3, deleted: 2);
      final data = await readDataFacts(db, reminders: () async => 4);
      expect(data!.profiles, 1);
      expect(data.medicines, 3);
      expect(data.schedules, 0);
      expect(data.doseRecords, 0);
      expect(data.scheduledReminders, 4);
    });

    test('shows only buckets in the report text, never a name', () async {
      await seed(pills: 3);
      final data = await readDataFacts(db, reminders: () async => null);
      final text = DiagnosticReport(createdAt: now, data: data).toText();
      expect(text, contains('medicines: 2-5'));
      expect(text, contains('reminders: unavailable'));
      expect(text, isNot(contains('Canary')));
    });

    test('a database that cannot be read is unavailable, not zero', () async {
      await db.customStatement('PRAGMA foreign_keys = OFF');
      await db.customStatement('DROP TABLE pills');
      await db.customStatement('DROP TABLE profiles');
      expect(await readDataFacts(db, reminders: () async => 0), isNull);
    });
  });
}
