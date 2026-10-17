import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/medication/medication_amount.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/layouts/tab_hand_off.dart';
import '../../../shared/motion/app_motion.dart';
import '../../../shared/motion/pressable.dart';
import '../../../shared/router/back_policy.dart';
import '../../../shared/theme/focus_tokens.dart';
import '../../../shared/widgets/capsule_mark.dart';
import '../../../shared/widgets/care_state.dart';
import '../../../shared/widgets/durable_save_feedback.dart';
import '../../pills/presentation/medication_form_kit.dart';
import '../../pills/presentation/medication_identity.dart';
import '../setup_controller.dart';
import '../setup_state.dart';
import 'routine_setup.dart';
import 'setup_hand_off.dart';
import 'setup_organiser.dart';
import 'setup_reminders.dart';

class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({
    super.key,
    this.request = const SetupRequest(),
    this.embedded = false,
  });
  final SetupRequest request;

  /// Shown inside Today's shell rather than as a page of its own. Back then
  /// reaches this screen through the shell's single Back policy (after any
  /// sheet or dialog has closed) instead of a competing listener.
  final bool embedded;
  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

/// Setup waits this long for a queued draft autosave before it goes ahead.
const _autosaveWait = Duration(seconds: 2);

/// No single setup step may hold the screen busy longer than this; past it the
/// step reports a save error and the controls come back.
const _stepLimit = Duration(seconds: 20);

class _SetupScreenState extends ConsumerState<SetupScreen> {
  final _person = TextEditingController();
  final _name = TextEditingController();
  final _strength = TextEditingController();
  final _packageForm = TextEditingController();
  final _quantity = TextEditingController();
  final _unit = TextEditingController();
  final _form = GlobalKey<FormState>();
  final _organiser = GlobalKey<SetupOrganiserState>();
  String? _hydrated;
  bool _unknown = true;
  bool _busy = false;
  String? _error;
  String? _feedback;
  Timer? _draftTimer;
  Future<void> _draftWrite = Future.value();
  SetupDraftData? _latest;
  StateController<bool Function()?>? _interceptor;
  SetupController get _controller =>
      ref.read(setupControllerProvider(widget.request).notifier);

  bool _stepBack() {
    final draft = _latest;
    if (draft == null || draft.step == SetupStep.start) return false;
    if (!_busy) _back(draft);
    return true;
  }

  @override
  void initState() {
    super.initState();
    if (!widget.embedded) return;
    final slot = ref.read(shellBackInterceptorProvider.notifier);
    _interceptor = slot;
    Future.microtask(() {
      if (mounted) slot.state = _stepBack;
    });
  }

  @override
  void dispose() {
    final slot = _interceptor;
    if (slot != null) {
      Future.microtask(() {
        if (slot.state == _stepBack) slot.state = null;
      });
    }
    _draftTimer?.cancel();
    for (final controller in [
      _person,
      _name,
      _strength,
      _packageForm,
      _quantity,
      _unit,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _hydrate(SetupDraftData draft) {
    final key = '${draft.id}/${draft.step.name}';
    if (_hydrated == key) return;
    _hydrated = key;
    _person.text = draft.review.personName;
    _name.text = draft.review.medication.name;
    _strength.text = draft.review.medication.packageStrength ?? '';
    _packageForm.text = draft.review.medication.form ?? '';
    _unknown = draft.review.medication.amount.isUnknown;
    _quantity.text = draft.review.medication.amount.quantityText ?? '';
    _unit.text = draft.review.medication.amount.unit ?? '';
  }

  MedicationReview _medication({MedicationReview? previous}) =>
      MedicationReview(
        name: _name.text.trim(),
        packageStrength: _strength.text.trim().isEmpty
            ? null
            : _strength.text.trim(),
        form: _packageForm.text.trim().isEmpty
            ? null
            : _packageForm.text.trim(),
        notes: previous?.notes,
        originalDosage: previous?.originalDosage,
        legacyDosageReviewed: previous?.legacyDosageReviewed ?? false,
        amount: _unknown
            ? const MedicationAmount.unknown()
            : MedicationAmount.known(_quantity.text.trim(), _unit.text.trim()),
      );

  SetupReview _review(SetupDraftData draft) => SetupReview(
    personName: draft.personId == null ? _person.text : draft.review.personName,
    avatar: draft.review.avatar,
    audience: draft.review.audience,
    medication: draft.medicationId == null
        ? _medication(previous: draft.review.medication)
        : draft.review.medication,
    routine: draft.review.routine,
    routineEffectiveFrom: draft.review.routineEffectiveFrom,
  );

  void _edited() {
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 450), () {
      if (!mounted || _busy) return;
      _draftWrite = _draftWrite.then((_) async {
        if (!mounted || _busy) return;
        final draft = ref
            .read(setupControllerProvider(widget.request))
            .asData
            ?.value;
        if (draft == null) return;
        try {
          await _controller.saveDraft(_review(draft)).timeout(_stepLimit);
        } on FormatException {
          /* An unfinished quantity stays in the form. */
        } on ArgumentError {
          /* Validation on save keeps incomplete input visible. */
        } on Object {
          if (mounted) {
            setState(() => _error = AppLocalizations.of(context).t08_saveError);
          }
        }
      });
    });
  }

  Future<void> _act(Future<void> Function(bool Function() owns) action) async {
    if (_busy) return;
    final repository = ref.read(setupRepositoryProvider).asData?.value;
    bool owns() {
      if (!mounted || repository == null) return false;
      final current = ref.read(setupRepositoryProvider);
      return !current.isLoading &&
          !current.hasError &&
          identical(repository, current.asData?.value);
    }

    if (!owns()) return;
    _draftTimer?.cancel();
    setState(() {
      _busy = true;
      _error = null;
      _feedback = null;
    });
    try {
      try {
        await _draftWrite.timeout(_autosaveWait);
      } on TimeoutException {
        // A stuck autosave must not hold the screen or queue behind itself.
        _draftWrite = Future.value();
      }
      if (!mounted ||
          !identical(
            repository,
            ref.read(setupRepositoryProvider).asData?.value,
          )) {
        return;
      }
      await action(owns).timeout(_stepLimit);
      if (!mounted ||
          !identical(
            repository,
            ref.read(setupRepositoryProvider).asData?.value,
          )) {
        return;
      }
      ref.invalidate(unfinishedSetupDraftProvider);
    } on Object {
      if (mounted &&
          identical(
            repository,
            ref.read(setupRepositoryProvider).asData?.value,
          )) {
        setState(() => _error = AppLocalizations.of(context).t08_saveError);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _advance(SetupStep step) => _act((owns) async {
    await _controller.advanceOrSkip(step);
  });

  Future<void> _back(SetupDraftData draft) => _act((owns) async {
    if (draft.step == SetupStep.person || draft.step == SetupStep.medication) {
      await _controller.saveDraft(_review(draft));
      if (!owns()) return;
    }
    final contextualStart =
        (widget.request.purpose == SetupPurpose.person &&
            draft.step == SetupStep.person) ||
        (widget.request.purpose == SetupPurpose.medication &&
            draft.step == SetupStep.medication);
    if (!mounted || !owns()) return;
    if (contextualStart) {
      if (context.canPop()) {
        context.pop();
      } else {
        context.go(
          widget.request.purpose == SetupPurpose.person
              ? '/profiles'
              : '/pills',
        );
      }
      return;
    }
    await _controller.advanceOrSkip(
      SetupStep.values[(draft.step.index - 1).clamp(
        0,
        SetupStep.values.length - 1,
      )],
    );
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final state = ref.watch(setupControllerProvider(widget.request));
    if (state.hasError) {
      return Scaffold(
        body: CareState(
          title: l.t08_unavailable,
          body: l.t08_unavailableBody,
          action: () => _controller.reload(),
          actionLabel: l.shared_retry,
        ),
      );
    }
    if (state.isLoading || state.asData == null) {
      return Scaffold(body: CareState(title: l.shared_loading, loading: true));
    }
    final draft = state.asData!.value;
    _latest = draft;
    _hydrate(draft);
    final step = draft.step;
    final start = step == SetupStep.start;
    // Saving a step rebuilds this page, so the organiser is built anew: it
    // starts from what the last one showed for this draft.
    final SetupOrganiserShown shown = (
      filled: setupOrganiserFilled(step),
      current: setupOrganiserCurrent(step),
    );
    final shownBefore = widget.request.purpose == SetupPurpose.onboarding
        ? ref.read(setupOrganiserMemoryProvider).swap(draft.id, shown)
        : null;
    // Embedded in the shell, Back is decided there. As a page of its own, the
    // first step leaves like any page and later steps go one step back.
    Widget withBack(Widget child) => widget.embedded
        ? child
        : PopScope(
            canPop: start && !isOnlyPage(context),
            onPopInvokedWithResult: (didPop, result) {
              if (didPop) return;
              if (start) {
                leaveToToday(context);
              } else if (!_busy) {
                _back(draft);
              }
            },
            child: child,
          );
    return withBack(
      Builder(
        builder: (context) => Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            leading: start
                ? null
                : IconButton(
                    tooltip: l.t08_back,
                    icon: const Icon(Icons.arrow_back),
                    onPressed: _busy ? null : () => _back(draft),
                  ),
            title: Text(
              start ? 'Simpastil' : l.r07_setupTitle,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          body: Column(
            children: [
              // First run only: each saved step drops a capsule into the
              // organiser.
              if (widget.request.purpose == SetupPurpose.onboarding)
                SetupOrganiser(
                  key: _organiser,
                  filled: shown.filled,
                  current: shown.current,
                  from: shownBefore,
                  height: _organiserHeight(context),
                ),
              Expanded(
                child: Form(
                  key: _form,
                  child: CareTransition(
                    child: KeyedSubtree(
                      key: ValueKey(step),
                      child: step == SetupStep.medication
                          ? _medicationPage(draft)
                          : _setupPage(draft),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Large text and short screens (landscape, split view) keep the
  /// organiser to a slim band so the form keeps its room.
  static double _organiserHeight(BuildContext context) {
    final scaled = MediaQuery.textScalerOf(context).scale(10) / 10;
    final short = MediaQuery.sizeOf(context).height < 640;
    return scaled >= 1.6 || short ? 60 : 96;
  }

  Widget _setupPage(SetupDraftData draft) {
    final l = AppLocalizations.of(context), theme = Theme.of(context);
    final colors = theme.colorScheme;
    final person = draft.step == SetupStep.person;
    final contextual = widget.request.purpose == SetupPurpose.medication;
    final total = contextual ? 3 : 4;
    final current =
        (draft.step == SetupStep.person
            ? 1
            : draft.step == SetupStep.routine
            ? 3
            : 4) -
        (contextual ? 1 : 0);
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: colors.outlineVariant),
    );
    return Theme(
      data: theme.copyWith(
        inputDecorationTheme: theme.inputDecorationTheme.copyWith(
          filled: true,
          fillColor: colors.surface,
          border: border,
          enabledBorder: border,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(56),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, bounds) => SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: FocusTokens.readingWidth,
                  minHeight: (bounds.maxHeight - 28).clamp(0, double.infinity),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (draft.step != SetupStep.start &&
                            widget.request.purpose != SetupPurpose.person) ...[
                          Semantics(
                            label: l.r07_stepCount(current, total),
                            child: ExcludeSemantics(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // First run counts its steps in the organiser above.
                                  if (widget.request.purpose !=
                                      SetupPurpose.onboarding) ...[
                                    Row(
                                      children: [
                                        for (var i = 0; i < total; i++)
                                          Expanded(
                                            child: Container(
                                              height: 9,
                                              margin:
                                                  EdgeInsetsDirectional.only(
                                                    end: i == total - 1 ? 0 : 7,
                                                  ),
                                              decoration: BoxDecoration(
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                                color: i < current
                                                    ? colors.primary
                                                    : colors.outlineVariant,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                  ],
                                  Text(
                                    l.r07_stepCount(current, total),
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),
                        ],
                        _step(draft),
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: Semantics(
                              liveRegion: true,
                              child: Text(
                                _error!,
                                style: TextStyle(color: colors.error),
                              ),
                            ),
                          ),
                        if (_feedback != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: DurableSaveFeedback(label: _feedback!),
                          ),
                      ],
                    ),
                    if (person)
                      Padding(
                        padding: const EdgeInsets.only(top: 28),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _button(
                              draft.personId == null
                                  ? l.t08_personSave
                                  : l.shared_continue,
                              () => _savePerson(draft),
                              keyName: 'save-person',
                            ),
                            TextButton(
                              onPressed: _busy
                                  ? null
                                  // First-run setup has no other place to go
                                  // before a person exists: /profiles bounces
                                  // back here. Keep the draft and step back to
                                  // the start screen, as Back does.
                                  : draft.personId == null &&
                                        widget.request.purpose ==
                                            SetupPurpose.onboarding
                                  ? () => _back(draft)
                                  : () => _act((owns) async {
                                      await _controller.saveDraft(
                                        _review(draft),
                                      );
                                      if (context.mounted && owns()) {
                                        context.go(
                                          draft.personId == null
                                              ? '/profiles'
                                              : '/pills',
                                        );
                                      }
                                    }),
                              child: Text(l.t08_finishLater),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _savePerson(SetupDraftData draft) {
    if (!_form.currentState!.validate()) return;
    if (draft.personId != null) {
      _advance(SetupStep.medication);
      return;
    }
    _act((owns) async {
      await _controller.savePerson(
        name: _person.text.trim(),
        avatar: draft.review.avatar,
      );
      if (owns() && widget.request.purpose == SetupPurpose.person) {
        await _controller.advanceOrSkip(SetupStep.complete);
        if (mounted && owns()) context.go('/profiles');
      }
    });
  }

  Widget _medicationPage(SetupDraftData draft) {
    final l = AppLocalizations.of(context),
        colors = Theme.of(context).colorScheme;
    final contextual = widget.request.purpose == SetupPurpose.medication;
    final total = contextual ? 3 : 4, current = contextual ? 1 : 2;
    // The actions stay pinned below the scrolling fields, so saving is always
    // one reach away however tall the form or the text grows.
    return SafeArea(
      top: false,
      child: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: FocusTokens.readingWidth,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Semantics(
                        label: l.r07_stepCount(current, total),
                        child: ExcludeSemantics(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // First run counts its steps in the organiser above.
                              if (widget.request.purpose !=
                                  SetupPurpose.onboarding) ...[
                                Row(
                                  children: [
                                    for (var i = 0; i < total; i++)
                                      Expanded(
                                        child: Container(
                                          height: 9,
                                          margin: EdgeInsetsDirectional.only(
                                            end: i == total - 1 ? 0 : 7,
                                          ),
                                          decoration: BoxDecoration(
                                            borderRadius: BorderRadius.circular(
                                              6,
                                            ),
                                            color: i < current
                                                ? colors.primary
                                                : colors.outlineVariant,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                              ],
                              Text(
                                l.r07_stepCount(current, total),
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(color: colors.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      CareTransition(
                        child: KeyedSubtree(
                          key: ValueKey(draft.step),
                          child: _medicationFields(draft),
                        ),
                      ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Semantics(
                            liveRegion: true,
                            child: Text(
                              _error!,
                              style: TextStyle(color: colors.error),
                            ),
                          ),
                        ),
                      if (_feedback != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: DurableSaveFeedback(label: _feedback!),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).scaffoldBackgroundColor,
              border: Border(
                top: BorderSide(
                  color: colors.outlineVariant.withValues(alpha: .6),
                ),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: FocusTokens.readingWidth,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Pressable(
                        radius: BorderRadius.circular(14),
                        child: FilledButton(
                          key: const ValueKey('save-medication'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(56),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 16,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          onPressed: _busy
                              ? null
                              : () => _saveMedication(draft),
                          child: Text(
                            _busy
                                ? l.t08_saving
                                : draft.medicationId == null
                                ? l.t08_saveMedication
                                : l.shared_continue,
                          ),
                        ),
                      ),
                      // While typing, the keyboard already takes half the
                      // screen: keep only Save so the fields keep their room.
                      if (MediaQuery.viewInsetsOf(context).bottom > 0)
                        const SizedBox(height: 6)
                      else
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => _act((owns) async {
                                  await _controller.saveDraft(_review(draft));
                                  if (mounted && owns()) {
                                    context.go('/pills');
                                  }
                                }),
                          child: Text(l.t08_finishLater),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _saveMedication(SetupDraftData draft) {
    final l = AppLocalizations.of(context);
    if (!_form.currentState!.validate()) return;
    if (draft.medicationId != null) {
      _advance(SetupStep.routine);
      return;
    }
    MedicationReview review;
    try {
      review = _medication(previous: draft.review.medication);
    } on Object {
      setState(() => _error = l.t08_invalidAmount);
      return;
    }
    _act((owns) async {
      await _controller.saveMedication(review);
    });
  }

  Widget _medicationFields(SetupDraftData draft) {
    final l = AppLocalizations.of(context),
        theme = Theme.of(context),
        colors = theme.colorScheme;
    final enabled = draft.medicationId == null && !_busy;
    final outline = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: colors.outlineVariant),
    );
    Widget field({
      required String keyName,
      required String label,
      required TextEditingController controller,
      String? hint,
      String? Function(String?)? validator,
    }) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(
          child: Text(
            label,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Semantics(
          label: label,
          child: TextFormField(
            key: ValueKey(keyName),
            controller: controller,
            enabled: enabled,
            style: theme.textTheme.bodyLarge?.copyWith(fontSize: 18),
            textCapitalization: TextCapitalization.sentences,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              hintText: hint,
              filled: true,
              fillColor: colors.surface,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 14,
              ),
              border: outline,
              enabledBorder: outline,
              disabledBorder: outline,
              focusedBorder: outline.copyWith(
                borderSide: BorderSide(color: colors.primary, width: 2),
              ),
              errorBorder: outline.copyWith(
                borderSide: BorderSide(color: colors.error),
              ),
              focusedErrorBorder: outline.copyWith(
                borderSide: BorderSide(color: colors.error, width: 2),
              ),
            ),
            onChanged: (_) => _edited(),
            validator: validator,
          ),
        ),
      ],
    );
    Widget pair(Widget first, Widget second) => LayoutBuilder(
      builder: (context, bounds) {
        final stack =
            bounds.maxWidth < 300 ||
            MediaQuery.textScalerOf(context).scale(16) > 21;
        return stack
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [first, const SizedBox(height: 16), second],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: first),
                  const SizedBox(width: 14),
                  Expanded(child: second),
                ],
              );
      },
    );
    final saved = draft.medicationId;
    // Its own colour is only known once the medication exists; until the
    // durable save it wears the app's violet and says so.
    final tint = saved == null
        ? colors.primary
        : medicationTint(id: saved, color: null);
    const identity = 'setup-medication';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.request.purpose == SetupPurpose.onboarding
              ? l.r07_firstMedication
              : l.t08_medicationTitle,
          style: theme.textTheme.headlineLarge?.copyWith(
            fontSize: 32,
            height: 1.1,
            fontWeight: FontWeight.w700,
            letterSpacing: -.6,
          ),
        ),
        const SizedBox(height: 16),
        MedicationPreview(
          listenable: Listenable.merge([_name, _strength, _packageForm]),
          name: () => _name.text,
          form: () => _packageForm.text,
          detail: () => previewLine([
            _strength.text,
            _packageForm.text,
            l.t08_forPerson(draft.review.personName),
          ]),
          tint: tint,
          caption: saved == null ? l.mf_colourAfterSave : null,
        ),
        const SizedBox(height: 16),
        FormSection(
          index: 0,
          identity: identity,
          icon: Icons.medication_outlined,
          title: l.mf_sectionWhat,
          hint: l.mf_sectionWhatHint,
          children: [
            field(
              keyName: 'medication-name',
              label: l.t08_medicationName,
              controller: _name,
              validator: (value) =>
                  (value?.trim().isEmpty ?? true) ? l.t08_required : null,
            ),
            const SizedBox(height: 16),
            pair(
              field(
                keyName: 'medication-form',
                label: l.t09_form,
                controller: _packageForm,
              ),
              field(
                keyName: 'medication-strength',
                label: l.r07_strength,
                controller: _strength,
              ),
            ),
            const SizedBox(height: 10),
            ListenableBuilder(
              listenable: _packageForm,
              builder: (context, _) => Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final value in [
                    l.r07_tablet,
                    l.r07_capsule,
                    l.r07_liquid,
                  ])
                    ChoiceChip(
                      key: ValueKey('form-chip-$value'),
                      label: Text(value),
                      avatar: ExcludeSemantics(
                        child: MedicationMark(
                          color: tint,
                          shape: medicationShapeOf(value),
                          size: 20,
                        ),
                      ),
                      showCheckmark: false,
                      selected:
                          _packageForm.text.trim().toLowerCase() ==
                          value.toLowerCase(),
                      onSelected: !enabled
                          ? null
                          : (_) {
                              _packageForm.text = value;
                              _edited();
                            },
                    ),
                ],
              ),
            ),
          ],
        ),
        FormSection(
          index: 1,
          identity: identity,
          icon: Icons.straighten_rounded,
          title: l.mf_sectionDose,
          hint: l.t08_amountHelp,
          children: [
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(l.t08_unknown, style: theme.textTheme.bodyLarge),
              value: _unknown,
              onChanged: !enabled
                  ? null
                  : (value) {
                      setState(() => _unknown = value);
                      _edited();
                    },
            ),
            AnimatedSize(
              duration: AppMotion.duration(context),
              curve: AppMotion.curve,
              alignment: Alignment.topCenter,
              child: _unknown
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: pair(
                        field(
                          keyName: 'medication-quantity',
                          label: l.t08_quantity,
                          controller: _quantity,
                          hint: l.t08_quantityHint,
                        ),
                        field(
                          keyName: 'medication-unit',
                          label: l.t08_unit,
                          controller: _unit,
                          hint: l.t08_unitHint,
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _heading(String title, String body) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: Theme.of(context).textTheme.headlineLarge?.copyWith(
          fontSize: 36,
          height: 1.1,
          fontWeight: FontWeight.w700,
          letterSpacing: -.7,
        ),
      ),
      const SizedBox(height: 12),
      Text(
        body,
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
          fontSize: 18,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 28),
    ],
  );
  Widget _button(String text, VoidCallback action, {String? keyName}) =>
      FilledButton(
        key: keyName == null ? null : ValueKey(keyName),
        onPressed: _busy ? null : action,
        child: Text(_busy ? AppLocalizations.of(context).t08_saving : text),
      );

  Widget _step(SetupDraftData draft) {
    final l = AppLocalizations.of(context);
    if (widget.request.purpose == SetupPurpose.person &&
        draft.personId != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DurableSaveFeedback(label: l.t09_personSaved),
          const SizedBox(height: 24),
          Text(
            draft.review.personName,
            style: Theme.of(context).textTheme.headlineLarge,
          ),
          const SizedBox(height: 28),
          _button(
            l.shared_done,
            () => _act((owns) async {
              await _controller.advanceOrSkip(SetupStep.complete);
              if (mounted && owns()) context.go('/profiles');
            }),
          ),
        ],
      );
    }
    switch (draft.step) {
      case SetupStep.start:
        final colors = Theme.of(context).colorScheme;
        return Column(
          key: const ValueKey('setup-start'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),
            _heading(l.r08_startTitle, l.r08_startBody),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                children: [
                  SetupPhoneMark(color: colors.onPrimaryContainer),
                  const SizedBox(height: 16),
                  Text(
                    l.t08_local,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: colors.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    l.r08_noAccount,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: colors.onPrimaryContainer,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            _button(
              l.r08_startHere,
              () => _advance(SetupStep.person),
              keyName: 'setup-begin',
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () => context.push('/login'),
              icon: const Icon(Icons.dns_outlined),
              label: Text(l.r08_connect),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border.all(color: colors.outlineVariant),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.restore),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l.r08_restore,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          l.r08_unavailable,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Text(
              l.r08_choiceLater,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
        );
      case SetupStep.person:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _heading(l.r08_personTitle, l.r08_personHint),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.person_outline,
                    size: 38,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      l.r08_personIdentity,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Text(
              l.t08_personName,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            TextFormField(
              key: const ValueKey('person-name'),
              controller: _person,
              enabled: draft.personId == null && !_busy,
              textCapitalization: TextCapitalization.words,
              autofillHints: const [AutofillHints.name],
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(hintText: l.t08_personName),
              onChanged: (_) => _edited(),
              validator: (v) =>
                  (v?.trim().isEmpty ?? true) ? l.t08_required : null,
            ),
          ],
        );
      case SetupStep.medication:
        return _medicationFields(draft);
      case SetupStep.routine:
        return RoutineSetup(
          key: ValueKey(draft.medicationId),
          draft: draft,
          request: widget.request,
          onContinue: () => _advance(SetupStep.reminders),
          onSkip: () => _advance(SetupStep.reminders),
        );
      case SetupStep.reminders:
        return SetupReminders(onContinue: () => _advance(SetupStep.ready));
      case SetupStep.ready:
      case SetupStep.complete:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _heading(l.t08_readyTitle, l.t08_readyBody),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const CapsuleMark(size: 40),
                  const SizedBox(height: 16),
                  Text(
                    draft.review.personName,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    draft.review.medication.name,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 16),
                  DurableSaveFeedback(label: l.t08_saved),
                ],
              ),
            ),
            const SizedBox(height: 24),
            _button(
              l.t08_openToday,
              () => _act((owns) async {
                // The organiser lays flat first, while setup is still on
                // screen: completing setup hands this page over to Today.
                // Its line then goes on to become Today's arc.
                final overlay = Overlay.of(context, rootOverlay: true);
                final hold = ref.read(todaySunriseHoldProvider);
                final line = await _organiser.currentState?.finish();
                if (!mounted || !owns()) return;
                if (line != null) startSetupHandOff(overlay, hold, line);
                if (draft.step != SetupStep.complete) {
                  await _controller.advanceOrSkip(SetupStep.complete);
                }
                ref.invalidate(unfinishedSetupDraftProvider);
                if (!mounted || !owns()) return;
                context.go('/home');
              }),
              keyName: 'open-today',
            ),
          ],
        );
    }
  }
}

/// Decorative device outline shared by fresh and resumed setup.
class SetupPhoneMark extends StatelessWidget {
  const SetupPhoneMark({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: 38,
      height: 62,
      padding: const EdgeInsets.only(bottom: 7),
      decoration: BoxDecoration(
        border: Border.all(color: color, width: 2.5),
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.bottomCenter,
      child: Container(
        width: 14,
        height: 3,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    ),
  );
}
