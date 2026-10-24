import 'dart:convert';

import 'package:drift/drift.dart';

import '../db/database.dart';

/// Why a refill queued before the server was known is refused by an older
/// server without the medication ledger.
///
/// The refusal happens before any request, so the server never holds the
/// refill. It stays blocked for the person (a server update lets Retry send
/// it; Discard drops it), and the next pull puts the server's count back on
/// the phone. [watchRefusedRefill] lets the medication say so where the
/// stock is shown.
const refillNeedsLedgerCode = 'REFILL_REQUIRES_MEDICATION_LEDGER';

/// Whether a refill of [pillId] is waiting, refused by an older server.
Future<bool> hasRefusedRefill(AppDatabase db, String pillId) async {
  final rows =
      await (db.select(db.pendingOperations)..where(
            (row) =>
                row.component.equals('medication') &
                row.state.equals('blocked') &
                row.safeErrorCode.equals(refillNeedsLedgerCode),
          ))
          .get();
  return rows.any((row) => refusedRefillPillId(row) == pillId);
}

/// [hasRefusedRefill], again whenever the journal changes.
Stream<bool> watchRefusedRefill(AppDatabase db, String pillId) => db
    .customSelect('SELECT 1', readsFrom: {db.pendingOperations})
    .watch()
    .asyncMap((_) => hasRefusedRefill(db, pillId))
    .distinct();

/// The local pill a refused refill was for, or null when [operation] is not
/// a readable refill.
String? refusedRefillPillId(PendingOperation operation) {
  try {
    final payload = jsonDecode(operation.payloadJson);
    if (payload is! Map) return null;
    final command = payload['inventoryCommand'];
    if (command is! Map || command['action'] != 'refill') return null;
    final id = command['pillId'];
    return id is String ? id : null;
  } on FormatException {
    return null;
  }
}
