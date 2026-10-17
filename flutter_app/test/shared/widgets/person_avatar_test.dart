import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/shared/theme/app_theme.dart';
import 'package:simpastil/shared/widgets/person_avatar.dart';

void main() {
  group('personTint', () {
    test('is stable for the same id and comes from the palette', () {
      for (final id in ['casey-1', 'p_42', '', 'ü-ñ']) {
        expect(personTint(id), personTint(id));
        expect(kPersonTints, contains(personTint(id)));
      }
    });

    test('spreads different people across several tints', () {
      final tints = {for (var i = 0; i < 40; i++) personTint('person-$i')};
      expect(tints.length, greaterThanOrEqualTo(5));
    });
  });

  group('personAvatarGlyph', () {
    test('uses a chosen emoji', () {
      expect(personAvatarGlyph('Casey', '🌻'), '🌻');
    });

    test('falls back to the initial for the default or no emoji', () {
      expect(personAvatarGlyph('casey', kDefaultPersonEmoji), 'C');
      expect(personAvatarGlyph('  rowan ', null), 'R');
      expect(personAvatarGlyph('', '  '), '?');
    });
  });

  test('avatar ink keeps 4.5:1 on its wash for every tint and theme', () {
    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      for (final tint in kPersonTints) {
        final colors = personAvatarColors(theme, tint);
        expect(
          AppTheme.contrast(colors.ink, colors.fill),
          greaterThanOrEqualTo(4.5),
          reason: '$tint on ${theme.brightness}',
        );
      }
    }
  });

  testWidgets('avatar keeps its size and stays out of semantics at 2x text', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PersonAvatar(id: 'casey', name: 'Casey'),
                  PersonAvatarStack(
                    people: [
                      (id: 'a', name: 'Ana', emoji: null),
                      (id: 'b', name: 'Bo', emoji: null),
                      (id: 'e', name: 'Eli', emoji: null),
                      (id: 'd', name: 'Di', emoji: null),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(const ValueKey('person-avatar-casey'))),
      const Size(46, 46),
    );
    expect(find.text('C'), findsOneWidget);
    expect(find.text('+1'), findsOneWidget);
    expect(find.bySemanticsLabel('C'), findsNothing);
    handle.dispose();
  });
}
