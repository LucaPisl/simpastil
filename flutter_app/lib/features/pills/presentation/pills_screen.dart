import '../../../shared/widgets/stock_recount_note.dart';
import 'medication_detail_sections.dart' show dosageNeedsReview;
import '../../../shared/format/clock.dart';
import '../../../shared/theme/wordmark.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/inventory/low_stock.dart';
import '../../../core/medication/expiry.dart';
import '../../../core/medication/medication_activity.dart';
import '../../../core/medication/medication_detail_provider.dart';
import '../../../core/errors/app_error.dart';
import '../../../shared/widgets/confirm_delete_dialog.dart';
import '../pill_provider.dart';
import 'medication_blister.dart';
import 'medication_compact_list.dart';
import 'medication_detail_screen.dart';
import '../medication_look_provider.dart';
import 'medication_identity.dart';
import 'medication_plate.dart';
import 'stock_capsule.dart';
import 'supply_runway.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../core/medication/medication_detail_repository.dart';
import '../../../core/medication/routine_definition.dart';
import '../../../core/medication/routine_repository.dart';
import '../../../core/workspace/workspace_provider.dart';
import '../../../core/sync/auto_sync_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/layouts/window_size.dart';
import '../../../shared/motion/app_motion.dart';
import '../../../shared/motion/pressable.dart';
import '../../../shared/motion/staggered_entrance.dart';
import '../../../shared/widgets/care_state.dart';
import '../../../shared/widgets/care_person_selector.dart';
import '../../profiles/profile_provider.dart';
import '../../schedules/presentation/routine_presentation.dart';

export 'medication_identity.dart'
    show MedicationShape, medicationShapeOf, medicationTint;

/// The medication list. On a phone it is a page of cards that open each
/// medication's page. A medium window lists compact tiles under a stock
/// summary, and an expanded window shows the list beside the selected
/// medication's details.
class PillsScreen extends ConsumerStatefulWidget {
  const PillsScreen({super.key});

  @override
  ConsumerState<PillsScreen> createState() => _PillsScreenState();
}

class _PillsScreenState extends ConsumerState<PillsScreen> {
  String get _lang => Localizations.localeOf(context).languageCode;

  bool _editing = false, _deleting = false;
  final _selectedIds = <String>{};
  final _search = TextEditingController();
  final _scroll = ScrollController();

  /// Each card's place in the list, so a blister pocket can bring it into
  /// view, and how many times it has been pointed at.
  final _cardKeys = <String, GlobalKey>{};
  final _pulses = <String, int>{};

  /// The medication the detail pane shows on an expanded window.
  String? _focusId;

  /// Whether a medium window has opened its search field.
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    final asked = ref.read(medicationFocusRequestProvider);
    if (asked != null) {
      _focusId = asked;
      _spendFocusRequest();
    }
  }

  /// A link to one medication reached an expanded window: select it in the
  /// pane. The request is cleared once taken, so asking for the same one again
  /// is a new request and a list made later does not replay it.
  void _spendFocusRequest() => WidgetsBinding.instance.addPostFrameCallback((
    _,
  ) {
    if (mounted) ref.read(medicationFocusRequestProvider.notifier).state = null;
  });

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _showCard(String id) async {
    if (_search.text.isNotEmpty && _cardKeys[id]?.currentContext == null) {
      // The card is hidden by the search; clear it so the card is there.
      setState(_search.clear);
      await WidgetsBinding.instance.endOfFrame;
    }
    final target = _cardKeys[id]?.currentContext;
    if (!mounted || target == null || !target.mounted) return;
    final quiet = AppMotion.quiet(context);
    await Scrollable.ensureVisible(
      target,
      alignment: .2,
      duration: quiet ? Duration.zero : AppMotion.emphasis,
      curve: AppMotion.curve,
    );
    if (mounted) setState(() => _pulses[id] = (_pulses[id] ?? 0) + 1);
  }

  MedicationDetailRepository? _selectionOrigin;
  String? _selectionPerson;

  bool _ownsSelection() {
    if (!mounted) return false;
    final ready = ref.read(medicationDetailRepositoryProvider);
    return !ready.isLoading &&
        !ready.hasError &&
        identical(_selectionOrigin, ready.asData?.value);
  }

  void _select(String? id) {
    final ready = ref.read(medicationDetailRepositoryProvider);
    if (ready.isLoading ||
        ready.hasError ||
        ready.asData == null ||
        _deleting) {
      return;
    }
    setState(() {
      if (!_editing) {
        _selectionOrigin = ready.requireValue;
        _selectionPerson = ref.read(selectedProfileIdProvider).asData?.value;
        _selectedIds.clear();
        _editing = true;
      }
      if (id != null && !_selectedIds.add(id)) _selectedIds.remove(id);
    });
  }

  Future<void> _deleteSelected() async {
    if (_deleting || _selectedIds.isEmpty || !_ownsSelection()) return;
    final targets = List<String>.of(_selectedIds);
    final l = AppLocalizations.of(context);
    setState(() => _deleting = true);
    try {
      final repository = ref.read(pillRepositoryProvider);
      final confirmed = await showConfirmDeleteDialog(
        context,
        title: l.pills_deleteCount(targets.length),
        message: l.pills_deleteConfirmMessage(targets.length),
      );
      if (!confirmed || !_ownsSelection()) return;
      final deleted = <String>{};
      for (final id in targets) {
        if (!_ownsSelection()) return;
        try {
          final result = await repository.delete(id);
          if (result is Ok) deleted.add(id);
        } on Object {
          // Each unsuccessful target remains selected for a deliberate retry.
        }
      }
      if (!mounted || !_ownsSelection()) return;
      setState(() {
        _selectedIds.removeAll(deleted);
        _editing = _selectedIds.isNotEmpty;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            [
              if (deleted.isNotEmpty) l.pills_deletedCount(deleted.length),
              if (deleted.length != targets.length) l.pills_couldNotDelete,
            ].join(' '),
          ),
        ),
      );
    } on Object {
      if (mounted && _ownsSelection()) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.pills_couldNotDelete)));
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  /// Pull to refresh: sync a connected workspace, then reload the list.
  Future<void> _refresh(BuildContext context) async {
    final l = AppLocalizations.of(context);
    final captured = ref.read(workspaceContextProvider).asData?.value;
    if (captured == null) return;
    try {
      if (!captured.isLocal) {
        await ref.read(autoSyncServiceProvider).syncNow(captured.ownerUserId);
      }
      if (!context.mounted ||
          !identical(
            captured,
            ref.read(workspaceContextProvider).asData?.value,
          )) {
        return;
      }
      ref.invalidate(medicationListProvider);
    } on Object {
      if (!context.mounted ||
          !identical(
            captured,
            ref.read(workspaceContextProvider).asData?.value,
          )) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.shared_syncFailed)));
    }
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final people = ref.read(profileListProvider).asData?.value;
    final selected = ref.read(selectedProfileIdProvider).asData?.value;
    if (people == null) return;
    if (people.isEmpty) {
      context.push('/setup?purpose=person');
      return;
    }
    var person = people
        .where((p) => p.profile.id == selected)
        .firstOrNull
        ?.profile
        .id;
    if (people.length == 1) person ??= people.single.profile.id;
    person ??= await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final p in people)
              ListTile(
                title: Text(p.profile.name),
                onTap: () => Navigator.of(sheet).pop(p.profile.id),
              ),
          ],
        ),
      ),
    );
    if (context.mounted && person != null) {
      context.push(
        Uri(
          path: '/setup',
          queryParameters: {'purpose': 'medication', 'person': person},
        ).toString(),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    ref.listen(medicationFocusRequestProvider, (_, asked) {
      if (asked == null) return;
      setState(() => _focusId = asked);
      _spendFocusRequest();
    });
    final items = ref.watch(medicationListProvider);
    final people = ref.watch(profileListProvider);
    final selected = ref.watch(selectedProfileIdProvider);
    final workspace = ref.watch(workspaceContextProvider);
    final detailRepository = ref.watch(medicationDetailRepositoryProvider);
    if (_editing &&
        (!identical(_selectionOrigin, detailRepository.asData?.value) ||
            _selectionPerson != selected.asData?.value ||
            detailRepository.hasError ||
            detailRepository.isLoading)) {
      _editing = false;
      _selectedIds.clear();
    }
    final unavailable =
        items.hasError ||
        people.hasError ||
        selected.hasError ||
        workspace.hasError;
    final loading =
        items.isLoading ||
        people.isLoading ||
        selected.isLoading ||
        workspace.isLoading;
    final ready = !loading && !unavailable;
    final window = WindowClass.of(context);
    if (window.showsRail) {
      // The rail carries Settings and the page keeps no app bar: its title,
      // summary and Add button are the page's own header.
      return Scaffold(
        body: SafeArea(
          child: unavailable
              ? CareState(
                  title: l.t08_unavailable,
                  body: l.t08_unavailableBody,
                  actionLabel: l.shared_retry,
                  action: () => ref.invalidate(medicationListProvider),
                )
              : loading
              ? CareState(title: l.shared_loading, loading: true)
              : _wide(
                  context,
                  items: items.requireValue,
                  local: workspace.requireValue.isLocal,
                  showPerson: selected.value == null,
                  ready: ready,
                  window: window,
                ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        titleSpacing: 20,
        title: Wordmark(l.appTitle),
        actions: [
          ..._menuActions(l, ready),
          // The side rail carries Settings on wide windows.
          if (!WindowClass.of(context).showsRail)
            IconButton(
              tooltip: l.nav_settings,
              onPressed: () => context.push('/settings'),
              icon: const Icon(Icons.settings_outlined, size: 26),
            ),
        ],
      ),
      // On wide windows the bar keeps the page's column, not the whole pane.
      bottomNavigationBar: ContentFrame(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: FilledButton.icon(
            key: const ValueKey('add-fab'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              textStyle: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontSize: 18),
            ),
            onPressed: !ready || _editing || _deleting
                ? null
                : () => _add(context, ref),
            icon: const Icon(Icons.add, size: 27),
            label: Text(l.r09_addMedication),
          ),
        ),
      ),
      body: unavailable
          ? CareState(
              title: l.t08_unavailable,
              body: l.t08_unavailableBody,
              actionLabel: l.shared_retry,
              action: () => ref.invalidate(medicationListProvider),
            )
          : loading
          ? CareState(title: l.shared_loading, loading: true)
          : RefreshIndicator(
              onRefresh: () => _refresh(context),
              child: ContentListView(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
                physics: const AlwaysScrollableScrollPhysics(),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l.t08_medications,
                          style: Theme.of(context).textTheme.headlineLarge
                              ?.copyWith(
                                fontSize: 38,
                                height: 1.1,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -.8,
                              ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          l.r09_medicationsBody,
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(
                                fontSize: 17,
                                color: colors.onSurfaceVariant,
                              ),
                        ),
                        MedicationExpiryNote(
                          summary: MedicationListSummary(
                            status: StockStatus.untracked,
                            attention: const [],
                            scheduled: 0,
                            asNeeded: 0,
                            expiring: expiringNamesOf(
                              items.requireValue,
                              now: DateTime.now(),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  ..._blister(
                    items.requireValue,
                    local: workspace.requireValue.isLocal,
                  ),
                  CarePersonSelector(
                    focusDeckPresentation: true,
                    people: people.requireValue.map((p) => p.profile).toList(),
                    selectedId: selected.value,
                    onChanged: (id) =>
                        ref.read(selectedProfileIdProvider.notifier).select(id),
                  ),
                  const SizedBox(height: 16),
                  _searchField(l),
                  const SizedBox(height: 16),
                  if (_editing)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        l.t10_selectedCount(_selectedIds.length),
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ),
                  if (items.requireValue.isEmpty) ...[
                    Text(
                      l.pills_noPillsYet,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(l.pills_addFirstSubtitle),
                  ] else
                    _medications(
                      items.requireValue,
                      local: workspace.requireValue.isLocal,
                      showPerson: selected.value == null,
                    ),
                ],
              ),
            ),
    );
  }

  /// The actions on the whole list: Select and Schedules, or Delete and Done
  /// while selecting.
  List<Widget> _menuActions(AppLocalizations l, bool ready) => [
    if (_editing) ...[
      IconButton(
        tooltip: l.pills_deleteSelectedTooltip,
        onPressed: _deleting || _selectedIds.isEmpty ? null : _deleteSelected,
        icon: const Icon(Icons.delete_outline),
      ),
      TextButton(
        onPressed: _deleting
            ? null
            : () => setState(() {
                _editing = false;
                _selectedIds.clear();
              }),
        child: Text(l.shared_done),
      ),
    ] else
      PopupMenuButton<String>(
        tooltip: l.r09_medicationActions,
        icon: const Icon(Icons.more_horiz),
        onSelected: (value) {
          if (value == 'select') _select(null);
          if (value == 'schedules') context.push('/schedules');
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'select',
            enabled: ready,
            child: Text(l.pills_edit),
          ),
          PopupMenuItem(value: 'schedules', child: Text(l.t08_scheduleTool)),
        ],
      ),
  ];

  Widget _searchField(AppLocalizations l, {bool autofocus = false}) {
    final colors = Theme.of(context).colorScheme;
    return TextField(
      key: const ValueKey('medication-search'),
      controller: _search,
      autofocus: autofocus,
      onChanged: (_) => setState(() {}),
      textInputAction: TextInputAction.search,
      onSubmitted: (_) => FocusScope.of(context).unfocus(),
      decoration: InputDecoration(
        hintText: l.r09_searchMedications,
        prefixIcon: Icon(Icons.search, color: colors.onSurfaceVariant),
        suffixIcon: _search.text.isEmpty
            ? null
            : IconButton(
                tooltip: l.r09_clearSearch,
                onPressed: () => setState(_search.clear),
                icon: const Icon(Icons.close),
              ),
        filled: false,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(
            color: colors.outlineVariant.withValues(alpha: .55),
          ),
        ),
      ),
    );
  }

  /// The Add button of the wide layouts: the page's one primary action.
  Widget _addButton(AppLocalizations l, bool ready) => Tooltip(
    message: l.r09_addMedication,
    child: FilledButton.icon(
      key: const ValueKey('add-fab'),
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      onPressed: !ready || _editing || _deleting
          ? null
          : () => _add(context, ref),
      icon: const Icon(Icons.add, size: 22),
      label: Text(l.shared_add),
    ),
  );

  /// The title row of the wide layouts, with a way back when the page was
  /// pushed over another one.
  Widget _title(AppLocalizations l) {
    final text = Theme.of(context).textTheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (Navigator.of(context).canPop())
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: IconButton(
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: Navigator.of(context).maybePop,
              icon: const Icon(Icons.arrow_back),
            ),
          ),
        Flexible(
          child: Text(
            l.t08_medications,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.headlineMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -.4,
            ),
          ),
        ),
      ],
    );
  }

  Widget _empty(AppLocalizations l) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(l.pills_noPillsYet, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      Text(l.pills_addFirstSubtitle),
    ],
  );

  /// The medications whose name holds the search, in the list's order.
  List<MedicationCareDetail> _matching(
    List<MedicationCareDetail> all, {
    required bool local,
  }) {
    final query = _search.text.trim().toLowerCase();
    return _inListOrder(
      all.where((m) => m.pill.name.toLowerCase().contains(query)),
      local,
    );
  }

  String _scheduleLine(
    MedicationCareDetail item, {
    required bool local,
    required bool showPerson,
  }) {
    final l = AppLocalizations.of(context);
    final noRoutine = local && item.routineVersions.isEmpty && !item.pill.isPrn;
    final schedule = item.pill.isPrn
        ? l.t09_prn
        : noRoutine
        ? l.r09_noRoutine
        : medicationRoutineLabel(context, item, local: local);
    return [if (showPerson) item.person.name, schedule].join(' · ');
  }

  Widget _row(
    MedicationCareDetail item, {
    required bool local,
    required bool showPerson,
    required bool inline,
    bool selected = false,
    VoidCallback? onOpen,
  }) {
    final pill = item.pill;
    return MedicationCompactRow(
      id: pill.id,
      name: pill.name,
      tint: medicationTint(id: pill.id, color: pill.color),
      shape: medicationShapeOf(item.review.form),
      subtitle: _scheduleLine(item, local: local, showPerson: showPerson),
      stock: item.stock?.whole,
      stockText: item.stock?.leftText(_lang),
      needsRecount: item.stock?.needsRecount ?? false,
      expiry: expiryState(pill.expiresOn, DateTime.now()),
      dosageNeedsReview: dosageNeedsReview(item.review),
      threshold: pill.lowStockThreshold,
      stockInline: inline,
      selected: selected,
      checked: _editing ? _selectedIds.contains(pill.id) : null,
      onTap: _deleting
          ? null
          : _editing
          ? () => _select(pill.id)
          : onOpen,
      onLongPress: _deleting ? null : () => _select(pill.id),
      onCheckedChanged: _deleting ? null : (_) => _select(pill.id),
    );
  }

  /// The list of a medium or expanded window: the compact page of a medium
  /// window, or the list beside the detail pane.
  Widget _wide(
    BuildContext context, {
    required List<MedicationCareDetail> items,
    required bool local,
    required bool showPerson,
    required bool ready,
    required WindowClass window,
  }) {
    final summary = summarizeMedications(
      stockEntriesOf(items, local: local, now: DateTime.now()),
      expiring: expiringNamesOf(items, now: DateTime.now()),
    );
    final people = ref.watch(profileListProvider).requireValue;
    // The selector is a bordered panel that draws nothing with fewer than two
    // people, so its gap to the search field or card grid under it goes with it.
    final selector = people.length < 2
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: CarePersonSelector(
              focusDeckPresentation: true,
              people: people.map((p) => p.profile).toList(),
              selectedId: ref.watch(selectedProfileIdProvider).value,
              onChanged: (id) =>
                  ref.read(selectedProfileIdProvider.notifier).select(id),
            ),
          );
    return window.isExpanded
        ? _expanded(
            context,
            items: items,
            local: local,
            showPerson: showPerson,
            ready: ready,
            summary: summary,
            selector: selector,
          )
        : _medium(
            context,
            items: items,
            local: local,
            showPerson: showPerson,
            ready: ready,
            summary: summary,
            selector: selector,
          );
  }

  Widget _medium(
    BuildContext context, {
    required List<MedicationCareDetail> items,
    required bool local,
    required bool showPerson,
    required bool ready,
    required MedicationListSummary summary,
    required Widget selector,
  }) {
    final l = AppLocalizations.of(context);
    final matching = _matching(items, local: local);
    final searching = _searching || _search.text.isNotEmpty;
    return RefreshIndicator(
      onRefresh: () => _refresh(context),
      child: ContentListView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        physics: const AlwaysScrollableScrollPhysics(),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [
          Row(
            children: [
              Expanded(child: _title(l)),
              IconButton(
                key: const ValueKey('medication-search-toggle'),
                tooltip: l.r09_searchMedications,
                isSelected: searching,
                onPressed: () => setState(() {
                  _searching = !searching;
                  if (!_searching) _search.clear();
                }),
                icon: const Icon(Icons.search),
              ),
              const SizedBox(width: 4),
              _addButton(l, ready),
              ..._menuActions(l, ready),
            ],
          ),
          const SizedBox(height: 12),
          if (searching) ...[
            _searchField(l, autofocus: _searching && _search.text.isEmpty),
            const SizedBox(height: 12),
          ],
          if (items.isNotEmpty) ...[
            MedicationStockStrip(summary: summary),
            MedicationExpiryNote(summary: summary),
            const SizedBox(height: 12),
          ],
          selector,
          if (_editing)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                l.t10_selectedCount(_selectedIds.length),
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
          if (items.isEmpty)
            _empty(l)
          else if (matching.isEmpty)
            Text(l.r09_noMatchingMedications)
          else
            LayoutBuilder(
              builder: (context, box) {
                final columns =
                    box.maxWidth < 460 ||
                        MediaQuery.textScalerOf(context).scale(16) > 21
                    ? 1
                    : 2;
                return Column(
                  children: [
                    for (var i = 0; i < matching.length; i += columns)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (var j = 0; j < columns; j++) ...[
                                if (j != 0) const SizedBox(width: 10),
                                Expanded(
                                  child: i + j < matching.length
                                      ? _row(
                                          matching[i + j],
                                          local: local,
                                          showPerson: showPerson,
                                          inline: true,
                                          onOpen: () => context.push(
                                            '/pills/${matching[i + j].pill.id}',
                                          ),
                                        )
                                      : const SizedBox.shrink(),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }

  /// The medication the detail pane shows: the one picked, else the first of
  /// the list.
  String? _paneId(List<MedicationCareDetail> items, bool local) {
    if (items.isEmpty) return null;
    if (_focusId != null && items.any((m) => m.pill.id == _focusId)) {
      return _focusId;
    }
    return _inListOrder(items, local).first.pill.id;
  }

  /// After the pane's medication was deleted, move to the one next to it.
  void _afterDelete(String id) {
    final all = ref.read(medicationListProvider).value ?? const [];
    final local = ref.read(workspaceContextProvider).value?.isLocal ?? true;
    final ordered = _inListOrder(all, local);
    final at = ordered.indexWhere((m) => m.pill.id == id);
    final String? next;
    if (at < 0) {
      next = null;
    } else if (at + 1 < ordered.length) {
      next = ordered[at + 1].pill.id;
    } else {
      next = at > 0 ? ordered[at - 1].pill.id : null;
    }
    setState(() => _focusId = next);
  }

  Widget _expanded(
    BuildContext context, {
    required List<MedicationCareDetail> items,
    required bool local,
    required bool showPerson,
    required bool ready,
    required MedicationListSummary summary,
    required Widget selector,
  }) {
    final l = AppLocalizations.of(context);
    final matching = _matching(items, local: local);
    final paneId = _paneId(items, local);
    final scheduled = [
      for (final m in _inListOrder(items, local))
        if (!m.pill.isPrn) m.pill.name,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, box) {
              final inline =
                  box.maxWidth >= 960 &&
                  MediaQuery.textScalerOf(context).scale(16) <= 19;
              final chips = items.isEmpty
                  ? null
                  : MedicationStatChips(
                      summary: summary,
                      scheduledNames: scheduled,
                    );
              final menu = Row(
                mainAxisSize: MainAxisSize.min,
                children: _menuActions(l, ready),
              );
              if (inline && chips != null) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _title(l),
                    const SizedBox(width: 32),
                    Expanded(child: chips),
                    const SizedBox(width: 8),
                    menu,
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(child: _title(l)),
                      menu,
                    ],
                  ),
                  if (chips != null) ...[const SizedBox(height: 12), chips],
                ],
              );
            },
          ),
          MedicationExpiryNote(summary: summary),
          const SizedBox(height: 16),
          Expanded(
            child: items.isEmpty
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _empty(l),
                      const SizedBox(height: 16),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: _addButton(l, ready),
                      ),
                    ],
                  )
                : LayoutBuilder(
                    builder: (context, box) {
                      final listWidth = (box.maxWidth * .36).clamp(
                        320.0,
                        420.0,
                      );
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            width: listWidth,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                selector,
                                Row(
                                  children: [
                                    Expanded(child: _searchField(l)),
                                    const SizedBox(width: 10),
                                    _addButton(l, ready),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                if (_editing)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: Text(
                                      l.t10_selectedCount(_selectedIds.length),
                                      style: Theme.of(
                                        context,
                                      ).textTheme.labelLarge,
                                    ),
                                  ),
                                Expanded(
                                  child: RefreshIndicator(
                                    onRefresh: () => _refresh(context),
                                    child: matching.isEmpty
                                        ? ListView(
                                            physics:
                                                const AlwaysScrollableScrollPhysics(),
                                            children: [
                                              Text(l.r09_noMatchingMedications),
                                            ],
                                          )
                                        : ListView.separated(
                                            key: const ValueKey(
                                              'medication-list',
                                            ),
                                            controller: _scroll,
                                            physics:
                                                const AlwaysScrollableScrollPhysics(),
                                            itemCount: matching.length,
                                            separatorBuilder: (_, _) =>
                                                const SizedBox(height: 8),
                                            itemBuilder: (context, i) => _row(
                                              matching[i],
                                              local: local,
                                              showPerson: showPerson,
                                              inline: false,
                                              selected:
                                                  matching[i].pill.id == paneId,
                                              onOpen: () => setState(
                                                () => _focusId =
                                                    matching[i].pill.id,
                                              ),
                                            ),
                                          ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 20),
                          Expanded(
                            child: paneId == null
                                ? const SizedBox.shrink()
                                : KeyedSubtree(
                                    key: ValueKey('medication-pane-$paneId'),
                                    child: MedicationDetailView(
                                      pillId: paneId,
                                      embedded: true,
                                      onDeleted: () => _afterDelete(paneId),
                                    ),
                                  ),
                          ),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _medications(
    List<MedicationCareDetail> all, {
    required bool local,
    required bool showPerson,
  }) {
    final query = _search.text.trim().toLowerCase();
    final items = _inListOrder(
      all.where((item) => item.pill.name.toLowerCase().contains(query)),
      local,
    );
    if (items.isEmpty) {
      return Text(AppLocalizations.of(context).r09_noMatchingMedications);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns =
            constraints.maxWidth < 330 ||
                MediaQuery.textScalerOf(context).scale(16) > 21
            ? 1
            : 2;
        return Column(
          children: [
            for (var i = 0; i < items.length; i += columns)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var j = 0; j < columns; j++) ...[
                        if (j != 0) const SizedBox(width: 8),
                        Expanded(
                          child: i + j < items.length
                              ? StaggeredEntrance(
                                  index: i + j,
                                  identity:
                                      'medication-${items[i + j].pill.id}',
                                  child: BlisterPulse(
                                    key: _cardKeys.putIfAbsent(
                                      items[i + j].pill.id,
                                      GlobalKey.new,
                                    ),
                                    count: _pulses[items[i + j].pill.id] ?? 0,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    child: _medicationCard(
                                      items[i + j],
                                      local: local,
                                      showPerson: showPerson,
                                    ),
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// The blister card under the title, in the list's order, when any
  /// medication tracks its supply.
  List<Widget> _blister(List<MedicationCareDetail> all, {required bool local}) {
    final now = DateTime.now();
    final cells = [
      for (final item in _inListOrder(all, local))
        BlisterCell(
          id: item.pill.id,
          name: item.pill.name,
          color: medicationTint(id: item.pill.id, color: item.pill.color),
          shape:
              ref
                  .watch(medicationLooksProvider)
                  .asData
                  ?.value[item.pill.id]
                  ?.shape ??
              medicationShapeOf(item.review.form),
          stock: item.stock?.whole,
          stockText: item.stock?.leftText(_lang),
          threshold: item.pill.lowStockThreshold,
          // The same "running low" rule as the stock card on Today.
          runsLowInDays: item.pill.isPrn
              ? null
              : daysUntilLowStock(
                  supplyForecastFor(item, local: local, now: now),
                ),
        ),
    ];
    if (!MedicationBlister.shows(cells)) return const [];
    return [
      MedicationBlister(
        key: const ValueKey('medication-blister'),
        cells: cells,
        scroll: _scroll,
        onTap: _showCard,
      ),
      const SizedBox(height: 20),
    ];
  }

  Widget _medicationCard(
    MedicationCareDetail item, {
    required bool local,
    required bool showPerson,
  }) {
    final l = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final noRoutine = local && item.routineVersions.isEmpty && !item.pill.isPrn;
    final cardSupply = local
        ? supplyForecastFor(item, local: true, now: DateTime.now())
        : null;
    final tint = medicationTint(id: item.pill.id, color: item.pill.color);
    return Pressable(
      onTap: _deleting
          ? null
          : _editing
          ? () => _select(item.pill.id)
          : () => context.push('/pills/${item.pill.id}'),
      radius: BorderRadius.circular(16),
      child: Stack(
        children: [
          // The card grows into the detail page's plate; its mark flies on
          // its own, so it sits over the card rather than in it.
          MedicationCardSurface(
            id: item.pill.id,
            tint: tint,
            // Tap belongs to the Pressable above; a tap-aware InkWell here would
            // win the arena and swallow it, so only long press is recognised.
            child: GestureDetector(
              key: ValueKey('medication-${item.pill.id}'),
              onLongPress: _deleting ? null : () => _select(item.pill.id),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 168),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
                  child: Column(
                    children: [
                      SizedBox(
                        height: 58,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Align(
                              alignment: AlignmentDirectional.topEnd,
                              child: _editing
                                  ? Checkbox(
                                      key: ValueKey(
                                        'select-medication-${item.pill.id}',
                                      ),
                                      value: _selectedIds.contains(
                                        item.pill.id,
                                      ),
                                      onChanged: _deleting
                                          ? null
                                          : (_) => _select(item.pill.id),
                                    )
                                  : PopupMenuButton<String>(
                                      tooltip: l.r09_medicationActions,
                                      padding: EdgeInsets.zero,
                                      icon: const Icon(
                                        Icons.more_vert,
                                        size: 21,
                                      ),
                                      onSelected: (action) {
                                        if (action == 'details') {
                                          context.push(
                                            '/pills/${item.pill.id}',
                                          );
                                        }
                                        if (action == 'select') {
                                          _select(item.pill.id);
                                        }
                                      },
                                      itemBuilder: (_) => [
                                        PopupMenuItem(
                                          value: 'details',
                                          child: Text(l.r09_viewDetails),
                                        ),
                                        PopupMenuItem(
                                          value: 'select',
                                          child: Text(l.r09_selectMedication),
                                        ),
                                      ],
                                    ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        item.pill.name,
                        textAlign: TextAlign.center,
                        style: text.titleMedium?.copyWith(
                          fontSize: 18,
                          height: 1.2,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (showPerson) ...[
                        const SizedBox(height: 4),
                        Text(
                          item.person.name,
                          textAlign: TextAlign.center,
                          style: text.labelMedium,
                        ),
                      ],
                      if (item.review.packageStrength != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          item.review.packageStrength!,
                          textAlign: TextAlign.center,
                          style: text.bodySmall,
                        ),
                      ],
                      const SizedBox(height: 6),
                      Text(
                        keepSeparatorsAttached(
                          noRoutine
                              ? l.r09_noRoutine
                              : medicationRoutineLabel(
                                  context,
                                  item,
                                  local: local,
                                ),
                        ),
                        textAlign: TextAlign.center,
                        style: text.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      if (dosageNeedsReview(item.review)) ...[
                        const SizedBox(height: 6),
                        Text(
                          keepSeparatorsAttached(l.t09_legacyDosage),
                          key: ValueKey('medication-legacy-${item.pill.id}'),
                          textAlign: TextAlign.center,
                          style: text.bodySmall,
                        ),
                      ],
                      if (expiryState(
                        item.pill.expiresOn,
                        DateTime.now(),
                      ).needsNotice) ...[
                        const SizedBox(height: 6),
                        MedicationExpiryTag(
                          key: ValueKey('medication-expiry-${item.pill.id}'),
                          state: expiryState(
                            item.pill.expiresOn,
                            DateTime.now(),
                          ),
                          center: true,
                        ),
                      ],
                      const Spacer(),
                      if (item.stock != null) ...[
                        const SizedBox(height: 8),
                        StockCapsule(
                          stock: item.stock!.whole,
                          stockText: item.stock!.leftText(_lang),
                          threshold: item.pill.lowStockThreshold,
                          runsLowInDays: item.pill.isPrn
                              ? null
                              : daysUntilLowStock(cardSupply),
                          color: medicationTint(
                            id: item.pill.id,
                            color: item.pill.color,
                          ),
                        ),
                        if (item.stock!.needsRecount)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: StockRecountNote(
                              key: ValueKey('recount-card-${item.pill.id}'),
                              center: true,
                            ),
                          ),
                        ?() {
                          final supply = cardSupply;
                          final line = supply == null
                              ? null
                              : supplyCardLine(context, supply);
                          if (line == null) return null;
                          return Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              line,
                              key: ValueKey('supply-card-${item.pill.id}'),
                              textAlign: TextAlign.center,
                              style: text.labelMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: supply!.enoughUntil == null
                                    ? Theme.of(context)
                                          .extension<AppSemanticColors>()!
                                          .statusMissed
                                    : null,
                              ),
                            ),
                          );
                        }(),
                      ],
                      if (noRoutine && !_editing) ...[
                        const SizedBox(height: 8),
                        FilledButton.tonal(
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 36),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: () =>
                              context.push('/pills/${item.pill.id}/routine'),
                          child: Text(
                            l.t08_addRoutine,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 8,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Center(
                child: ExcludeSemantics(
                  child: MedicationMarkHero(
                    id: item.pill.id,
                    name: item.pill.name,
                    color: tint,
                    shape: medicationShapeOf(item.review.form),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Earliest dose of the day first, then by name.
List<MedicationCareDetail> _inListOrder(
  Iterable<MedicationCareDetail> items,
  bool local,
) => items.toList()
  ..sort((a, b) {
    final time = _firstRoutineMinute(
      a,
      local,
    ).compareTo(_firstRoutineMinute(b, local));
    return time != 0 ? time : a.pill.name.compareTo(b.pill.name);
  });

int _firstRoutineMinute(MedicationCareDetail detail, bool local) {
  if (local) {
    final now = DateTime.now().toUtc();
    final version =
        detail.routineVersions
            .where((v) => !v.effectiveFrom.isAfter(now))
            .lastOrNull ??
        detail.routineVersions.lastOrNull;
    if (version == null) return 1441;
    final definition = RoutineDefinition.fromJson(
      jsonDecode(version.definitionJson) as Map<String, dynamic>,
    );
    final time = definition.times.firstOrNull;
    return time == null ? 1440 : time.hour * 60 + time.minute;
  }
  final times =
      detail.schedules
          .where((s) => s.isActive && !s.isDeleted)
          .map((s) => s.hour * 60 + s.minute)
          .toList()
        ..sort();
  return times.firstOrNull ?? (detail.pill.isPrn ? 1440 : 1441);
}

/// [medicationRoutineLabel] with each clock time kept whole: "9:00 AM" wraps
/// as one word, never as "9:00" over "AM".
String medicationRoutineLabel(
  BuildContext context,
  MedicationCareDetail detail, {
  required bool local,
}) => keepTimesWhole(_routineLabel(context, detail, local: local));

String _routineLabel(
  BuildContext context,
  MedicationCareDetail detail, {
  required bool local,
}) {
  final l = AppLocalizations.of(context);
  // An as-needed medicine never shows a routine or schedule.
  if (detail.pill.isPrn) return l.asn_onlyWhenNeeded;
  if (local) {
    if (detail.routineVersions.isEmpty) return l.t09_noRoutine;
    final now = DateTime.now().toUtc();
    final active = detail.routineVersions
        .where((v) => !v.effectiveFrom.isAfter(now))
        .lastOrNull;
    final version = active ?? detail.routineVersions.last;
    final definition = RoutineDefinition.fromJson(
      jsonDecode(version.definitionJson) as Map<String, dynamic>,
    );
    return active == null
        ? '${routineSummary(context, definition)} · ${l.t09_changesFrom} ${routineInstantLabel(context, version.effectiveFrom, definition.timeZone)}'
        : routineSummary(context, definition);
  }
  final active = detail.schedules
      .where((s) => s.isActive && !s.isDeleted)
      .toList();
  if (active.isEmpty) return l.pills_noActiveSchedules;
  return active
      .map((s) => TimeOfDay(hour: s.hour, minute: s.minute).format(context))
      .join(' · ');
}

class StockChip extends StatelessWidget {
  const StockChip({
    super.key,
    required this.stock,
    required this.threshold,
    this.stockText,
    this.referencePresentation = false,
  });

  final int stock;
  final int? threshold;

  /// The count as printed, when it is the exact stock in a unit.
  final String? stockText;
  final bool referencePresentation;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    final isLow = threshold != null && stock <= threshold!;
    final isNegative = stock < 0;
    final isEmpty = stock == 0;

    final Color bgColor;
    final Color fgColor;
    if (isNegative || isEmpty) {
      bgColor = cs.errorContainer;
      fgColor = cs.onErrorContainer;
    } else if (isLow) {
      bgColor = Colors.amber.shade100;
      fgColor = Colors.amber.shade900;
    } else {
      bgColor = referencePresentation
          ? cs.primaryContainer
          : cs.surfaceContainerHighest;
      fgColor = referencePresentation
          ? cs.onPrimaryContainer
          : cs.onSurfaceVariant;
    }

    final l = AppLocalizations.of(context);
    final stockLabel = l.pills_stockLeft(stockText ?? '$stock');
    final spokenLabel = isNegative
        ? Localizations.localeOf(context).languageCode == 'ro'
              ? 'Atenție: stoc negativ. $stockLabel'
              : 'Warning: negative stock. $stockLabel'
        : stockLabel;
    return Semantics(
      label: spokenLabel,
      child: ExcludeSemantics(
        child: Chip(
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
          avatar: referencePresentation && !isNegative
              ? null
              : Icon(
                  isNegative
                      ? Icons.warning_amber_rounded
                      : Icons.inventory_2_outlined,
                  size: 14,
                  color: fgColor,
                ),
          label: Text(
            stockLabel,
            style: (referencePresentation ? text.labelLarge : text.labelSmall)
                ?.copyWith(color: fgColor),
          ),
          backgroundColor: bgColor,
          side: BorderSide.none,
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }
}
