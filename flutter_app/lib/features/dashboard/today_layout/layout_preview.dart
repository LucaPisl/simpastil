import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/db/database.dart';
import '../../../core/medication/care_day.dart';
import '../../../core/medication/care_recording.dart';
import '../../../core/medication/medication_amount.dart';
import '../../../core/medication/occurrence_materializer.dart';
import '../../../core/medication/routine_definition.dart';
import '../../../core/storage/layout_family_preference.dart';
import '../../../l10n/app_localizations.dart';
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

/// A fictional example day for layout previews: two people, three doses at
/// 08:00 (taken), 13:00 and 20:00, on the date of [now]. Nothing here is read
/// from or written to care storage. Shared by the chooser and layout tests.
/// The as-needed dose recorded the same day is [layoutPreviewAsNeeded].
CareDay layoutPreviewDay(AppLocalizations l, DateTime now) {
  final date = routineDateKey(now);
  final alex = _previewPerson('preview-person-a', l.r16_examplePerson);
  final sam = _previewPerson('preview-person-b', 'Sam');
  return CareDay(
    localDate: date,
    state: CareDayState.pending,
    people: [alex, sam],
    entries: [
      _previewEntry(now, alex, 'morning', l.lay_exampleMorning, 8, taken: true),
      _previewEntry(now, sam, 'noon', l.lay_exampleNoon, 13),
      _previewEntry(now, alex, 'evening', l.lay_exampleEvening, 20),
    ],
    prn: const [],
  );
}

/// The example as-needed dose of [layoutPreviewDay]: recorded by the first
/// person at 12:05, with no planned time, as a real as-needed dose is.
List<CareDayEntry> layoutPreviewAsNeeded(AppLocalizations l, DateTime now) {
  final alex = _previewPerson('preview-person-a', l.r16_examplePerson);
  return [
    _previewEntry(
      now,
      alex,
      'as-needed',
      l.lay_exampleAsNeeded,
      12,
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
  int hour, {
  int minute = 0,
  bool taken = false,
  bool asNeeded = false,
}) {
  final created = DateTime.utc(2026);
  final date = routineDateKey(now);
  taken = taken || asNeeded;
  final pill = Pill(
    id: 'preview-pill-$id',
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
    timeZone: 'UTC',
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
    timeZone: 'UTC',
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

/// Renders [family] over the example day. Alternative layouts get a local,
/// simulated [TodayLayoutData]: a tap plays the same taken moment but only
/// changes this preview. Focus deck is shown as itself and does not respond
/// to taps, because its actions always record.
class LayoutPreview extends StatefulWidget {
  const LayoutPreview({
    super.key,
    required this.family,
    required this.now,
    this.interactive = true,
  });
  final LayoutFamily family;
  final DateTime now;
  final bool interactive;

  @override
  State<LayoutPreview> createState() => _LayoutPreviewState();
}

class _LayoutPreviewState extends State<LayoutPreview> {
  CareDay? _day;
  List<CareDayEntry> _asNeeded = const [];
  Locale? _locale;
  final Map<String, ({String state, OccurrenceEvent? head, int version})>
  _rows = {};
  String? _focused;
  ReceiptMoment? _moment;
  final Set<String> _played = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final locale = Localizations.localeOf(context);
    if (_day == null || locale != _locale) {
      _locale = locale;
      final l = AppLocalizations.of(context);
      _day = layoutPreviewDay(l, widget.now);
      _asNeeded = layoutPreviewAsNeeded(l, widget.now);
      _rows.clear();
    }
  }

  MedicationOccurrence _rowOf(CareDayEntry entry) {
    final local = _rows[entry.occurrence.id];
    if (local == null) return entry.occurrence;
    return entry.occurrence.copyWith(
      state: local.state,
      stateVersion: local.version,
    );
  }

  void _set(CareDayEntry entry, {required bool undo}) {
    final row = _rowOf(entry);
    final head = _previewEvent(
      row,
      row.stateVersion,
      undo ? 'undo' : 'take',
      DateTime.now().hour,
    );
    setState(() {
      _rows[entry.occurrence.id] = (
        state: undo ? 'pending' : 'taken',
        head: undo ? null : head,
        version: row.stateVersion + 1,
      );
      _moment = (occurrenceId: entry.occurrence.id, token: head.id, undo: undo);
    });
  }

  @override
  Widget build(BuildContext context) {
    final day = _day!;
    final builder = todayLayouts[widget.family];
    if (builder == null) {
      return AbsorbPointer(
        child: FocusDeck(day: day, asNeeded: _asNeeded),
      );
    }
    final data = TodayLayoutData(
      day: day,
      asNeeded: _asNeeded,
      focusedId: _focused,
      busyId: null,
      error: null,
      rowOf: _rowOf,
      headOf: (entry) {
        final local = _rows[entry.occurrence.id];
        return local == null ? entry.head : local.head;
      },
      sharingOf: (entry) => entry.sharing,
      momentOf: (id) => _moment?.occurrenceId == id ? _moment : null,
      settleToken: null,
      claimMoment: _played.add,
      onMomentDone: (token) {
        if (mounted && _moment?.token == token) {
          setState(() => _moment = null);
        }
      },
      travelTimeOf: (_) => null,
      isToday: true,
      onTake: (entry) => _set(entry, undo: false),
      onUndo: (entry) => _set(entry, undo: true),
      onFocus: (id) => setState(() => _focused = id),
      onOpenDetails: (_) {},
    );
    final layout = builder(context, data);
    return widget.interactive ? layout : AbsorbPointer(child: layout);
  }
}
