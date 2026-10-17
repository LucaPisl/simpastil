import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/errors/app_error.dart';
import 'package:simpastil/features/pills/pill_provider.dart';
import 'package:simpastil/features/pills/pill_repository.dart';
import 'package:simpastil/features/pills/presentation/add_edit_pill_sheet.dart';
import 'package:simpastil/features/pills/presentation/medication_identity.dart';
import 'package:simpastil/features/profiles/profile_provider.dart';
import 'package:simpastil/l10n/app_localizations.dart';

class _UpdateCall {
  _UpdateCall(
    this.id,
    this.color,
    this.stock,
    this.threshold,
    this.isPrn, [
    this.name,
  ]);
  final String id;
  final String? color;
  final int? stock;
  final int? threshold;
  final bool isPrn;
  final String? name;
}

class _Repo implements PillRepository {
  final calls = <_UpdateCall>[];
  Object? throwOnUpdate;

  @override
  Future<Result<Pill>> update(
    String localId, {
    required String name,
    String? dosage,
    String? notes,
    String? color,
    int? currentStock,
    int? lowStockThreshold,
    bool isPrn = false,
  }) async {
    if (throwOnUpdate != null) throw throwOnUpdate!;
    calls.add(
      _UpdateCall(localId, color, currentStock, lowStockThreshold, isPrn, name),
    );
    return Ok(_pill(localId));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Mode extends SiblingDetectionNotifier {
  @override
  SiblingDetectionMode build() => SiblingDetectionMode.nameOnly;
}

Pill _pill(String id, {String? color, int? stock, bool isPrn = false}) {
  final now = DateTime.utc(2026, 10, 1);
  return Pill(
    id: id,
    profileId: 'profile-$id',
    name: 'Vitamin D',
    dosage: null,
    notes: null,
    color: color,
    currentStock: stock,
    lowStockThreshold: null,
    isPrn: isPrn,
    createdAt: now,
    updatedAt: now,
    serverId: null,
    revision: 3,
    syncStatus: 'synced',
    lastSyncAt: null,
    isDeleted: false,
  );
}

void main() {
  late AppDatabase db;
  late _Repo repo;

  setUp(() {
    db = AppDatabase.forTesting();
    addTearDown(db.close);
    repo = _Repo();
  });

  Future<void> open(WidgetTester tester, Pill pill) async {
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pillRepositoryProvider.overrideWithValue(repo),
          databaseProvider.overrideWithValue(db),
          currentUserIdProvider.overrideWithValue('user'),
          profileListProvider.overrideWith((ref) => Stream.value(const [])),
          siblingDetectionModeProvider.overrideWith(_Mode.new),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    showAddEditPillSheet(context: context, pill: pill),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  for (final color in [null, '#EC407A', '#123456']) {
    testWidgets('stock-only save keeps the colour ($color)', (tester) async {
      await open(tester, _pill('pill-a', color: color));
      await tester.tap(find.byKey(const ValueKey('save-pill')));
      await tester.pumpAndSettle();
      expect(repo.calls.single.color, color);
    });
  }

  testWidgets('the as-needed switch reads "Only when I need it" and saving '
      'stays on the medication form', (tester) async {
    await open(tester, _pill('pill-a'));
    final switchTile = find.byKey(const ValueKey('pill-only-when-needed'));
    expect(find.text('Only when I need it'), findsOneWidget);
    expect(
      find.text(
        'No routine and no reminders. Record a dose whenever you take it.',
      ),
      findsOneWidget,
    );
    expect(find.text('As-needed (PRN)'), findsNothing);
    await tester.ensureVisible(switchTile);
    await tester.tap(switchTile);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('save-pill')));
    await tester.pumpAndSettle();
    expect(repo.calls.single.isPrn, isTrue);
    // Saving closes the sheet; no schedule or routine sheet follows.
    expect(find.text('Add schedule'), findsNothing);
    expect(find.text('Add a routine'), findsNothing);
    expect(find.byKey(const ValueKey('save-pill')), findsNothing);
  });

  testWidgets('the swatch shown selected matches the card fallback tint', (
    tester,
  ) async {
    await open(tester, _pill('pill-a'));
    final hex = medicationFallbackHex('pill-a');
    final semantics = tester.getSemantics(find.byKey(ValueKey('tint-$hex')));
    expect(semantics.flagsCollection.isSelected, isNot(0));
  });

  testWidgets('picking a swatch is written', (tester) async {
    await open(tester, _pill('pill-a'));
    await tester.tap(find.byKey(const ValueKey('tint-#5C6BC0')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('save-pill')));
    await tester.pumpAndSettle();
    expect(repo.calls.single.color, '#5C6BC0');
  });

  testWidgets('tracking stock without an alert level saves on first tap', (
    tester,
  ) async {
    await open(tester, _pill('pill-a'));
    await tester.tap(find.byType(Switch).at(1));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('pill-stock')), '12');
    await tester.tap(find.byKey(const ValueKey('save-pill')));
    await tester.pumpAndSettle();
    expect(repo.calls.single.stock, 12);
    expect(repo.calls.single.threshold, isNull);
  });

  testWidgets('an invalid field is announced and brought into view', (
    tester,
  ) async {
    await open(tester, _pill('pill-a'));
    await tester.tap(find.byType(Switch).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('save-pill')));
    await tester.pumpAndSettle();
    expect(repo.calls, isEmpty);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('Use a whole number, like 30.'), findsWidgets);
  });

  testWidgets('a throwing repository clears the spinner and says so', (
    tester,
  ) async {
    repo.throwOnUpdate = StateError('boom');
    await open(tester, _pill('pill-a'));
    await tester.tap(find.byKey(const ValueKey('save-pill')));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('save-pill')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('sibling propagation goes through the repository and keeps '
      'fields it does not propagate', (tester) async {
    final now = DateTime.utc(2026, 10, 1);
    await db.usersDao.upsert(
      UsersCompanion.insert(
        id: 'user',
        email: 'u@fictional.invalid',
        createdAt: now,
        updatedAt: now,
      ),
    );
    for (final id in ['pill-a', 'pill-b']) {
      await db.profilesDao.upsert(
        ProfilesCompanion.insert(
          id: 'profile-$id',
          userId: 'user',
          name: 'P $id',
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
    await db.pillsDao.upsert(
      PillsCompanion.insert(
        id: 'pill-a',
        profileId: 'profile-pill-a',
        name: 'Vitamin D',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await db.pillsDao.upsert(
      PillsCompanion.insert(
        id: 'pill-b',
        profileId: 'profile-pill-b',
        name: 'Vitamin D',
        color: const Value('#66BB6A'),
        currentStock: const Value(7),
        isPrn: const Value(true),
        createdAt: now,
        updatedAt: now,
      ),
    );
    await open(tester, _pill('pill-a'));
    await tester.enterText(find.byKey(const ValueKey('pill-name')), 'Vit D3');
    await tester.tap(find.byKey(const ValueKey('save-pill')));
    await tester.pumpAndSettle();
    expect(repo.calls.map((c) => c.id), ['pill-a', 'pill-b']);
    final sibling = repo.calls.last;
    expect(sibling.name, 'Vit D3');
    expect(sibling.color, '#66BB6A'); // colour untouched, not propagated
    expect(sibling.stock, 7);
    expect(sibling.isPrn, isTrue);
    // No direct write bypassed the repository.
    expect((await db.pillsDao.getById('pill-b'))?.name, 'Vitamin D');
  });
}
