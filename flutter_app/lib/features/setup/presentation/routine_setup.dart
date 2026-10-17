import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/medication/routine_definition.dart';
import '../../../core/medication/routine_provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/durable_save_feedback.dart';
import '../../pills/presentation/add_edit_schedule_sheet.dart';
import '../../schedules/presentation/routine_editor.dart';
import '../setup_controller.dart';
import '../setup_state.dart';

class RoutineSetup extends ConsumerStatefulWidget {
  const RoutineSetup({
    super.key,
    required this.draft,
    required this.request,
    required this.onContinue,
    required this.onSkip,
  });
  final SetupDraftData draft;
  final SetupRequest request;
  final VoidCallback onContinue;
  final VoidCallback onSkip;
  @override
  ConsumerState<RoutineSetup> createState() => _RoutineSetupState();
}

class _RoutineSetupState extends ConsumerState<RoutineSetup> {
  bool _editing = false, _saved = false, _checked = false, _connected = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _editing = widget.draft.review.routine != null;
    _load();
  }

  Future<void> _load() async {
    try {
      final repository = await ref.read(routineRepositoryProvider.future);
      final existing = repository.context.isLocal
          ? await repository.loadForPill(widget.draft.medicationId!)
          : const [];
      if (!mounted ||
          !identical(
            ref.read(routineRepositoryProvider).asData?.value,
            repository,
          )) {
        return;
      }
      setState(() {
        _saved = existing.isNotEmpty;
        _checked = true;
        _connected = !repository.context.isLocal;
      });
    } on Object {
      if (mounted) {
        setState(() => _error = AppLocalizations.of(context).t08_unavailable);
      }
    }
  }

  Future<void> _draft(RoutineDefinition definition, DateTime boundary) async {
    final controller = ref.read(
      setupControllerProvider(widget.request).notifier,
    );
    final review = widget.draft.review;
    await controller.saveDraft(
      SetupReview(
        personName: review.personName,
        avatar: review.avatar,
        audience: review.audience,
        medication: review.medication,
        routine: definition,
        routineEffectiveFrom: boundary,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l.r08_routineTitle,
          style: text.headlineLarge?.copyWith(
            fontSize: 36,
            height: 1.1,
            fontWeight: FontWeight.w700,
            letterSpacing: -.7,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          '${widget.draft.review.personName} · ${widget.draft.review.medication.name}',
          style: text.bodyLarge?.copyWith(
            fontSize: 18,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 10),
        DurableSaveFeedback(
          label: _saved ? l.t08_routineSaved : l.t08_medicationSaved,
        ),
        const SizedBox(height: 16),
        if (!_editing && !_saved) ...[
          Text(l.t08_routineBody, style: text.bodyLarge),
          const SizedBox(height: 20),
        ],
        if (!_checked && _error == null) const LinearProgressIndicator(),
        if (_saved)
          FilledButton(
            key: const ValueKey('routine-continue'),
            onPressed: widget.onContinue,
            child: Text(l.shared_continue),
          )
        else if (_connected) ...[
          FilledButton(
            onPressed: () => showAddEditScheduleSheet(
              context: context,
              pillId: widget.draft.medicationId!,
            ),
            child: Text(l.t08_addRoutine),
          ),
          TextButton(
            onPressed: widget.onContinue,
            child: Text(l.shared_continue),
          ),
          TextButton(onPressed: widget.onSkip, child: Text(l.t08_notNow)),
        ] else if (!_editing) ...[
          FilledButton(
            key: const ValueKey('add-routine'),
            onPressed: _checked ? () => setState(() => _editing = true) : null,
            child: Text(l.t08_addRoutine),
          ),
          TextButton(onPressed: widget.onSkip, child: Text(l.t08_notNow)),
        ] else
          RoutineEditor(
            setupPresentation: true,
            pillId: widget.draft.medicationId!,
            amount: widget.draft.review.medication.amount,
            initial: widget.draft.review.routine,
            onDraft: _draft,
            onSaved: () => setState(() => _saved = true),
            onSkip: widget.onSkip,
          ),
        if (_error != null) ...[
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          TextButton(onPressed: _load, child: Text(l.shared_retry)),
        ],
      ],
    );
  }
}
