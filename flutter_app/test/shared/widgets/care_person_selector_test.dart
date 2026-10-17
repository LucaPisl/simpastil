import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/widgets/care_person_selector.dart';

Profile _person(String id, String name) => Profile(
  id: id,
  userId: 'u',
  name: name,
  avatarEmoji: '',
  isActive: true,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  revision: 0,
  syncStatus: 'synced',
  isDeleted: false,
);

Widget _host(String? selected, ValueChanged<String?> onChanged) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: CarePersonSelector(
      people: [_person('a', 'Casey'), _person('b', 'Mara')],
      selectedId: selected,
      onChanged: onChanged,
      focusDeckPresentation: true,
    ),
  ),
);

void main() {
  testWidgets('says Everyone once while no person is chosen', (tester) async {
    await tester.pumpWidget(_host(null, (_) {}));
    expect(find.text('Everyone'), findsOneWidget);
  });

  testWidgets('offers a way back to Everyone while a person is chosen', (
    tester,
  ) async {
    String? last = 'a';
    await tester.pumpWidget(_host('a', (id) => last = id));
    expect(find.text('Casey'), findsOneWidget);
    await tester.tap(find.text('Everyone'));
    expect(last, isNull);
  });
}
