import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../network/pinned_connection.dart';
import '../../features/updates/data/update_hint.dart' show isValidReleaseUrl;
import '../api/scoped_auth_interceptor.dart';

enum CapabilityAvailability {
  absent,
  unavailable,
  localAccessUnavailable,
  present,
}

enum MedicationSyncStep {
  legacySplit,
  permanentReconciliation,
  inactiveBridge,
  activeLedger,
}

/// Whether the server can email password-reset links. Servers from before the
/// field existed (or with an unrecognised value) are [unknown], never assumed
/// either way.
enum EmailResetAvailability { available, unavailable, unknown }

/// Reads the additive `emailReset` field tolerantly.
EmailResetAvailability parseEmailReset(Object? value) => switch (value) {
  'available' => EmailResetAvailability.available,
  'unavailable' => EmailResetAvailability.unavailable,
  _ => EmailResetAvailability.unknown,
};

/// How a changed email is applied. [confirm]: a link goes to the new address
/// first. [immediate]: the server has no mail and applies it at once.
/// [unknown]: an older server, or an unrecognised value.
enum EmailChangeMode { confirm, immediate, unknown }

/// Reads the additive `emailChange` field tolerantly.
EmailChangeMode parseEmailChange(Object? value) => switch (value) {
  'confirm' => EmailChangeMode.confirm,
  'immediate' => EmailChangeMode.immediate,
  _ => EmailChangeMode.unknown,
};

class ServerCapabilities {
  const ServerCapabilities({
    required this.medicationLedgerActive,
    required this.minimumClientBuild,
    required this.serverRelease,
    this.medicationBridgeContractVersion = 1,
    this.medicationBridgePrnCommands = false,
    this.bridgeUndo = false,
    this.recordedMiss = false,
    this.scheduleWindows = false,
    this.movedHistory = false,
    this.ledgerPrn = false,
    this.medicationDetails = false,
    this.medicationShapes = false,
    this.medicationDetailsExtra = false,
    this.medicationPhoto = false,
    this.fractionalStock = false,
    this.recordedBy = false,
    this.accountSettings = false,
    this.accountSelfService = false,
    this.emailChange = EmailChangeMode.unknown,
    this.emailReset = EmailResetAvailability.unknown,
    this.latestClientBuild,
    this.latestReleaseUrl,
  });

  final bool medicationLedgerActive;
  final int minimumClientBuild;
  final String serverRelease;
  final int medicationBridgeContractVersion;
  final bool medicationBridgePrnCommands;

  /// Additive server flag: bridge commands accept status `pending` (Undo).
  /// Absent on older servers; never part of strict contract equality.
  final bool bridgeUndo;

  /// Medication command contract 3: the ledger accepts the `miss` action and
  /// pulls the `missed` state. A contract-2 server never records misses, and
  /// this build then keeps the automatic-miss sweep switched off.
  final bool recordedMiss;

  /// Additive server flag: schedules accept `interval` (every N days) and
  /// optional start and end dates. Absent on older servers; never part of
  /// strict contract equality.
  final bool scheduleWindows;

  /// Additive server flag: the server can take moved past scheduled history.
  /// Absent on older servers; never part of strict contract equality.
  final bool movedHistory;

  /// Additive server flag: the exact PRN command stays open after ledger
  /// activation and moves stock there. The server never creates PRN
  /// occurrences itself, so without it an as-needed dose recorded on an
  /// active ledger has nowhere to go and waits.
  final bool ledgerPrn;

  /// Medication detail contract 1: the reviewed amount per use, package
  /// strength, form and reviewed flag travel with the pill. Against a server
  /// without it those stay on the device that reviewed them, so this build
  /// holds the review rather than sending a body the server would reject.
  final bool medicationDetails;

  /// Medication shape contract 1: the silhouette a person picked for a
  /// medication travels with the pill. Against a server without it the pick
  /// stays on this device, and the request leaves it out rather than being
  /// refused as an unknown field.
  final bool medicationShapes;

  /// Medication extras contract 1: as-needed limits, an expiry date and the
  /// prescriber and pharmacy contacts travel with the pill. Against a server
  /// without it they stay on this device and the request leaves them out.
  final bool medicationDetailsExtra;

  /// Medication photo contract 1: one cleaned JPEG per medication, stored and
  /// shared through `/pills/:id/photo`, with its hash on the pill. Against a
  /// server without it the photo stays on this device and is never sent.
  final bool medicationPhoto;

  /// Whether the server stores exact fractional stock and a stock unit
  /// (`contracts.fractionalStock: 1`). A server without it (1.2.0) stays fully
  /// usable; the app then keeps the plain whole-count rules.
  final bool fractionalStock;

  /// Whether the server stores and shares the name of who recorded a dose
  /// (`contracts.medicationRecordedBy: 1`). A server without it stays fully
  /// usable; the app then keeps the name on this device only.
  final bool recordedBy;

  /// Whether the server keeps the settings that follow the account
  /// (`contracts.accountSettings: 1`). A server without it stays fully usable;
  /// every setting then stays on its device and nothing is queued.
  final bool accountSettings;

  /// Whether the account can change its email, export its data and be deleted
  /// from the app (`contracts.accountSelfService: 1`). A server without it
  /// stays fully usable; those actions are then not offered.
  final bool accountSelfService;

  /// Additive: how a changed email is applied (see [EmailChangeMode]).
  final EmailChangeMode emailChange;

  /// Additive: whether this server can email reset links.
  final EmailResetAvailability emailReset;

  /// Additive: the app build of the newest published release and its page,
  /// reported by a server that ran its daily update check. Anything that does
  /// not validate parses to null and never makes the snapshot unavailable.
  final int? latestClientBuild;
  final String? latestReleaseUrl;

  List<MedicationSyncStep> get medicationSyncOrder => [
    // This remains first even if the device returns after server activation:
    // split writes are reconciled permanently before ordinary medication work.
    MedicationSyncStep.permanentReconciliation,
    medicationLedgerActive
        ? MedicationSyncStep.activeLedger
        : MedicationSyncStep.inactiveBridge,
  ];
}

/// Which sync transport a capability snapshot permits.
enum SyncProtocol { legacyCompatibility, componentSync, blocked }

/// Stable safe code for "this app is too old for the server". The sync
/// diagnostics already map it to the update-required headline.
const String clientUpgradeRequiredCode = 'CLIENT_UPGRADE_REQUIRED';

/// The `medicationCommands` versions this build can run against. 2 is the
/// ledger without recorded misses, 3 adds `miss`/`missed`.
const Set<int> _acceptedMedicationCommands = {2, 3};

/// Contract versions this build speaks (the newest it understands). A server
/// advertising a higher integer for any of these has moved past this app, so
/// the user must update the app; a lower or missing value means the server
/// must be updated instead.
const Map<String, int> _requiredContracts = {
  'componentSync': 2,
  'fractionalStock': 1,
  'medicationRecordedBy': 1,
  'accountSettings': 1,
  'accountSelfService': 1,
  'legacySplitReconciliation': 1,
  'medicationBridgeCommands': 1,
  'medicationBridgeSync': 1,
  'medicationCommands': 3,
  'medicationDetails': 1,
  'medicationShapes': 1,
  'medicationDetailsExtra': 1,
  'medicationPhoto': 1,
};

class CapabilitySnapshot {
  const CapabilitySnapshot._(
    this.availability,
    this.capabilities, {
    this.clientUpdateRequired = false,
  });

  const CapabilitySnapshot.absent()
    : this._(CapabilityAvailability.absent, null);
  const CapabilitySnapshot.unavailable()
    : this._(CapabilityAvailability.unavailable, null);

  /// The server's contracts moved past this app: blocked, with an explicit
  /// "update the app" code instead of a silent unavailable state.
  const CapabilitySnapshot.updateRequired()
    : this._(
        CapabilityAvailability.unavailable,
        null,
        clientUpdateRequired: true,
      );
  const CapabilitySnapshot.localAccessUnavailable()
    : this._(CapabilityAvailability.localAccessUnavailable, null);
  const CapabilitySnapshot.present(ServerCapabilities capabilities)
    : this._(CapabilityAvailability.present, capabilities);

  final CapabilityAvailability availability;
  final ServerCapabilities? capabilities;

  /// True when the server needs a newer app than this build (contract bump or
  /// `minimumClientBuild` above [simpastilClientBuild]).
  final bool clientUpdateRequired;

  bool get _belowMinimumClientBuild =>
      availability == CapabilityAvailability.present &&
      capabilities!.minimumClientBuild > simpastilClientBuild;

  /// The single place that chooses which transport family may run. Network
  /// failure is deliberately not equivalent to an old-server 404, so only an
  /// `absent` snapshot selects the un-journaled compatibility path.
  SyncProtocol get protocol => _belowMinimumClientBuild
      ? SyncProtocol.blocked
      : switch (availability) {
          CapabilityAvailability.absent => SyncProtocol.legacyCompatibility,
          CapabilityAvailability.unavailable ||
          CapabilityAvailability.localAccessUnavailable => SyncProtocol.blocked,
          CapabilityAvailability.present => SyncProtocol.componentSync,
        };

  /// Stable safe code explaining why [SyncProtocol.blocked] holds work.
  String? get blockedStableCode =>
      clientUpdateRequired || _belowMinimumClientBuild
      ? clientUpgradeRequiredCode
      : switch (availability) {
          CapabilityAvailability.localAccessUnavailable =>
            'CLIENT_CONNECTION_ACCESS_UNAVAILABLE',
          CapabilityAvailability.unavailable =>
            'SERVER_CAPABILITIES_UNAVAILABLE',
          _ => null,
        };

  List<MedicationSyncStep> get medicationSyncOrder => switch (availability) {
    CapabilityAvailability.absent => const [MedicationSyncStep.legacySplit],
    CapabilityAvailability.unavailable => const [],
    CapabilityAvailability.localAccessUnavailable => const [],
    CapabilityAvailability.present => capabilities!.medicationSyncOrder,
  };
}

int? _validLatestBuild(Object? value) =>
    value is int && value > 0 ? value : null;

String? _validReleaseUrl(Object? value) =>
    value is String && isValidReleaseUrl(value) ? value : null;

class CapabilitiesClient {
  CapabilitiesClient(this._dio);

  final Dio _dio;
  CapabilitySnapshot? _current;

  CapabilitySnapshot? get current => _current;

  Future<CapabilitySnapshot> refresh() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>('/capabilities');
      final body = response.data;
      final contracts = body?['contracts'];
      if (body != null &&
          body['apiNamespace'] == 'v1' &&
          contracts is Map<String, dynamic> &&
          _requiredContracts.entries.any((contract) {
            final advertised = contracts[contract.key];
            return advertised is int && advertised > contract.value;
          })) {
        return _current = const CapabilitySnapshot.updateRequired();
      }
      if (body == null ||
          body['apiNamespace'] != 'v1' ||
          contracts is! Map<String, dynamic> ||
          contracts['componentSync'] != 2 ||
          contracts['legacySplitReconciliation'] != 1 ||
          contracts['medicationBridgeCommands'] != 1 ||
          contracts['medicationBridgeSync'] != 1 ||
          !_acceptedMedicationCommands.contains(
            contracts['medicationCommands'],
          ) ||
          body['medicationLedgerActive'] is! bool ||
          body['minimumClientBuild'] is! int ||
          body['minimumClientBuild'] < 1 ||
          body['serverRelease'] is! String ||
          (body['serverRelease'] as String).isEmpty) {
        return _current = const CapabilitySnapshot.unavailable();
      }
      return _current = CapabilitySnapshot.present(
        ServerCapabilities(
          medicationLedgerActive: body['medicationLedgerActive'] as bool,
          minimumClientBuild: body['minimumClientBuild'] as int,
          serverRelease: body['serverRelease'] as String,
          bridgeUndo: body['bridgeUndo'] == true,
          recordedMiss:
              contracts['medicationCommands'] == 3 &&
              body['recordedMiss'] == true,
          scheduleWindows: body['scheduleWindows'] == true,
          movedHistory: body['movedHistory'] == true,
          ledgerPrn:
              body['ledgerPrn'] == true &&
              contracts['medicationBridgePrnCommands'] == 1,
          medicationDetails: contracts['medicationDetails'] == 1,
          medicationShapes: contracts['medicationShapes'] == 1,
          medicationDetailsExtra: contracts['medicationDetailsExtra'] == 1,
          medicationPhoto: contracts['medicationPhoto'] == 1,
          fractionalStock: contracts['fractionalStock'] == 1,
          recordedBy: contracts['medicationRecordedBy'] == 1,
          accountSettings: contracts['accountSettings'] == 1,
          accountSelfService: contracts['accountSelfService'] == 1,
          emailChange: parseEmailChange(body['emailChange']),
          emailReset: parseEmailReset(body['emailReset']),
          latestClientBuild: _validLatestBuild(body['latestClientBuild']),
          latestReleaseUrl: _validReleaseUrl(body['latestReleaseUrl']),
          medicationBridgePrnCommands:
              contracts['medicationBridgePrnCommands'] == 1 &&
              contracts['medicationBridgePrnSync'] == 5,
          medicationBridgeContractVersion:
              contracts['medicationBridgePrnCommands'] == 1 &&
                  contracts['medicationBridgePrnSync'] == 5
              ? 5
              : contracts['medicationBridgeOccurrenceSync'] == 4
              ? 4
              : contracts['medicationBridgeAncestorSync'] == 3
              ? 3
              : contracts['medicationBridgeParentSync'] == 2
              ? 2
              : 1,
        ),
      );
    } on DioException catch (error) {
      // A changed server key is not "capabilities unavailable": sync must stop
      // and the person must see why.
      if (pinMismatchOf(error) != null) rethrow;
      if (error.response?.statusCode == 401 ||
          error.response?.statusCode == 403) {
        rethrow;
      }
      final snapshot = error.response?.statusCode == 404
          ? const CapabilitySnapshot.absent()
          : error.type == DioExceptionType.cancel &&
                error.message == ScopedAuthInterceptor.accessUnavailableMessage
          ? const CapabilitySnapshot.localAccessUnavailable()
          : const CapabilitySnapshot.unavailable();
      return _current = snapshot;
    } on Object {
      return _current = const CapabilitySnapshot.unavailable();
    }
  }
}

final capabilitiesClientProvider = Provider<CapabilitiesClient>((ref) {
  return CapabilitiesClient(ref.watch(apiClientProvider).dio);
});

/// What the sign-in screens may promise about password reset. This asks
/// `/capabilities` directly and checks nothing else, so an old or unreachable
/// server (or one this build cannot run against) still reads as [unknown]
/// rather than blocking the screen.
final emailResetAvailabilityProvider =
    FutureProvider.autoDispose<EmailResetAvailability>((ref) async {
      try {
        final response = await ref
            .watch(apiClientProvider)
            .dio
            .get<Map<String, dynamic>>('/capabilities');
        return parseEmailReset(response.data?['emailReset']);
      } on Object {
        return EmailResetAvailability.unknown;
      }
    });
