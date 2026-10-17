import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/backup/backup_codec.dart';
import 'package:simpastil/core/backup/backup_inventory.dart';
import 'package:simpastil/core/backup/backup_manifest.dart';

BackupDocument example() => BackupDocument(
  id: 'fictional-backup',
  capturedAt: DateTime.utc(2026, 10, 1, 9),
  sourceSchema: 10,
  scope: BackupScope.full,
  tables: {
    for (final name in BackupInventory.portableTableNamesFor(10)) name: [],
    'users': [
      {
        'id': 'fictional-owner',
        'email': '',
        'created_at': 1,
        'updated_at': 1,
        'server_id': null,
        'sync_status': 'local',
        'last_sync_at': null,
        'is_deleted': 0,
      },
    ],
  },
  preferences: {'app_locale': 'ro'},
);

Matcher failure(BackupFailureCode code) =>
    throwsA(isA<BackupFailure>().having((e) => e.code, 'code', code));

void main() {
  const codec = BackupCodec();

  test(
    'shallow oversized row structure is rejected before JSON object allocation',
    () {
      final text =
          '{"tables":{"users":[${List.filled(200001, '{}').join(',')}]}}';
      expect(
        () => BackupDocument.parse(utf8.encode(text)),
        failure(BackupFailureCode.tooLarge),
      );
    },
  );

  test(
    'password file authenticates content and exact header, preserves source',
    () async {
      final original = example();
      final file = await codec.encode(
        original,
        password: 'Fictional passphrase 1',
      );
      expect(
        utf8.decode(file, allowMalformed: true),
        isNot(contains('fictional-owner')),
      );
      final decoded = await codec.decode(
        file,
        password: 'Fictional passphrase 1',
      );
      expect(decoded.toJson(), original.toJson());
      await expectLater(
        codec.decode(file, password: 'Wrong fictional password'),
        failure(BackupFailureCode.passwordOrIntegrity),
      );
      final changed = Uint8List.fromList(file)..[40] ^= 1;
      await expectLater(
        codec.decode(changed, password: 'Fictional passphrase 1'),
        failure(BackupFailureCode.passwordOrIntegrity),
      );
      final damaged = Uint8List.fromList(file)..[80] ^= 1;
      await expectLater(
        codec.decode(damaged, password: 'Fictional passphrase 1'),
        failure(BackupFailureCode.passwordOrIntegrity),
      );
      expect(original.toJson(), example().toJson());
    },
  );

  test(
    'clear backup requires explicit review and detects damaged stored bytes',
    () async {
      await expectLater(
        codec.encode(example()),
        failure(BackupFailureCode.passwordRequired),
      );
      final file = await codec.encode(example(), allowClear: true);
      expect(codec.isPasswordProtected(file), isFalse);
      expect((await codec.decode(file)).toJson(), example().toJson());
      final damaged = Uint8List.fromList(file)..[80] ^= 1;
      await expectLater(
        codec.decode(damaged),
        failure(BackupFailureCode.integrity),
      );
    },
  );

  test(
    'untrusted header rejects future version, KDF work and truncated length',
    () async {
      final file = await codec.encode(example(), allowClear: true);
      final future = Uint8List.fromList(file);
      ByteData.sublistView(future).setUint16(8, 2, Endian.big);
      await expectLater(
        codec.decode(future),
        failure(BackupFailureCode.unsupportedVersion),
      );
      final expensive = Uint8List.fromList(file);
      ByteData.sublistView(expensive).setUint32(16, 0xffffffff, Endian.big);
      await expectLater(
        codec.decode(expensive),
        failure(BackupFailureCode.invalidContainer),
      );
      await expectLater(
        codec.decode(Uint8List.sublistView(file, 0, file.length - 1)),
        failure(BackupFailureCode.invalidContainer),
      );
    },
  );

  test(
    'document parsing refuses authority fields, duplicate identities and deep JSON',
    () {
      final authority = example().toJson();
      ((authority['tables'] as Map)['users'] as List)
              .first['session_generation'] =
          99;
      expect(
        () => BackupDocument.fromJson(authority),
        failure(BackupFailureCode.invalidDocument),
      );
      final duplicate = example().toJson();
      final users = (duplicate['tables'] as Map)['users'] as List;
      users.add(Map<String, Object?>.from(users.first as Map));
      expect(
        () => BackupDocument.fromJson(duplicate),
        failure(BackupFailureCode.invalidDocument),
      );
      final deep = '${'[' * 40}0${']' * 40}';
      expect(
        () => BackupDocument.parse(utf8.encode(deep)),
        failure(BackupFailureCode.invalidDocument),
      );
      final future = example().toJson()..['sourceSchema'] = 19;
      expect(
        () => BackupDocument.fromJson(future),
        failure(BackupFailureCode.unsupportedSchema),
      );
    },
  );

  group('schema 16 adds only a device-local table', () {
    BackupDocument at(int schema) => BackupDocument(
      id: 'fictional-backup',
      capturedAt: DateTime.utc(2026, 10, 1, 9),
      sourceSchema: schema,
      scope: BackupScope.full,
      tables: {
        for (final name in BackupInventory.portableTableNamesFor(schema))
          name: [],
      },
      preferences: const {},
    );

    test('person_first_seen is excluded from every portable table set', () {
      expect(BackupInventory.excludedTables, contains('person_first_seen'));
      expect(BackupInventory.sourceColumns, contains('person_first_seen'));
      for (final schema in [10, 11, 12, 13, 14, 15, 16, 17, 18]) {
        expect(
          BackupInventory.portableTableNamesFor(schema),
          isNot(contains('person_first_seen')),
          reason: 'schema $schema',
        );
      }
    });

    test('schemas 14 and 15 keep their exact column map', () {
      expect(
        BackupInventory.columnsFor(15),
        same(BackupInventory.schema15SourceColumns),
      );
      expect(
        BackupInventory.columnsFor(14),
        same(BackupInventory.schema15SourceColumns),
      );
      expect(
        BackupInventory.schema15SourceColumns,
        isNot(contains('person_first_seen')),
      );
      expect(
        BackupInventory.columnsFor(16),
        same(BackupInventory.sourceColumns),
      );
      expect(
        BackupInventory.columnsFor(17),
        same(BackupInventory.sourceColumns),
      );
      expect(
        BackupInventory.columnsFor(18),
        same(BackupInventory.sourceColumns),
      );
      expect(BackupInventory.sourceColumns.keys.toSet(), {
        ...BackupInventory.schema15SourceColumns.keys,
        'person_first_seen',
      });
      expect(
        BackupInventory.portableTableNamesFor(16).toSet(),
        BackupInventory.portableTableNamesFor(15).toSet(),
      );
    });

    test('v15 and v16 documents validate and round trip', () {
      for (final schema in [15, 16, 17, 18]) {
        final document = at(schema);
        expect(document.tables, isNot(contains('person_first_seen')));
        final parsed = BackupDocument.fromJson(document.toJson());
        expect(parsed.sourceSchema, schema);
        expect(parsed.tables, isNot(contains('person_first_seen')));
      }
    });

    test('a document that carries the device-local table is refused', () {
      final json = at(16).toJson();
      (json['tables'] as Map)['person_first_seen'] = <Map<String, Object?>>[];
      expect(
        () => BackupDocument.fromJson(json),
        failure(BackupFailureCode.invalidDocument),
      );
    });
  });
}
