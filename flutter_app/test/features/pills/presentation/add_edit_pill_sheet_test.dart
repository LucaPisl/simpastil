import 'package:simpastil/core/medication/medication_extras.dart';
import 'package:simpastil/core/inventory/exact_stock.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/sync/ledger_mode_hint.dart';
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
  final shapes = <String?>[];
  final quantities = <ExactStock?>[];
  final units = <String?>[];
  final extrasSeen = <MedicationExtras?>[];
  final stockCountedSeen = <bool>[];
  Object? throwOnUpdate;

  @override
  Future<Result<Pill>> update(
    String localId, {
    required String name,
    String? dosage,
    String? notes,
    String? color,
    int? currentStock,
    ExactStock? stockQuantity,
    String? stockUnit,
    int? lowStockThreshold,
    bool isPrn = false,
    String? shape,
    MedicationExtras? extras,
    bool stockCounted = false,
  }) async {
    if (throwOnUpdate != null) throw throwOnUpdate!;
    stockCountedSeen.add(stockCounted);
    shapes.add(shape);
    extrasSeen.add(extras);
    quantities.add(stockQuantity);
    units.add(stockUnit);
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
    stockNeedsRecount: false,
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

  Future<void> open(
    WidgetTester tester,
    Pill pill, {
    Locale locale = const Locale('en'),
  }) async {
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
          locale: locale,
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

  testWidgets('saving other fields is not a stock count', (tester) async {
    await open(tester, _pill('pill-a', stock: 10));
    await tester.tap(find.byKey(const ValueKey('tint-#0E3DA7')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('save-pill')));
    await tester.pumpAndSettle();
    expect(repo.stockCountedSeen.single, isFalse);
  });

  testWidgets('re-entering the same stock is a stock count', (tester) async {
    await open(tester, _pill('pill-a', stock: 10));
    final field = find.byKey(const ValueKey('pill-stock'));
    await tester.enterText(field, '1');
    await tester.enterText(field, '10');
    await tester.tap(find.byKey(const ValueKey('save-pill')));
    await tester.pumpAndSettle();
    expect(repo.stockCountedSeen.single, isTrue);
    expect(repo.calls.single.stock, 10);
  });

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
    await tester.tap(find.byKey(const ValueKey('tint-#0E3DA7')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('save-pill')));
    await tester.pumpAndSettle();
    expect(repo.calls.single.color, '#0E3DA7');
  });

  testWidgets('saving without picking a shape leaves the stored one alone', (
    tester,
  ) async {
    await open(tester, _pill('pill-a'));
    await tester.tap(find.byKey(const ValueKey('save-pill')));
    await tester.pumpAndSettle();
    expect(repo.shapes.single, isNull);
  });

  testWidgets('picking a shape is written by its wire name', (tester) async {
    await open(tester, _pill('pill-a'));
    final pick = find.byKey(const ValueKey('shape-diamond'));
    await tester.ensureVisible(pick);
    await tester.tap(pick);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('save-pill')));
    await tester.pumpAndSettle();
    expect(repo.shapes.single, 'diamond');
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

  for (final (code, shown) in [('en', '1.5'), ('ro', '1,5')]) {
    testWidgets('the saved gap reads with the $code decimal separator and '
        'either separator saves the same', (tester) async {
      await open(
        tester,
        _pill(
          'pill-a',
          isPrn: true,
        ).copyWith(prnMinGapMinutes: const Value(90)),
        locale: Locale(code),
      );
      final field = find.byKey(const ValueKey('edit-medication-min-gap-hours'));
      await tester.ensureVisible(field);
      expect(tester.widget<TextField>(field).controller!.text, shown);
      for (final typed in ['2.5', '2,5']) {
        await tester.enterText(field, typed);
        await tester.tap(find.byKey(const ValueKey('save-pill')));
        await tester.pumpAndSettle();
        expect(repo.extrasSeen.last?.prnMinGapMinutes, 150, reason: typed);
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
      }
    });
  }

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

  group('part counts', () {
    Pill counted({String? unit}) => _pill('pill-a', stock: 7).copyWith(
      stockQuantity: Value(unit == null ? null : '7'),
      stockUnit: Value(unit),
    );

    Future<void> enter(WidgetTester tester, String text) async {
      await tester.enterText(find.byKey(const ValueKey('pill-stock')), text);
      await tester.tap(find.byKey(const ValueKey('save-pill')));
      await tester.pumpAndSettle();
    }

    testWidgets('are saved in the unit when the server holds them', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        LedgerModeHint.fractionalStockKey: true,
      });
      await open(tester, counted(unit: 'tablet'));
      await enter(tester, '7.5');
      expect(repo.quantities.single?.toWire(), '7.5');
      expect(repo.units.single, 'tablet');
    });

    testWidgets('are refused without a unit to count them in', (tester) async {
      SharedPreferences.setMockInitialValues({
        LedgerModeHint.fractionalStockKey: true,
      });
      await open(tester, counted());
      await enter(tester, '7.5');
      expect(repo.calls, isEmpty);
      expect(
        find.text(
          'To count part of a tablet, first set the amount per dose in tablets.',
        ),
        findsWidgets,
      );
    });

    testWidgets('are refused when the server may not hold them', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await open(tester, counted(unit: 'tablet'));
      await enter(tester, '7.5');
      expect(repo.calls, isEmpty);
      expect(find.text('Use a whole number, like 30.'), findsWidgets);
    });

    testWidgets('a whole count still saves when the server may not hold part '
        'counts', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await open(tester, counted(unit: 'tablet'));
      await enter(tester, '8');
      expect(repo.calls, hasLength(1));
    });
  });
}
