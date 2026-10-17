import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/database.dart';
import '../utils/app_logger.dart';
import '../utils/safe_diagnostics.dart';
import '../utils/server_id_extractor.dart';
import '../workspace/workspace_context.dart';
import 'held_stock.dart';
import 'sync_write_scope.dart';

/// Un-journaled compatibility path for servers that predate `/capabilities`
/// (capability availability `absent`). It replays pending profiles, pills,
/// schedules and dose logs through the original per-resource REST routes and
/// pulls them back without component checkpoints.
///
/// [SyncService] stays the facade: it selects this module through
/// `CapabilitySnapshot.protocol` and keeps the flush-before-pull order. The
/// rules are unchanged: server wins for profiles, pills and schedules, local
/// wins for dose logs, and a row whose `syncStatus` is not `synced` is never
/// overwritten by a pull.
class LegacySyncCompat {
  LegacySyncCompat({
    required AppDatabase db,
    required Dio dio,
    required SyncWriteScope? writeScope,
    required Future<void> Function(String userId, SharedPreferences preferences)
    recordLastSync,
  }) : _db = db,
       _dio = dio,
       _writeScope = writeScope,
       _recordLastSync = recordLastSync;

  final AppDatabase _db;
  final Dio _dio;
  final SyncWriteScope? _writeScope;
  final Future<void> Function(String userId, SharedPreferences preferences)
  _recordLastSync;

  Future<T> _write<T>(Future<T> Function() action) =>
      _writeScope?.write(action) ?? _db.transaction(action);

  Future<T> _writeEntity<T>(
    String type,
    String id,
    Future<T> Function() action,
  ) => _write(() async {
    await _writeScope?.requireEntity(type, id);
    return action();
  });

  /// Profiles, then pills, then schedules, skipping rows owned by the journal.
  Future<void> flushStable({required String userId}) async {
    await _flushProfiles(
      userId: userId,
      skipLocalIds: await _journaledEntityIds(userId, 'profile'),
    );
    await _flushPills(
      userId: userId,
      skipLocalIds: await _journaledEntityIds(userId, 'pill'),
    );
    await _flushSchedules(
      userId: userId,
      skipLocalIds: await _journaledEntityIds(userId, 'schedule'),
    );
  }

  Future<bool> pull({required String userId}) =>
      _pullLegacyFromServerInner(userId: userId);

  Future<void> flushDoseLogs({required String userId}) =>
      _flushDoseLogs(userId: userId);

  /// Map the response to the row sent, without acknowledging an edit made
  /// while its HTTP request was in flight. Mapping and pending state are one
  /// guarded transaction, so a subsequent pull cannot overwrite that edit.
  Future<void> _markLegacyReceipt(
    String type,
    String id,
    String serverId,
    Object sent,
  ) => _writeEntity(type, id, () async {
    final Object? current;
    final String? owner;
    switch (type) {
      case 'profile':
        final row = await _db.profilesDao.getById(id);
        current = row;
        owner = row?.userId;
      case 'pill':
        final row = await _db.pillsDao.getById(id);
        current = row;
        owner = row == null
            ? null
            : (await _db.profilesDao.getById(row.profileId))?.userId;
      case 'schedule':
        final row = await _db.schedulesDao.getById(id);
        current = row;
        final pill = row == null
            ? null
            : await _db.pillsDao.getById(row.pillId);
        owner = pill == null
            ? null
            : (await _db.profilesDao.getById(pill.profileId))?.userId;
      case 'doseLog':
        final row = await _db.doseLogsDao.getById(id);
        current = row;
        final schedule = row == null
            ? null
            : await _db.schedulesDao.getById(row.scheduleId);
        final pill = schedule == null
            ? null
            : await _db.pillsDao.getById(schedule.pillId);
        owner = pill == null
            ? null
            : (await _db.profilesDao.getById(pill.profileId))?.userId;
      default:
        throw ArgumentError.value(type, 'type');
    }
    if (current == null || owner == null) return;
    var preservePending = current != sent;
    for (final operation in await _db.pendingOperationsDao.getUnsettledForUser(
      owner,
    )) {
      if (operation.state == 'committed' || operation.state == 'discarded') {
        continue;
      }
      final payload = jsonDecode(operation.payloadJson);
      if (payload is Map<String, dynamic> &&
          payload['entityType'] == type &&
          payload['entityLocalId'] == id) {
        preservePending = true;
        break;
      }
    }
    final table = switch (type) {
      'profile' => 'profiles',
      'pill' => 'pills',
      'schedule' => 'schedules',
      'doseLog' => 'dose_logs',
      _ => throw StateError('Unsupported entity'),
    };
    await _db.customUpdate(
      'UPDATE $table SET server_id=?, sync_status=?, last_sync_at=? WHERE id=?',
      variables: [
        Variable<String>(serverId),
        Variable<String>(preservePending ? 'pending' : 'synced'),
        Variable<int>(DateTime.now().millisecondsSinceEpoch),
        Variable<String>(id),
      ],
      updates: {
        switch (type) {
          'profile' => _db.profiles,
          'pill' => _db.pills,
          'schedule' => _db.schedules,
          'doseLog' => _db.doseLogs,
          _ => throw StateError('Unsupported entity'),
        },
      },
    );
  });
  Future<void> _upsertProfile(ProfilesCompanion row) => _write(() async {
    await _writeScope?.requireEntity(
      'profile',
      row.id.value,
      allowMissing: true,
    );
    if (row.userId.present) _writeScope?.requireOwner(row.userId.value);
    await _db.profilesDao.upsert(row);
  });
  Future<void> _upsertPill(PillsCompanion row) => _write(() async {
    await _writeScope?.requireEntity('pill', row.id.value, allowMissing: true);
    if (row.profileId.present) {
      await _writeScope?.requireEntity('profile', row.profileId.value);
    }
    await _db.pillsDao.upsert(row);
  });
  Future<void> _upsertSchedule(SchedulesCompanion row) => _write(() async {
    await _writeScope?.requireEntity(
      'schedule',
      row.id.value,
      allowMissing: true,
    );
    if (row.pillId.present) {
      await _writeScope?.requireEntity('pill', row.pillId.value);
    }
    await _db.schedulesDao.upsert(row);
  });
  Future<void> _upsertDoseLog(DoseLogsCompanion row) => _write(() async {
    await _writeScope?.requireEntity(
      'doseLog',
      row.id.value,
      allowMissing: true,
    );
    if (row.scheduleId.present) {
      await _writeScope?.requireEntity('schedule', row.scheduleId.value);
    }
    await _db.doseLogsDao.upsert(row);
  });

  Future<String?> _readLegacyWatermark(
    String userId,
    String profileId,
    String legacyKey,
    SharedPreferences preferences,
  ) async {
    final scope = _writeScope;
    if (scope == null) return preferences.getString(legacyKey);
    final workspaceId = await scope.workspaceId;
    return _write(() async {
      await scope.requireEntity('profile', profileId);
      final row =
          await (_db.select(_db.workspaceSyncCheckpoints)..where(
                (row) =>
                    row.workspaceId.equals(workspaceId) &
                    row.profileId.equals(profileId) &
                    row.channel.equals('legacyDoseLogs'),
              ))
              .getSingleOrNull();
      return row?.cursor;
    });
  }

  Future<void> _recordLegacyWatermark(
    String userId,
    String profileId,
    String legacyKey,
    String cursor,
    SharedPreferences preferences,
  ) async {
    final scope = _writeScope;
    if (scope == null) {
      await preferences.setString(legacyKey, cursor);
      return;
    }
    scope.requireOwner(userId);
    final workspaceId = await scope.workspaceId;
    await _write(() async {
      await scope.requireEntity('profile', profileId);
      await _db
          .into(_db.workspaceSyncCheckpoints)
          .insertOnConflictUpdate(
            WorkspaceSyncCheckpointsCompanion.insert(
              workspaceId: workspaceId,
              profileId: profileId,
              channel: 'legacyDoseLogs',
              cursor: cursor,
              completedAt: DateTime.now().toUtc(),
            ),
          );
    });
  }

  Future<Set<String>> _journaledEntityIds(
    String userId,
    String entityType,
  ) async {
    final ids = <String>{};
    for (final operation in await _db.pendingOperationsDao.getForUser(userId)) {
      if (operation.component != 'stable' && operation.component != 'account') {
        continue;
      }
      try {
        final payload = jsonDecode(operation.payloadJson);
        if (payload is Map<String, dynamic> &&
            payload['entityType'] == entityType &&
            payload['entityLocalId'] is String) {
          ids.add(payload['entityLocalId'] as String);
        }
      } on FormatException {
        // Malformed intent is not a license to use the legacy writer.
      }
    }
    return ids;
  }

  // ── Profiles ───────────────────────────────────────────────────────────────

  Future<void> _flushProfiles({
    required String userId,
    Set<String> skipLocalIds = const {},
  }) async {
    final pending = await _db.profilesDao.getPendingSync();
    for (final p in pending) {
      if (p.userId != userId || skipLocalIds.contains(p.id)) continue;
      try {
        if (p.isDeleted && p.serverId != null) {
          await _dio.delete<void>('/profiles/${p.serverId}');
          await _markLegacyReceipt('profile', p.id, p.serverId!, p);
        } else if (!p.isDeleted && p.serverId == null) {
          final resp = await _dio.post<Map<String, dynamic>>(
            '/profiles',
            data: {'name': p.name, 'avatarEmoji': p.avatarEmoji},
          );
          final serverId = extractServerId(resp.data);
          if (serverId != null) {
            await _markLegacyReceipt('profile', p.id, serverId, p);
          } else {
            AppLogger.warning(
              'SyncService',
              'Profile ${p.id}: POST succeeded but response lacked data.id',
            );
          }
        } else if (!p.isDeleted && p.serverId != null) {
          await _dio.patch<void>(
            '/profiles/${p.serverId}',
            data: {
              'name': p.name,
              'avatarEmoji': p.avatarEmoji,
              'updatedAt': p.updatedAt.toUtc().toIso8601String(),
            },
          );
          await _markLegacyReceipt('profile', p.id, p.serverId!, p);
        } else {
          await _markLegacyReceipt('profile', p.id, p.id, p);
        }
      } on DioException catch (e) {
        if (e.response?.statusCode == 429) {
          AppLogger.warning(
            'SyncService',
            'Profile flush rate-limited, stopping',
          );
          break;
        } else if (e.response?.statusCode == 409 && p.serverId != null) {
          await _markLegacyReceipt('profile', p.id, p.serverId!, p);
        } else if (e.response?.statusCode == 404 && p.isDeleted) {
          await _markLegacyReceipt('profile', p.id, p.serverId ?? p.id, p);
        } else {
          _logDioFailure('stable', '/profiles', e);
        }
      }
    }
  }

  // ── Pills ──────────────────────────────────────────────────────────────────

  Future<void> _flushPills({
    required String userId,
    Set<String> skipLocalIds = const {},
  }) async {
    final pending = await _db.pillsDao.getPendingSync();
    for (final p in pending) {
      // Child-record guard: skip if parent profile has no serverId yet.
      final profile = await _db.profilesDao.getById(p.profileId);
      if (profile == null ||
          profile.userId != userId ||
          skipLocalIds.contains(p.id) ||
          (profile.serverId == null && !p.isDeleted)) {
        AppLogger.debug(
          'SyncService',
          'Pill ${p.id}: parent profile not synced, skipping',
        );
        continue;
      }

      try {
        if (p.isDeleted && p.serverId != null) {
          await _dio.delete<void>(
            '/profiles/${profile.serverId ?? p.profileId}/pills/${p.serverId}',
          );
          await _markLegacyReceipt('pill', p.id, p.serverId!, p);
        } else if (!p.isDeleted && p.serverId == null) {
          final resp = await _dio.post<Map<String, dynamic>>(
            '/profiles/${profile.serverId ?? p.profileId}/pills',
            data: {
              'name': p.name,
              if (p.dosage != null) 'dosage': p.dosage,
              if (p.notes != null) 'notes': p.notes,
              if (p.color != null) 'color': p.color,
              if (p.currentStock != null) 'currentStock': p.currentStock,
              if (p.lowStockThreshold != null)
                'lowStockThreshold': p.lowStockThreshold,
              if (p.isPrn) 'isPrn': true,
            },
          );
          final serverId = extractServerId(resp.data);
          if (serverId != null) {
            await _markLegacyReceipt('pill', p.id, serverId, p);
          } else {
            AppLogger.warning(
              'SyncService',
              'Pill ${p.id}: POST succeeded but response lacked data.id',
            );
          }
        } else if (!p.isDeleted && p.serverId != null) {
          await _dio.patch<void>(
            '/profiles/${profile.serverId ?? p.profileId}/pills/${p.serverId}',
            data: {
              'name': p.name,
              'dosage': p.dosage,
              'notes': p.notes,
              'color': p.color,
              'currentStock': p.currentStock,
              'lowStockThreshold': p.lowStockThreshold,
              'isPrn': p.isPrn,
              'updatedAt': p.updatedAt.toUtc().toIso8601String(),
            },
          );
          await _markLegacyReceipt('pill', p.id, p.serverId!, p);
        } else {
          await _markLegacyReceipt('pill', p.id, p.id, p);
        }
      } on DioException catch (e) {
        if (e.response?.statusCode == 429) {
          AppLogger.warning('SyncService', 'Pill flush rate-limited, stopping');
          break;
        } else if (e.response?.statusCode == 409 && p.serverId != null) {
          await _markLegacyReceipt('pill', p.id, p.serverId!, p);
        } else if (e.response?.statusCode == 404 && p.isDeleted) {
          await _markLegacyReceipt('pill', p.id, p.serverId ?? p.id, p);
        } else {
          _logDioFailure('stable', '/profiles/example/pills', e);
        }
      }
    }
  }

  // ── Schedules ──────────────────────────────────────────────────────────────

  Future<void> _flushSchedules({
    required String userId,
    Set<String> skipLocalIds = const {},
  }) async {
    final pending = await _db.schedulesDao.getPendingSync();
    for (final s in pending) {
      final pill = await _db.pillsDao.getById(s.pillId);
      final profile = pill == null
          ? null
          : await _db.profilesDao.getById(pill.profileId);
      if (pill == null ||
          profile == null ||
          profile.userId != userId ||
          skipLocalIds.contains(s.id) ||
          (pill.serverId == null && !s.isDeleted)) {
        AppLogger.debug(
          'SyncService',
          'Schedule ${s.id}: parent pill not synced, skipping',
        );
        continue;
      }

      try {
        if (s.isDeleted && s.serverId != null) {
          await _dio.delete<void>(
            '/pills/${pill.serverId ?? s.pillId}/schedules/${s.serverId}',
          );
          await _markLegacyReceipt('schedule', s.id, s.serverId!, s);
        } else if (!s.isDeleted && s.serverId == null) {
          final resp = await _dio.post<Map<String, dynamic>>(
            '/pills/${pill.serverId ?? s.pillId}/schedules',
            data: {
              'hour': s.hour,
              'minute': s.minute,
              'frequency': s.frequency,
              'isActive': s.isActive,
              if (s.frequencyDays != null)
                'frequencyDays': jsonDecode(s.frequencyDays!),
            },
          );
          final serverId = extractServerId(resp.data);
          if (serverId != null) {
            await _markLegacyReceipt('schedule', s.id, serverId, s);
          } else {
            AppLogger.warning(
              'SyncService',
              'Schedule ${s.id}: POST succeeded but response lacked data.id',
            );
          }
        } else if (!s.isDeleted && s.serverId != null) {
          await _dio.patch<void>(
            '/pills/${pill.serverId ?? s.pillId}/schedules/${s.serverId}',
            data: {
              'hour': s.hour,
              'minute': s.minute,
              'frequency': s.frequency,
              'isActive': s.isActive,
              'frequencyDays': s.frequencyDays != null
                  ? jsonDecode(s.frequencyDays!)
                  : null,
              'updatedAt': s.updatedAt.toUtc().toIso8601String(),
            },
          );
          await _markLegacyReceipt('schedule', s.id, s.serverId!, s);
        } else {
          await _markLegacyReceipt('schedule', s.id, s.id, s);
        }
      } on DioException catch (e) {
        if (e.response?.statusCode == 429) {
          AppLogger.warning(
            'SyncService',
            'Schedule flush rate-limited, stopping',
          );
          break;
        } else if (e.response?.statusCode == 409 && s.serverId != null) {
          await _markLegacyReceipt('schedule', s.id, s.serverId!, s);
        } else if (e.response?.statusCode == 404 && s.isDeleted) {
          await _markLegacyReceipt('schedule', s.id, s.serverId ?? s.id, s);
        } else {
          _logDioFailure('stable', '/pills/example/schedules', e);
        }
      }
    }
  }

  Future<bool> _pullLegacyFromServerInner({required String userId}) async {
    bool profilesPulled = false;
    // Tracks (serverUUID, localUUID) for each pulled profile so child pulls
    // can use the correct local parent id.
    final List<({String serverId, String localId})> pulledProfiles = [];

    // ── 1. Profiles ──────────────────────────────────────────────────────────
    try {
      final resp = await _dio.get<Map<String, dynamic>>('/profiles');
      final rawList = resp.data?['profiles'];
      if (rawList is List) {
        await _write(() async {
          for (final raw in rawList) {
            final p = raw as Map<String, dynamic>;
            final serverId = p['id'] as String;

            // Check whether this server entity is already tracked locally
            // under a different (offline-created) UUID.
            final existing = await _db.profilesDao.getByServerId(serverId);
            if (existing != null) {
              await _writeScope?.requireEntity('profile', existing.id);
            }
            final localId = existing?.id ?? serverId;

            // Server tombstone: soft-delete locally and skip child pulls.
            if (p['deletedAt'] != null) {
              if (existing != null && !existing.isDeleted) {
                await _writeEntity(
                  'profile',
                  localId,
                  () => _db.profilesDao.softDelete(localId),
                );
              }
              continue;
            }

            final canUpsert =
                existing == null ||
                (existing.id == serverId && existing.syncStatus == 'synced');
            if (canUpsert) {
              await _upsertProfile(
                ProfilesCompanion(
                  id: Value(serverId),
                  userId: Value(userId),
                  name: Value(p['name'] as String),
                  avatarEmoji: Value((p['avatarEmoji'] as String?) ?? '👤'),
                  isActive: Value((p['isActive'] as bool?) ?? true),
                  createdAt: Value(DateTime.parse(p['createdAt'] as String)),
                  updatedAt: Value(DateTime.parse(p['updatedAt'] as String)),
                  serverId: Value(serverId),
                  syncStatus: const Value('synced'),
                  isDeleted: const Value(false),
                ),
              );
            }

            pulledProfiles.add((serverId: serverId, localId: localId));
          }
        });
        profilesPulled = true;
      }
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) rethrow;
      _logDioFailure('account', '/profiles', e);
      return false;
    } on WorkspaceAccessFailure {
      rethrow;
    } on Object {
      AppLogger.warning('SyncService', 'Pull profiles failed (non-Dio)');
      return false;
    }

    // ── 2. Pills (per profile) ───────────────────────────────────────────────
    final List<({String serverId, String localId})> pulledPills = [];
    for (final profileEntry in pulledProfiles) {
      try {
        final resp = await _dio.get<Map<String, dynamic>>(
          '/profiles/${profileEntry.serverId}/pills',
        );
        final rawList = resp.data?['pills'];
        if (rawList is List) {
          // A count with an unsent stock command is the phone's, not the
          // server's older one.
          final keepStockFor = await unsettledInventoryPillIds(_db, userId);
          await _write(() async {
            for (final raw in rawList) {
              final p = raw as Map<String, dynamic>;
              final serverId = p['id'] as String;

              final existing = await _db.pillsDao.getByServerId(serverId);
              if (existing != null) {
                await _writeScope?.requireEntity('pill', existing.id);
              }
              final localId = existing?.id ?? serverId;

              if (p['deletedAt'] != null) {
                if (existing != null && !existing.isDeleted) {
                  await _writeEntity(
                    'pill',
                    localId,
                    () => _db.pillsDao.softDelete(localId),
                  );
                }
                continue;
              }

              final canUpsert =
                  existing == null ||
                  (existing.id == serverId && existing.syncStatus == 'synced');
              if (canUpsert) {
                await _upsertPill(
                  PillsCompanion(
                    id: Value(serverId),
                    profileId: Value(profileEntry.localId),
                    name: Value(p['name'] as String),
                    dosage: Value(p['dosage'] as String?),
                    notes: Value(p['notes'] as String?),
                    color: Value(p['color'] as String?),
                    currentStock: Value(
                      existing != null && keepStockFor.contains(existing.id)
                          ? existing.currentStock
                          : p['currentStock'] as int?,
                    ),
                    lowStockThreshold: Value(p['lowStockThreshold'] as int?),
                    isPrn: Value((p['isPrn'] as bool?) ?? false),
                    createdAt: Value(DateTime.parse(p['createdAt'] as String)),
                    updatedAt: Value(DateTime.parse(p['updatedAt'] as String)),
                    serverId: Value(serverId),
                    syncStatus: const Value('synced'),
                    isDeleted: const Value(false),
                  ),
                );
              }

              pulledPills.add((serverId: serverId, localId: localId));
            }
          });
        }
      } on DioException catch (e) {
        if (e.response?.statusCode == 401) rethrow;
        _logDioFailure('stable', '/profiles/example/pills', e);
      } on WorkspaceAccessFailure {
        rethrow;
      } catch (_) {
        AppLogger.warning('SyncService', 'Pull pills component failed');
      }
    }

    // ── 3. Schedules (per pill) ──────────────────────────────────────────────
    // serverToLocalScheduleId is used in the dose_logs section below to resolve
    // the server-side scheduleId FK to the correct local id.
    final Map<String, String> serverToLocalScheduleId = {};
    for (final pillEntry in pulledPills) {
      try {
        final resp = await _dio.get<Map<String, dynamic>>(
          '/pills/${pillEntry.serverId}/schedules',
        );
        final rawList = resp.data?['schedules'];
        if (rawList is List) {
          await _write(() async {
            for (final raw in rawList) {
              final s = raw as Map<String, dynamic>;
              final serverId = s['id'] as String;

              final existing = await _db.schedulesDao.getByServerId(serverId);
              if (existing != null) {
                await _writeScope?.requireEntity('schedule', existing.id);
              }
              final localId = existing?.id ?? serverId;
              serverToLocalScheduleId[serverId] = localId;

              if (s['deletedAt'] != null) {
                if (existing != null && !existing.isDeleted) {
                  await _writeEntity(
                    'schedule',
                    localId,
                    () => _db.schedulesDao.softDelete(localId),
                  );
                }
                continue;
              }

              final canUpsert =
                  existing == null ||
                  (existing.id == serverId && existing.syncStatus == 'synced');
              if (canUpsert) {
                final rawFreqDays = s['frequencyDays'];
                final freqDaysStr = rawFreqDays is List
                    ? jsonEncode(rawFreqDays)
                    : null;
                await _upsertSchedule(
                  SchedulesCompanion(
                    id: Value(serverId),
                    pillId: Value(pillEntry.localId),
                    hour: Value(s['hour'] as int),
                    minute: Value(s['minute'] as int),
                    frequency: Value(s['frequency'] as String),
                    frequencyDays: Value(freqDaysStr),
                    isActive: Value((s['isActive'] as bool?) ?? true),
                    createdAt: Value(DateTime.parse(s['createdAt'] as String)),
                    updatedAt: Value(DateTime.parse(s['updatedAt'] as String)),
                    serverId: Value(serverId),
                    syncStatus: const Value('synced'),
                    isDeleted: const Value(false),
                  ),
                );
              }
            }
          });
        }
      } on DioException catch (e) {
        if (e.response?.statusCode == 401) rethrow;
        _logDioFailure('stable', '/pills/example/schedules', e);
      } on WorkspaceAccessFailure {
        rethrow;
      } catch (_) {
        AppLogger.warning('SyncService', 'Pull schedules component failed');
      }
    }

    // ── 4. Dose logs (per profile, delta sync with keyset cursor) ──────
    const logPageSize = 500;
    // Keep this client reset window below server tombstone retention (90 days).
    const watermarkMaxAgeDays = 88;
    for (final profileEntry in pulledProfiles) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final watermarkKey = 'sync_watermark_doseLogs_${profileEntry.serverId}';
        String? watermark = await _readLegacyWatermark(
          userId,
          profileEntry.localId,
          watermarkKey,
          prefs,
        );

        // Stale watermark reset: if >88 days old, trigger full pull
        // (server purges tombstones after 90 days)
        if (watermark != null) {
          final watermarkDate = DateTime.tryParse(watermark);
          if (watermarkDate != null &&
              DateTime.now().difference(watermarkDate).inDays >
                  watermarkMaxAgeDays) {
            watermark = null;
            // A stale cursor is ignored; publication waits for a completed pull.
          }
        }

        String? cursor;
        String? latestServerTime;
        bool hasMore = true;

        while (hasMore) {
          final queryParams = <String, dynamic>{'limit': logPageSize};
          if (watermark != null) {
            queryParams['since'] = watermark;
          }
          if (cursor != null) {
            queryParams['cursor'] = cursor;
          }

          final resp = await _dio.get<Map<String, dynamic>>(
            '/profiles/${profileEntry.serverId}/logs',
            queryParameters: queryParams,
          );
          final rawList = resp.data?['logs'];
          final serverTime = resp.data?['serverTime'] as String?;
          if (serverTime != null) latestServerTime = serverTime;

          if (rawList is! List || rawList.isEmpty) break;

          await _write(() async {
            for (final raw in rawList) {
              final l = raw as Map<String, dynamic>;
              final serverId = l['id'] as String;
              final serverScheduleId = l['scheduleId'] as String;
              final deletedAt = l['deletedAt'] as String?;

              final existing = await _db.doseLogsDao.getByServerId(serverId);
              if (existing != null) {
                await _writeScope?.requireEntity('doseLog', existing.id);
              }

              if (deletedAt != null) {
                // Tombstone: soft-delete the local row if it exists and is synced
                if (existing == null) continue;
                if (existing.syncStatus != 'synced') continue;
                if (existing.isDeleted) continue;
                await _upsertDoseLog(
                  DoseLogsCompanion(
                    id: Value(existing.id),
                    scheduleId: Value(existing.scheduleId),
                    scheduledAt: Value(existing.scheduledAt),
                    takenAt: Value(existing.takenAt),
                    status: Value(existing.status),
                    note: Value(existing.note),
                    createdAt: Value(existing.createdAt),
                    updatedAt: Value(DateTime.parse(l['updatedAt'] as String)),
                    serverId: Value(serverId),
                    syncStatus: const Value('synced'),
                    isDeleted: const Value(true),
                  ),
                );
                continue;
              }

              // Live row: insert or update
              if (existing != null && existing.id != serverId) continue;
              if (existing != null && existing.syncStatus != 'synced') continue;
              if (existing != null && existing.isDeleted) continue;

              final localScheduleId =
                  serverToLocalScheduleId[serverScheduleId] ?? serverScheduleId;
              final serverUpdatedAt = l['updatedAt'] as String?;
              await _upsertDoseLog(
                DoseLogsCompanion(
                  id: Value(serverId),
                  scheduleId: Value(localScheduleId),
                  scheduledAt: Value(
                    DateTime.parse(l['scheduledAt'] as String),
                  ),
                  takenAt: Value(
                    l['takenAt'] != null
                        ? DateTime.parse(l['takenAt'] as String)
                        : null,
                  ),
                  status: Value(l['status'] as String),
                  note: Value(l['note'] as String?),
                  createdAt: Value(DateTime.parse(l['createdAt'] as String)),
                  updatedAt: Value(
                    serverUpdatedAt != null
                        ? DateTime.parse(serverUpdatedAt)
                        : DateTime.parse(l['createdAt'] as String),
                  ),
                  serverId: Value(serverId),
                  syncStatus: const Value('synced'),
                  isDeleted: const Value(false),
                ),
              );
            }
          });

          final nextCursor = resp.data?['nextCursor'] as String?;
          hasMore = nextCursor != null;
          cursor = nextCursor;
        }

        // Advance watermark only after all pages succeeded
        if (latestServerTime != null) {
          final serverDt = DateTime.parse(latestServerTime);
          final laggedWatermark = serverDt.subtract(const Duration(seconds: 2));
          await _recordLegacyWatermark(
            userId,
            profileEntry.localId,
            watermarkKey,
            laggedWatermark.toUtc().toIso8601String(),
            prefs,
          );
        }
      } on DioException catch (e) {
        if (e.response?.statusCode == 401) rethrow;
        _logDioFailure('medication', '/profiles/example/logs', e);
      } on WorkspaceAccessFailure {
        rethrow;
      } catch (_) {
        AppLogger.warning('SyncService', 'Pull logs component failed');
      }
    }

    // ── 5. Persist last-sync timestamp ──────────────────────────────────────
    if (profilesPulled) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await _recordLastSync(userId, prefs);
      } on WorkspaceAccessFailure {
        rethrow;
      } catch (_) {
        // Non-fatal; sync still succeeded.
      }
    }

    return profilesPulled;
  }

  // ── Dose Logs ─────────────────────────────────────────────────────────────

  Future<void> _flushDoseLogs({required String userId}) async {
    final pending = await _db.doseLogsDao.getPendingSync();
    for (final log in pending) {
      if (await _db.pendingOperationsDao.hasEffectForLegacySource(log.id)) {
        continue;
      }
      final schedule = await _db.schedulesDao.getById(log.scheduleId);
      final pill = schedule == null
          ? null
          : await _db.pillsDao.getById(schedule.pillId);
      final profile = pill == null
          ? null
          : await _db.profilesDao.getById(pill.profileId);
      if (schedule == null ||
          profile == null ||
          profile.userId != userId ||
          (schedule.serverId == null && !log.isDeleted)) {
        AppLogger.debug(
          'SyncService',
          'DoseLog ${log.id}: parent schedule not synced, skipping',
        );
        continue;
      }

      try {
        if (log.isDeleted && log.serverId != null) {
          try {
            await _dio.delete<void>('/logs/${log.serverId}');
          } on DioException catch (e) {
            if (e.response?.statusCode != 404) rethrow;
          }
          await _markLegacyReceipt('doseLog', log.id, log.serverId!, log);
        } else if (!log.isDeleted && log.serverId == null) {
          final resp = await _dio.post<Map<String, dynamic>>(
            '/logs/${schedule.serverId ?? log.scheduleId}',
            data: {
              'scheduledAt': log.scheduledAt.toUtc().toIso8601String(),
              'status': log.status,
              if (log.takenAt != null)
                'takenAt': log.takenAt!.toUtc().toIso8601String(),
              if (log.note != null) 'note': log.note,
            },
          );
          final serverId = extractServerId(resp.data);
          if (serverId != null) {
            await _markLegacyReceipt('doseLog', log.id, serverId, log);
          } else {
            AppLogger.warning(
              'SyncService',
              'DoseLog ${log.id}: POST succeeded but response lacked data.id',
            );
          }
        } else if (!log.isDeleted && log.serverId != null) {
          await _dio.patch<void>(
            '/logs/${log.serverId}',
            data: {
              'status': log.status,
              if (log.takenAt != null)
                'takenAt': log.takenAt!.toUtc().toIso8601String(),
              'note': log.note,
              'updatedAt': log.updatedAt.toUtc().toIso8601String(),
            },
          );
          await _markLegacyReceipt('doseLog', log.id, log.serverId!, log);
        } else {
          await _markLegacyReceipt('doseLog', log.id, log.id, log);
        }
      } on DioException catch (e) {
        if (e.response?.statusCode == 429) {
          AppLogger.warning(
            'SyncService',
            'DoseLog flush rate-limited, stopping',
          );
          break;
        } else if (e.response?.statusCode == 409) {
          await _resolveDoseLogConflict(log, e);
        } else {
          _logDioFailure('medication', '/logs/example', e);
        }
      }
    }
  }

  /// Local-wins conflict resolution: the server rejected our POST because a
  /// row already exists for this (schedule, scheduledAt). PATCH our status
  /// onto that row so the user's most recent explicit action sticks.
  ///
  /// Falls back to the legacy 'conflict' marker when the server is too old
  /// to include `existingId` in the 409 body. On PATCH failure the log stays
  /// pending and retries next flush.
  Future<void> _resolveDoseLogConflict(DoseLog log, DioException e) async {
    final body = e.response?.data;
    final raw = body is Map<String, dynamic> ? body['existingId'] : null;
    final existingId = raw is String ? raw : null;

    if (existingId == null) {
      await _writeEntity(
        'doseLog',
        log.id,
        () => _db.doseLogsDao.markConflict(log.id),
      );
      return;
    }

    try {
      await _dio.patch<void>(
        '/logs/$existingId',
        data: {
          'status': log.status,
          if (log.takenAt != null)
            'takenAt': log.takenAt!.toUtc().toIso8601String(),
        },
      );
      // If an earlier failed PATCH let pullFromServer insert the server row
      // as its own local row (id == serverId), remove that ghost before
      // claiming the serverId — getByServerId must stay single-valued.
      await _writeEntity('doseLog', log.id, () async {
        final ghost = await _db.doseLogsDao.getByServerId(existingId);
        if (ghost != null && ghost.id != log.id) {
          await _writeScope?.requireEntity('doseLog', ghost.id);
          await _db.doseLogsDao.deleteById(ghost.id);
        }
        await _db.doseLogsDao.markSynced(log.id, existingId);
      });
    } on DioException catch (e2) {
      _logDioFailure('medication', '/logs/example', e2);
    }
  }

  void _logDioFailure(String component, String route, DioException error) {
    SafeDiagnostics.logHttpEvent(
      SafeDiagnostics.httpEvent(
        event: 'http_failed',
        path: route,
        statusCode: error.response?.statusCode,
        duration: Duration.zero,
        correlationId: SafeDiagnostics.correlationIdFrom(error),
        component: component,
      ),
    );
  }
}
