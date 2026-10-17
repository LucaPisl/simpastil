// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'medication_ledger_dao.dart';

// ignore_for_file: type=lint
mixin _$MedicationLedgerDaoMixin on DatabaseAccessor<AppDatabase> {
  $UsersTable get users => attachedDatabase.users;
  $MedicationOccurrencesTable get medicationOccurrences =>
      attachedDatabase.medicationOccurrences;
  $OccurrenceEventsTable get occurrenceEvents =>
      attachedDatabase.occurrenceEvents;
  $InventoryEventsTable get inventoryEvents => attachedDatabase.inventoryEvents;
  MedicationLedgerDaoManager get managers => MedicationLedgerDaoManager(this);
}

class MedicationLedgerDaoManager {
  final _$MedicationLedgerDaoMixin _db;
  MedicationLedgerDaoManager(this._db);
  $$UsersTableTableManager get users =>
      $$UsersTableTableManager(_db.attachedDatabase, _db.users);
  $$MedicationOccurrencesTableTableManager get medicationOccurrences =>
      $$MedicationOccurrencesTableTableManager(
        _db.attachedDatabase,
        _db.medicationOccurrences,
      );
  $$OccurrenceEventsTableTableManager get occurrenceEvents =>
      $$OccurrenceEventsTableTableManager(
        _db.attachedDatabase,
        _db.occurrenceEvents,
      );
  $$InventoryEventsTableTableManager get inventoryEvents =>
      $$InventoryEventsTableTableManager(
        _db.attachedDatabase,
        _db.inventoryEvents,
      );
}
