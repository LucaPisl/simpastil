import 'dart:convert';
import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/protection/access_gate.dart';
import 'package:simpastil/core/protection/app_lock_controller.dart';
import 'package:simpastil/core/projections/projection_effects_gate.dart';
import 'package:simpastil/core/projections/projection_reconciler.dart';
import 'package:simpastil/core/projections/reminder_projection.dart';
import 'package:simpastil/core/session/session_generation_repository.dart';
import 'package:simpastil/l10n/app_localizations.dart';
import 'package:simpastil/core/notifications/notification_action_handler.dart';
import 'package:simpastil/core/projections/projection_command_id.dart';
import 'package:simpastil/core/widget/widget_action_handler.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../../helpers/care_recording_fixture.dart';

class _PolicyStorage implements AppLockPolicyStorage {
  _PolicyStorage(bool enabled)
    : value = AppLockPolicy(enabled: enabled, revision: 'fixture').encode();
  String value;
  Future<void> Function()? beforeWrite;
  Completer<void>? reloadEntered;
  Completer<void>? releaseReload;
  @override
  Object? get policyValue => value;
  @override
  Object? get legacyValue => null;
  @override
  Future<void> reload() async {
    final entered = reloadEntered;
    if (entered != null && !entered.isCompleted) {
      entered.complete();
      await releaseReload!.future;
    }
  }

  @override
  Future<bool> write(String next) async {
    await beforeWrite?.call();
    value = next;
    return true;
  }
}

class _SnoozePlatform implements ReminderNotificationPlatform {
  final scheduled = <ReminderProjection>[];
  Future<void> Function()? beforePending;
  @override
  Future<bool> hasNotificationPermission() async => true;
  @override
  Future<bool> hasExactAlarmPermission() async => true;
  @override
  Future<void> initialize() async {}
  @override
  Future<List<PlatformReminderRequest>> pendingRequests() async {
    await beforePending?.call();
    return [];
  }

  @override
  Future<void> schedule(
    ReminderProjection reminder, {
    required AppLocalizations localizations,
  }) async {
    scheduled.add(reminder);
  }

  @override
  Future<void> cancel(int id) async {}
  @override
  Future<void> cancelAll() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(tzdata.initializeTimeZones);
  tearDown(tzdata.initializeTimeZones);

  for (final notification in [false, true]) {
    for (final action in ['take', 'skip']) {
      for (final mode in [0, 1, 2, 3]) {
        test(
          '${['unlocked', 'locked', 'enable wins', 'recording wins'][mode]} ${notification ? 'reminder' : 'widget'} $action preserves cold-zone and lock boundaries',
          () async {
            final locked = mode == 1 || mode == 2;
            final fixture = await CareRecordingFixture.create(
              routineTimeZone: 'Europe/Bucharest',
              routineHour: 12,
              legacyStock: 10,
            );
            addTearDown(fixture.db.close);
            final storage = _PolicyStorage(mode == 1);
            final policy = AppLockPolicyStore(
              storage,
              gate: SerialProjectionEffectsGate(),
            );
            final gate = AccessGate(policy);
            final context = fixture.workspace.context;
            final occurrence = fixture.occurrence;
            await fixture.db
                .into(fixture.db.devicePersonReminders)
                .insertOnConflictUpdate(
                  DevicePersonRemindersCompanion.insert(
                    profileId: fixture.person.id,
                    enabled: const Value(true),
                  ),
                );
            final projectionId = reminderProjectionId(
              userId: context.ownerUserId,
              sessionGeneration: context.accessEpoch,
              occurrenceId: occurrence.id,
              kind: notification ? 'reminder' : 'widget',
              workspaceId: context.workspaceId,
              grantEpoch: context.accessEpoch,
              stateVersion: occurrence.stateVersion,
            );
            final identity = <String, Object>{
              'version': 2,
              'workspaceId': context.workspaceId,
              'grantEpoch': context.accessEpoch,
              'session_generation': context.accessEpoch,
              'active_user_id': context.ownerUserId,
              'occurrenceId': occurrence.id,
              'projectionId': projectionId,
              'stateVersion': occurrence.stateVersion,
            };
            Future<void> deliver() => notification
                ? dispatchNotificationAction(
                    NotificationResponse(
                      notificationResponseType:
                          NotificationResponseType.selectedNotificationAction,
                      actionId: action == 'take' ? 'taken' : 'skip',
                      payload: jsonEncode({
                        'version': 2,
                        'workspaceId': context.workspaceId,
                        'grantEpoch': context.accessEpoch,
                        'userId': context.ownerUserId,
                        'sessionGeneration': context.accessEpoch,
                        'occurrenceId': occurrence.id,
                        'projectionId': projectionId,
                        'stateVersion': occurrence.stateVersion,
                      }),
                    ),
                    plugin: FlutterLocalNotificationsPlugin(),
                    database: fixture.db,
                    access: fixture.workspace.access,
                    accessGate: gate,
                    reconcileRetryWait: (_) async {},
                    scheduleReconcileRetry: (_) async {},
                  )
                : handleWidgetAction(
                    Uri(
                      scheme: 'simpastil',
                      host: action,
                      queryParameters: identity.map(
                        (key, value) => MapEntry(key, value.toString()),
                      ),
                    ),
                    db: fixture.db,
                    access: fixture.workspace.access,
                    accessGate: gate,
                  );

            final stockBefore = (await fixture.db.pillsDao.getById(
              fixture.pill.id,
            ))!.currentStock;
            // A new headless engine has no foreground timezone initialization.
            tz.timeZoneDatabase.clear();
            if (mode == 2) {
              final entered = Completer<void>();
              final release = Completer<void>();
              final held = policy.gate.run(() async {
                entered.complete();
                await release.future;
              });
              await entered.future;
              final enable = policy.replace(
                expected: policy.snapshot(),
                enabled: true,
                requireCurrent: () {},
              );
              final callback = deliver();
              release.complete();
              await held;
              await enable;
              await callback;
            } else if (mode == 3) {
              storage.reloadEntered = Completer<void>();
              storage.releaseReload = Completer<void>();
              final callback = deliver();
              await storage.reloadEntered!.future.timeout(
                const Duration(seconds: 2),
              );
              storage.beforeWrite = () async {
                expect(
                  await fixture.db.medicationLedgerDao.getEventsForOccurrence(
                    occurrence.id,
                  ),
                  hasLength(1),
                );
              };
              final enable = policy.replace(
                expected: policy.snapshot(),
                enabled: true,
                requireCurrent: () {},
              );
              storage.releaseReload!.complete();
              await callback;
              await enable;
              expect(policy.snapshot().enabled, isTrue);
            } else {
              await deliver();
            }
            final saved = (await fixture.db.medicationLedgerDao
                .getOccurrenceById(occurrence.id))!;
            if (locked) {
              expect(saved.state, 'pending');
              expect(
                await fixture.db.medicationLedgerDao.getEventsForOccurrence(
                  occurrence.id,
                ),
                isEmpty,
              );
              expect(
                await fixture.db.select(fixture.db.pendingOperations).get(),
                isEmpty,
              );
              expect(
                (await fixture.db.pillsDao.getById(
                  fixture.pill.id,
                ))!.currentStock,
                stockBefore,
              );
              return;
            }
            expect(saved.state, action == 'take' ? 'taken' : 'skipped');
            expect(saved.timeZone, 'Europe/Bucharest');
            final events = await fixture.db.medicationLedgerDao
                .getEventsForOccurrence(occurrence.id);
            expect(events, hasLength(1));
            expect(events.single.actualTimeKnown, action == 'take');
            expect(
              events.single.actualAt,
              action == 'take' ? isNotNull : isNull,
            );
            expect(
              await fixture.db.select(fixture.db.pendingOperations).get(),
              isEmpty,
            );

            final paris = tz.getLocation('Europe/Paris');
            tz.setLocalLocation(paris);
            await deliver();
            expect(tz.local, same(paris));
            expect(
              await fixture.db.medicationLedgerDao.getEventsForOccurrence(
                occurrence.id,
              ),
              hasLength(1),
            );
          },
        );
      }
    }
  }
  for (final mode in [0, 1, 2]) {
    test(
      'Snooze admission mode $mode preserves care and refuses an effective lock',
      () async {
        final fixture = await CareRecordingFixture.create(legacyStock: 10);
        addTearDown(fixture.db.close);
        final context = fixture.workspace.context;
        final occurrence = fixture.occurrence;
        await fixture.db
            .into(fixture.db.devicePersonReminders)
            .insertOnConflictUpdate(
              DevicePersonRemindersCompanion.insert(
                profileId: fixture.person.id,
                enabled: const Value(true),
              ),
            );
        final storage = _PolicyStorage(mode == 1);
        final policy = AppLockPolicyStore(
          storage,
          gate: SerialProjectionEffectsGate(),
        );
        final platform = _SnoozePlatform();
        if (mode == 2) {
          platform.beforePending = () async {
            await policy.replace(
              expected: policy.snapshot(),
              enabled: true,
              requireCurrent: () {},
            );
          };
        }
        final reconciler = ProjectionReconciler(
          database: fixture.db,
          preferences: fixture.workspace.preferences,
          generations: SessionGenerationRepository(
            fixture.workspace.preferences,
            access: fixture.workspace.access,
          ),
          platform: platform,
          platformKind: ReminderPlatformKind.android,
          access: fixture.workspace.access,
          clock: () => CareRecordingFixture.planned,
        );
        final projection = reminderProjectionId(
          userId: context.ownerUserId,
          sessionGeneration: context.accessEpoch,
          occurrenceId: occurrence.id,
          kind: 'reminder',
          workspaceId: context.workspaceId,
          grantEpoch: context.accessEpoch,
          stateVersion: occurrence.stateVersion,
        );
        final occurrencesBefore = await fixture.db.medicationLedgerDao
            .getOccurrencesForUser(context.ownerUserId);
        expect(occurrencesBefore, hasLength(1));
        await dispatchNotificationAction(
          NotificationResponse(
            notificationResponseType:
                NotificationResponseType.selectedNotificationAction,
            actionId: 'snooze',
            payload: jsonEncode({
              'version': 2,
              'workspaceId': context.workspaceId,
              'grantEpoch': context.accessEpoch,
              'userId': context.ownerUserId,
              'sessionGeneration': context.accessEpoch,
              'occurrenceId': occurrence.id,
              'projectionId': projection,
              'stateVersion': occurrence.stateVersion,
            }),
          ),
          plugin: FlutterLocalNotificationsPlugin(),
          database: fixture.db,
          access: fixture.workspace.access,
          accessGate: AccessGate(policy),
          projectionReconciler: reconciler,
        );
        expect(platform.scheduled, mode == 0 ? hasLength(1) : isEmpty);
        if (mode != 0) {
          expect(
            await fixture.db.medicationLedgerDao.getOccurrencesForUser(
              context.ownerUserId,
            ),
            occurrencesBefore,
          );
        }
        expect(
          (await fixture.db.medicationLedgerDao.getOccurrenceById(
            occurrence.id,
          ))!.state,
          'pending',
        );
        expect(
          await fixture.db.medicationLedgerDao.getEventsForOccurrence(
            occurrence.id,
          ),
          isEmpty,
        );
        expect(
          await fixture.db.select(fixture.db.pendingOperations).get(),
          isEmpty,
        );
        expect(
          (await fixture.db.pillsDao.getById(fixture.pill.id))!.currentStock,
          10,
        );
      },
    );
  }
}
