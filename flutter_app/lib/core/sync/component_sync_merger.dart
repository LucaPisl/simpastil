import '../db/database.dart';
import '../workspace/workspace_context.dart';
import 'sync_write_scope.dart';
import 'sync_models.dart';
import '../utils/safe_diagnostics.dart';
import 'account_settlement_merger.dart';
import 'medication_projection_merger.dart';
import 'pill_unsent_work.dart';
import 'stable_record_merger.dart';

/// Applies a fully staged component page set in the staging transaction.
/// Server state never replaces a locally pending stable edit or medication
/// command projection.
const accountSettlementProjectionRevision = 'legacy-settlement-v1';

const _journalNeutralKinds = {'profile', 'pill', 'schedule'};

class ComponentSyncMerger {
  ComponentSyncMerger(
    this.db, {
    this.writeScope,
    bool medicationDetailsExtra = false,
    bool medicationPhoto = false,
  }) : _account = AccountSettlementMerger(db, writeScope: writeScope) {
    _stable = StableRecordMerger(
      db,
      writeScope: writeScope,
      reviews: _account,
      medicationDetailsExtra: medicationDetailsExtra,
      medicationPhoto: medicationPhoto,
    );
    _medication = MedicationProjectionMerger(db, writeScope: writeScope);
  }

  final AppDatabase db;
  final SyncWriteScope? writeScope;
  final AccountSettlementMerger _account;
  late final StableRecordMerger _stable;
  late final MedicationProjectionMerger _medication;

  Future<void> merge(
    String userId,
    SyncComponent component,
    List<Map<String, dynamic>> changes, {
    int? contractVersion,
  }) async {
    writeScope?.requireOwner(userId);
    await writeScope?.check();
    // Notes written for identity mappings by earlier builds are not review
    // items; closing them here runs on the first pull after the upgrade.
    await _account.clearAppliedMappingNotes(userId);
    final profileIds = <String, String>{};
    final pillIds = <String, String>{};
    final scheduleIds = <String, String>{};
    // Read once for the whole batch, and only when a pill needs it.
    Future<PillJournal>? journal;
    Future<PillJournal> pillJournal() =>
        journal ??= PillJournal.read(db, userId);
    for (final change in changes) {
      if (change['component'] != component.name) {
        throw const FormatException('Staged component identity mismatch.');
      }
      final payload = change['payload'];
      if (payload is! Map<String, dynamic> || payload['kind'] is! String) {
        throw const FormatException('Staged component payload is invalid.');
      }
      // Only pill, profile and schedule merges are known to leave the journal
      // alone; after any other kind it is read again when a pill next needs it.
      if (!_journalNeutralKinds.contains(payload['kind'])) journal = null;
      try {
        switch (payload['kind']) {
          case 'account':
            await _account.mergeAccount(userId, payload);
            break;
          case 'migrationIssue':
            await _account.mergeMigrationIssue(userId, payload);
            break;
          case 'profile':
            await _stable.mergeProfile(userId, payload, profileIds);
            break;
          case 'pill':
            await _stable.mergePill(
              payload,
              profileIds,
              pillIds,
              userId: userId,
              journal: pillJournal,
            );
            break;
          case 'schedule':
            await _stable.mergeSchedule(payload, pillIds, scheduleIds);
            break;
          case 'bridgeDose':
            await _medication.mergeBridgeDose(
              userId,
              change,
              payload,
              scheduleIds,
              contractVersion,
            );
            break;
          case 'bridgeStock':
            await _medication.mergeBridgeStock(userId, payload, pillIds);
            break;
          case 'medicationOccurrence':
            if (component == SyncComponent.medicationBridge) {
              await _medication.mergeBridgeOccurrence(
                userId,
                change,
                payload,
                pillIds,
                scheduleIds,
                contractVersion,
              );
            } else {
              await _medication.mergeOccurrence(
                userId,
                payload,
                pillIds,
                scheduleIds,
              );
            }
            break;
          case 'occurrenceEvent':
            if (component == SyncComponent.medicationBridge) {
              final source = change['sourceIdentity'];
              final parent = await db.medicationLedgerDao
                  .getOccurrenceByServerId(payload['occurrenceId'] as String);
              if (contractVersion != 5 ||
                  change['schemaVersion'] != 2 ||
                  change['entityType'] != 'occurrence_event' ||
                  change['entityId'] != payload['id'] ||
                  change['operation'] != 'upsert' ||
                  source is! Map ||
                  source['sourceKind'] != 'occurrence_event' ||
                  source['sourceId'] != payload['id'] ||
                  source['sourceRevision'] != payload['serverSequence'] ||
                  parent?.source != 'prn' ||
                  parent?.provenance != 'exact') {
                throw const FormatException(
                  'PRN event requires bridge v5 exact identity.',
                );
              }
              final take = payload['action'] == 'take';
              final undo = payload['action'] == 'undo';
              if ((!take && !undo) ||
                  payload['origin'] != 'native' ||
                  payload['baseVersion'] != (take ? '0' : '1') ||
                  payload['resultVersion'] != (take ? '1' : '2') ||
                  payload['fromState'] != (take ? 'pending' : 'taken') ||
                  payload['toState'] != (take ? 'taken' : 'pending') ||
                  (take && payload['reversesEventId'] != null) ||
                  (undo &&
                      (payload['reversesEventId'] is! String ||
                          payload['administrationAmount'] != null)) ||
                  ((payload['actualAt'] != null) !=
                      (payload['actualTimeKnown'] == true))) {
                throw const FormatException(
                  'PRN event causal shape is invalid.',
                );
              }
              if (undo) {
                final reversal = await db.medicationLedgerDao
                    .getOccurrenceEventByServerId(
                      payload['reversesEventId'] as String,
                    );
                if (reversal == null ||
                    reversal.occurrenceId != parent!.id ||
                    reversal.action != 'take' ||
                    reversal.resultVersion != 1) {
                  throw const FormatException(
                    'PRN reversal identity is invalid.',
                  );
                }
              }
              if (payload['action'] == 'take' &&
                  payload['administrationAmount'] == null) {
                throw const FormatException('PRN take amount is missing.');
              }
            }
            await _medication.mergeOccurrenceEvent(userId, payload);
            break;
          case 'inventoryEvent':
            await _medication.mergeInventoryEvent(userId, payload, pillIds);
            break;
          case 'identityMapping':
            await _account.mergeIdentityMapping(userId, change, payload);
            break;
          case 'legacyEstimatedHistory':
            await _account.recordReviewIssue(userId, change, payload);
            break;
          case 'tombstone':
            await _stable.mergeTombstone(
              userId,
              payload,
              profileIds,
              pillIds,
              scheduleIds,
            );
            break;
          default:
            throw const FormatException('Unsupported staged sync item.');
        }
      } on WorkspaceAccessFailure catch (error) {
        SafeDiagnostics.logAccessRefusal(
          component: component.name,
          payloadKind: payload['kind'] as String,
          reason: error.code.name,
        );
        rethrow;
      }
    }
  }
}
