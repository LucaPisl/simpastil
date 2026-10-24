import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/medication_amount.dart';
import 'package:simpastil/core/medication/medication_shape.dart';
import 'package:simpastil/core/medication/routine_definition.dart';
import 'package:simpastil/features/dashboard/as_needed/as_needed_controller.dart';
import 'package:simpastil/features/dashboard/as_needed/as_needed_dose_editor.dart';
import 'package:simpastil/features/dashboard/as_needed/as_needed_option.dart';
import 'package:simpastil/l10n/app_localizations.dart';

class _Pill extends Fake implements Pill {
  @override
  String get id => 'pill-1';
  @override
  String get name => 'Fictional relief';
  @override
  String? get color => null;
}

class _Person extends Fake implements Profile {
  @override
  String get name => 'Fictional person';
}

/// An option whose recording waits for a review in Settings.
class _ReviewOption extends Fake implements AsNeededOption {
  @override
  String get pillId => 'pill-1';
  @override
  Pill get pill => _Pill();
  @override
  Profile get person => _Person();
  @override
  MedicationAmount get usualAmount => MedicationAmount.known('1', 'tablet');
  @override
  MedicationShape get shape => MedicationShape.round;
  @override
  bool get needsReview => true;
}

void main() {
  for (final (locale, message) in [
    ('en', 'Review this medication in Settings before you record a dose.'),
    (
      'ro',
      'Revizuiește acest medicament în Setări înainte să înregistrezi o doză.',
    ),
  ]) {
    testWidgets('Save on an option waiting for review says why ($locale)', (
      tester,
    ) async {
      late AsNeededController controller;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            locale: Locale(locale),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Consumer(
              builder: (context, ref, _) {
                controller = AsNeededController(
                  ref: ref,
                  localDate: () => routineDateKey(DateTime.now()),
                  canFeel: () => false,
                  onUndoStockUnchanged: () {},
                );
                return Scaffold(
                  body: AsNeededDoseEditor(
                    option: _ReviewOption(),
                    controller: controller,
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final save = find.byKey(const ValueKey('as-needed-save'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(controller.waitsForReview, isTrue);
      expect(controller.ignoredWhileBusy, isFalse);
      expect(find.text(message), findsOneWidget);
      // Nothing was saved, so the editor stays open and Save works again.
      expect(save, findsOneWidget);
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    });
  }

  Future<AsNeededController> pumpEditor(
    WidgetTester tester, {
    required String locale,
    ThemeMode mode = ThemeMode.light,
    void Function(BuildContext)? onOpenReview,
  }) async {
    late AsNeededController controller;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: Locale(locale),
          theme: ThemeData(brightness: Brightness.light),
          darkTheme: ThemeData(brightness: Brightness.dark),
          themeMode: mode,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: Consumer(
            builder: (context, ref, _) {
              controller = AsNeededController(
                ref: ref,
                localDate: () => routineDateKey(DateTime.now()),
                canFeel: () => false,
                onUndoStockUnchanged: () {},
              );
              return Scaffold(
                body: AsNeededDoseEditor(
                  option: _ReviewOption(),
                  controller: controller,
                  onOpenReview: onOpenReview,
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final save = find.byKey(const ValueKey('as-needed-save'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    // The editor's list builds lazily: bring the review action into view.
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('as-needed-open-review')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    return controller;
  }

  for (final (locale, label) in [
    ('en', 'Review in Settings'),
    ('ro', 'Revizuiește în Setări'),
  ]) {
    testWidgets('the review-first message offers the way to Settings '
        '($locale)', (tester) async {
      var opened = 0;
      await pumpEditor(tester, locale: locale, onOpenReview: (_) => opened++);
      final action = find.byKey(const ValueKey('as-needed-open-review'));
      expect(action, findsOneWidget);
      expect(
        find.descendant(of: action, matching: find.text(label)),
        findsOneWidget,
      );
      expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(opened, 1);
    });
  }

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('the review action meets the accessibility guidelines '
        '(${mode.name})', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpEditor(tester, locale: 'en', mode: mode, onOpenReview: (_) {});
      final action = find.byKey(const ValueKey('as-needed-open-review'));
      await tester.ensureVisible(action);
      await tester.pumpAndSettle();
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });
  }

  testWidgets('the review action follows the review-first state, not the '
      'message text', (tester) async {
    await pumpEditor(tester, locale: 'en', onOpenReview: (_) {});
    expect(find.byKey(const ValueKey('as-needed-open-review')), findsOneWidget);

    // Choosing a time clears the message: the review action goes with it.
    final when = find.byKey(const ValueKey('as-needed-when-m15'));
    await tester.scrollUntilVisible(
      when,
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(when);
    await tester.pumpAndSettle();
    expect(
      find.text('Review this medication in Settings before you record a dose.'),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('as-needed-open-review')), findsNothing);
  });
}
