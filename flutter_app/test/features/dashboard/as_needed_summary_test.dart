import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/care_provider.dart';
import 'package:simpastil/core/medication/care_recording.dart';
import 'package:simpastil/features/pills/presentation/medication_identity.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/features/dashboard/as_needed/as_needed_option.dart';
import 'package:simpastil/features/dashboard/as_needed/as_needed_summary.dart';
import 'package:simpastil/features/setup/setup_repository.dart';
import 'package:simpastil/features/setup/setup_state.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../../helpers/protected_workspace_fixture.dart';

Future<AsNeededSummary> _summary(ProviderContainer container, String id) async {
  final sub = container.listen(asNeededSummariesProvider, (_, _) {});
  addTearDown(sub.close);
  // Let the stream emit at least once.
  for (var i = 0; i < 50; i++) {
    final v = container.read(asNeededSummariesProvider);
    if (v.hasError) {
      fail('asNeededSummariesProvider failed: ${v.error}\n${v.stackTrace}');
    }
    if (v.hasValue) return v.value![id]!;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('asNeededSummariesProvider never produced a value');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(tzdata.initializeTimeZones);

  late ProtectedWorkspaceFixture workspace;
  late AppDatabase db;
  late Pill pill;
  late ProviderContainer container;
  late AsNeededOption option;

  setUp(() async {
    workspace = await ProtectedWorkspaceFixture.create(
      ownerId: '10000000-0000-4000-8000-000000000001',
    );
    db = workspace.db;
    final setup = SetupRepository(
      database: db,
      access: workspace.access,
      context: workspace.context,
    );
    var draft = await setup.resumeOrCreateDraft();
    draft = (await setup.savePerson(
      draft.id,
      draft.revision,
      name: 'Fictional Alex',
      avatar: 'A',
    )).draft;
    draft = (await setup.saveMedication(
      draft.id,
      draft.revision,
      const MedicationReview(name: 'Fictional as-needed medication'),
    )).draft;
    await (db.update(db.pills)..where((p) => p.id.equals(draft.medicationId!)))
        .write(const PillsCompanion(isPrn: Value(true)));
    pill = (await db.pillsDao.getById(draft.medicationId!))!;
    final person = (await db.profilesDao.getById(draft.personId!))!;
    const sentinelId = '10000000-0000-4000-8000-000000000002';
    final now = DateTime.utc(2026, 9, 30);
    await db.schedulesDao.upsert(
      SchedulesCompanion.insert(
        id: sentinelId,
        pillId: pill.id,
        hour: 0,
        minute: 0,
        frequency: 'prn',
        timeZone: const Value('Europe/Bucharest'),
        timeZoneStatus: const Value('known'),
        createdAt: now,
        updatedAt: now,
      ),
    );
    option = AsNeededOption.connected(
      person: person,
      pill: pill,
      usualAmount: const MedicationAmount.unknown(),
      shape: medicationShapeOf(null),
      form: null,
      sentinel: (await db.schedulesDao.getById(sentinelId))!,
      sentinelMissing: false,
      review: null,
    );
    container = await workspace.createContainer();
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
  });

  Future<CareRecordingReceipt> record(DateTime at) async {
    final service = await container.read(careRecordingServiceProvider.future);
    final intent = await option.prepare(
      service,
      localDate: routineDateKey(at),
      amount: const MedicationAmount.unknown(),
      at: at,
    );
    return service.commit(intent);
  }

  test('a recorded connected dose counts today', () async {
    final at = DateTime.now().subtract(const Duration(minutes: 5));
    await record(at);
    final s = await _summary(container, pill.id);
    expect(s.todayCount, 1);
    expect(s.lastTakenToday, isNotNull);
  });

  test('an undone dose no longer counts', () async {
    final receipt = await record(
      DateTime.now().subtract(const Duration(minutes: 5)),
    );
    final service = await container.read(careRecordingServiceProvider.future);
    await service.commit(await service.prepareUndo(receipt));
    final s = await _summary(container, pill.id);
    expect(s.todayCount, 0);
    expect(s.lastTakenToday, isNull);
  });

  test(
    'another as-needed medication without doses does not hide a dose',
    () async {
      final now = DateTime.utc(2026, 9, 30);
      await db.pillsDao.upsert(
        PillsCompanion.insert(
          id: '10000000-0000-4000-8000-0000000000aa',
          profileId: option.person.id,
          name: 'Fictional idle medication',
          isPrn: const Value(true),
          createdAt: now,
          updatedAt: now,
        ),
      );
      await record(DateTime.now().subtract(const Duration(minutes: 5)));
      final s = await _summary(container, pill.id);
      expect(s.todayCount, 1);
      expect(s.lastTakenToday, isNotNull);
      final idle = await _summary(
        container,
        '10000000-0000-4000-8000-0000000000aa',
      );
      expect(idle.todayCount, 0);
    },
  );
}
