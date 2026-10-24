import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database.dart';
import '../../../core/medication/care_day.dart';
import '../../../core/medication/care_provider.dart';
import '../../../core/medication/care_recording.dart';
import '../../../core/medication/medication_amount.dart';
import '../../../core/medication/occurrence_materializer.dart';
import '../../../core/medication/routine_definition.dart';
import '../../../core/storage/layout_family_preference.dart';
import '../../../core/utils/app_clock.dart';
import '../../../l10n/app_localizations.dart';
import '../../profiles/profile_provider.dart';
import '../focus_deck.dart';
import 'today_layout.dart';
import 'today_layouts.dart';

/// Layout names, in words the chooser and Settings share.
String layoutFamilyName(AppLocalizations l, LayoutFamily family) =>
    switch (family) {
      LayoutFamily.focusDeck => l.t15_focusDeck,
      LayoutFamily.timeline => l.lay_timeline,
      LayoutFamily.peopleLanes => l.lay_peopleLanes,
      LayoutFamily.dayPlanner => l.lay_dayPlanner,
      LayoutFamily.actionInbox => l.lay_actionInbox,
      LayoutFamily.dailyJournal => l.lay_dailyJournal,
    };

String layoutFamilyDescription(AppLocalizations l, LayoutFamily family) =>
    switch (family) {
      LayoutFamily.focusDeck => l.lay_focusDeckBody,
      LayoutFamily.timeline => l.lay_timelineBody,
      LayoutFamily.peopleLanes => l.lay_peopleLanesBody,
      LayoutFamily.dayPlanner => l.lay_dayPlannerBody,
      LayoutFamily.actionInbox => l.lay_actionInboxBody,
      LayoutFamily.dailyJournal => l.lay_dailyJournalBody,
    };

IconData layoutFamilyIcon(LayoutFamily family) => switch (family) {
  LayoutFamily.focusDeck => Icons.view_carousel_outlined,
  LayoutFamily.timeline => Icons.timeline,
  LayoutFamily.peopleLanes => Icons.view_week_outlined,
  LayoutFamily.dayPlanner => Icons.calendar_view_day_outlined,
  LayoutFamily.actionInbox => Icons.inbox_outlined,
  LayoutFamily.dailyJournal => Icons.menu_book_outlined,
};

/// A fictional example day for layout previews, in [zone]: two people, three
/// doses at 08:00 (taken), 13:00 and 20:00, on the date of [now]. Nothing here
/// is read from or written to care storage. Previews show it when the person
/// has nothing planned today; shared by the chooser and layout tests.
/// The as-needed dose recorded the same day is [layoutPreviewAsNeeded].
CareDay layoutPreviewDay(
  AppLocalizations l,
  DateTime now, {
  String zone = 'UTC',
}) {
  final date = routineDateKey(now);
  final alex = _previewPerson('preview-person-a', l.r16_examplePerson);
  final sam = _previewPerson('preview-person-b', 'Sam');
  return CareDay(
    localDate: date,
    state: CareDayState.pending,
    people: [alex, sam],
    entries: [
      _previewEntry(
        now,
        alex,
        'morning',
        l.lay_exampleMorning,
        8,
        zone,
        taken: true,
      ),
      _previewEntry(now, sam, 'noon', l.lay_exampleNoon, 13, zone),
      _previewEntry(now, alex, 'evening', l.lay_exampleEvening, 20, zone),
    ],
    prn: const [],
  );
}

/// The example as-needed dose of [layoutPreviewDay]: recorded by the first
/// person at 12:05, with no planned time, as a real as-needed dose is.
List<CareDayEntry> layoutPreviewAsNeeded(
  AppLocalizations l,
  DateTime now, {
  String zone = 'UTC',
}) {
  final alex = _previewPerson('preview-person-a', l.r16_examplePerson);
  return [
    _previewEntry(
      now,
      alex,
      'as-needed',
      l.lay_exampleAsNeeded,
      12,
      zone,
      minute: 5,
      asNeeded: true,
    ),
  ];
}

Profile _previewPerson(String id, String name) {
  final created = DateTime.utc(2026);
  return Profile(
    id: id,
    userId: 'preview',
    name: name,
    avatarEmoji: name.characters.first,
    isActive: true,
    createdAt: created,
    updatedAt: created,
    revision: 0,
    syncStatus: 'synced',
    isDeleted: false,
  );
}

CareDayEntry _previewEntry(
  DateTime now,
  Profile who,
  String id,
  String name,
  int hour,
  String zone, {
  int minute = 0,
  bool taken = false,
  bool asNeeded = false,
}) {
  final created = DateTime.utc(2026);
  final date = routineDateKey(now);
  taken = taken || asNeeded;
  final pill = Pill(
    id: 'preview-pill-$id',
    stockNeedsRecount: false,
    profileId: who.id,
    name: name,
    isPrn: asNeeded,
    createdAt: created,
    updatedAt: created,
    revision: 0,
    syncStatus: 'synced',
    isDeleted: false,
  );
  final hh = hour.toString().padLeft(2, '0');
  final mm = minute.toString().padLeft(2, '0');
  final snapshot = ScheduleSnapshotV1(
    pillName: name,
    dosage: null,
    frequency: asNeeded ? 'prn' : 'daily',
    frequencyDays: null,
    hour: hour,
    minute: minute,
    timeZone: zone,
    profileId: who.id,
    profileName: who.name,
  );
  final occurrence = MedicationOccurrence(
    id: 'preview-$id',
    userId: 'preview',
    pillId: pill.id,
    occurrenceKey: 'preview:$id',
    source: asNeeded ? 'prn' : 'scheduled',
    plannedLocalDate: date,
    plannedLocalTime: asNeeded ? null : '$hh:$mm:00',
    timeZone: zone,
    plannedAt: asNeeded
        ? null
        : DateTime(now.year, now.month, now.day, hour).toUtc(),
    expected: !asNeeded,
    snapshotVersion: 1,
    scheduleSnapshotJson: jsonEncode(snapshot.toJson()),
    provenance: 'exact',
    state: taken ? 'taken' : 'pending',
    stateVersion: taken ? 1 : 0,
    createdAt: created,
    updatedAt: created,
  );
  return CareDayEntry(
    occurrence: occurrence,
    person: who,
    pill: pill,
    snapshot: snapshot,
    plannedAmount: MedicationAmount.known('1', 'tablet'),
    sharing: CareSharingOutcome.localOnly,
    head: taken
        ? _previewEvent(
            occurrence,
            0,
            'take',
            hour,
            minute: asNeeded ? minute : 4,
          )
        : null,
  );
}

OccurrenceEvent _previewEvent(
  MedicationOccurrence row,
  int base,
  String action,
  int hour, {
  int minute = 4,
}) => OccurrenceEvent(
  id: 'preview-event-${row.id}-$base',
  userId: 'preview',
  occurrenceId: row.id,
  commandId: 'preview-command-${row.id}-$base',
  action: action,
  fromState: action == 'take' ? 'pending' : 'taken',
  toState: action == 'take' ? 'taken' : 'pending',
  actualAt: DateTime.parse(
    '${row.plannedLocalDate}T${hour.toString().padLeft(2, '0')}:'
    '${minute.toString().padLeft(2, '0')}:00Z',
  ),
  actualTimeKnown: action == 'take',
  origin: 'preview',
  baseVersion: base,
  resultVersion: base + 1,
  recordedAt: DateTime.utc(2026),
);

/// The day a layout preview shows: its doses and the as-needed doses
/// recorded that day.
typedef LayoutPreviewDay = ({CareDay day, List<CareDayEntry> asNeeded});

/// Today for the person selected on Today, filtered as Today shows it. Null
/// while it loads, when it cannot be read, or when nothing is planned today;
/// previews then show the example day.
final layoutPreviewOwnDayProvider = Provider.autoDispose<LayoutPreviewDay?>((
  ref,
) {
  final person = ref.watch(selectedProfileIdProvider);
  if (person.isLoading || person.hasError) return null;
  final loaded = ref
      .watch(
        careDayProvider(
          CareDayRequest(
            localDate: ref.watch(todayProvider),
            personId: person.value,
          ),
        ),
      )
      .asData
      ?.value;
  if (loaded == null) return null;
  final entries = [
    for (final e in loaded.entries)
      if (e.occurrence.source != 'prn' &&
          (e.occurrence.expected || e.occurrence.state != 'pending'))
        e,
  ];
  if (entries.isEmpty) return null;
  return (
    day: CareDay(
      localDate: loaded.localDate,
      state: loaded.state,
      people: loaded.people,
      entries: entries,
      prn: loaded.prn,
      nextDose: loaded.nextDose,
    ),
    asNeeded: [
      for (final e in loaded.entries)
        if (e.occurrence.source == 'prn' && e.occurrence.state == 'taken') e,
    ],
  );
});

/// Renders [family] over [own], the person's own day, or over the example
/// day when there is none. A preview only shows: nothing inside it responds
/// to touch or to a screen reader's actions, so nothing can be recorded.
class LayoutPreview extends StatefulWidget {
  const LayoutPreview({
    super.key,
    required this.family,
    required this.now,
    this.own,
    this.zone = 'UTC',
  });
  final LayoutFamily family;
  final DateTime now;
  final LayoutPreviewDay? own;

  /// The example day's time zone: the device's own, so its times read as
  /// local times with no second clock beside them.
  final String zone;

  @override
  State<LayoutPreview> createState() => _LayoutPreviewState();
}

class _LayoutPreviewState extends State<LayoutPreview> {
  // The example day is built once per language, zone and date: a fresh copy
  // on every rebuild would read to the layouts as a changed day.
  LayoutPreviewDay? _sample;
  (Locale, String, String)? _sampleKey;

  LayoutPreviewDay _example(BuildContext context) {
    final key = (
      Localizations.localeOf(context),
      widget.zone,
      routineDateKey(widget.now),
    );
    if (_sample == null || key != _sampleKey) {
      final l = AppLocalizations.of(context);
      _sampleKey = key;
      _sample = (
        day: layoutPreviewDay(l, widget.now, zone: widget.zone),
        asNeeded: layoutPreviewAsNeeded(l, widget.now, zone: widget.zone),
      );
    }
    return _sample!;
  }

  @override
  Widget build(BuildContext context) {
    final family = widget.family;
    final now = widget.now;
    final (:day, :asNeeded) = widget.own ?? _example(context);
    final builder = todayLayouts[family];
    if (builder == null) {
      return IgnorePointer(
        child: FocusDeck(day: day, asNeeded: asNeeded),
      );
    }
    final data = TodayLayoutData(
      day: day,
      asNeeded: asNeeded,
      focusedId: null,
      busyId: null,
      error: null,
      rowOf: (entry) => entry.occurrence,
      headOf: (entry) => entry.head,
      sharingOf: (entry) => entry.sharing,
      momentOf: (_) => null,
      settleToken: null,
      claimMoment: (_) => false,
      onMomentDone: (_) {},
      travelTimeOf: (_) => null,
      isToday: true,
      now: now,
      onTake: (_) {},
      onUndo: (_) {},
      onFocus: (_) {},
      onOpenDetails: (_) {},
    );
    return IgnorePointer(child: builder(context, data));
  }
}
