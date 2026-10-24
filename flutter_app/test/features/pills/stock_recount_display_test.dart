import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/pills/presentation/medication_compact_list.dart';
import 'package:simpastil/features/pills/presentation/medication_identity.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:simpastil/shared/widgets/stock_recount_note.dart';

Widget _host(Widget child, {String language = 'en'}) => MaterialApp(
  locale: Locale(language),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  theme: AppTheme.light(),
  home: Scaffold(body: child),
);

MedicationCompactRow _row({required bool needsRecount}) => MedicationCompactRow(
  id: 'third',
  name: 'Thirdmed',
  tint: Colors.teal,
  shape: MedicationShape.round,
  subtitle: 'Every day',
  stock: 10,
  stockText: '10',
  needsRecount: needsRecount,
  threshold: null,
  stockInline: false,
);

void main() {
  testWidgets('a list row says the count needs a recount', (tester) async {
    await tester.pumpWidget(_host(_row(needsRecount: true)));
    expect(find.text('10 left · needs a recount'), findsOneWidget);
    await tester.pumpWidget(_host(_row(needsRecount: false)));
    expect(find.text('10 left'), findsOneWidget);
    expect(find.textContaining('recount'), findsNothing);
  });

  testWidgets('a list row recount is tan like the note, not red', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_row(needsRecount: true)));
    final semantic = AppTheme.light().extension<AppSemanticColors>()!;
    final text = tester.widget<Text>(find.text('10 left · needs a recount'));
    expect(text.style?.color, semantic.statusWarning);
    expect(text.style?.color, isNot(semantic.statusMissed));
  });

  testWidgets('the note is worded in both languages', (tester) async {
    await tester.pumpWidget(
      _host(const StockRecountNote(explain: true), language: 'ro'),
    );
    expect(find.text('Trebuie renumărat'), findsOneWidget);
    expect(find.textContaining('o treime'), findsOneWidget);
    await tester.pumpWidget(_host(const StockRecountNote(explain: true)));
    expect(find.text('Needs a recount'), findsOneWidget);
    expect(find.textContaining('third of a tablet'), findsOneWidget);
  });
}
