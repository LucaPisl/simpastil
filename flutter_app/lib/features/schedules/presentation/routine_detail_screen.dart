import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/db/database.dart';
import '../../../core/errors/app_error.dart';
import '../../../core/medication/medication_detail_provider.dart';
import '../../../core/medication/routine_definition.dart';
import '../../../core/medication/routine_repository.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/care_state.dart';
import '../../../shared/widgets/durable_save_feedback.dart';
import '../../../shared/widgets/readable_zone_picker.dart';
import '../../../shared/widgets/confirm_delete_dialog.dart';
import '../../pills/presentation/add_edit_schedule_sheet.dart';
import '../../pills/presentation/as_needed_medication_panel.dart';
import '../../pills/schedule_provider.dart';
import 'routine_editor.dart';
import 'routine_presentation.dart';

class RoutineDetailScreen extends ConsumerStatefulWidget {
  const RoutineDetailScreen({super.key, required this.pillId});
  final String pillId;
  @override
  ConsumerState<RoutineDetailScreen> createState() =>
      _RoutineDetailScreenState();
}

class _RoutineDetailScreenState extends ConsumerState<RoutineDetailScreen> {
  bool _editing = false, _saved = false;
  LocalRoutine? _editVersion;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final state = ref.watch(medicationDetailProvider(widget.pillId));
    final repoState = ref.watch(medicationDetailRepositoryProvider);
    final repository = repoState.asData?.value;
    if (state.hasError || repoState.hasError) {
      return Scaffold(
        appBar: AppBar(),
        body: CareState(
          title: l.t08_unavailable,
          body: l.t08_unavailableBody,
          actionLabel: l.shared_retry,
          action: () => ref.invalidate(medicationDetailProvider(widget.pillId)),
        ),
      );
    }
    if (state.isLoading || repoState.isLoading || repository == null) {
      return Scaffold(
        appBar: AppBar(),
        body: CareState(title: l.shared_loading, loading: true),
      );
    }
    final detail = state.requireValue;
    if (detail.pill.isPrn) {
      // An as-needed medicine has no routine or schedule to show.
      return Scaffold(
        appBar: AppBar(title: Text(detail.pill.name)),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.t08_forPerson(detail.person.name), style: text.labelLarge),
              const SizedBox(height: 16),
              AsNeededMedicationPanel(detail: detail),
            ],
          ),
        ),
      );
    }
    final latest = detail.routineVersions.lastOrNull;
    final active = detail.routineVersions
        .where((v) => !v.effectiveFrom.isAfter(DateTime.now().toUtc()))
        .lastOrNull;
    RoutineDefinition definition(LocalRoutine row) =>
        RoutineDefinition.fromJson(
          jsonDecode(row.definitionJson) as Map<String, dynamic>,
        );
    return Scaffold(
      appBar: AppBar(title: Text(l.t09_routineDetails)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.t08_forPerson(detail.person.name), style: text.labelLarge),
            const SizedBox(height: 12),
            Text(detail.pill.name, style: text.headlineMedium),
            const SizedBox(height: 24),
            if (_saved) ...[
              DurableSaveFeedback(label: l.t08_routineSaved),
              const SizedBox(height: 24),
            ],
            if (!repository.context.isLocal) ...[
              if (detail.schedules.isEmpty)
                Text(l.pills_noSchedulesYet, style: text.bodyLarge),
              for (final schedule in detail.schedules)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    TimeOfDay(
                      hour: schedule.hour,
                      minute: schedule.minute,
                    ).format(context),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(connectedSchedulePatternLabel(context, schedule)),
                      for (final line in connectedScheduleDateLines(
                        context,
                        schedule,
                      ))
                        Text(line),
                      Text(
                        schedule.isActive
                            ? l.schedules_active
                            : l.schedules_paused,
                      ),
                    ],
                  ),
                  trailing: Wrap(
                    children: [
                      IconButton(
                        tooltip: l.pills_editScheduleTooltip,
                        onPressed: () => showAddEditScheduleSheet(
                          context: context,
                          pillId: detail.pill.id,
                          pillIsPrn: detail.pill.isPrn,
                          schedule: schedule,
                        ),
                        icon: const Icon(Icons.edit_outlined),
                      ),
                      IconButton(
                        tooltip: l.pills_deleteScheduleTooltip,
                        onPressed: () async {
                          final schedules = ref.read(
                            scheduleRepositoryProvider,
                          );
                          final yes = await showConfirmDeleteDialog(
                            context,
                            title: l.pills_deleteScheduleTitle,
                            message: l.pills_deleteScheduleMessage(
                              schedule.frequency,
                              TimeOfDay(
                                hour: schedule.hour,
                                minute: schedule.minute,
                              ).format(context),
                            ),
                          );
                          if (!yes || !context.mounted) return;
                          final result = await schedules.delete(schedule.id);
                          if (!context.mounted ||
                              !identical(
                                repository,
                                ref
                                    .read(medicationDetailRepositoryProvider)
                                    .asData
                                    ?.value,
                              )) {
                            return;
                          }
                          if (result is Err) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(l.t08_saveError)),
                            );
                          }
                        },
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                ),
              FilledButton(
                onPressed: () => showAddEditScheduleSheet(
                  context: context,
                  pillId: detail.pill.id,
                  pillIsPrn: detail.pill.isPrn,
                ),
                child: Text(l.pills_addSchedule),
              ),
            ] else if (_editing || latest == null)
              RoutineEditor(
                key: ValueKey('editor-${_editVersion?.revision ?? 0}'),
                pillId: detail.pill.id,
                amount: detail.review.amount,
                initial: _editVersion == null
                    ? null
                    : definition(_editVersion!),
                routineId: _editVersion?.routineId,
                expectedRevision: _editVersion?.revision ?? 0,
                earliestBoundary: _editVersion?.effectiveFrom,
                onSaved: () {
                  if (mounted) {
                    setState(() {
                      _editing = false;
                      _saved = true;
                    });
                  }
                },
              )
            else ...[
              if (active != null) ...[
                Text(l.t09_routine, style: text.titleMedium),
                const SizedBox(height: 12),
                Text(
                  routineSummary(context, definition(active)),
                  style: text.headlineSmall,
                ),
                const SizedBox(height: 12),
                Text(readableZone(context, definition(active).timeZone)),
                if (definition(active).startDate != null)
                  Text(
                    '${l.t09_startDate} · ${routineDateLabel(context, definition(active).startDate!)}',
                  ),
                if (definition(active).endDate != null)
                  Text(
                    '${l.t09_endDate} · ${routineDateLabel(context, definition(active).endDate!)}',
                  ),
              ],
              if (active?.revision != latest.revision) ...[
                const SizedBox(height: 24),
                Text(l.t09_changesFrom, style: text.titleMedium),
                Text(
                  routineInstantLabel(
                    context,
                    latest.effectiveFrom,
                    definition(latest).timeZone,
                  ),
                ),
                Text(readableZone(context, definition(latest).timeZone)),
                const SizedBox(height: 12),
                Text(
                  routineSummary(context, definition(latest)),
                  style: text.titleLarge,
                ),
              ],
              const SizedBox(height: 24),
              Text(l.t09_preserveRecords),
              const SizedBox(height: 24),
              FilledButton(
                key: const ValueKey('edit-routine'),
                onPressed: () => setState(() {
                  _editing = true;
                  _editVersion = latest;
                  _saved = false;
                }),
                child: Text(l.t09_editRoutine),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
