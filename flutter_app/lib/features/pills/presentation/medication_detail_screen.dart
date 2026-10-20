import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:go_router/go_router.dart';
import '../../../core/inventory/supply_forecast.dart';
import '../../../core/medication/medication_detail_provider.dart';
import '../../../core/medication/medication_detail_repository.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/format/clock.dart';
import '../../../shared/layouts/window_size.dart';
import '../../../shared/motion/app_motion.dart';
import '../../../shared/widgets/care_state.dart';
import '../../../shared/widgets/durable_save_feedback.dart';
import '../../../shared/widgets/confirm_delete_dialog.dart';
import '../../../core/errors/app_error.dart';
import '../../schedules/presentation/day_part.dart';
import '../../schedules/presentation/routine_presentation.dart';
import '../../setup/setup_state.dart';
import '../pill_provider.dart';
import 'add_edit_pill_sheet.dart';
import 'as_needed_medication_panel.dart';
import 'medication_detail_sections.dart';
import 'medication_edit.dart';
import 'medication_identity.dart';
import 'medication_plate.dart';
import 'medication_routine_info.dart';
import 'pills_screen.dart' show medicationRoutineLabel, medicationTint;
import 'supply_runway.dart';

/// The medication a link asked the expanded workspace to select. The list takes
/// it when it shows and clears it, so a later list does not replay it.
final medicationFocusRequestProvider = StateProvider<String?>((ref) => null);

/// What the link to one medication opens: its own page on a phone or a medium
/// window. An expanded window has no page for one medication: the workspace is
/// the one list beside the details, so the link hands the medication to it and
/// returns to `/pills`. That leaves one list in the stack, Back as on
/// `/pills`, and no page to fly into.
class MedicationRoutePage extends ConsumerStatefulWidget {
  const MedicationRoutePage({super.key, required this.pillId});
  final String pillId;

  @override
  ConsumerState<MedicationRoutePage> createState() =>
      _MedicationRoutePageState();
}

class _MedicationRoutePageState extends ConsumerState<MedicationRoutePage> {
  bool _handingOff = false;

  void _handOffToWorkspace() {
    if (_handingOff) return;
    _handingOff = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handingOff = false;
      // A window that shrank in the meantime shows the page again.
      if (!mounted || !WindowClass.of(context).isExpanded) return;
      ref.read(medicationFocusRequestProvider.notifier).state = widget.pillId;
      context.go('/pills');
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!WindowClass.of(context).isExpanded) {
      return MedicationDetailScreen(pillId: widget.pillId);
    }
    _handOffToWorkspace();
    return const Scaffold();
  }
}

/// A medication's page: pushed from the list on a phone or a medium window.
class MedicationDetailScreen extends StatelessWidget {
  const MedicationDetailScreen({super.key, required this.pillId});
  final String pillId;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(AppLocalizations.of(context).t08_medications)),
    body: MedicationDetailView(pillId: pillId),
  );
}

/// A medication's details: its stock, the last 14 days, the recent doses and
/// the actions on it.
///
/// On a page ([embedded] false) the content is a column of cards under the
/// medication's plate. [embedded] is the pane beside the list on an expanded
/// window: one surface that fills its space, with a header and flat sections.
class MedicationDetailView extends ConsumerStatefulWidget {
  const MedicationDetailView({
    super.key,
    required this.pillId,
    this.embedded = false,
    this.onDeleted,
  });

  final String pillId;
  final bool embedded;

  /// Called after the medication was deleted from here. Without it the page
  /// returns to the list.
  final VoidCallback? onDeleted;

  @override
  ConsumerState<MedicationDetailView> createState() =>
      _MedicationDetailViewState();
}

class _MedicationDetailViewState extends ConsumerState<MedicationDetailView> {
  MedicationDetailSave? _saved;

  bool _stillOn(MedicationDetailRepository repository) =>
      mounted &&
      identical(
        ref.read(medicationDetailRepositoryProvider).asData?.value,
        repository,
      );

  Future<void> _edit(
    MedicationCareDetail detail,
    MedicationDetailRepository repository, {
    bool stock = false,
  }) async {
    final Future<MedicationDetailSave?> opened;
    if (stock) {
      opened = showMedicationStockEditor(context, detail, repository);
    } else {
      opened = showMedicationReview(context, detail, repository);
    }
    final saved = await opened;
    if (saved != null && _stillOn(repository)) setState(() => _saved = saved);
  }

  Future<void> _delete(
    MedicationCareDetail detail,
    MedicationDetailRepository repository,
  ) async {
    final l = AppLocalizations.of(context);
    final pillRepo = ref.read(pillRepositoryProvider);
    final confirmed = await showConfirmDeleteDialog(
      context,
      title: l.pills_deletePill,
      message: l.pills_deletePillMessage(detail.pill.name),
    );
    if (!confirmed || !mounted) return;
    final result = await pillRepo.delete(detail.pill.id);
    if (!mounted || !_stillOn(repository)) return;
    if (result is Err) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.pills_couldNotDelete)));
    } else if (widget.onDeleted != null) {
      widget.onDeleted!();
    } else {
      context.go('/pills');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final state = ref.watch(medicationDetailProvider(widget.pillId));
    final repoState = ref.watch(medicationDetailRepositoryProvider);
    final repository = repoState.asData?.value;
    // The list already holds this medication: show it on the first frame so
    // the card's surface and mark have a plate to fly into while the page's
    // own stream starts.
    final listed = ref
        .watch(medicationListProvider)
        .value
        ?.where((m) => m.pill.id == widget.pillId)
        .firstOrNull;
    final shown = state.value ?? (state.isLoading ? listed : null);
    final Widget body;
    if (state.hasError || repoState.hasError) {
      body = CareState(
        title: l.t08_unavailable,
        body: l.t08_unavailableBody,
        actionLabel: l.shared_retry,
        action: () => ref.invalidate(medicationDetailProvider(widget.pillId)),
      );
    } else if (shown == null || repository == null) {
      body = CareState(title: l.shared_loading, loading: true);
    } else if (widget.embedded) {
      return _pane(context, shown, repository);
    } else {
      body = _page(context, shown, repository);
    }
    return widget.embedded ? _PaneSurface(child: body) : body;
  }

  Widget _feedback(AppLocalizations l, {required double bottom}) =>
      AnimatedSize(
        duration: AppMotion.duration(context),
        curve: AppMotion.curve,
        alignment: Alignment.topCenter,
        child: _saved == null
            ? const SizedBox(width: double.infinity)
            : Padding(
                padding: EdgeInsets.only(bottom: bottom),
                child: DurableSaveFeedback(
                  label: _saved!.sharing == SetupSharingState.pending
                      ? l.t09_savedPending
                      : l.t09_savedSummary,
                ),
              ),
      );

  /// Where the routine is read and opened (a medication that is not as
  /// needed), or the as-needed panel with its recent doses.
  List<Widget> _routine(
    BuildContext context,
    MedicationCareDetail detail,
    MedicationDetailRepository repository,
  ) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    if (detail.pill.isPrn) return [AsNeededMedicationPanel(detail: detail)];
    return [
      Text(l.t09_routine, style: text.titleLarge),
      const SizedBox(height: 12),
      Text(
        medicationRoutineLabel(
          context,
          detail,
          local: repository.context.isLocal,
        ),
        style: text.bodyLarge,
      ),
      const SizedBox(height: 16),
      _routineButton(detail, repository),
    ];
  }

  Widget _routineButton(
    MedicationCareDetail detail,
    MedicationDetailRepository repository,
  ) {
    final l = AppLocalizations.of(context);
    final label = Text(
      detail.routineVersions.isEmpty && repository.context.isLocal
          ? l.t08_addRoutine
          : l.t09_routineDetails,
    );
    void open() => context.push('/pills/${detail.pill.id}/routine');
    return widget.embedded
        ? FilledButton.tonalIcon(
            key: const ValueKey('open-routine-details'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
            onPressed: open,
            icon: const Icon(Icons.schedule_rounded, size: 20),
            label: label,
          )
        : FilledButton(
            key: const ValueKey('open-routine-details'),
            onPressed: open,
            child: label,
          );
  }

  List<Widget> _connected(
    BuildContext context,
    MedicationCareDetail detail,
    MedicationDetailRepository repository,
  ) {
    if (repository.context.isLocal) return const [];
    final l = AppLocalizations.of(context);
    return [
      const SizedBox(height: 24),
      Text(l.t09_connectedDetails),
      TextButton(
        onPressed: () =>
            showAddEditPillSheet(context: context, pill: detail.pill),
        child: Text(l.pills_editPillTooltip),
      ),
    ];
  }

  Widget _page(
    BuildContext context,
    MedicationCareDetail detail,
    MedicationDetailRepository repository,
  ) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final review = detail.review;
    final tint = medicationTint(id: detail.pill.id, color: detail.pill.color);
    final supply = supplyForecastFor(
      detail,
      local: repository.context.isLocal,
      now: DateTime.now(),
    );
    return ContentColumn(
      builder: (context, gutter) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24) + gutter,
        children: [
          MedicationPlate(
            id: detail.pill.id,
            tint: tint,
            shape: medicationShapeOf(review.form),
            children: [
              Text(
                detail.pill.name,
                textAlign: TextAlign.center,
                style: text.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                l.t08_forPerson(detail.person.name),
                textAlign: TextAlign.center,
                style: text.labelLarge,
              ),
            ],
          ),
          const SizedBox(height: 24),
          // The sections share the plate's edges.
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _feedback(l, bottom: 24),
              MedicationStockSection(
                detail: detail,
                forecast: supply,
                tint: tint,
                onAddStock: () => _edit(detail, repository, stock: true),
              ),
              const SizedBox(height: 14),
              MedicationLast14Section(detail: detail, tint: tint),
              if (!detail.pill.isPrn) ...[
                const SizedBox(height: 14),
                MedicationRecentSection(detail: detail),
              ],
              const SizedBox(height: 28),
              Text(l.t08_amount, style: text.titleMedium),
              Text(
                review.amount.isUnknown
                    ? l.t08_unknown
                    : '${review.amount.quantityText} ${review.amount.unit}',
                style: text.bodyLarge,
              ),
              const SizedBox(height: 8),
              Text(l.t09_medicationAmountHelp, style: text.bodyMedium),
              if (review.packageStrength != null) ...[
                const SizedBox(height: 20),
                Text(l.t08_strength, style: text.titleMedium),
                Text(review.packageStrength!, style: text.bodyLarge),
              ],
              if (review.form != null) ...[
                const SizedBox(height: 16),
                Text(l.t09_form, style: text.titleMedium),
                Text(review.form!),
              ],
              if (review.originalDosage != null) ...[
                const SizedBox(height: 20),
                Text(
                  review.legacyDosageReviewed
                      ? l.t09_legacyDosageReviewed
                      : l.t09_legacyDosage,
                  style: text.labelLarge,
                ),
                Text(review.originalDosage!),
              ],
              if (review.notes != null) ...[
                const SizedBox(height: 20),
                Text(l.t09_notes, style: text.titleMedium),
                Text(review.notes!),
              ],
              const SizedBox(height: 24),
              OutlinedButton(
                key: const ValueKey('edit-medication-details'),
                onPressed: () => _edit(detail, repository),
                child: Text(l.t09_reviewDetails),
              ),
              const SizedBox(height: 28),
              ..._routine(context, detail, repository),
              ..._connected(context, detail, repository),
              const SizedBox(height: 24),
              TextButton.icon(
                onPressed: () => _delete(detail, repository),
                icon: const Icon(Icons.delete_outline),
                label: Text(l.pills_deletePill),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// The pane beside the list: its own surface, a header with Edit, three
  /// facts at a glance, then the stock and the last 14 days side by side.
  Widget _pane(
    BuildContext context,
    MedicationCareDetail detail,
    MedicationDetailRepository repository,
  ) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final cs = theme.colorScheme;
    final review = detail.review;
    final local = repository.context.isLocal;
    final tint = medicationTint(id: detail.pill.id, color: detail.pill.color);
    final supply = supplyForecastFor(detail, local: local, now: DateTime.now());
    final facts = <(String, String)>[
      if (review.packageStrength != null)
        (l.t08_strength, review.packageStrength!),
      if (review.form != null) (l.t09_form, review.form!),
      if (review.originalDosage != null)
        (
          review.legacyDosageReviewed
              ? l.t09_legacyDosageReviewed
              : l.t09_legacyDosage,
          review.originalDosage!,
        ),
      if (review.notes != null) (l.t09_notes, review.notes!),
    ];
    return _PaneSurface(
      child: LayoutBuilder(
        builder: (context, box) {
          final inner = box.maxWidth - 48;
          final sideBySide = inner >= 540;
          final stock = MedicationStockSection(
            detail: detail,
            forecast: supply,
            tint: tint,
            flat: true,
            showSummary: false,
            onAddStock: () => _edit(detail, repository, stock: true),
          );
          final last14 = MedicationLast14Section(
            detail: detail,
            tint: tint,
            flat: true,
          );
          return SingleChildScrollView(
            key: const ValueKey('medication-pane-scroll'),
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: tint.withValues(
                          alpha: theme.brightness == Brightness.dark
                              ? .22
                              : .16,
                        ),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      alignment: Alignment.center,
                      child: MedicationMark(
                        color: tint,
                        shape: medicationShapeOf(review.form),
                        size: 44,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Semantics(
                            header: true,
                            child: Text(
                              detail.pill.name,
                              key: const ValueKey('pane-medication-name'),
                              style: text.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Text(
                            [
                              detail.pill.isPrn
                                  ? l.t08_asNeeded
                                  : l.tm_kindScheduled,
                              l.t08_forPerson(detail.person.name),
                            ].join(' · '),
                            style: text.bodyMedium?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      key: const ValueKey('edit-medication-details'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 48),
                      ),
                      onPressed: () => _edit(detail, repository),
                      icon: const Icon(Icons.edit_outlined, size: 20),
                      label: Text(l.tm_edit),
                    ),
                    PopupMenuButton<String>(
                      key: const ValueKey('medication-pane-menu'),
                      tooltip: l.r09_medicationActions,
                      onSelected: (value) {
                        if (value == 'delete') _delete(detail, repository);
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'delete',
                          child: Text(l.pills_deletePill),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _feedback(l, bottom: 16),
                _FactTiles(detail: detail, local: local, forecast: supply),
                const SizedBox(height: 24),
                if (sideBySide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: stock),
                      const SizedBox(width: 28),
                      Expanded(child: last14),
                    ],
                  )
                else ...[
                  stock,
                  const SizedBox(height: 24),
                  last14,
                ],
                if (facts.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Wrap(
                    spacing: 28,
                    runSpacing: 16,
                    children: [
                      for (final (label, value) in facts)
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: sideBySide ? (inner - 28) / 2 : inner,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(label, style: text.titleSmall),
                              Text(value, style: text.bodyLarge),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 24),
                if (!detail.pill.isPrn) ...[
                  MedicationRecentSection(detail: detail, flat: true),
                  const SizedBox(height: 24),
                  _routineButton(detail, repository),
                ] else
                  AsNeededMedicationPanel(detail: detail),
                ..._connected(context, detail, repository),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// The surface the expanded pane sits on.
class _PaneSurface extends StatelessWidget {
  const _PaneSurface({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      key: const ValueKey('medication-pane'),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: .5)),
      ),
      child: ClipRRect(borderRadius: BorderRadius.circular(27), child: child),
    );
  }
}

/// Schedule, amount and stock of a medication, each in its own tile.
class _FactTiles extends StatelessWidget {
  const _FactTiles({
    required this.detail,
    required this.local,
    required this.forecast,
  });

  final MedicationCareDetail detail;
  final bool local;
  final SupplyForecast? forecast;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final review = detail.review;
    final times = plannedTimesOf(detail, local: local);
    final routine = local ? currentRoutineOf(detail) : null;
    final String scheduleValue;
    String? scheduleNote;
    if (detail.pill.isPrn) {
      scheduleValue = l.t08_asNeeded;
      scheduleNote = l.asn_onlyWhenNeeded;
    } else if (times.isEmpty) {
      scheduleValue = '–';
      scheduleNote = l.r09_noRoutine;
    } else {
      scheduleValue = times.map((t) => clockTime(context, t)).join(' · ');
      scheduleNote = [
        if (routine != null) routinePatternLabel(context, routine),
        if (times.length == 1) dayPartLabel(l, dayPartOf(times.first)),
      ].join(' · ');
    }
    final stock = detail.pill.currentStock;
    final tiles = [
      _Tile(
        key: const ValueKey('tile-schedule'),
        label: l.tm_statSchedule,
        value: scheduleValue,
        note: scheduleNote,
      ),
      _Tile(
        key: const ValueKey('tile-amount'),
        label: l.t08_amount,
        value: review.amount.isUnknown
            ? l.t08_unknown
            : '${review.amount.quantityText} ${review.amount.unit}',
        note: l.tm_perUse,
      ),
      _Tile(
        key: const ValueKey('tile-stock'),
        label: l.tm_stockTitle,
        value: stock == null ? l.tm_noCount : l.pills_stockLeft(stock),
        note: stock == null || forecast == null
            ? null
            : stockRunsOutLine(context, forecast!),
      ),
    ];
    return LayoutBuilder(
      builder: (context, box) {
        final cols = box.maxWidth >= 480 ? 3 : 2;
        const gap = 10.0;
        final width = (box.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final tile in tiles) SizedBox(width: width, child: tile),
          ],
        );
      },
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({super.key, required this.label, required this.value, this.note});
  final String label, value;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final text = theme.textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: .7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: text.labelMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          if (note != null && note!.isNotEmpty)
            Text(
              note!,
              style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}
