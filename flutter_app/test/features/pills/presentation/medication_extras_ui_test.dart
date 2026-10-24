import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/medication_extras.dart';
import 'package:simpastil/core/medication/prn_limits.dart';
import 'package:simpastil/features/dashboard/as_needed/as_needed_limit_dialog.dart';
import 'package:simpastil/features/pills/presentation/medication_extras_fields.dart';
import 'package:simpastil/features/pills/presentation/medication_extras_section.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/shared/theme/app_theme.dart';

Widget _app(
  Widget child, {
  double scale = 1,
  bool dark = false,
  Size? size,
  List<Override> overrides = const [],
}) => ProviderScope(
  overrides: overrides,
  child: MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: dark ? AppTheme.dark() : AppTheme.light(),
    home: MediaQuery(
      data: MediaQueryData(
        size: size ?? const Size(800, 1200),
        textScaler: TextScaler.linear(scale),
      ),
      child: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  ),
);

void main() {
  group('limit dialog', () {
    for (final dark in [false, true]) {
      testWidgets('fits at text scale 1.3 (${dark ? 'dark' : 'light'})', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(360, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final state = PrnLimitState(
          countIn24h: 3,
          maxPer24h: 3,
          minGapMinutes: 270,
          breach: PrnLimitBreach.both,
          nextAllowedAt: DateTime(2026, 10, 22, 18, 30),
        );
        await tester.pumpWidget(
          _app(
            AsNeededLimitDialog(
              medicationName: 'Fakeolol extra strength long name',
              state: state,
            ),
            scale: 1.3,
            dark: dark,
            size: const Size(360, 640),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('as-needed-limit-dialog')), findsOne);
        expect(find.textContaining('4.5'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('as-needed-limit-record-anyway')),
          warnIfMissed: false,
        );
      });
    }
  });

  group('details section', () {
    const extras = MedicationExtras(
      prnMaxPer24h: 3,
      prnMinGapMinutes: 240,
      expiresOn: '2026-11-01',
      prescriberName: 'Dr Fictional',
      prescriberPhone: '+40 21 555 0100',
      pharmacyName: 'Fictional Pharmacy',
    );

    testWidgets('shows limits, expiry, contacts, and nothing when empty', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          MedicationExtrasSection(extras: extras, now: DateTime(2026, 10, 22)),
        ),
      );
      expect(find.text('At most 3 in 24 hours'), findsOneWidget);
      expect(find.text('At least 4 hours apart'), findsOneWidget);
      expect(find.byKey(const ValueKey('medication-expiry')), findsOneWidget);
      expect(find.text('Dr Fictional'), findsOneWidget);
      expect(find.text('Fictional Pharmacy'), findsOneWidget);
      // Only the prescriber has a number, so only one call button.
      expect(
        find.byKey(const ValueKey('medication-prescriber-call')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('medication-pharmacy-call')),
        findsNothing,
      );

      await tester.pumpWidget(
        _app(const MedicationExtrasSection(extras: MedicationExtras.none)),
      );
      expect(
        find.byKey(const ValueKey('medication-extras-section')),
        findsNothing,
      );
    });

    testWidgets('tap to call opens a tel link with dialable characters only', (
      tester,
    ) async {
      final launched = <Uri>[];
      await tester.pumpWidget(
        _app(
          const MedicationExtrasSection(extras: extras),
          overrides: [
            phoneLauncherProvider.overrideWithValue((uri) async {
              launched.add(uri);
              return true;
            }),
          ],
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey('medication-prescriber-call')),
      );
      await tester.pump();
      expect(launched.single.scheme, 'tel');
      expect(launched.single.path, '+40215550100');
    });

    testWidgets('a failed call says so', (tester) async {
      await tester.pumpWidget(
        _app(
          const MedicationExtrasSection(extras: extras),
          overrides: [
            phoneLauncherProvider.overrideWithValue((uri) async => false),
          ],
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey('medication-prescriber-call')),
      );
      await tester.pump();
      expect(find.text("Couldn't open the phone app"), findsOneWidget);
    });

    testWidgets('the call button has a spoken label with name and number', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _app(const MedicationExtrasSection(extras: extras)),
      );
      expect(
        find.bySemanticsLabel('Call Dr Fictional, +40 21 555 0100'),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('expired reads as expired', (tester) async {
      await tester.pumpWidget(
        _app(
          MedicationExtrasSection(
            extras: const MedicationExtras(expiresOn: '2026-10-01'),
            now: DateTime(2026, 10, 22),
          ),
        ),
      );
      expect(
        (tester.widget(find.byKey(const ValueKey('medication-expiry'))) as Text)
            .data,
        startsWith('Expired'),
      );
    });

    testWidgets(
      'a due expiry says "Expires" once and a mix is titled Details',
      (tester) async {
        await tester.pumpWidget(
          _app(
            MedicationExtrasSection(
              extras: extras,
              now: DateTime(2026, 10, 22),
            ),
          ),
        );
        expect(
          (tester.widget(find.byKey(const ValueKey('medication-expiry')))
                  as Text)
              .data,
          'Expires in 10 days · Nov 1, 2026',
        );
        expect(find.text('Details'), findsOneWidget);
        expect(find.text('Expiry date'), findsOneWidget);
        expect(find.text('Limits'), findsOneWidget);
      },
    );

    testWidgets('contacts alone keep their own title', (tester) async {
      await tester.pumpWidget(
        _app(
          const MedicationExtrasSection(
            extras: MedicationExtras(prescriberName: 'Dr Fictional'),
          ),
        ),
      );
      expect(find.text('Prescriber and pharmacy'), findsOneWidget);
      expect(find.text('Details'), findsNothing);
    });

    test('telUri keeps only dialable characters', () {
      expect(
        telUri('(021) 555-0100 #2').toString(),
        'tel:0215550100#2'.replaceAll('#', '%23'),
      );
    });
  });

  group('edit fields', () {
    for (final width in [390.0, 1000.0]) {
      testWidgets('render and validate at ${width.round()} wide', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final editor = MedicationExtrasEditor(MedicationExtras.none);
        addTearDown(editor.dispose);
        late BuildContext captured;
        await tester.pumpWidget(
          _app(
            Builder(
              builder: (context) {
                captured = context;
                return Column(
                  children: medicationExtrasSections(
                    context: context,
                    editor: editor,
                    identity: 'pill',
                    firstIndex: 0,
                    enabled: true,
                    showLimits: true,
                  ),
                );
              },
            ),
            size: Size(width, 1600),
          ),
        );
        for (final key in [
          'edit-medication-max-per-24h',
          'edit-medication-min-gap-hours',
          'edit-medication-expiry-pick',
          'edit-medication-prescriber-name',
          'edit-medication-prescriber-phone',
          'edit-medication-pharmacy-name',
          'edit-medication-pharmacy-phone',
        ]) {
          expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
        }
        expect(tester.takeException(), isNull);
        final l = AppLocalizations.of(captured);
        expect(editor.isValid(l), isTrue);
        editor.prescriberPhone.text = 'call me';
        expect(editor.isValid(l), isFalse);
        editor.prescriberPhone.text = '+40 21 555 0100';
        editor.maxPer24h.text = '4';
        editor.gapHours.text = '4,5';
        expect(editor.isValid(l), isTrue);
        final read = editor.read();
        expect(read.prnMaxPer24h, 4);
        expect(read.prnMinGapMinutes, 270);
        expect(read.prescriberPhone, '+40 21 555 0100');
      });
    }
  });
}
