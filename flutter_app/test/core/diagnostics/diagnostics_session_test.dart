import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/diagnostics/diagnostic_event.dart';
import 'package:simpastil/core/diagnostics/diagnostics_recorder.dart';
import 'package:simpastil/core/diagnostics/diagnostics_session.dart';
import 'package:simpastil/core/diagnostics/session_marker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('simpastil-diag-');
  });
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('SessionMarker', () {
    test('the first run has no previous ending', () async {
      expect(await SessionMarker(dir).begin(), isNull);
    });

    test('a run that ended in front is reported on the next start', () async {
      var now = DateTime.utc(2026, 10, 18, 9);
      final marker = SessionMarker(dir, clock: () => now);
      await marker.begin();
      now = DateTime.utc(2026, 10, 18, 10);
      expect(
        await SessionMarker(dir, clock: () => now).begin(),
        DateTime.utc(2026, 10, 18, 9),
      );
    });

    test('a run that left the front is a normal ending', () async {
      final marker = SessionMarker(dir);
      await marker.begin();
      await marker.markBackground();
      expect(await SessionMarker(dir).begin(), isNull);
    });

    test(
      'coming back to the front makes the next ending count again',
      () async {
        final marker = SessionMarker(dir);
        await marker.begin();
        await marker.markBackground();
        await marker.markForeground();
        expect(await SessionMarker(dir).begin(), isNotNull);
      },
    );

    test('keeps the dismissal across later writes', () async {
      final marker = SessionMarker(dir);
      await marker.begin();
      final incident = DateTime.utc(2026, 10, 18, 9);
      await marker.dismiss(incident);
      await marker.markBackground();
      expect(await marker.dismissedAt(), incident);
    });

    test('a damaged file reads as no information, not a crash', () async {
      File('${dir.path}/session.json').writeAsStringSync('{"v":1,"state"');
      expect(await SessionMarker(dir).begin(), isNull);
    });
  });

  group('DiagnosticsSession', () {
    DiagnosticsSession sessionFor(Directory dir, {ProcessExit? exit}) =>
        DiagnosticsSession(
          recorder: DiagnosticsRecorder(directory: () async => dir),
          lastProcessExit: exit == null ? null : () async => exit,
        );

    Future<void> endInFront(Directory dir, DateTime at) async {
      await SessionMarker(dir, clock: () => at).begin();
    }

    test('no incident after a normal ending', () async {
      final first = sessionFor(dir);
      await first.start();
      first.didChangeAppLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await sessionFor(dir).pendingIncident(), isNull);
    });

    test('an ending in front is an incident until dismissed', () async {
      final at = DateTime.utc(2026, 10, 18, 9);
      await endInFront(dir, at);
      final second = sessionFor(dir);
      expect((await second.pendingIncident())?.at, at);
      await second.dismissIncident();
      expect(await second.pendingIncident(), isNull);
      // The next start after that dismissal does not announce it again.
      await SessionMarker(dir).markBackground();
      expect(await sessionFor(dir).pendingIncident(), isNull);
    });

    test('records the ending as an unclean_end event', () async {
      await endInFront(dir, DateTime.utc(2026, 10, 18, 9));
      final recorder = DiagnosticsRecorder(directory: () async => dir);
      final session = DiagnosticsSession(recorder: recorder);
      await session.start();
      final kinds = (await recorder.recent()).map((e) => e.kind);
      expect(
        kinds,
        containsAll([DiagnosticKind.uncleanEnd, DiagnosticKind.appStarted]),
      );
    });

    test(
      'a system or user stop reported by Android is not an incident',
      () async {
        final at = DateTime.utc(2026, 10, 18, 9);
        await endInFront(dir, at);
        final session = sessionFor(
          dir,
          exit: ProcessExit(
            reason: 'user_requested',
            at: at.add(const Duration(minutes: 5)),
          ),
        );
        expect(await session.pendingIncident(), isNull);
      },
    );

    for (final reason in const [
      'package_updated',
      'package_state_change',
      'freezer',
      'user_stopped',
      'permission_change',
    ]) {
      test('$reason reported by Android is not an incident', () async {
        final at = DateTime.utc(2026, 10, 18, 9);
        await endInFront(dir, at);
        final session = sessionFor(
          dir,
          exit: ProcessExit(
            reason: reason,
            at: at.add(const Duration(minutes: 1)),
          ),
        );
        expect(await session.pendingIncident(), isNull);
      });
    }

    test(
      'a native crash reported by Android is an incident with its reason',
      () async {
        final at = DateTime.utc(2026, 10, 18, 9);
        await endInFront(dir, at);
        final session = sessionFor(
          dir,
          exit: ProcessExit(
            reason: 'crash_native',
            at: at.add(const Duration(minutes: 5)),
          ),
        );
        final incident = await session.pendingIncident();
        expect(incident?.exit?.reason, 'crash_native');
      },
    );

    test('an Android record older than the run is ignored', () async {
      final at = DateTime.utc(2026, 10, 18, 9);
      await endInFront(dir, at);
      final session = sessionFor(
        dir,
        exit: ProcessExit(
          reason: 'user_requested',
          at: at.subtract(const Duration(days: 2)),
        ),
      );
      expect((await session.pendingIncident())?.exit, isNull);
    });

    test('an unknown Android reason is read as other', () async {
      final at = DateTime.utc(2026, 10, 18, 9);
      await endInFront(dir, at);
      final session = sessionFor(
        dir,
        exit: ProcessExit(
          reason: 'canary; drop table',
          at: at.add(const Duration(minutes: 1)),
        ),
      );
      expect((await session.pendingIncident())?.exit?.reason, 'other');
    });
  });
}
