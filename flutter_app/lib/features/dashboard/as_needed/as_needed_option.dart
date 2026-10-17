import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../../core/db/database.dart'
    show LocalRoutine, Pill, Profile, Schedule;
import '../../../core/medication/care_provider.dart';
import '../../../core/medication/care_recording.dart';
import '../../../core/medication/medication_amount.dart';
import '../../../core/medication/medication_detail_provider.dart';
import '../../../core/medication/medication_detail_repository.dart';
import '../../../core/medication/routine_definition.dart';
import '../../../core/workspace/workspace_provider.dart';
import '../../pills/presentation/medication_identity.dart';

/// Why an as-needed medication cannot be recorded until it is reviewed.
enum AsNeededReview { ambiguous, routine, zone }

/// One as-needed medication that can be recorded from Today, whether it lives
/// in a local workspace (a PRN routine) or a connected one (a PRN sentinel).
///
/// Moves the prepare, sentinel and review rules that used to live in Focus
/// deck's `_AsNeeded` and `_ConnectedAsNeeded` unchanged.
class AsNeededOption {
  AsNeededOption.local({
    required this.person,
    required this.pill,
    required LocalRoutine routine,
    required RoutineDefinition definition,
    required this.shape,
    required this.form,
  }) : // The fields are nullable (connected options have neither).
       // ignore: prefer_initializing_formals
       routine = routine,
       // ignore: prefer_initializing_formals
       definition = definition,
       usualAmount = definition.amount,
       sentinel = null,
       sentinelMissing = false,
       review = null;

  const AsNeededOption.connected({
    required this.person,
    required this.pill,
    required this.usualAmount,
    required this.shape,
    required this.form,
    required this.sentinel,
    required this.sentinelMissing,
    required this.review,
  }) : routine = null,
       definition = null;

  final Profile person;
  final Pill pill;
  final MedicationAmount usualAmount;
  final MedicationShape shape;

  /// The medication's form as written ("Tablet", "Syrup"...), if any.
  final String? form;

  /// Set when recording must wait for a review in Settings.
  final AsNeededReview? review;

  final LocalRoutine? routine;
  final RoutineDefinition? definition;
  final Schedule? sentinel;

  /// Connected only: no sentinel exists yet, so recording creates one. It
  /// carries no history to review.
  final bool sentinelMissing;

  String get pillId => pill.id;
  bool get isLocal => routine != null;
  bool get needsReview => review != null;

  /// The zone that decides which day a recorded time belongs to.
  tz.Location get zone {
    try {
      if (definition != null) return tz.getLocation(definition!.timeZone);
      final name = sentinel?.timeZone;
      if (name != null) return tz.getLocation(name);
    } on Object {
      // Falls through to the device zone.
    }
    return tz.local;
  }

  /// The reviewed day a dose at [at] belongs to; the viewed [localDate] when
  /// the time is not known.
  String reviewedDate(String localDate, DateTime? at) =>
      at == null ? localDate : routineDateKey(tz.TZDateTime.from(at, zone));

  /// Prepares one PRN dose. [createSentinel] is only called for a connected
  /// option with no sentinel yet and must return the created schedule, or null
  /// when it could not be saved (then [AsNeededSaveFailed] is thrown).
  Future<PreparedCareIntent> prepare(
    CareRecordingService service, {
    required String localDate,
    required MedicationAmount amount,
    required DateTime? at,
    String? note,
    Future<Schedule?> Function()? createSentinel,
  }) async {
    if (isLocal) {
      return service.preparePrn(
        personId: person.id,
        pillId: pill.id,
        expectedRoutineRevision: routine!.revision,
        reviewedLocalDate: reviewedDate(localDate, at),
        amount: amount,
        actualAt: at,
        actualTimeKnown: at != null,
        note: note,
      );
    }
    var use = sentinel;
    if (use == null) {
      use = createSentinel == null ? null : await createSentinel();
      if (use == null) throw const AsNeededSaveFailed();
    }
    final date = _dateIn(use, localDate, at);
    return service.prepareConnectedPrn(
      personId: person.id,
      pillId: pill.id,
      sentinelId: use.id,
      reviewedLocalDate: date,
      amount: amount,
      actualAt: at,
      actualTimeKnown: at != null,
      note: note,
    );
  }

  String _dateIn(Schedule use, String localDate, DateTime? at) {
    if (at == null) return localDate;
    final name = use.timeZone;
    tz.Location zone;
    try {
      zone = name == null ? tz.local : tz.getLocation(name);
    } on Object {
      zone = tz.local;
    }
    return routineDateKey(tz.TZDateTime.from(at, zone));
  }
}

/// A missing sentinel could not be created.
class AsNeededSaveFailed implements Exception {
  const AsNeededSaveFailed();
}

/// Review reason for a connected medication's sentinels; null when it can be
/// recorded (including when none exists yet).
AsNeededReview? connectedReview(List<Schedule> all) {
  if (all.isEmpty) return null;
  final sentinels = all
      .where((s) => !s.isDeleted && s.isActive && s.frequency == 'prn')
      .toList();
  if (sentinels.length > 1) return AsNeededReview.ambiguous;
  if (sentinels.isEmpty) return AsNeededReview.routine;
  final sentinel = sentinels.single;
  if (sentinel.timeZoneStatus != 'known' || sentinel.timeZone == null) {
    return AsNeededReview.zone;
  }
  try {
    tz.getLocation(sentinel.timeZone!);
  } on Object {
    return AsNeededReview.zone;
  }
  return null;
}

/// The as-needed medications for the viewed day, or an error when the
/// connected medication list cannot be read.
final asNeededOptionsProvider = Provider.autoDispose
    .family<AsyncValue<List<AsNeededOption>>, CareDayRequest>((ref, request) {
      final workspace = ref.watch(workspaceContextProvider).asData?.value;
      final list = ref.watch(medicationListProvider);
      String? formOf(String pillId) {
        for (final d in list.asData?.value ?? const <MedicationCareDetail>[]) {
          if (d.pill.id == pillId) return d.review.form;
        }
        return null;
      }

      if (workspace == null) return const AsyncLoading();
      if (workspace.isLocal) {
        final day = ref.watch(careDayProvider(request));
        if (day.hasError) {
          return AsyncError(day.error!, day.stackTrace ?? StackTrace.empty);
        }
        final value = day.asData?.value;
        if (value == null) return const AsyncLoading();
        return AsyncData([
          for (final o in value.prn)
            AsNeededOption.local(
              person: o.person,
              pill: o.pill,
              routine: o.routine,
              definition: o.definition,
              shape: medicationShapeOf(formOf(o.pill.id)),
              form: formOf(o.pill.id),
            ),
        ]);
      }
      if (list.hasError) {
        return AsyncError(list.error!, list.stackTrace ?? StackTrace.empty);
      }
      final details = list.asData?.value;
      if (details == null) return const AsyncLoading();
      return AsyncData([
        for (final d in details)
          if (d.pill.isPrn &&
              (request.personId == null || d.person.id == request.personId))
            _connected(d),
      ]);
    });

AsNeededOption _connected(MedicationCareDetail d) {
  final sentinels = d.schedules
      .where((s) => !s.isDeleted && s.isActive && s.frequency == 'prn')
      .toList();
  return AsNeededOption.connected(
    person: d.person,
    pill: d.pill,
    usualAmount: d.review.amount,
    shape: medicationShapeOf(d.review.form),
    form: d.review.form,
    sentinel: sentinels.length == 1 ? sentinels.single : null,
    sentinelMissing: d.schedules.isEmpty,
    review: connectedReview(d.schedules),
  );
}
