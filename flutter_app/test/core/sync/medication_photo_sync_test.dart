import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/medication/medication_photo_processor.dart';
import 'package:simpastil/core/medication/medication_photo_sync.dart';
import 'package:simpastil/core/sync/account_settlement_merger.dart';
import 'package:simpastil/core/sync/stable_record_merger.dart';

const _profile = '10000000-0000-4000-8000-000000000802';
const _pill = '10000000-0000-4000-8000-000000000803';
final _at = DateTime.utc(2026, 10, 23, 8);

Uint8List _jpeg(int seed) {
  final random = math.Random(seed);
  final image = img.Image(width: 64, height: 48);
  for (final pixel in image) {
    pixel
      ..r = random.nextInt(256)
      ..g = random.nextInt(256)
      ..b = random.nextInt(256);
  }
  return cleanMedicationPhoto(
    Uint8List.fromList(img.encodeJpg(image, quality: 90)),
  ).bytes;
}

String _sha(Uint8List bytes) => sha256.convert(bytes).toString();

Map<String, dynamic> _item({Map<String, dynamic>? photo}) => {
  'id': _pill,
  'profileId': _profile,
  'revision': '3',
  'name': 'Fakeolol',
  'dosage': null,
  'notes': null,
  'color': null,
  'currentStock': 3,
  'lowStockThreshold': null,
  'isPrn': false,
  'deletedAt': null,
  'createdAt': '2026-10-12T08:00:00.000Z',
  'updatedAt': '2026-10-13T08:00:00.000Z',
  'photo': ?photo,
};

class _Call {
  _Call(this.method, this.path, this.body, this.contentType);
  final String method, path;
  final Object? body;
  final String? contentType;
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final ResponseBody Function(RequestOptions options) respond;
  final calls = <_Call>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final chunks = <int>[];
    if (requestStream != null) {
      await for (final part in requestStream) {
        chunks.addAll(part);
      }
    }
    calls.add(
      _Call(
        options.method,
        options.path,
        Uint8List.fromList(chunks),
        options.contentType,
      ),
    );
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body, [int status = 200]) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.forTesting();
    await db.usersDao.upsert(
      UsersCompanion.insert(
        id: 'u1',
        email: 'u@example.com',
        createdAt: _at,
        updatedAt: _at,
      ),
    );
    await db.profilesDao.upsert(
      ProfilesCompanion.insert(
        id: _profile,
        userId: 'u1',
        name: 'P',
        createdAt: _at,
        updatedAt: _at,
        serverId: const Value(_profile),
        syncStatus: const Value('synced'),
      ),
    );
    await db.pillsDao.upsert(
      PillsCompanion.insert(
        id: _pill,
        profileId: _profile,
        name: 'Old',
        createdAt: _at,
        updatedAt: _at,
        serverId: const Value(_pill),
        revision: const Value(2),
        syncStatus: const Value('synced'),
      ),
    );
  });
  tearDown(() async => db.close());

  Future<MedicationPhoto?> row() => (db.select(
    db.medicationPhotos,
  )..where((t) => t.pillId.equals(_pill))).getSingleOrNull();

  Future<void> localPhoto(Uint8List bytes, String status, {int revision = 0}) =>
      db
          .into(db.medicationPhotos)
          .insert(
            MedicationPhotosCompanion.insert(
              pillId: _pill,
              bytesBase64: Value(base64Encode(bytes)),
              sha256: _sha(bytes),
              revision: Value(revision),
              syncStatus: Value(status),
            ),
          );

  Future<void> merge(Map<String, dynamic> item, {bool capable = true}) =>
      StableRecordMerger(
        db,
        reviews: AccountSettlementMerger(db),
        medicationPhoto: capable,
      ).mergePill(item, {_profile: _profile}, {});

  group('merging a pulled pill', () {
    test('a photo the account holds is marked for download', () async {
      final bytes = _jpeg(1);
      await merge(_item(photo: {'sha256': _sha(bytes), 'revision': '4'}));
      final stored = (await row())!;
      expect(stored.syncStatus, 'fetch');
      expect(stored.sha256, _sha(bytes));
      expect(stored.revision, 4);
      expect(stored.bytesBase64, isEmpty);
    });

    test('the same photo is only confirmed, not fetched again', () async {
      final bytes = _jpeg(1);
      await localPhoto(bytes, 'synced', revision: 2);
      await merge(_item(photo: {'sha256': _sha(bytes), 'revision': '5'}));
      final stored = (await row())!;
      expect(stored.syncStatus, 'synced');
      expect(stored.revision, 5);
      expect(stored.bytesBase64, base64Encode(bytes));
    });

    test('a different photo on the account replaces a synced one', () async {
      await localPhoto(_jpeg(1), 'synced', revision: 2);
      final other = _jpeg(2);
      await merge(_item(photo: {'sha256': _sha(other), 'revision': '6'}));
      final stored = (await row())!;
      expect(stored.syncStatus, 'fetch');
      expect(stored.remoteSha256, _sha(other));
    });

    test('no photo on the account removes a synced one', () async {
      await localPhoto(_jpeg(1), 'synced', revision: 2);
      await merge(_item());
      expect(await row(), isNull);
    });

    test('a photo waiting to be sent is never overwritten', () async {
      final mine = _jpeg(1);
      await localPhoto(mine, 'pending');
      await merge(_item(photo: {'sha256': _sha(_jpeg(2)), 'revision': '9'}));
      var stored = (await row())!;
      expect(stored.syncStatus, 'pending');
      expect(stored.bytesBase64, base64Encode(mine));
      await merge(_item());
      stored = (await row())!;
      expect(stored.syncStatus, 'pending');
    });

    test('a removal waiting to be sent is never undone', () async {
      await localPhoto(_jpeg(1), 'removing', revision: 2);
      await merge(_item(photo: {'sha256': _sha(_jpeg(1)), 'revision': '5'}));
      expect((await row())!.syncStatus, 'removing');
    });

    test(
      'a photo is never overwritten while the pill itself is unsent',
      () async {
        await (db.update(db.pills)..where((p) => p.id.equals(_pill))).write(
          const PillsCompanion(syncStatus: Value('pending')),
        );
        final mine = _jpeg(1);
        await localPhoto(mine, 'pending');
        await merge(_item(photo: {'sha256': _sha(_jpeg(2)), 'revision': '9'}));
        expect((await row())!.bytesBase64, base64Encode(mine));
      },
    );

    test('without the contract the photo row is left alone', () async {
      await localPhoto(_jpeg(1), 'synced', revision: 2);
      await merge(_item(), capable: false);
      expect(await row(), isNotNull);
    });
  });

  group('MedicationPhotoSync', () {
    MedicationPhotoSync sync(_Adapter adapter) => MedicationPhotoSync(
      db: db,
      dio: Dio(BaseOptions(baseUrl: 'https://example.test'))
        ..httpClientAdapter = adapter,
    );

    test('upload sends the bytes as image/jpeg and marks it synced', () async {
      final bytes = _jpeg(1);
      await localPhoto(bytes, 'pending');
      final adapter = _Adapter(
        (_) => _json({'revision': '1', 'pillRevision': '3'}),
      );
      await sync(adapter).upload('u1');
      final call = adapter.calls.single;
      expect(call.method, 'PUT');
      expect(call.path, '/pills/$_pill/photo');
      expect(call.contentType, 'image/jpeg');
      expect(call.body, bytes);
      final stored = (await row())!;
      expect(stored.syncStatus, 'synced');
      expect(stored.revision, 1);
      // The upload moved the pill's revision on the account; follow it.
      expect((await db.pillsDao.getById(_pill))!.revision, 3);
    });

    test('a pill that is not synced yet waits', () async {
      await (db.update(db.pills)..where((p) => p.id.equals(_pill))).write(
        const PillsCompanion(syncStatus: Value('pending')),
      );
      await localPhoto(_jpeg(1), 'pending');
      final adapter = _Adapter((_) => _json({}));
      await sync(adapter).upload('u1');
      expect(adapter.calls, isEmpty);
      expect((await row())!.syncStatus, 'pending');
    });

    test('a refused photo stays here and is not retried', () async {
      await localPhoto(_jpeg(1), 'pending');
      final adapter = _Adapter((_) => _json({'code': 'x'}, 422));
      await sync(adapter).upload('u1');
      expect((await row())!.syncStatus, 'rejected');
      await sync(adapter).upload('u1');
      expect(adapter.calls, hasLength(1));
    });

    test('a failed upload leaves the photo to try again', () async {
      await localPhoto(_jpeg(1), 'pending');
      final adapter = _Adapter((_) => _json({'code': 'x'}, 500));
      await sync(adapter).upload('u1');
      expect((await row())!.syncStatus, 'pending');
    });

    test('a removal is sent once and the row goes away', () async {
      await localPhoto(_jpeg(1), 'removing', revision: 2);
      final adapter = _Adapter((_) => ResponseBody.fromString('', 204));
      await sync(adapter).upload('u1');
      expect(adapter.calls.single.method, 'DELETE');
      expect(await row(), isNull);
    });

    test('download stores the bytes and the revision header', () async {
      final bytes = _jpeg(3);
      await db
          .into(db.medicationPhotos)
          .insert(
            MedicationPhotosCompanion.insert(
              pillId: _pill,
              sha256: _sha(bytes),
              revision: const Value(4),
              syncStatus: const Value('fetch'),
              remoteSha256: Value(_sha(bytes)),
            ),
          );
      final adapter = _Adapter(
        (_) => ResponseBody.fromBytes(
          bytes,
          200,
          headers: {
            'content-type': ['image/jpeg'],
            'x-photo-revision': ['5'],
          },
        ),
      );
      await sync(adapter).fetch('u1');
      final stored = (await row())!;
      expect(stored.syncStatus, 'synced');
      expect(stored.revision, 5);
      expect(base64Decode(stored.bytesBase64), bytes);
      expect(stored.sha256, _sha(bytes));
    });

    test('a photo chosen meanwhile is not replaced by a download', () async {
      final mine = _jpeg(1);
      await localPhoto(mine, 'fetch');
      final theirs = _jpeg(2);
      final adapter = _Adapter((options) {
        // The person picks a photo while the download is in flight.
        db.customStatement(
          "UPDATE medication_photos SET sync_status='pending'",
        );
        return ResponseBody.fromBytes(theirs, 200);
      });
      await sync(adapter).fetch('u1');
      await Future<void>.delayed(Duration.zero);
      final stored = (await row())!;
      expect(stored.syncStatus, 'pending');
      expect(stored.bytesBase64, base64Encode(mine));
    });

    test('a file that is not an acceptable photo is not stored', () async {
      await localPhoto(_jpeg(1), 'fetch');
      await (db.update(
        db.medicationPhotos,
      )).write(const MedicationPhotosCompanion(bytesBase64: Value('')));
      final adapter = _Adapter(
        (_) => ResponseBody.fromBytes(Uint8List.fromList([1, 2, 3]), 200),
      );
      await sync(adapter).fetch('u1');
      final stored = (await row())!;
      expect(stored.syncStatus, 'fetch');
      expect(stored.bytesBase64, isEmpty);
    });
  });
}
