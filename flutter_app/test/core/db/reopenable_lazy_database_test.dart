import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/db/reopenable_lazy_database.dart';
import 'package:simpastil/core/storage/protected_database.dart';

void main() {
  test('a refused opening is retried by the next query', () async {
    var openings = 0;
    final db = AppDatabase(
      ReopenableLazyDatabase(() async {
        openings++;
        if (openings == 1) {
          throw const ProtectedStoreFailure(ProtectedStoreFailureCode.busy);
        }
        return NativeDatabase.memory();
      }),
    );
    addTearDown(db.close);

    await expectLater(
      db.customSelect('SELECT 1').get(),
      throwsA(isA<ProtectedStoreFailure>()),
    );
    final rows = await db.customSelect('SELECT 1 AS one').get();

    expect(rows.single.read<int>('one'), 1);
    expect(openings, 2);
  });

  test('concurrent queries share one failed opening', () async {
    var openings = 0;
    final db = AppDatabase(
      ReopenableLazyDatabase(() async {
        openings++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        if (openings == 1) {
          throw const ProtectedStoreFailure(ProtectedStoreFailureCode.busy);
        }
        return NativeDatabase.memory();
      }),
    );
    addTearDown(db.close);

    final first = await Future.wait([
      db
          .customSelect('SELECT 1')
          .get()
          .then((_) => true, onError: (_) => false),
      db
          .customSelect('SELECT 1')
          .get()
          .then((_) => true, onError: (_) => false),
    ]);
    expect(first, [false, false]);
    await db.customSelect('SELECT 1').get();
    expect(openings, 2);
  });

  test('closing after a refused opening does not rethrow it', () async {
    final db = AppDatabase(
      ReopenableLazyDatabase(
        () async => throw const ProtectedStoreFailure(
          ProtectedStoreFailureCode.keyMissing,
        ),
      ),
    );
    await expectLater(
      db.customSelect('SELECT 1').get(),
      throwsA(isA<ProtectedStoreFailure>()),
    );
    await db.close();
  });

  test('only an opening after a refusal is announced, once', () async {
    var openings = 0;
    var reopened = 0;
    final db = AppDatabase(
      ReopenableLazyDatabase(() async {
        openings++;
        if (openings == 1) {
          throw const ProtectedStoreFailure(ProtectedStoreFailureCode.busy);
        }
        return NativeDatabase.memory();
      }, onReopened: () => reopened++),
    );
    addTearDown(db.close);
    await expectLater(db.customSelect('SELECT 1').get(), throwsA(anything));
    expect(reopened, 0);
    await db.customSelect('SELECT 1').get();
    await db.customSelect('SELECT 1').get();
    expect(reopened, 1);

    var plain = 0;
    final healthy = AppDatabase(
      ReopenableLazyDatabase(
        () async => NativeDatabase.memory(),
        onReopened: () => plain++,
      ),
    );
    addTearDown(healthy.close);
    await healthy.customSelect('SELECT 1').get();
    expect(plain, 0);
  });
}
