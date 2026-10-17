import 'dart:convert';

import 'backup_inventory.dart';

enum BackupScope { full, availableCare }

enum BackupFailureCode {
  passwordRequired,
  passwordOrIntegrity,
  integrity,
  unsupportedVersion,
  unsupportedSchema,
  invalidContainer,
  invalidDocument,
  tooLarge,
  fullBackupUnavailable,
  ownershipUnproven,
  staleAccess,
  sourceChanged,
  saveFailed,
}

class BackupFailure implements Exception {
  const BackupFailure(this.code);
  final BackupFailureCode code;
  @override
  String toString() => 'BackupFailure(${code.name})';
}

const maximumBackupBytes = 64 * 1024 * 1024;
const maximumBackupRows = 200000;
const maximumBackupStringBytes = 4 * 1024 * 1024;
const maximumBackupDepth = 32;

/// Check structural depth before JSON decoding allocates a nested object tree.
/// Quoted braces and escaped quotes cannot increase the structural depth.
void checkBackupJsonDepth(String text, {bool requireBalanced = true}) {
  var depth = 0, quoted = false, escaped = false;
  for (final character in text.codeUnits) {
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (character == 92) {
        escaped = true;
      } else if (character == 34) {
        quoted = false;
      }
    } else if (character == 34) {
      quoted = true;
    } else if (character == 123 || character == 91) {
      if (++depth > maximumBackupDepth) {
        throw const BackupFailure(BackupFailureCode.invalidDocument);
      }
    } else if (character == 125 || character == 93) {
      if (--depth < 0) {
        if (requireBalanced) {
          throw const BackupFailure(BackupFailureCode.invalidDocument);
        }
        depth = 0;
      }
    }
  }
  if (requireBalanced && (depth != 0 || quoted)) {
    throw const BackupFailure(BackupFailureCode.invalidDocument);
  }
}

/// Portable factual values only. No live account or device access capability.
class BackupDocument {
  BackupDocument({
    required String id,
    required DateTime capturedAt,
    required int sourceSchema,
    required BackupScope scope,
    required Map<String, List<Map<String, Object?>>> tables,
    required Map<String, Object?> preferences,
  }) : this._validated({
         'documentVersion': 1,
         'id': id,
         'capturedAt': capturedAt.toUtc().toIso8601String(),
         'sourceSchema': sourceSchema,
         'scope': scope.name,
         'tables': tables,
         'preferences': preferences,
       });

  BackupDocument._validated(Map<String, Object?> json) {
    if (json['documentVersion'] != 1) {
      throw const BackupFailure(BackupFailureCode.unsupportedVersion);
    }
    final schema = json['sourceSchema'];
    if (schema is! int ||
        !const {10, 11, 12, 13, 14, 15, 16, 17, 18}.contains(schema)) {
      throw const BackupFailure(BackupFailureCode.unsupportedSchema);
    }
    if (json.length != 7 ||
        !json.keys.toSet().containsAll(const {
          'documentVersion',
          'id',
          'capturedAt',
          'sourceSchema',
          'scope',
          'tables',
          'preferences',
        })) {
      throw const BackupFailure(BackupFailureCode.invalidDocument);
    }
    final identity = json['id'], time = json['capturedAt'];
    if (identity is! String ||
        identity.isEmpty ||
        identity.length > 128 ||
        time is! String ||
        time.length > 40) {
      throw const BackupFailure(BackupFailureCode.invalidDocument);
    }
    final parsedTime = DateTime.tryParse(time);
    final parsedScope = BackupScope.values.where(
      (v) => v.name == json['scope'],
    );
    if (parsedTime == null || !parsedTime.isUtc || parsedScope.length != 1) {
      throw const BackupFailure(BackupFailureCode.invalidDocument);
    }
    id = identity;
    capturedAt = parsedTime;
    sourceSchema = schema;
    scope = parsedScope.single;
    final rawTables = json['tables'], rawPreferences = json['preferences'];
    if (rawTables is! Map ||
        rawPreferences is! Map ||
        rawTables.length !=
            BackupInventory.portableTableNamesFor(schema).length ||
        rawPreferences.length > 10000) {
      throw const BackupFailure(BackupFailureCode.invalidDocument);
    }
    var rowCount = 0;
    final safeTables = <String, List<Map<String, Object?>>>{};
    for (final name in BackupInventory.portableTableNamesFor(schema)) {
      final rawRows = rawTables[name];
      if (rawRows is! List ||
          (rowCount += rawRows.length) > maximumBackupRows) {
        throw const BackupFailure(BackupFailureCode.invalidDocument);
      }
      final fields = BackupInventory.portableColumns(
        name,
        schema: schema,
      ).toSet();
      final identities = <String>{};
      final safeRows = <Map<String, Object?>>[];
      for (final rawRow in rawRows) {
        if (rawRow is! Map ||
            rawRow.length != fields.length ||
            !rawRow.keys.toSet().containsAll(fields)) {
          throw const BackupFailure(BackupFailureCode.invalidDocument);
        }
        final row = <String, Object?>{};
        for (final column in fields) {
          final value = rawRow[column];
          if (value != null &&
                  value is! String &&
                  value is! num &&
                  value is! bool ||
              value is double && !value.isFinite) {
            throw const BackupFailure(BackupFailureCode.invalidDocument);
          }
          if (value is String) {
            if (utf8.encode(value).length > maximumBackupStringBytes) {
              throw const BackupFailure(BackupFailureCode.tooLarge);
            }
            // Retained legacy JSON remains opaque factual evidence, including
            // malformed old payloads. Its depth must still be safe to inspect.
            if (column.endsWith('_json')) {
              checkBackupJsonDepth(value, requireBalanced: false);
            }
          }
          row[column] = value;
        }
        final key = [
          for (final column in BackupInventory.primaryKeys[name]!) row[column],
        ];
        if (key.any((value) => value == null) ||
            !identities.add(jsonEncode(key))) {
          throw const BackupFailure(BackupFailureCode.invalidDocument);
        }
        safeRows.add(Map.unmodifiable(row));
      }
      safeTables[name] = List.unmodifiable(safeRows);
    }
    tables = Map.unmodifiable(safeTables);
    final safePreferences = <String, Object?>{};
    for (final entry in rawPreferences.entries) {
      final key = entry.key, value = entry.value;
      if (key is! String ||
          !BackupInventory.preferenceAllowed(key) ||
          value != null &&
              value is! String &&
              value is! num &&
              value is! bool &&
              !(value is List && value.every((v) => v is String)) ||
          value is double && !value.isFinite) {
        throw const BackupFailure(BackupFailureCode.invalidDocument);
      }
      if (utf8.encode(jsonEncode(value)).length > maximumBackupStringBytes) {
        throw const BackupFailure(BackupFailureCode.tooLarge);
      }
      safePreferences[key] = value is List
          ? List<String>.unmodifiable(value.cast<String>())
          : value;
    }
    preferences = Map.unmodifiable(safePreferences);
  }

  late final String id;
  late final DateTime capturedAt;
  late final int sourceSchema;
  late final BackupScope scope;
  late final Map<String, List<Map<String, Object?>>> tables;
  late final Map<String, Object?> preferences;

  factory BackupDocument.fromJson(Map<String, Object?> value) =>
      BackupDocument._validated(value);

  static BackupDocument parse(List<int> bytes) {
    if (bytes.length > maximumBackupBytes) {
      throw const BackupFailure(BackupFailureCode.tooLarge);
    }
    try {
      final text = utf8.decode(bytes);
      // Fixed document shape, row/member/string bounds are checked before
      // jsonDecode can allocate a wide tree. Opaque care JSON stays a scalar.
      _DocumentShapeScan(text).check();
      final value = jsonDecode(text);
      if (value is! Map<String, dynamic>) {
        throw const BackupFailure(BackupFailureCode.invalidDocument);
      }
      return BackupDocument.fromJson(value);
    } on BackupFailure {
      rethrow;
    } on Object {
      throw const BackupFailure(BackupFailureCode.invalidDocument);
    }
  }

  String toJsonText() => jsonEncode({
    'documentVersion': 1,
    'id': id,
    'capturedAt': capturedAt.toUtc().toIso8601String(),
    'sourceSchema': sourceSchema,
    'scope': scope.name,
    'tables': tables,
    'preferences': preferences,
  });

  Map<String, Object?> toJson() => {
    'documentVersion': 1,
    'id': id,
    'capturedAt': capturedAt.toUtc().toIso8601String(),
    'sourceSchema': sourceSchema,
    'scope': scope.name,
    'tables': {
      for (final entry in tables.entries)
        entry.key: [
          for (final row in entry.value) Map<String, Object?>.of(row),
        ],
    },
    'preferences': {
      for (final entry in preferences.entries)
        entry.key: entry.value is List
            ? List.of(entry.value as List)
            : entry.value,
    },
  };
}

/// This is a bounded shape scan, not a replacement JSON decoder. The standard
/// decoder still validates scalar syntax and builds the already bounded tree.
class _DocumentShapeScan {
  _DocumentShapeScan(this.text);
  final String text;
  int at = 0, rows = 0, preferenceItems = 0;
  Never invalid() =>
      throw const BackupFailure(BackupFailureCode.invalidDocument);
  Never oversized() => throw const BackupFailure(BackupFailureCode.tooLarge);
  void whitespace() {
    while (at < text.length &&
        const {9, 10, 13, 32}.contains(text.codeUnitAt(at))) {
      at++;
    }
  }

  bool consume(int character) {
    whitespace();
    if (at >= text.length || text.codeUnitAt(at) != character) return false;
    at++;
    return true;
  }

  void require(int character) {
    if (!consume(character)) invalid();
  }

  void check() {
    object('root');
    whitespace();
    if (at != text.length) invalid();
  }

  String string({bool key = false}) {
    whitespace();
    final start = at;
    require(34);
    var bytes = 0;
    while (at < text.length) {
      var c = text.codeUnitAt(at++);
      if (c == 34) {
        return key ? jsonDecode(text.substring(start, at)) as String : '';
      }
      if (c == 92) {
        if (at >= text.length) invalid();
        c = text.codeUnitAt(at++);
        if (c == 117) {
          if (at + 4 > text.length) invalid();
          final decoded = int.tryParse(text.substring(at, at + 4), radix: 16);
          if (decoded == null) invalid();
          c = decoded;
          at += 4;
          if (c >= 0xd800 &&
              c <= 0xdbff &&
              at + 6 <= text.length &&
              text.substring(at, at + 2) == r'\u') {
            final low = int.tryParse(text.substring(at + 2, at + 6), radix: 16);
            if (low != null && low >= 0xdc00 && low <= 0xdfff) {
              at += 6;
              bytes += 4;
              c = -1;
            }
          }
        } else {
          c = 0;
        }
      } else if (c >= 0xd800 &&
          c <= 0xdbff &&
          at < text.length &&
          text.codeUnitAt(at) >= 0xdc00 &&
          text.codeUnitAt(at) <= 0xdfff) {
        at++;
        bytes += 4;
        c = -1;
      }
      if (c >= 0) bytes += c < 128 ? 1 : (c < 2048 ? 2 : 3);
      if (bytes > (key ? 256 : maximumBackupStringBytes)) oversized();
    }
    invalid();
  }

  void scalar({bool stringOnly = false}) {
    whitespace();
    if (at >= text.length) invalid();
    final c = text.codeUnitAt(at);
    if (c == 34) {
      string();
      return;
    }
    if (stringOnly || c == 123 || c == 91 || c == 125 || c == 93) invalid();
    final start = at;
    while (at < text.length &&
        !const {9, 10, 13, 32, 44, 93, 125}.contains(text.codeUnitAt(at))) {
      if (at - start > 128) invalid();
      at++;
    }
    if (start == at) invalid();
  }

  void object(String kind, [String? table]) {
    require(123);
    final keys = <String>{};
    if (consume(125)) return;
    while (true) {
      final key = string(key: true);
      if (!keys.add(key)) invalid();
      if (kind == 'root' &&
              !const {
                'documentVersion',
                'id',
                'capturedAt',
                'sourceSchema',
                'scope',
                'tables',
                'preferences',
              }.contains(key) ||
          kind == 'tables' && !BackupInventory.primaryKeys.containsKey(key) ||
          kind == 'row' &&
              !BackupInventory.portableColumns(table!).contains(key) ||
          kind == 'preferences' && !BackupInventory.preferenceAllowed(key)) {
        invalid();
      }
      if (kind == 'preferences' && keys.length > 10000) oversized();
      require(58);
      if (kind == 'root' && const {'tables', 'preferences'}.contains(key)) {
        object(key);
      } else if (kind == 'tables') {
        require(91);
        if (!consume(93)) {
          while (true) {
            if (++rows > maximumBackupRows) oversized();
            object('row', key);
            if (consume(93)) break;
            require(44);
          }
        }
      } else if (kind == 'preferences' && consume(91)) {
        if (!consume(93)) {
          while (true) {
            if (++preferenceItems > 10000) oversized();
            scalar(stringOnly: true);
            if (consume(93)) break;
            require(44);
          }
        }
      } else {
        scalar();
      }
      if (consume(125)) break;
      require(44);
    }
  }
}
