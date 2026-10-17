import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/errors/app_error.dart';
import 'package:simpastil/core/medication/care_sharing_provider.dart';
import 'package:simpastil/core/medication/care_sharing_status.dart';
import 'package:simpastil/core/sync/auto_sync_service.dart';
import 'package:simpastil/features/dashboard/care_record_form.dart';
import 'package:simpastil/features/pills/legacy_routine_review_repository.dart';
import 'package:simpastil/features/pills/schedule_repository.dart';
import 'package:simpastil/features/profiles/profile_provider.dart';
import 'package:simpastil/features/settings/presentation/legacy_routine_review_screen.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../../../helpers/protected_workspace_fixture.dart';

final _captureKey = GlobalKey();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    tzdata.initializeTimeZones();
    // Optional local rendering evidence uses a real typeface, never Ahem.
    final font = Platform.environment['REVIEW_FONT'];
    if (font != null) {
      final bytes = ByteData.sublistView(await File(font).readAsBytes());
      for (final family in ['Roboto', 'Ahem']) {
        await (FontLoader(family)..addFont(Future.value(bytes))).load();
      }
      final icons = File('${File(font).parent.path}/MaterialIcons-Regular.otf');
      if (await icons.exists()) {
        await (FontLoader('MaterialIcons')..addFont(
              Future.value(ByteData.sublistView(await icons.readAsBytes())),
            ))
            .load();
      }
    }
  });

  late ProtectedWorkspaceFixture fixture;
  late _Schedules schedules;
  late _ReviewRepository repository;
  late _Sync sync;

  setUp(() async {
    fixture = await ProtectedWorkspaceFixture.create(
      ownerId: 'fictional-owner',
    );
    final now = DateTime.utc(2026, 10, 4);
    await fixture.db.profilesDao.upsert(
      ProfilesCompanion.insert(
        id: 'person',
        userId: fixture.context.ownerUserId,
        name: 'Example person',
        createdAt: now,
        updatedAt: now,
        syncStatus: const Value('synced'),
      ),
    );
    await fixture.db.pillsDao.upsert(
      PillsCompanion.insert(
        id: 'pill',
        profileId: 'person',
        name: 'Example medication',
        createdAt: now,
        updatedAt: now,
        syncStatus: const Value('synced'),
      ),
    );
    schedules = _Schedules();
    sync = _Sync();
    repository = _ReviewRepository(
      database: fixture.db,
      access: fixture.access,
      context: fixture.context,
      schedules: schedules,
    );
    for (final (id, frequency, days, status) in [
      ('daily', 'daily', null, 'synced'),
      ('weekly', 'custom', '[1,3]', 'synced'),
      ('invalid', 'weekly', '[0]', 'synced'),
      ('pending', 'daily', null, 'pending'),
    ]) {
      await fixture.db.schedulesDao.upsert(
        SchedulesCompanion.insert(
          id: id,
          pillId: 'pill',
          hour: 8,
          minute: 30,
          frequency: frequency,
          frequencyDays: Value(days),
          createdAt: now,
          updatedAt: now,
          serverId: Value('server-$id'),
          syncStatus: Value(status),
        ),
      );
      await fixture.db.migrationIssuesDao.record(
        MigrationIssuesCompanion.insert(
          id: 'issue-$id',
          userId: fixture.context.ownerUserId,
          entityType: 'schedule',
          entityId: 'server-$id',
          issueCode: 'schedule_timezone_review_required',
          snapshotJson: '{}',
          serverId: Value('issue-$id'),
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
  });
  tearDown(() async => fixture.db.close());

  Future<void> pump(WidgetTester tester, {bool accessible = false}) async {
    await tester.binding.setSurfaceSize(const Size(412, 914));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...fixture.overrides,
          currentUserIdProvider.overrideWithValue('fictional-owner'),
          legacyRoutineReviewRepositoryProvider.overrideWith(
            (_) async => repository,
          ),
          autoSyncServiceProvider.overrideWithValue(sync),
        ],
        child: MaterialApp(
          locale: Locale(accessible ? 'ro' : 'en'),
          theme: _renderTheme(accessible),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(accessible ? 2 : 1),
              disableAnimations: accessible,
            ),
            child: RepaintBoundary(key: _captureKey, child: child),
          ),
          home: const Scaffold(),
          initialRoute: '/review',
          routes: {'/review': (_) => const LegacyRoutineReviewScreen()},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'preview preserves times and days, explains skips, and writes only on confirm',
    (tester) async {
      await pump(tester);
      expect(find.text('Bucharest, Romania'), findsOneWidget);
      expect(find.textContaining('Applies from midnight'), findsOneWidget);
      expect(find.text('8:30 AM · Daily'), findsOneWidget);
      expect(find.text('8:30 AM · Mon, Wed'), findsOneWidget);
      expect(find.textContaining('Next planned dose:'), findsNWidgets(2));
      expect(find.textContaining('Europe/'), findsNothing);
      expect(schedules.calls, isEmpty);
      expect(
        await fixture.db.select(fixture.db.occurrenceEvents).get(),
        isEmpty,
      );
      await _capture(tester, 'routine-review-light');
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('legacy-review-confirm')),
        250,
      );
      expect(find.textContaining('its saved days need'), findsOneWidget);
      expect(find.textContaining('pending changes'), findsOneWidget);
      await _capture(tester, 'routine-review-confirm');
      await tester.tap(find.byKey(const ValueKey('legacy-review-confirm')));
      await tester.pumpAndSettle();
      expect(schedules.calls, hasLength(2));
      expect(sync.calls, 1);
      expect(
        find.textContaining('2 routines accepted by the server'),
        findsOneWidget,
      );
      expect(
        await fixture.db.migrationIssuesDao.getUnresolved(
          fixture.context.ownerUserId,
        ),
        hasLength(4),
      );
      expect(
        await fixture.db.select(fixture.db.occurrenceEvents).get(),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'partial failure freezes choices and retries only remaining routine',
    (tester) async {
      schedules.failSecond = true;
      await pump(tester);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('legacy-review-confirm')),
        300,
      );
      await tester.tap(find.byKey(const ValueKey('legacy-review-confirm')));
      await tester.pumpAndSettle();
      expect(find.textContaining('1 of 2 routines accepted'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text(
          'Could not reach the server. Check your connection, then sync to check this review before retrying.',
        ),
        180,
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Could not reach the server. Check your connection, then sync to check this review before retrying.',
        ),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('legacy-review-zone')),
        -300,
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('legacy-review-zone')),
            )
            .onPressed,
        isNull,
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('legacy-review-date')),
        150,
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('legacy-review-date')),
            )
            .onPressed,
        isNull,
      );
      schedules.failSecond = false;
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('legacy-review-confirm')),
        300,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('legacy-review-confirm')));
      await tester.pumpAndSettle();
      expect(schedules.calls, ['daily', 'weekly', 'weekly']);
      expect(
        find.textContaining('2 routines accepted by the server'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Romanian dark large text and reduced motion keeps review usable',
    (tester) async {
      await pump(tester, accessible: true);
      expect(find.text('București, România'), findsOneWidget);
      await _capture(tester, 'routine-review-ro-dark-large');
      await tester.scrollUntilVisible(
        find.textContaining('miezul nopții'),
        220,
      );
      await tester.scrollUntilVisible(
        find.textContaining('08:30 · Zilnic'),
        220,
      );
      await _capture(tester, 'routine-review-ro-dark-large-dose');
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('legacy-review-confirm')),
        220,
      );
      await _capture(tester, 'routine-review-ro-dark-large-confirm');
      expect(find.text('Confirmă orele pentru 2 programe'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(schedules.calls, isEmpty);
    },
  );

  for (final accessible in [false, true]) {
    testWidgets(
      'readable place selection preserves cancel and same-zone preview accessible=$accessible',
      (tester) async {
        await pump(tester, accessible: accessible);
        final zoneControl = find.byKey(const ValueKey('legacy-review-zone'));
        final initialLabel = accessible
            ? 'București, România'
            : 'Bucharest, Romania';
        expect(tester.widget(zoneControl), isA<OutlinedButton>());
        expect(
          find.widgetWithText(OutlinedButton, initialLabel),
          findsOneWidget,
        );
        expect(repository.previewZones, ['Europe/Bucharest']);
        final initialPreview = repository.previews.single;
        expect(schedules.calls, isEmpty);
        expect(find.textContaining('Europe/'), findsNothing);

        Future<void> openPicker() async {
          await tester.ensureVisible(zoneControl);
          await tester.tap(zoneControl);
          await tester.pumpAndSettle();
        }

        Future<void> choosePlace(String query, String label) async {
          await openPicker();
          await tester.enterText(find.byType(TextField), query);
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(ListTile, label));
          await tester.pumpAndSettle();
        }

        await openPicker();
        await tester.enterText(find.byType(TextField), 'London');
        await tester.pumpAndSettle();
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(
          find.widgetWithText(OutlinedButton, initialLabel),
          findsOneWidget,
        );
        expect(repository.previewZones, ['Europe/Bucharest']);
        expect(repository.previews.single, same(initialPreview));
        expect(schedules.calls, isEmpty);

        await choosePlace(accessible ? 'Bucuresti' : 'Bucharest', initialLabel);
        expect(repository.previewZones, ['Europe/Bucharest']);
        expect(repository.previews.single, same(initialPreview));
        expect(schedules.calls, isEmpty);

        const selectedLabel = 'London · Europe';
        await choosePlace('London', selectedLabel);
        expect(
          find.widgetWithText(OutlinedButton, selectedLabel),
          findsOneWidget,
        );
        expect(repository.previewZones, ['Europe/Bucharest', 'Europe/London']);
        expect(repository.previews, hasLength(2));
        expect(repository.previews.last.timeZone, 'Europe/London');
        expect(
          repository.previews.last.effectiveFromLocalDate,
          initialPreview.effectiveFromLocalDate,
        );
        expect(repository.previews.last.items, hasLength(2));
        expect(schedules.calls, isEmpty);
        expect(find.textContaining('Europe/'), findsNothing);
        expect(
          find.textContaining(
            accessible ? 'Ora dispozitivului' : 'Device time',
          ),
          findsNothing,
        );
        final boundary = find.textContaining(
          accessible
              ? 'Se aplică de la miezul nopții'
              : 'Applies from midnight',
        );
        await tester.scrollUntilVisible(boundary, 180);
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(boundary).data, contains(selectedLabel));
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('legacy-review-confirm')),
          250,
        );
        await tester.tap(find.byKey(const ValueKey('legacy-review-confirm')));
        await tester.pumpAndSettle();
        expect(schedules.calls, ['daily', 'weekly']);
        expect(schedules.zones, ['Europe/London', 'Europe/London']);
        expect(sync.calls, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'connected freshness wording uses received evidence without implying shared care',
    (tester) async {
      Future<void> status(DateTime? received) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              careSharingStatusProvider.overrideWith(
                (_) => Stream.value(
                  CareSharingStatus(
                    isLocalOnly: false,
                    lastCarePullAt: received,
                    pendingCount: 0,
                    needsReviewCount: 0,
                    uncertainCount: 0,
                  ),
                ),
              ),
            ],
            child: const MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(body: CareSharingSummary()),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await status(null);
      expect(
        find.textContaining('Server records have not been verified'),
        findsOneWidget,
      );
      expect(find.textContaining('Shared care'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await status(DateTime.utc(2026, 10, 4, 8));
      expect(find.textContaining('Last server update received:'), findsNothing);
      expect(find.textContaining('Shared care'), findsNothing);
    },
  );
}

Future<void> _capture(WidgetTester tester, String name) async {
  final directory = Platform.environment['REVIEW_CAPTURE_DIR'];
  if (directory == null) return;
  await tester.runAsync(() async {
    final boundary =
        _captureKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png').writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

class _Sync implements AutoSyncService {
  int calls = 0;
  @override
  Future<void> syncNow(String userId, {int? generation}) async {
    calls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ReviewRepository extends LegacyRoutineReviewRepository {
  _ReviewRepository({
    required super.database,
    required super.access,
    required super.context,
    required super.schedules,
  });

  final previewZones = <String>[];
  final previews = <LegacyRoutineReviewPreview>[];

  @override
  Future<LegacyRoutineReviewPreview> preview({
    required String timeZone,
    required DateTime effectiveFromLocalDate,
  }) async {
    previewZones.add(timeZone);
    final preview = await super.preview(
      timeZone: timeZone,
      effectiveFromLocalDate: effectiveFromLocalDate,
    );
    previews.add(preview);
    return preview;
  }
}

class _Schedules implements ScheduleRepository {
  final calls = <String>[];
  final zones = <String>[];
  bool failSecond = false;
  @override
  Future<Result<Schedule>> repair({
    required String localId,
    required String issueId,
    required int expectedIssueRevision,
    required int hour,
    required int minute,
    required String frequency,
    required List<int>? frequencyDays,
    required bool isActive,
    required DateTime effectiveFromLocalDate,
    required String timeZone,
  }) async {
    calls.add(localId);
    zones.add(timeZone);
    if (failSecond && calls.length == 2) {
      return const Err(NetworkError('fictional'));
    }
    return Ok(
      Schedule(
        id: localId,
        pillId: 'pill',
        hour: hour,
        minute: minute,
        frequency: frequency,
        timeZone: timeZone,
        timeZoneStatus: 'known',
        frequencyDays: null,
        isActive: isActive,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        serverId: null,
        revision: 1,
        syncStatus: 'synced',
        lastSyncAt: null,
        isDeleted: false,
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ThemeData _renderTheme(bool dark) {
  final theme = dark ? AppTheme.dark() : AppTheme.light();
  if (Platform.environment['REVIEW_FONT'] == null) return theme;
  final label = theme.textTheme.labelLarge!.copyWith(fontFamily: 'Roboto');
  return theme.copyWith(
    appBarTheme: theme.appBarTheme.copyWith(
      titleTextStyle: theme.appBarTheme.titleTextStyle!.copyWith(
        fontFamily: 'Roboto',
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: theme.filledButtonTheme.style!.copyWith(
        textStyle: WidgetStatePropertyAll(label),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: theme.outlinedButtonTheme.style!.copyWith(
        textStyle: WidgetStatePropertyAll(label),
      ),
    ),
  );
}
