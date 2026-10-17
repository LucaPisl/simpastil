import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

enum ProtectedStoreFailureCode {
  busy,
  keyMissing,
  keyUnavailable,
  cipherUnavailable,
  unreadableStore,
  unsupportedSchema,
  activeStoreMissing,
  invalidMarker,
  migrationFailed,
  insufficientSpace,
  ioFailure,
}

/// Deliberately excludes native error text, SQL, paths and key material.
class ProtectedStoreFailure implements Exception {
  const ProtectedStoreFailure(this.code);
  final ProtectedStoreFailureCode code;
  @override
  String toString() => 'ProtectedStoreFailure(${code.name})';
}

abstract interface class DeviceDatabaseKeyStore {
  Future<String?> read();
  Future<void> write(String key);
}

enum PreparationPoint {
  inspecting,
  snapshotWritten,
  recoveryEncrypted,
  recoveryVerified,
  candidateMigrated,
  candidateVerified,
  beforePublication,
  pointerReplaced,
  pointerDurable,
  activeReopened,
}

class DatabaseEvidence {
  const DatabaseEvidence(this.schema, this.rows, this.fingerprint);
  final int schema;
  final Map<String, int> rows;
  final String fingerprint;
}

enum LegacyRetirementStatus { notNeeded, pending, retired }

/// Capability for an already verified store; never expose it to presentation.
class PreparedDatabase {
  PreparedDatabase._(
    this.file,
    this._key,
    this.recovery,
    this.evidence, {
    this.legacyRetirement = LegacyRetirementStatus.notNeeded,
  });
  final File file;
  final String _key;
  final File? recovery;
  final DatabaseEvidence evidence;
  final LegacyRetirementStatus legacyRetirement;
  void configure(Database db) => _configureCipher(db, _key);

  /// Established stores are never opened with SQLite's CREATE flag.
  Database openEstablished() {
    if (!file.existsSync()) {
      throw const ProtectedStoreFailure(
        ProtectedStoreFailureCode.activeStoreMissing,
      );
    }
    final db = _openRaw(file.path, _key);
    try {
      if (db.userVersion != evidence.schema || db.userVersion <= 0) {
        throw const ProtectedStoreFailure(
          ProtectedStoreFailureCode.unreadableStore,
        );
      }
      return db;
    } catch (_) {
      db.close();
      rethrow;
    }
  }

  @override
  String toString() => 'PreparedDatabase(protected)';
}

typedef CandidateMigration = Future<void> Function(PreparedDatabase candidate);

/// Startup-only coordination. Live restore must first drain normal writers.
/// An exclusive SQLite transaction coordinates distinct isolates and engines.
class ProtectedStoreCoordinator {
  ProtectedStoreCoordinator({
    required this.root,
    required this.legacy,
    required this.keyStore,
    required this.expectedSchema,
    required this.migrateCandidate,
    required this.syncDirectory,
    this.validateReady,
    this.onPoint,
    this.acquisitionLimit = const Duration(seconds: 3),
    this.preparationWaitLimit = const Duration(minutes: 2),
  });

  final Directory root;
  final File legacy;
  final DeviceDatabaseKeyStore keyStore;
  final int expectedSchema;
  final CandidateMigration migrateCandidate;
  final Future<void> Function(String path) syncDirectory;
  final Future<void> Function(PreparedDatabase database)? validateReady;
  final Future<void> Function(PreparationPoint point)? onPoint;
  final Duration acquisitionLimit;

  /// How long an opener waits while another isolate or engine prepares care.
  /// A first launch after an update can migrate a large store for longer than
  /// [acquisitionLimit]; the gate is only held by a live preparer.
  final Duration preparationWaitLimit;

  Future<PreparedDatabase> prepare() async {
    Database? gate;
    Database? reservation;
    var gateHeld = false;
    var sourceHeld = false;
    try {
      await root.create(recursive: true);
      gate = sqlite3.open('${root.path}/preparation.sqlite');
      _requireCipher(gate);
      await _reserve(gate, 'BEGIN EXCLUSIVE', limit: preparationWaitLimit);
      gateHeld = true;
      final marker = await _readMarker();
      if (marker != null && (marker['targetSchema'] as int) > expectedSchema) {
        throw const ProtectedStoreFailure(
          ProtectedStoreFailureCode.unsupportedSchema,
        );
      }
      final generationsExist = root.listSync().any(
        (entry) =>
            entry is Directory &&
            entry.path.split('/').last.startsWith('generation-'),
      );
      if (marker == null && generationsExist) {
        throw const ProtectedStoreFailure(
          ProtectedStoreFailureCode.invalidMarker,
        );
      }
      final active = marker?['active'] as String?;
      final activeFile = active == null
          ? null
          : _generationFile(active, 'care.db');
      if (activeFile != null && !await activeFile.exists()) {
        throw const ProtectedStoreFailure(
          ProtectedStoreFailureCode.activeStoreMissing,
        );
      }
      final source = activeFile ?? (await legacy.exists() ? legacy : null);
      if (marker != null &&
          active == null &&
          source == null &&
          marker['sourceRequired'] != false) {
        throw const ProtectedStoreFailure(
          ProtectedStoreFailureCode.activeStoreMissing,
        );
      }
      final encryptedSource = activeFile != null;
      final hasProtectedArtifacts = marker != null || generationsExist;
      var key = await _readKey();
      if (key == null) {
        if (hasProtectedArtifacts) {
          throw const ProtectedStoreFailure(
            ProtectedStoreFailureCode.keyMissing,
          );
        }
        key = _randomToken(32);
        try {
          await keyStore.write(key);
          if (await keyStore.read() != key) {
            throw const ProtectedStoreFailure(
              ProtectedStoreFailureCode.keyUnavailable,
            );
          }
        } catch (_) {
          throw const ProtectedStoreFailure(
            ProtectedStoreFailureCode.keyUnavailable,
          );
        }
      }
      if (!RegExp(r'^[A-Za-z0-9_\-=]{43,128}$').hasMatch(key)) {
        throw const ProtectedStoreFailure(
          ProtectedStoreFailureCode.keyUnavailable,
        );
      }

      DatabaseEvidence? original;
      if (source != null) {
        original = await _inspect(source, encryptedSource ? key : null);
        if (encryptedSource && original.schema == expectedSchema) {
          final recovery = marker?['recovery'] as String?;
          final copy = recovery == null
              ? null
              : _generationFile(recovery, 'recovery.db');
          final prepared = PreparedDatabase._(source, key, copy, original);
          try {
            await validateReady?.call(prepared);
          } on ProtectedStoreFailure {
            rethrow;
          } catch (_) {
            throw const ProtectedStoreFailure(
              ProtectedStoreFailureCode.unreadableStore,
            );
          }
          final retirement = await _retireLegacy(marker!, prepared);
          return PreparedDatabase._(
            source,
            key,
            copy,
            original,
            legacyRetirement: retirement,
          );
        }
        reservation = _openRaw(source.path, encryptedSource ? key : null);
        await _reserve(reservation, 'BEGIN IMMEDIATE');
        sourceHeld = true;
        // Reinspect under the writer reservation before establishing the snapshot.
        original = await _inspect(source, encryptedSource ? key : null);
      }

      final generation = 'generation-${_randomToken(16)}';
      final directory = Directory('${root.path}/$generation');
      final recoveryFile = File('${directory.path}/recovery.db');
      final candidateFile = File('${directory.path}/care.db');
      final preparing = <String, Object?>{
        'version': 1,
        'cipher': 'chacha20',
        'active': active,
        'recovery': marker?['recovery'],
        'pending': generation,
        'state': 'inspecting',
        'targetSchema': expectedSchema,
        'sourceRequired': source != null,
        // Only a committed active generation can bind the original recovery.
        // A failed unexposed attempt must not strand retirement on its copy.
        'retirement': active == null ? null : marker?['retirement'],
        'recoveryEvidence': marker?['recoveryEvidence'],
      };
      await _writeMarker(preparing);
      await directory.create();
      final generationFile = File('${directory.path}/generation.json');
      final generationDescription = <String, Object?>{
        'version': 1,
        'purpose': 'startupPreparation',
        'generation': generation,
        'everPublished': false,
      };
      await generationFile.writeAsString(
        jsonEncode(generationDescription),
        flush: true,
      );
      await syncDirectory(directory.path);
      await _point(PreparationPoint.inspecting);

      if (source != null) {
        final sourcePath = source.path;
        final outputPath = recoveryFile.path;
        final sourceKey = encryptedSource ? key : null;
        await Isolate.run(() {
          final raw = _openRaw(sourcePath, sourceKey);
          try {
            raw.execute("VACUUM INTO '${_sqlString(outputPath)}'");
          } finally {
            raw.close();
          }
        });
        await _point(PreparationPoint.snapshotWritten);
        if (!encryptedSource) {
          final path = recoveryFile.path;
          final persistedKey = key;
          await Isolate.run(() {
            final raw = _openRaw(path, null);
            try {
              if (raw
                      .select('PRAGMA journal_mode=DELETE')
                      .single
                      .values
                      .single !=
                  'delete') {
                throw const ProtectedStoreFailure(
                  ProtectedStoreFailureCode.ioFailure,
                );
              }
              raw.execute("PRAGMA cipher='chacha20'");
              raw.execute("PRAGMA rekey='${_sqlString(persistedKey)}'");
            } finally {
              raw.close();
            }
          });
        }
        await _flushFile(recoveryFile);
        await syncDirectory(directory.path);
        await _point(PreparationPoint.recoveryEncrypted);
        final recovered = await _inspect(recoveryFile, key);
        if (recovered.schema != original!.schema ||
            recovered.fingerprint != original.fingerprint) {
          throw const ProtectedStoreFailure(
            ProtectedStoreFailureCode.unreadableStore,
          );
        }
        preparing['state'] = 'recoveryVerified';
        await _writeMarker(preparing);
        await _point(PreparationPoint.recoveryVerified);
        // This is a closed, verified snapshot with no live WAL to omit.
        await recoveryFile.copy(candidateFile.path);
      }

      final candidate = PreparedDatabase._(
        candidateFile,
        key,
        source == null ? null : recoveryFile,
        original ?? const DatabaseEvidence(0, {}, ''),
      );
      try {
        await migrateCandidate(candidate);
      } on ProtectedStoreFailure {
        rethrow;
      } catch (error) {
        if (_isFull(error)) {
          throw const ProtectedStoreFailure(
            ProtectedStoreFailureCode.insufficientSpace,
          );
        }
        throw const ProtectedStoreFailure(
          ProtectedStoreFailureCode.migrationFailed,
        );
      }
      await _point(PreparationPoint.candidateMigrated);
      // Candidate stays at its final path; retain/checkpoint its WAL normally.
      final candidatePath = candidateFile.path;
      final persistedKey = key;
      await Isolate.run(() {
        final raw = _openRaw(candidatePath, persistedKey);
        try {
          final checkpoint = raw
              .select('PRAGMA wal_checkpoint(TRUNCATE)')
              .single;
          if (checkpoint.values.first != 0) {
            throw const ProtectedStoreFailure(ProtectedStoreFailureCode.busy);
          }
        } finally {
          raw.close();
        }
      });
      final migrated = await _inspect(candidateFile, key);
      if (migrated.schema != expectedSchema) {
        throw const ProtectedStoreFailure(
          ProtectedStoreFailureCode.migrationFailed,
        );
      }
      await _flushFile(candidateFile);
      await syncDirectory(directory.path);
      preparing['state'] = 'candidateVerified';
      await _writeMarker(preparing);
      await _point(PreparationPoint.candidateVerified);
      await _point(PreparationPoint.beforePublication);
      // A failure here conservatively retains this generation forever. Cleanup
      // must never infer that a once-published store had no normal writers.
      generationDescription['everPublished'] = true;
      await generationFile.writeAsString(
        jsonEncode(generationDescription),
        flush: true,
      );
      await syncDirectory(directory.path);
      final ready = <String, Object?>{
        'version': 1,
        'cipher': 'chacha20',
        'active': generation,
        'recovery': source == null ? null : generation,
        'pending': null,
        'state': 'ready',
        'targetSchema': expectedSchema,
        'retirement':
            preparing['retirement'] ??
            (source != null && !encryptedSource
                ? <String, Object?>{
                    'generation': generation,
                    'schema': original!.schema,
                    'fingerprint': original.fingerprint,
                    'state': 'pending',
                  }
                : null),
        'recoveryEvidence': original == null
            ? null
            : <String, Object?>{
                'schema': original.schema,
                'fingerprint': original.fingerprint,
                'rows': original.rows,
                'savedAtMs': DateTime.now().toUtc().millisecondsSinceEpoch,
              },
      };
      await _writeMarker(ready, publishing: true);
      await _point(PreparationPoint.pointerDurable);
      final reopened = await _inspect(candidateFile, key);
      if (reopened.fingerprint != migrated.fingerprint) {
        throw const ProtectedStoreFailure(
          ProtectedStoreFailureCode.unreadableStore,
        );
      }
      await _point(PreparationPoint.activeReopened);
      if (sourceHeld) {
        reservation!.execute('ROLLBACK');
        sourceHeld = false;
      }
      reservation?.close();
      reservation = null;
      final prepared = PreparedDatabase._(
        candidateFile,
        key,
        candidate.recovery,
        reopened,
      );
      final retirement = await _retireLegacy(ready, prepared);
      return PreparedDatabase._(
        candidateFile,
        key,
        candidate.recovery,
        reopened,
        legacyRetirement: retirement,
      );
    } on ProtectedStoreFailure {
      rethrow;
    } on SqliteException catch (error) {
      throw ProtectedStoreFailure(
        _isFull(error)
            ? ProtectedStoreFailureCode.insufficientSpace
            : ProtectedStoreFailureCode.unreadableStore,
      );
    } on FileSystemException catch (error) {
      throw ProtectedStoreFailure(
        _isFull(error)
            ? ProtectedStoreFailureCode.insufficientSpace
            : ProtectedStoreFailureCode.ioFailure,
      );
    } finally {
      try {
        try {
          if (sourceHeld) reservation!.execute('ROLLBACK');
        } finally {
          reservation?.close();
        }
      } finally {
        try {
          if (gateHeld) gate!.execute('ROLLBACK');
        } finally {
          gate?.close();
        }
      }
    }
  }

  Future<String?> _readKey() async {
    try {
      return await keyStore.read();
    } catch (_) {
      throw const ProtectedStoreFailure(
        ProtectedStoreFailureCode.keyUnavailable,
      );
    }
  }

  /// Best-effort retirement never prevents access to verified active care.
  /// A pending status explicitly means some local bytes remain unprotected.
  Future<LegacyRetirementStatus> _retireLegacy(
    Map<String, dynamic> marker,
    PreparedDatabase prepared,
  ) async {
    final description = marker['retirement'];
    if (description == null) return LegacyRetirementStatus.notNeeded;
    final retirement = Map<String, dynamic>.from(description as Map);
    Database? source;
    var held = false;
    try {
      final recovery = _generationFile(
        retirement['generation'] as String,
        'recovery.db',
      );
      final protectedOriginal = await _inspect(recovery, prepared._key);
      if (protectedOriginal.schema != retirement['schema'] ||
          protectedOriginal.fingerprint != retirement['fingerprint']) {
        return LegacyRetirementStatus.pending;
      }
      final active = await _inspect(prepared.file, prepared._key);
      if (active.fingerprint != prepared.evidence.fingerprint) {
        return LegacyRetirementStatus.pending;
      }
      if (!await legacy.exists()) {
        if (!const {'deleting', 'retired'}.contains(retirement['state']) ||
            await _legacyHasSidecars()) {
          return LegacyRetirementStatus.pending;
        }
        if (retirement['state'] != 'retired') {
          await syncDirectory(legacy.parent.path);
        }
      } else {
        source = _openRaw(legacy.path, null);
        await _reserve(source, 'BEGIN IMMEDIATE');
        held = true;
        final original = await _inspect(legacy, null);
        if (original.fingerprint != retirement['fingerprint'] ||
            original.schema != retirement['schema']) {
          return LegacyRetirementStatus.pending;
        }
        source.execute('ROLLBACK');
        held = false;
        source.close();
        source = null;
        // All default app openings still wait at the preparation gate.
        // Let SQLite settle its own journal; never discard a live WAL.
        final settle = _openRaw(legacy.path, null);
        try {
          if (settle
                      .select('PRAGMA wal_checkpoint(TRUNCATE)')
                      .single
                      .values
                      .first !=
                  0 ||
              settle
                      .select('PRAGMA journal_mode=DELETE')
                      .single
                      .values
                      .single !=
                  'delete') {
            return LegacyRetirementStatus.pending;
          }
        } finally {
          settle.close();
        }
        final settled = await _inspect(legacy, null);
        if (settled.fingerprint != retirement['fingerprint'] ||
            await _legacyHasSidecars()) {
          return LegacyRetirementStatus.pending;
        }
        retirement['state'] = 'deleting';
        marker['retirement'] = retirement;
        await _writeMarker(marker);
        await legacy.delete();
        await syncDirectory(legacy.parent.path);
      }
      retirement['state'] = 'retired';
      marker['retirement'] = retirement;
      await _writeMarker(marker);
      return LegacyRetirementStatus.retired;
    } catch (_) {
      // Do not include file names or native error strings in diagnostics.
      return LegacyRetirementStatus.pending;
    } finally {
      try {
        if (held) source!.execute('ROLLBACK');
      } finally {
        source?.close();
      }
    }
  }

  Future<bool> _legacyHasSidecars() async {
    for (final suffix in ['-wal', '-shm', '-journal']) {
      if (await File('${legacy.path}$suffix').exists()) return true;
    }
    return false;
  }

  Future<void> _reserve(Database db, String command, {Duration? limit}) async {
    db.execute('PRAGMA busy_timeout=0');
    final elapsed = Stopwatch()..start();
    while (true) {
      try {
        db.execute(command);
        return;
      } on SqliteException catch (error) {
        if (!const {5, 6}.contains(error.resultCode)) rethrow;
        if (elapsed.elapsed >= (limit ?? acquisitionLimit)) {
          throw const ProtectedStoreFailure(ProtectedStoreFailureCode.busy);
        }
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    }
  }

  File _generationFile(String generation, String name) =>
      protectedStoreFile(root, generation, name);

  Future<Map<String, dynamic>?> _readMarker() =>
      readProtectedStoreManifest(root, expectedSchema);

  Future<void> _writeMarker(
    Map<String, Object?> value, {
    bool publishing = false,
  }) async {
    final temporary = File('${root.path}/store.next');
    await temporary.writeAsString(jsonEncode(value), flush: true);
    await temporary.rename('${root.path}/store.json');
    if (publishing) await _point(PreparationPoint.pointerReplaced);
    await syncDirectory(root.path);
  }

  Future<DatabaseEvidence> _inspect(File file, String? key) async {
    final path = file.path;
    final maximum = expectedSchema;
    return Isolate.run(() => _inspectSync(path, key, maximum));
  }

  Future<void> _point(PreparationPoint point) async => onPoint?.call(point);
}

String _randomToken(int bytes) {
  final random = Random.secure();
  return base64Url.encode(List.generate(bytes, (_) => random.nextInt(256)));
}

String _sqlString(String value) => value.replaceAll("'", "''");
String _identifier(String value) => '"${value.replaceAll('"', '""')}"';

void _requireCipher(Database db) {
  if (db.select('PRAGMA cipher').isEmpty) {
    throw const ProtectedStoreFailure(
      ProtectedStoreFailureCode.cipherUnavailable,
    );
  }
}

void _configureCipher(Database db, String key) {
  try {
    _requireCipher(db);
    db.execute("PRAGMA cipher='chacha20'");
    db.execute("PRAGMA key='${_sqlString(key)}'");
    db.select('SELECT count(*) FROM sqlite_master');
  } on ProtectedStoreFailure {
    rethrow;
  } catch (_) {
    throw const ProtectedStoreFailure(
      ProtectedStoreFailureCode.unreadableStore,
    );
  }
}

Database _openRaw(String path, String? key) {
  final db = sqlite3.open(path, mode: OpenMode.readWrite);
  try {
    _requireCipher(db);
    if (key != null) _configureCipher(db, key);
    return db;
  } catch (_) {
    db.close();
    rethrow;
  }
}

DatabaseEvidence _inspectSync(String path, String? key, int maximum) {
  if (!File(path).existsSync() || File(path).lengthSync() == 0) {
    throw const ProtectedStoreFailure(
      ProtectedStoreFailureCode.unreadableStore,
    );
  }
  final db = _openRaw(path, key);
  var held = false;
  try {
    db.execute('BEGIN');
    held = true;
    final version = db.userVersion;
    if (version > maximum) {
      throw const ProtectedStoreFailure(
        ProtectedStoreFailureCode.unsupportedSchema,
      );
    }
    if (version <= 0 ||
        db.select('PRAGMA integrity_check').single.values.single != 'ok') {
      throw const ProtectedStoreFailure(
        ProtectedStoreFailureCode.unreadableStore,
      );
    }
    final sink = _DigestSink();
    final hash = sha256.startChunkedConversion(sink);
    final rows = <String, int>{};
    final tables = db.select(
      "SELECT name, sql FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
    );
    for (final table in tables) {
      final name = table['name'] as String;
      hash.add(utf8.encode(jsonEncode([name, table['sql']])));
      final columns = db
          .select('PRAGMA table_info(${_identifier(name)})')
          .map((row) => row['name'] as String)
          .toList();
      final statement = db.prepare(
        'SELECT * FROM ${_identifier(name)} ORDER BY ${columns.map(_identifier).join(',')}',
      );
      var count = 0;
      try {
        final cursor = statement.selectCursor();
        while (cursor.moveNext()) {
          hash.add(
            utf8.encode(
              jsonEncode(
                columns.map((column) {
                  final value = cursor.current[column];
                  return value is List<int>
                      ? {'blob': base64.encode(value)}
                      : value;
                }).toList(),
              ),
            ),
          );
          count++;
        }
      } finally {
        statement.close();
      }
      rows[name] = count;
    }
    hash.close();
    return DatabaseEvidence(version, rows, sink.value!.toString());
  } finally {
    try {
      if (held) db.execute('ROLLBACK');
    } finally {
      db.close();
    }
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

Future<void> _flushFile(File file) async {
  final handle = await file.open(mode: FileMode.append);
  try {
    await handle.flush();
  } finally {
    await handle.close();
  }
}

bool _isFull(Object error) =>
    (error is SqliteException && error.resultCode == 13) ||
    (error is FileSystemException &&
        const {28, 112}.contains(error.osError?.errorCode));

Future<Map<String, dynamic>?> readProtectedStoreManifest(
  Directory root,
  int maximumSchema,
) async {
  final file = File('${root.path}/store.json');
  if (!await file.exists()) return null;
  try {
    if (await file.length() > 4096) throw const FormatException();
    final value = jsonDecode(await file.readAsString());
    if (value is! Map<String, dynamic> ||
        value['version'] != 1 ||
        value['cipher'] != 'chacha20' ||
        !const {
          'inspecting',
          'recoveryVerified',
          'candidateVerified',
          'ready',
        }.contains(value['state']) ||
        value['targetSchema'] is! int ||
        (value['targetSchema'] as int) <= 0 ||
        (value['active'] != null && value['active'] is! String) ||
        (value['recovery'] != null && value['recovery'] is! String) ||
        (value['pending'] != null && value['pending'] is! String) ||
        (value['state'] == 'ready' && value['active'] == null)) {
      throw const FormatException();
    }
    if ((value['sourceRequired'] != null && value['sourceRequired'] is! bool) ||
        (value['state'] == 'ready' && value['pending'] != null)) {
      throw const FormatException();
    }
    for (final field in ['active', 'recovery', 'pending']) {
      final generation = value[field] as String?;
      if (generation != null) protectedStoreFile(root, generation, 'care.db');
    }
    final retirement = value['retirement'];
    if (retirement != null) {
      if (retirement is! Map<String, dynamic> ||
          !const {
            'pending',
            'deleting',
            'retired',
          }.contains(retirement['state']) ||
          retirement['schema'] is! int ||
          (retirement['schema'] as int) <= 0 ||
          retirement['fingerprint'] is! String ||
          !RegExp(
            r'^[a-f0-9]{64}$',
          ).hasMatch(retirement['fingerprint'] as String) ||
          retirement['generation'] is! String) {
        throw const FormatException();
      }
      protectedStoreFile(
        root,
        retirement['generation'] as String,
        'recovery.db',
      );
    }
    final recovery = value['recoveryEvidence'];
    if (value['recovery'] == null) {
      if (recovery != null) throw const FormatException();
    } else if (recovery is! Map<String, dynamic> ||
        recovery['schema'] is! int ||
        (recovery['schema'] as int) <= 0 ||
        (recovery['schema'] as int) > maximumSchema ||
        recovery['fingerprint'] is! String ||
        !RegExp(
          r'^[a-f0-9]{64}$',
        ).hasMatch(recovery['fingerprint'] as String) ||
        recovery['rows'] is! Map ||
        !(recovery['rows'] as Map).values.every(
          (count) => count is int && count >= 0,
        ) ||
        recovery['savedAtMs'] is! int ||
        (recovery['savedAtMs'] as int) < 0 ||
        (recovery['savedAtMs'] as int) > 8640000000000000) {
      throw const FormatException();
    }
    if ((value['targetSchema'] as int) > maximumSchema) {
      throw const ProtectedStoreFailure(
        ProtectedStoreFailureCode.unsupportedSchema,
      );
    }
    return value;
  } on ProtectedStoreFailure {
    rethrow;
  } catch (_) {
    throw const ProtectedStoreFailure(ProtectedStoreFailureCode.invalidMarker);
  }
}

File protectedStoreFile(Directory root, String generation, String name) {
  if (!RegExp(r'^generation-[A-Za-z0-9_\-=]{22,24}$').hasMatch(generation) ||
      !const {
        'care.db',
        'recovery.db',
        'preferences.db',
        'generation.json',
      }.contains(name)) {
    throw const ProtectedStoreFailure(ProtectedStoreFailureCode.invalidMarker);
  }
  return File('${root.path}/$generation/$name');
}

class ProtectedReplacementRecovery {
  const ProtectedReplacementRecovery(
    this.generation,
    this.evidence,
    this.preferencesDigest,
  );
  final String generation;
  final DatabaseEvidence evidence;
  final String preferencesDigest;
}

/// The caller holds the protected-store gate and one continuous care writer
/// reservation. No activation or care write occurs in this copy primitive.
Future<ProtectedReplacementRecovery> createProtectedReplacementRecovery({
  required Directory root,
  required DeviceDatabaseKeyStore keyStore,
  required int maximumSchema,
  required String expectedManifestRevision,
  required Map<String, Object?> preferences,
  required Future<void> Function(String) syncDirectory,
  Future<void> Function(PreparationPoint)? onPoint,
}) async {
  try {
    final savedPreferences = _recoveryPreferences(preferences);
    final manifest = await readProtectedStoreManifest(root, maximumSchema);
    if (manifest == null ||
        manifest['state'] != 'ready' ||
        sha256.convert(utf8.encode(jsonEncode(manifest))).toString() !=
            expectedManifestRevision) {
      throw const ProtectedStoreFailure(
        ProtectedStoreFailureCode.invalidMarker,
      );
    }
    final key = await _recoveryKey(keyStore);
    final source = protectedStoreFile(
      root,
      manifest['active'] as String,
      'care.db',
    );
    await _requirePrivateFile(root, source);
    final sourcePath = source.path;
    final original = await Isolate.run(
      () => _inspectSync(sourcePath, key, maximumSchema),
    );
    final generation = 'generation-${_randomToken(16)}';
    final directory = Directory('${root.path}/$generation');
    await directory.create();
    await syncDirectory(root.path);
    // A failed copy may be useful for manual recovery; ordinary cleanup never
    // removes a replacement recovery, even before marker publication.
    await protectedStoreFile(root, generation, 'generation.json').writeAsString(
      jsonEncode({
        'version': 1,
        'generation': generation,
        'purpose': 'fullRestoreRecovery',
        'everPublished': true,
        'createdAtMs': DateTime.now().toUtc().millisecondsSinceEpoch,
      }),
      flush: true,
    );
    final recovery = protectedStoreFile(root, generation, 'recovery.db');
    final outputPath = recovery.path;
    await Isolate.run(() {
      final reader = _openRaw(sourcePath, key);
      try {
        reader.execute("VACUUM INTO '${_sqlString(outputPath)}'");
      } finally {
        reader.close();
      }
    });
    final preferenceFile = protectedStoreFile(
      root,
      generation,
      'preferences.db',
    );
    final preferencePath = preferenceFile.path;
    await Isolate.run(() {
      final db = sqlite3.open(preferencePath);
      try {
        _configureCipher(db, key);
        db.execute(
          'CREATE TABLE preferences (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
        );
        db.execute('BEGIN');
        final insert = db.prepare('INSERT INTO preferences VALUES (?,?)');
        try {
          for (final entry in savedPreferences.entries) {
            insert.execute([entry.key, jsonEncode(entry.value)]);
          }
        } finally {
          insert.close();
        }
        db.userVersion = 1;
        db.execute('COMMIT');
      } finally {
        db.close();
      }
    });
    await _flushFile(recovery);
    await _flushFile(preferenceFile);
    await syncDirectory(directory.path);
    await onPoint?.call(PreparationPoint.recoveryEncrypted);
    final copied = await Isolate.run(
      () => _inspectSync(outputPath, key, maximumSchema),
    );
    if (copied.schema != original.schema ||
        copied.fingerprint != original.fingerprint) {
      throw const ProtectedStoreFailure(
        ProtectedStoreFailureCode.unreadableStore,
      );
    }
    final preferencesDigest = _preferencesDigest(savedPreferences);
    final reopened = await readProtectedRecoveryPreferences(
      root: root,
      keyStore: keyStore,
      generation: generation,
      expectedDigest: preferencesDigest,
    );
    if (_preferencesDigest(reopened) != preferencesDigest) {
      throw const ProtectedStoreFailure(
        ProtectedStoreFailureCode.unreadableStore,
      );
    }
    await onPoint?.call(PreparationPoint.recoveryVerified);
    final next = {
      ...manifest,
      'recovery': generation,
      'recoveryEvidence': {
        'schema': copied.schema,
        'rows': copied.rows,
        'fingerprint': copied.fingerprint,
        'preferencesDigest': preferencesDigest,
        'savedAtMs': DateTime.now().toUtc().millisecondsSinceEpoch,
      },
    };
    final temporary = File('${root.path}/store.next');
    await temporary.writeAsString(jsonEncode(next), flush: true);
    await temporary.rename('${root.path}/store.json');
    await syncDirectory(root.path);
    return ProtectedReplacementRecovery(generation, copied, preferencesDigest);
  } on ProtectedStoreFailure {
    rethrow;
  } catch (error) {
    throw ProtectedStoreFailure(
      _isFull(error)
          ? ProtectedStoreFailureCode.insufficientSpace
          : ProtectedStoreFailureCode.ioFailure,
    );
  }
}

Future<Map<String, Object?>> readProtectedRecoveryPreferences({
  required Directory root,
  required DeviceDatabaseKeyStore keyStore,
  required String generation,
  required String expectedDigest,
}) async {
  try {
    final file = protectedStoreFile(root, generation, 'preferences.db');
    await _requirePrivateFile(root, file);
    final key = await _recoveryKey(keyStore), path = file.path;
    final result = await Isolate.run(() {
      _inspectSync(path, key, 1);
      final db = _openRaw(path, key);
      try {
        final rows = db.select(
          'SELECT key,value FROM preferences ORDER BY key',
        );
        if (rows.length > 10000) throw const FormatException();
        return _recoveryPreferences({
          for (final row in rows)
            row['key']
                as String: (row['value'] as String).length <= 4 * 1024 * 1024
                ? jsonDecode(row['value'] as String)
                : throw const FormatException(),
        });
      } finally {
        db.close();
      }
    });
    if (_preferencesDigest(result) != expectedDigest) {
      throw const FormatException();
    }
    return Map.unmodifiable(result);
  } on ProtectedStoreFailure {
    rethrow;
  } catch (_) {
    throw const ProtectedStoreFailure(
      ProtectedStoreFailureCode.unreadableStore,
    );
  }
}

Future<String> _recoveryKey(DeviceDatabaseKeyStore store) async {
  String? key;
  try {
    key = await store.read();
  } catch (_) {
    throw const ProtectedStoreFailure(ProtectedStoreFailureCode.keyUnavailable);
  }
  if (key == null) {
    throw const ProtectedStoreFailure(ProtectedStoreFailureCode.keyMissing);
  }
  if (!RegExp(r'^[A-Za-z0-9_\-=]{43,128}$').hasMatch(key)) {
    throw const ProtectedStoreFailure(ProtectedStoreFailureCode.keyUnavailable);
  }
  return key;
}

Future<void> _requirePrivateFile(Directory root, File file) async {
  if (await file.resolveSymbolicLinks() !=
      '${await root.resolveSymbolicLinks()}/${file.parent.path.split('/').last}/${file.uri.pathSegments.last}') {
    throw const ProtectedStoreFailure(
      ProtectedStoreFailureCode.unreadableStore,
    );
  }
}

Map<String, Object?> _recoveryPreferences(Map<String, Object?> input) {
  if (input.length > 10000 ||
      input.keys.any((k) => k.length > 256) ||
      input.values.any(
        (v) =>
            !(v == null ||
                v is bool ||
                v is int ||
                (v is double && v.isFinite) ||
                (v is String && v.length <= 4 * 1024 * 1024) ||
                (v is List &&
                    v.length <= 10000 &&
                    v.every(
                      (item) =>
                          item is String && item.length <= 4 * 1024 * 1024,
                    ))),
      )) {
    throw const FormatException();
  }
  final names = input.keys.toList()..sort();
  return {
    for (final name in names)
      name: input[name] is List
          ? List<String>.unmodifiable((input[name] as List).cast<String>())
          : input[name],
  };
}

String _preferencesDigest(Map<String, Object?> value) => sha256
    .convert(utf8.encode(jsonEncode(_recoveryPreferences(value))))
    .toString();

Future<DatabaseEvidence> verifyProtectedDatabase(
  File file,
  DeviceDatabaseKeyStore keyStore,
  int maximumSchema,
) async {
  String? key;
  try {
    key = await keyStore.read();
  } catch (_) {
    throw const ProtectedStoreFailure(ProtectedStoreFailureCode.keyUnavailable);
  }
  if (key == null) {
    throw const ProtectedStoreFailure(ProtectedStoreFailureCode.keyMissing);
  }
  if (!RegExp(r'^[A-Za-z0-9_\-=]{43,128}$').hasMatch(key)) {
    throw const ProtectedStoreFailure(ProtectedStoreFailureCode.keyUnavailable);
  }
  final path = file.path;
  try {
    return await Isolate.run(() => _inspectSync(path, key, maximumSchema));
  } on ProtectedStoreFailure {
    rethrow;
  } catch (_) {
    throw const ProtectedStoreFailure(
      ProtectedStoreFailureCode.unreadableStore,
    );
  }
}
