import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../core/medication/care_day.dart';
import '../../core/medication/care_recording.dart';
import '../../core/medication/dose_selection_controller.dart';
import '../../core/medication/medication_command.dart';
import '../../core/medication/routine_definition.dart';
import '../../core/workspace/workspace_provider.dart';
import '../../l10n/app_localizations.dart';
import '../../shared/layouts/window_size.dart';
import '../../shared/widgets/care_state.dart';
import '../../shared/motion/app_motion.dart';
import '../../shared/widgets/durable_save_feedback.dart';
import 'care_record_form.dart';
import 'today_layout/today_layout.dart';

/// The review freezes exact entry IDs and versions. Live list arrival/reorder
/// cannot silently alter the selected care or its prepared retry commands.
class SelectedDosesReview extends ConsumerStatefulWidget {
  const SelectedDosesReview({
    super.key,
    required this.day,
    required this.service,
    this.personId,
  });
  final CareDay day;
  final CareRecordingService service;
  final String? personId;
  @override
  ConsumerState<SelectedDosesReview> createState() =>
      _SelectedDosesReviewState();
}

class _SelectedDosesReviewState extends ConsumerState<SelectedDosesReview> {
  late final List<CareDayEntry> _entries;
  late final DateTime _openedAt;
  final _ids = <String>{};
  String? _person;
  DoseSelectionController? _controller;
  DoseSelectionResult? _result;
  DateTime? _reviewedAt;
  bool _unknownTime = false, _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _openedAt = DateTime.now().toUtc();
    _entries = List.unmodifiable(
      widget.day.entries.where(
        (e) =>
            e.occurrence.expected &&
            e.canRecord &&
            e.occurrence.state == 'pending',
      ),
    );
    _person = widget.personId;
    _unknownTime = widget.day.localDate != routineDateKey(DateTime.now());
  }

  Future<void> _review() async {
    if (_busy ||
        _person == null ||
        _ids.isEmpty ||
        !careServiceIsCurrent(ref, widget.service)) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final time = _unknownTime ? null : DateTime.now().toUtc();
      final controller = DoseSelectionController(
        service: widget.service,
        personId: _person!,
        localDate: widget.day.localDate,
      );
      for (final row in _entries.where((e) => _ids.contains(e.occurrence.id))) {
        controller.select(
          await widget.service.prepare(
            personId: row.person.id,
            occurrenceId: row.occurrence.id,
            expectedStateVersion: row.occurrence.stateVersion,
            action: MedicationAction.take,
            amount: row.plannedAmount,
            actualAt: time,
            actualTimeKnown: time != null,
          ),
        );
      }
      if (!mounted || !careServiceIsCurrent(ref, widget.service)) return;
      setState(() {
        _controller = controller;
        _reviewedAt = time;
      });
    } on Object {
      if (mounted && careServiceIsCurrent(ref, widget.service)) {
        setState(() => _error = AppLocalizations.of(context).t08_recordError);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _commit() async {
    if (_busy || !careServiceIsCurrent(ref, widget.service)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await _controller!.commit(
      reviewedLocalDate: widget.day.localDate,
    );
    if (!mounted) return;
    setState(() {
      _result = result;
      _busy = false;
    });
  }

  void _editReview() => setState(() {
    _controller = null;
    _reviewedAt = null;
    _error = null;
  });

  void _remove(CareDayEntry row) {
    if (_busy || _result != null) return;
    setState(() {
      _controller!.deselect(row.occurrence.id);
      _ids.remove(row.occurrence.id);
      if (_ids.isEmpty) {
        _controller = null;
        _reviewedAt = null;
      }
    });
  }

  Future<void> _choosePerson(Map<String, String> people) async {
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final person in people.entries)
                ListTile(
                  title: Text(person.value),
                  trailing: person.key == _person
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () {
                    setState(() {
                      _person = person.key;
                      _ids.clear();
                    });
                    Navigator.of(sheetContext).pop();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    ref.watch(workspaceContextProvider);
    if (!careServiceIsCurrent(ref, widget.service)) {
      return Scaffold(
        appBar: AppBar(),
        body: CareState(title: l.t08_unavailable, body: l.t08_unavailableBody),
      );
    }
    final people = {for (final e in _entries) e.person.id: e.person.name};
    final reviewed = _controller != null;
    final rows = _entries
        .where(
          (e) => reviewed
              ? _ids.contains(e.occurrence.id)
              : e.person.id == _person,
        )
        .toList();
    final person = people[_person];
    final large = MediaQuery.textScalerOf(context).scale(16) > 22;
    final locale = Localizations.localeOf(context).toString();
    final day = widget.day.localDate == routineDateKey(DateTime.now())
        ? l.t08_today
        : DateFormat.yMMMMd(
            locale,
          ).format(parseRoutineDate(widget.day.localDate));
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        toolbarHeight: large ? 96 : kToolbarHeight,
        title: Text(
          reviewed ? l.r14_reviewDoses : l.t10_select,
          maxLines: 2,
          textAlign: TextAlign.center,
        ),
        leadingWidth: reviewed || large ? null : 92,
        leading: reviewed || large
            ? null
            : TextButton(
                onPressed: _busy
                    ? null
                    : () => Navigator.of(context).maybePop(),
                child: Text(l.shared_cancel),
              ),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1),
        ),
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final content = _content(
              context,
              l,
              people,
              rows,
              person,
              day,
              reviewed,
              large,
            );
            final footer = _footer(context, l, person, reviewed);
            // Keep ordinary review actions anchored. At larger text or a
            // short viewport, let the complete review and controls scroll.
            final scrollAll = large || constraints.maxHeight < 520;
            return CareTransition(
              child: SizedBox(
                key: ValueKey(
                  !reviewed
                      ? 'select'
                      : _result == null
                      ? 'review'
                      : 'result/${_result!.saved.length}',
                ),
                height: constraints.maxHeight,
                // The scroll views span the pane, so the side margins scroll;
                // the content and the anchored footer keep the page column.
                child: scrollAll
                    ? ContentScrollView(
                        child: Column(children: [content, footer]),
                      )
                    : Column(
                        children: [
                          Expanded(child: ContentScrollView(child: content)),
                          ContentFrame(child: footer),
                        ],
                      ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _content(
    BuildContext context,
    AppLocalizations l,
    Map<String, String> people,
    List<CareDayEntry> rows,
    String? person,
    String day,
    bool reviewed,
    bool large,
  ) {
    final theme = Theme.of(context);
    final heading = Text(
      person == null
          ? l.t10_choosePerson
          : reviewed
          ? person
          : l.r14_personDay(person, day),
      style: theme.textTheme.headlineLarge?.copyWith(
        fontSize: 30,
        fontWeight: FontWeight.w700,
        height: 1.15,
      ),
    );
    final prior = rows.where((row) => !_later(row)).toList();
    final later = rows.where(_later).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!reviewed && (people.length > 1 || person == null))
            Semantics(
              button: true,
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: _busy ? null : () => _choosePerson(people),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(child: heading),
                      const SizedBox(width: 8),
                      const Icon(Icons.expand_more),
                    ],
                  ),
                ),
              ),
            )
          else
            heading,
          const SizedBox(height: 8),
          Text(
            reviewed ? l.r14_selectedDoses(_ids.length) : l.r14_chooseDoses,
            style: theme.textTheme.titleMedium?.copyWith(
              fontSize: 18,
              fontWeight: FontWeight.w400,
            ),
          ),
          const SizedBox(height: 20),
          if (_result case final result?) ...[
            Semantics(
              liveRegion: true,
              child: Text(
                result.isComplete ? l.t10_allSaved : l.t10_partial,
                style: theme.textTheme.titleLarge,
              ),
            ),
            const SizedBox(height: 20),
          ],
          if (reviewed) ...[
            Text(
              l.r14_plannedFor(day),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w400,
              ),
            ),
            const Divider(height: 24),
            for (final row in rows) _reviewRow(context, l, row, large),
            const SizedBox(height: 16),
            _timeReview(context, l, large),
          ] else if (person != null) ...[
            Text(
              l.r14_unrecordedCount(rows.length),
              style: theme.textTheme.titleLarge?.copyWith(fontSize: 20),
            ),
            const SizedBox(height: 12),
            if (prior.isNotEmpty) _selectionGroup(context, l, prior, large),
            if (later.isNotEmpty) ...[
              if (prior.isNotEmpty) ...[
                const SizedBox(height: 24),
                Text(l.r14_later, style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
              ],
              _selectionGroup(context, l, later, large),
            ],
            const SizedBox(height: 16),
            _timeChoice(context, l),
          ],
          const SizedBox(height: 16),
          Text(l.t10_selectionHint, style: theme.textTheme.bodySmall),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Semantics(
              liveRegion: true,
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          ],
        ],
      ),
    );
  }

  bool _later(CareDayEntry row) =>
      row.occurrence.plannedAt?.isAfter(_openedAt) ?? false;

  String _time(CareDayEntry row, AppLocalizations l) =>
      plannedTimeLabel(context, row.occurrence);

  Widget _selectionGroup(
    BuildContext context,
    AppLocalizations l,
    List<CareDayEntry> rows,
    bool large,
  ) => ClipRRect(
    borderRadius: BorderRadius.circular(8),
    child: Column(
      children: [
        for (var index = 0; index < rows.length; index++) ...[
          if (index > 0) const Divider(height: 1, indent: 8, endIndent: 8),
          _selectionRow(context, l, rows[index], large),
        ],
      ],
    ),
  );

  Widget _selectionRow(
    BuildContext context,
    AppLocalizations l,
    CareDayEntry row,
    bool large,
  ) {
    final theme = Theme.of(context);
    final selected = _ids.contains(row.occurrence.id);
    final foreground = selected
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurface;
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          row.snapshot.pillName,
          style: theme.textTheme.titleMedium?.copyWith(color: foreground),
        ),
        const SizedBox(height: 3),
        Text(
          careAmountLabel(l, row.plannedAmount),
          style: theme.textTheme.bodyMedium?.copyWith(color: foreground),
        ),
        const SizedBox(height: 3),
        Text(
          _later(row) ? l.t08_later : l.t08_unrecorded,
          style: theme.textTheme.bodySmall?.copyWith(color: foreground),
        ),
      ],
    );
    final time = Text(
      _time(row, l),
      style: theme.textTheme.titleLarge?.copyWith(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: foreground,
      ),
    );
    return Material(
      color: selected
          ? theme.colorScheme.primaryContainer
          : theme.colorScheme.surface,
      child: CheckboxListTile(
        key: ValueKey('select-${row.occurrence.id}'),
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        title: large
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [time, const SizedBox(height: 6), details],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 70, child: time),
                  const SizedBox(width: 10),
                  Expanded(child: details),
                ],
              ),
        value: selected,
        onChanged: _busy
            ? null
            : (value) => setState(() {
                if (value == true) {
                  _ids.add(row.occurrence.id);
                } else {
                  _ids.remove(row.occurrence.id);
                }
              }),
      ),
    );
  }

  Widget _reviewRow(
    BuildContext context,
    AppLocalizations l,
    CareDayEntry row,
    bool large,
  ) {
    final theme = Theme.of(context);
    final remove = TextButton(
      key: ValueKey('remove-${row.occurrence.id}'),
      onPressed: _busy ? null : () => _remove(row),
      child: Text(l.r14_remove),
    );
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          row.snapshot.pillName,
          style: theme.textTheme.titleMedium?.copyWith(fontSize: 18),
        ),
        const SizedBox(height: 4),
        Text(
          careAmountLabel(l, row.plannedAmount),
          style: theme.textTheme.bodyMedium,
        ),
        if (_result?.saved[row.occurrence.id] case final saved?)
          DurableSaveFeedback(label: careSharingLabel(l, saved.sharing)),
        if (_result?.failed.containsKey(row.occurrence.id) == true)
          Text(
            l.t10_retryItem,
            style: TextStyle(color: theme.colorScheme.error),
          ),
      ],
    );
    final time = Text(
      _time(row, l),
      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (large) ...[
          time,
          const SizedBox(height: 8),
          details,
          if (_result == null)
            Align(alignment: Alignment.centerRight, child: remove),
        ] else
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 60, child: time),
              const SizedBox(width: 12),
              Expanded(child: details),
              if (_result == null) remove,
            ],
          ),
        const Divider(height: 24),
      ],
    );
  }

  Widget _timeChoice(BuildContext context, AppLocalizations l) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(l.t10_actual, style: Theme.of(context).textTheme.titleMedium),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(l.t08_unknownTime),
        value: _unknownTime,
        onChanged: _busy
            ? null
            : (value) => setState(() => _unknownTime = value),
      ),
      if (!_unknownTime) Text(l.t08_takenNow),
    ],
  );

  Widget _timeReview(BuildContext context, AppLocalizations l, bool large) {
    final theme = Theme.of(context);
    final time = Text(
      careInstantLabel(context, _reviewedAt),
      style: theme.textTheme.titleMedium,
    );
    final change = _result == null
        ? TextButton(
            onPressed: _busy ? null : _editReview,
            child: Text(l.shared_change),
          )
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l.t10_actual,
          style: theme.textTheme.titleLarge?.copyWith(fontSize: 20),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border.all(color: theme.colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(8),
          ),
          child: large
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    time,
                    if (change != null)
                      Align(alignment: Alignment.centerRight, child: change),
                  ],
                )
              : Row(
                  children: [
                    const Icon(Icons.access_time),
                    const SizedBox(width: 12),
                    Expanded(child: time),
                    ?change,
                  ],
                ),
        ),
        const SizedBox(height: 8),
        Text(l.r14_sameTime, style: theme.textTheme.bodySmall),
        if (_reviewedAt != null)
          Text(l.t10_timeHere, style: theme.textTheme.bodySmall),
      ],
    );
  }

  Widget _footer(
    BuildContext context,
    AppLocalizations l,
    String? person,
    bool reviewed,
  ) {
    final theme = Theme.of(context);
    final result = _result;
    final buttonStyle = FilledButton.styleFrom(
      minimumSize: const Size.fromHeight(52),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      textStyle: theme.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w700,
      ),
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            !reviewed
                ? l.r14_selectionCount(_ids.length)
                : result != null
                ? l.r14_savedCount(result.saved.length, _ids.length)
                : l.r14_recordFor(person ?? l.t10_unknownPerson),
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          if (!reviewed) ...[
            FilledButton(
              key: const ValueKey('selection-review'),
              style: buttonStyle,
              onPressed: _busy || _ids.isEmpty ? null : _review,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _busy ? l.shared_loading : l.r14_reviewCount(_ids.length),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.arrow_forward),
                ],
              ),
            ),
            TextButton(
              onPressed: _busy || _ids.isEmpty
                  ? null
                  : () => setState(_ids.clear),
              child: Text(l.r14_clearSelection),
            ),
          ] else ...[
            if (result == null || !result.isComplete)
              FilledButton(
                key: const ValueKey('selection-record'),
                style: buttonStyle,
                onPressed: _busy ? null : _commit,
                child: Text(
                  _busy
                      ? l.t08_saving
                      : result == null
                      ? l.r14_recordCount(_ids.length)
                      : l.t10_retryRemaining,
                  textAlign: TextAlign.center,
                ),
              ),
            if (result == null)
              TextButton(
                onPressed: _busy ? null : _editReview,
                child: Text(l.t10_edit),
              ),
            if (result != null)
              TextButton(
                onPressed: _busy
                    ? null
                    : () => Navigator.of(context).pop(result),
                child: Text(l.t10_done),
              ),
          ],
        ],
      ),
    );
  }
}
