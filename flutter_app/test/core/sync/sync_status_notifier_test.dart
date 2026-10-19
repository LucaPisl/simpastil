import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/network/pinned_connection.dart';
import 'package:simpastil/core/sync/sync_error_classifier.dart';
import 'package:simpastil/core/sync/sync_models.dart';
import 'package:simpastil/core/sync/sync_status_notifier.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  group('SyncStatusNotifier', () {
    test('initial state is idle with no history', () {
      final status = container.read(syncStatusProvider);
      expect(status.phase, SyncPhase.idle);
      expect(status.lastSuccessAt, isNull);
      expect(status.failingSince, isNull);
      expect(status.pendingCount, 0);
    });

    test('markSyncing preserves history fields', () async {
      final notifier = container.read(syncStatusProvider.notifier);
      await notifier.markFailure(
        DioException(
          requestOptions: RequestOptions(path: '/'),
          type: DioExceptionType.connectionError,
        ),
        pendingCount: 2,
      );
      notifier.markSyncing();

      final status = container.read(syncStatusProvider);
      expect(status.phase, SyncPhase.syncing);
      expect(status.lastError, isNotNull);
      expect(status.pendingCount, 2);
    });

    test('markSuccess clears failure state and persists timestamp', () async {
      final notifier = container.read(syncStatusProvider.notifier);
      await notifier.markFailure(Exception('x'), pendingCount: 1);
      await notifier.markSuccess(pendingCount: 0);

      final status = container.read(syncStatusProvider);
      expect(status.phase, SyncPhase.idle);
      expect(status.lastSuccessAt, isNotNull);
      expect(status.lastError, isNull);
      expect(status.failingSince, isNull);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('last_sync_at'), isNotNull);
      expect(prefs.getString('sync_failing_since'), isNull);
    });

    test(
      'markFailure keeps the original failingSince across repeats',
      () async {
        final notifier = container.read(syncStatusProvider.notifier);
        await notifier.markFailure(Exception('x'), pendingCount: 1);
        final first = container.read(syncStatusProvider).failingSince;
        await notifier.markFailure(Exception('y'), pendingCount: 1);

        expect(container.read(syncStatusProvider).failingSince, first);
      },
    );

    test('restores a persisted failure from prefs', () async {
      SharedPreferences.setMockInitialValues({
        'last_sync_at': '2026-06-10T08:00:00.000',
        'sync_failing_since': '2026-06-11T14:02:00.000',
        'last_sync_error': 'Server error',
      });
      final c = ProviderContainer();
      addTearDown(c.dispose);

      c.read(syncStatusProvider); // triggers build + restore
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final status = c.read(syncStatusProvider);
      expect(status.phase, SyncPhase.failure);
      // A value stored by an earlier release (the English sentence) reads as
      // its stable code.
      expect(status.lastError, 'SYNC_SERVER_ERROR');
      expect(status.failingSince, DateTime.parse('2026-06-11T14:02:00.000'));
      expect(status.lastSuccessAt, DateTime.parse('2026-06-10T08:00:00.000'));
    });

    test('treats a newer background success as healed on restore', () async {
      SharedPreferences.setMockInitialValues({
        'last_sync_at': '2026-06-11T15:00:00.000',
        'sync_failing_since': '2026-06-11T14:02:00.000',
        'last_sync_error': 'Server error',
      });
      final c = ProviderContainer();
      addTearDown(c.dispose);

      c.read(syncStatusProvider);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final status = c.read(syncStatusProvider);
      expect(status.phase, SyncPhase.idle);
      expect(status.lastError, isNull);
      expect(status.failingSince, isNull);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('sync_failing_since'), isNull);
      expect(prefs.getString('last_sync_error'), isNull);
    });

    test('a live outcome beats the prefs restore', () async {
      SharedPreferences.setMockInitialValues({
        'sync_failing_since': '2026-06-11T14:02:00.000',
        'last_sync_error': 'Server error',
      });
      final c = ProviderContainer();
      addTearDown(c.dispose);

      final notifier = c.read(syncStatusProvider.notifier);
      await notifier.markSuccess(
        pendingCount: 0,
      ); // lands before restore checks
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(c.read(syncStatusProvider).phase, SyncPhase.idle);
      expect(c.read(syncStatusProvider).lastSuccessAt, isNotNull);
    });

    test(
      'preflight failure retains the last available component evidence',
      () async {
        final notifier = container.read(syncStatusProvider.notifier);
        const run = SyncRunResult([
          SyncStageResult(
            stageId: 'pull.stable',
            outcome: SyncComponentOutcome.failed(
              safeErrorCode: 'SYNC_STAGE_FAILED',
            ),
          ),
        ]);
        await notifier.markFailure(
          const SyncFailedException(),
          pendingCount: 1,
          lastRun: run,
        );
        await notifier.markFailure(
          Exception('fictional preflight'),
          pendingCount: 1,
        );
        expect(container.read(syncStatusProvider).lastRun, same(run));
      },
    );

    test('local connection refusal supplies a specific sync status', () async {
      final notifier = container.read(syncStatusProvider.notifier);
      const run = SyncRunResult([
        SyncStageResult(
          stageId: 'pull.pull',
          outcome: SyncComponentOutcome.failed(
            safeErrorCode: 'CLIENT_CONNECTION_ACCESS_UNAVAILABLE',
          ),
        ),
      ]);

      await notifier.markFailure(
        const SyncFailedException(),
        pendingCount: 0,
        lastRun: run,
      );

      expect(
        container.read(syncStatusProvider).lastError,
        'CLIENT_CONNECTION_ACCESS_UNAVAILABLE',
      );
    });

    test('markFailure persists the failure keys', () async {
      final notifier = container.read(syncStatusProvider.notifier);
      await notifier.markFailure(Exception('x'), pendingCount: 1);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('sync_failing_since'), isNotNull);
      expect(prefs.getString('last_sync_error'), 'SYNC_FAILED');
    });
  });

  group('classifySyncError', () {
    DioException dioOf(DioExceptionType type, {int? status}) => DioException(
      requestOptions: RequestOptions(path: '/'),
      type: type,
      response: status == null
          ? null
          : Response(
              requestOptions: RequestOptions(path: '/'),
              statusCode: status,
            ),
    );

    test('connection errors → offline message', () {
      expect(
        classifySyncError(dioOf(DioExceptionType.connectionError)),
        'SYNC_OFFLINE',
      );
      expect(
        classifySyncError(dioOf(DioExceptionType.connectionTimeout)),
        'SYNC_OFFLINE',
      );
    });

    test('send/receive timeouts → timed out', () {
      expect(
        classifySyncError(dioOf(DioExceptionType.sendTimeout)),
        'SYNC_TIMEOUT',
      );
      expect(
        classifySyncError(dioOf(DioExceptionType.receiveTimeout)),
        'SYNC_TIMEOUT',
      );
    });

    test('5xx → server error', () {
      expect(
        classifySyncError(dioOf(DioExceptionType.badResponse, status: 503)),
        'SYNC_SERVER_ERROR',
      );
    });

    test('pull-failed sentinel → unreachable message', () {
      expect(
        classifySyncError(const SyncFailedException()),
        'SYNC_SERVER_UNREACHABLE',
      );
    });

    test('anything else → generic', () {
      expect(classifySyncError(Exception('boom')), 'SYNC_FAILED');
    });

    test('a pin mismatch (also wrapped by Dio) → server key changed', () {
      const mismatch = CertificatePinMismatch(
        host: 'h.example',
        port: 443,
        pinned: 'AA',
        presented: 'BB',
      );
      expect(classifySyncError(mismatch), 'SERVER_KEY_CHANGED');
      expect(
        classifySyncError(
          DioException(
            requestOptions: RequestOptions(path: '/'),
            type: DioExceptionType.unknown,
            error: mismatch,
          ),
        ),
        'SERVER_KEY_CHANGED',
      );
    });
  });

  group('normalizeSyncErrorCode', () {
    test('English sentences stored by earlier releases map to codes', () {
      expect(
        normalizeSyncErrorCode('You appear to be offline'),
        'SYNC_OFFLINE',
      );
      expect(normalizeSyncErrorCode('Connection timed out'), 'SYNC_TIMEOUT');
      expect(normalizeSyncErrorCode('Server error'), 'SYNC_SERVER_ERROR');
      expect(normalizeSyncErrorCode('Sync failed'), 'SYNC_FAILED');
      expect(
        normalizeSyncErrorCode("Couldn't reach the server"),
        'SYNC_SERVER_UNREACHABLE',
      );
    });

    test('codes and unknown values pass through', () {
      expect(normalizeSyncErrorCode('SYNC_OFFLINE'), 'SYNC_OFFLINE');
      expect(
        normalizeSyncErrorCode('CLIENT_UPGRADE_REQUIRED'),
        'CLIENT_UPGRADE_REQUIRED',
      );
      expect(normalizeSyncErrorCode(null), isNull);
    });
  });
}
