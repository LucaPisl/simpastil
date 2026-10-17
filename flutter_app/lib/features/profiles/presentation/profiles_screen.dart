import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sync/auto_sync_service.dart';
import '../../../core/db/database.dart';
import '../../../shared/format/clock.dart';
import '../../../core/errors/app_error.dart';
import '../../../core/medication/care_day.dart';
import '../../../core/medication/late_dose.dart';
import '../../../core/medication/care_provider.dart';
import '../../../core/medication/occurrence_detail_provider.dart';
import '../../../core/medication/routine_definition.dart';
import '../../../shared/layouts/window_size.dart';
import '../../../shared/motion/app_motion.dart';
import '../../../shared/motion/pressable.dart';
import '../../../shared/motion/staggered_entrance.dart';
import '../../dashboard/care_record_form.dart';
import '../../../core/workspace/workspace_provider.dart';
import '../../../core/workspace/workspace_context.dart';
import '../../../shared/widgets/care_state.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/confirm_delete_dialog.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/error_view.dart';
import '../../../shared/widgets/person_avatar.dart';
import '../../../shared/widgets/status_chip.dart';
import '../../pills/presentation/medication_identity.dart';
import '../profile_provider.dart';
import '../profile_repository.dart';
import 'add_edit_profile_sheet.dart';
import 'person_day_line.dart';
import '../../dashboard/today_layout/today_layout.dart';

class ProfilesScreen extends ConsumerWidget {
  const ProfilesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context), colors = theme.colorScheme;
    final profiles = ref.watch(profileListProvider);
    final workspace = ref.watch(workspaceContextProvider);
    final available =
        !workspace.isLoading && !workspace.hasError && workspace.asData != null;
    return Scaffold(
      appBar: AppBar(
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        titleSpacing: 20,
        title: Text(
          l.appTitle,
          style: theme.textTheme.titleLarge?.copyWith(
            color: colors.primary,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          if (available &&
              !workspace.requireValue.isLocal &&
              profiles.asData != null)
            IconButton(
              key: const ValueKey('connected-people-management'),
              tooltip: l.r09_managePeople,
              icon: const Icon(Icons.tune),
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                showDragHandle: true,
                builder: (_) => SizedBox(
                  height: MediaQuery.sizeOf(context).height * .8,
                  child: _ConnectedPeopleManagement(),
                ),
              ),
            ),
          IconButton(
            tooltip: l.profiles_addTooltip,
            onPressed: available
                ? () => context.push('/setup?purpose=person')
                : null,
            icon: const Icon(Icons.person_add_outlined),
          ),
          // The side rail carries Settings on wide windows.
          if (!WindowClass.of(context).showsRail)
            IconButton(
              tooltip: l.nav_settings,
              onPressed: () => context.push('/settings'),
              icon: const Icon(Icons.settings_outlined, size: 26),
            ),
        ],
      ),
      body: !available
          ? CareState(
              title: workspace.hasError ? l.t08_unavailable : l.shared_loading,
              loading: !workspace.hasError,
            )
          : profiles.hasError
          ? ErrorView(
              message: l.profiles_couldNotLoad,
              onRetry: () => ref.invalidate(profileListProvider),
            )
          : profiles.isLoading || profiles.asData == null
          ? CareState(title: l.shared_loading, loading: true)
          : RefreshIndicator(
              onRefresh: () async {
                final captured = workspace.requireValue;
                try {
                  if (!captured.isLocal) {
                    await ref
                        .read(autoSyncServiceProvider)
                        .syncNow(captured.ownerUserId);
                  }
                  if (!context.mounted ||
                      !identical(
                        captured,
                        ref.read(workspaceContextProvider).asData?.value,
                      )) {
                    return;
                  }
                  ref.invalidate(profileListProvider);
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
              },
              child: profiles.requireValue.isEmpty
                  ? EmptyState(
                      art: EmptyStateArt.people,
                      ctaIcon: Icons.person_add_alt_1_outlined,
                      title: l.profiles_noProfYet,
                      subtitle: l.profiles_createToGetStarted,
                      ctaLabel: l.profiles_createFirstCta,
                      onCta: () => context.push('/setup?purpose=person'),
                    )
                  : _CarePeople(profiles: profiles.requireValue),
            ),
    );
  }
}

class _ConnectedPeopleManagement extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workspace = ref.watch(workspaceContextProvider);
    final profiles = ref.watch(profileListProvider);
    final l = AppLocalizations.of(context);
    if (workspace.hasError ||
        profiles.hasError ||
        workspace.asData?.value.isLocal == true) {
      return CareState(title: l.t08_unavailable);
    }
    if (workspace.isLoading ||
        profiles.isLoading ||
        workspace.asData == null ||
        profiles.asData == null) {
      return CareState(title: l.shared_loading, loading: true);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
          child: Semantics(
            header: true,
            child: Text(
              l.r09_managePeople,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ),
        Expanded(child: _ProfileList(profiles: profiles.requireValue)),
      ],
    );
  }
}

Future<void> _viewCare(
  BuildContext context,
  WidgetRef ref,
  String? personId,
) async {
  final captured = ref.read(workspaceContextProvider).asData?.value;
  if (captured == null) return;
  final selection = ref.read(selectedProfileIdProvider.notifier);
  // The tapped row may move or leave the list once its person is in focus,
  // so the checks after the unroll do not lean on its context or ref.
  final container = ProviderScope.containerOf(context, listen: false);
  final router = GoRouter.of(context);
  final from = router.routerDelegate.currentConfiguration.uri.path;
  bool current() =>
      identical(
        captured,
        container.read(workspaceContextProvider).asData?.value,
      ) &&
      container.read(selectedProfileIdProvider).valueOrNull == personId &&
      router.routerDelegate.currentConfiguration.uri.path == from;
  try {
    await selection.select(personId);
    if (!current()) return;
    // A person rising from the rows unrolls their ring into the card first.
    await container.read(personDayLocatorProvider).landed;
    if (!current()) return;
    router.go('/home');
  } on Object {
    // A changed protected context cannot redirect a newer viewer.
  }
}

class _CarePeople extends ConsumerWidget {
  const _CarePeople({required this.profiles});
  final List<ProfileWithCount> profiles;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context), theme = Theme.of(context);
    final selected = ref.watch(selectedProfileIdProvider);
    if (selected.hasError) return CareState(title: l.t08_unavailable);
    // Choosing a person reloads the selection; the list keeps the previous
    // one meanwhile, so the tapped row, its ring and the cards stay put.
    if (!selected.hasValue) {
      return CareState(title: l.shared_loading, loading: true);
    }
    final focus =
        profiles.where((p) => p.profile.id == selected.value).firstOrNull ??
        profiles.first;
    final ordered = [
      focus,
      ...profiles.where((p) => p.profile.id != focus.profile.id),
    ];
    // The list spans the pane (so the side margins scroll) and every row
    // keeps the page's column by adding the gutter to its own padding.
    return PersonUnrollHost(
      child: ContentColumn(
        builder: (context, gutter) {
          final inset = const EdgeInsets.symmetric(horizontal: 20) + gutter;
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(top: 0, bottom: 24),
            children: [
              Padding(
                padding: inset,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l.r09_peopleToday,
                        style: theme.textTheme.headlineLarge?.copyWith(
                          fontSize: 38,
                          height: 1.1,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -.8,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        l.r09_peopleBody,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontSize: 17,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              LayoutBuilder(
                builder: (context, bounds) {
                  // Cards are sized to the column; the strip itself runs the
                  // width of the pane and scrolls under the side margins.
                  final column = bounds.maxWidth - gutter.horizontal;
                  final large =
                      column < 360 ||
                      MediaQuery.textScalerOf(context).scale(16) > 22;
                  final cardWidth = large || profiles.length == 1
                      ? column - 40
                      : column * .76;
                  return SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: inset,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var i = 0; i < ordered.length; i++) ...[
                          if (i != 0) const SizedBox(width: 10),
                          SizedBox(
                            // Keyed, so a person keeps their card (and its
                            // drawn line) when the focus moves.
                            key: ValueKey(
                              'person-card-slot-${ordered[i].profile.id}',
                            ),
                            width: cardWidth,
                            child: StaggeredEntrance(
                              index: i,
                              identity: 'person-card-${ordered[i].profile.id}',
                              child: _PersonCareCard(
                                person: ordered[i].profile,
                                highlighted: i == 0,
                                preview: i != 0 && !large,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 14),
              for (final (index, item) in ordered.indexed.skip(1))
                Padding(
                  padding: inset.copyWith(top: 0, bottom: 10),
                  child: StaggeredEntrance(
                    index: index,
                    identity: 'person-row-${item.profile.id}',
                    child: _PersonCareRow(person: item.profile),
                  ),
                ),
              if (profiles.length > 1)
                Padding(
                  padding: inset,
                  child: StaggeredEntrance(
                    index: ordered.length,
                    identity: 'person-everyone',
                    child: _EveryoneRow(
                      people: [for (final item in ordered) item.profile],
                      onTap: () => _viewCare(context, ref, null),
                    ),
                  ),
                ),
              Padding(
                padding: inset.copyWith(top: 12, bottom: 0),
                child: const CareSharingSummary(),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _MedicationCount extends ConsumerWidget {
  const _MedicationCount({required this.personId});
  final String personId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final count = ref.watch(pillCountByProfileProvider(personId));
    return Text(
      count.hasError
          ? l.t08_unavailable
          : count.isLoading || count.asData == null
          ? l.shared_loading
          : l.r09_medicationCount(count.requireValue),
      key: ValueKey('person-medication-count-$personId'),
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _PersonCareCard extends ConsumerWidget {
  const _PersonCareCard({
    required this.person,
    required this.highlighted,
    this.preview = false,
  });
  final Profile person;
  final bool highlighted, preview;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context), theme = Theme.of(context);
    final colors = theme.colorScheme;
    final day = ref.watch(
      careDayProvider(
        CareDayRequest(
          localDate: routineDateKey(DateTime.now()),
          personId: person.id,
        ),
      ),
    );
    final hasRoutine =
        !day.hasError && day.valueOrNull?.entries.isNotEmpty == true;
    // A reload keeps showing the day it had, so the card never empties.
    final care = day.hasError ? null : day.valueOrNull;
    final tint = personTint(person.id);
    final dark = theme.brightness == Brightness.dark;
    final base = colors.surfaceContainerLow;
    final buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
    );
    return Container(
      key: ValueKey('person-care-${person.id}'),
      decoration: BoxDecoration(
        // The focused person wears a wash of their own tint; others stay on
        // the quiet group surface so the eye lands on one card.
        color: highlighted ? null : base,
        gradient: highlighted
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color.alphaBlend(
                    tint.withValues(alpha: dark ? .22 : .14),
                    base,
                  ),
                  Color.alphaBlend(
                    tint.withValues(alpha: dark ? .07 : .04),
                    base,
                  ),
                ],
              )
            : null,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: highlighted
              ? tint.withValues(alpha: .45)
              : colors.outlineVariant.withValues(alpha: .5),
        ),
      ),
      padding: const EdgeInsets.all(6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 0, 12),
            child: Row(
              children: [
                PersonAvatar(
                  id: person.id,
                  name: person.name,
                  emoji: person.avatarEmoji,
                  size: 52,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        person.name,
                        maxLines: preview ? 2 : null,
                        overflow: preview ? TextOverflow.ellipsis : null,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      _MedicationCount(personId: person.id),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  key: ValueKey('person-actions-${person.id}'),
                  tooltip: l.r09_managePeople,
                  onSelected: (value) {
                    if (value == 'reminders') {
                      final current = ref.read(workspaceContextProvider);
                      if (current.isLoading ||
                          current.hasError ||
                          current.asData == null) {
                        return;
                      }
                      final repository = ref.read(profileRepositoryProvider);
                      showModalBottomSheet<void>(
                        context: context,
                        isScrollControlled: true,
                        showDragHandle: true,
                        builder: (_) => _PersonReminderSettings(
                          person: person,
                          captured: current.requireValue,
                          repository: repository,
                        ),
                      );
                    }
                    if (value == 'edit') {
                      showAddEditProfileSheet(
                        context: context,
                        profile: person,
                      );
                    }
                    if (value == 'add') {
                      context.push(
                        Uri(
                          path: '/setup',
                          queryParameters: {
                            'purpose': 'medication',
                            'person': person.id,
                          },
                        ).toString(),
                      );
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'reminders',
                      child: Text(l.t14_personReminders),
                    ),
                    PopupMenuItem(
                      value: 'edit',
                      child: Text(l.profiles_editTitle),
                    ),
                    PopupMenuItem(
                      value: 'add',
                      child: Text(l.t09_addMedication),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(18),
            ),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _PersonCareFacts(
                  personId: person.id,
                  day: day,
                  preview: preview,
                  beside:
                      care != null &&
                          care.entries.any(
                            (e) =>
                                e.occurrence.source != 'prn' &&
                                personDoseMinute(e) != null,
                          )
                      ? PersonDayLine(
                          key: ValueKey('person-day-line-${person.id}'),
                          personId: person.id,
                          care: care,
                          locator: ref.read(personDayLocatorProvider),
                        )
                      : null,
                ),
                const SizedBox(height: 16),
                if (highlighted)
                  FilledButton.icon(
                    key: ValueKey('view-person-${person.id}'),
                    onPressed: () => _viewCare(context, ref, person.id),
                    icon: const Icon(Icons.format_list_bulleted),
                    label: Text(
                      hasRoutine ? l.r09_viewRoutine : l.t09_viewCare,
                      textAlign: TextAlign.center,
                    ),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                      shape: buttonShape,
                    ),
                  )
                else
                  OutlinedButton.icon(
                    key: ValueKey('view-person-${person.id}'),
                    onPressed: () => _viewCare(context, ref, person.id),
                    icon: const Icon(Icons.format_list_bulleted),
                    label: Text(
                      hasRoutine ? l.r09_viewRoutine : l.t09_viewCare,
                      textAlign: TextAlign.center,
                    ),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                      side: BorderSide(
                        color: colors.primary.withValues(alpha: .6),
                      ),
                      shape: buttonShape,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "View everyone": the faces of everyone in care, then the action.
class _EveryoneRow extends StatelessWidget {
  const _EveryoneRow({required this.people, required this.onTap});
  final List<Profile> people;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), theme = Theme.of(context);
    final colors = theme.colorScheme;
    return MergeSemantics(
      child: Semantics(
        button: true,
        child: Pressable(
          key: const ValueKey('view-everyone'),
          onTap: onTap,
          radius: BorderRadius.circular(20),
          child: Container(
            constraints: const BoxConstraints(minHeight: 56),
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: colors.outlineVariant.withValues(alpha: .5),
              ),
            ),
            child: Row(
              children: [
                PersonAvatarStack(
                  people: [
                    for (final p in people)
                      (id: p.id, name: p.name, emoji: p.avatarEmoji),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    l.r09_viewEveryone,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: colors.primary,
                    ),
                  ),
                ),
                ExcludeSemantics(
                  child: Icon(Icons.chevron_right, color: colors.primary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PersonReminderSettings extends ConsumerStatefulWidget {
  const _PersonReminderSettings({
    required this.person,
    required this.captured,
    required this.repository,
  });
  final Profile person;
  final WorkspaceContext captured;
  final ProfileRepository repository;
  @override
  ConsumerState<_PersonReminderSettings> createState() =>
      _PersonReminderSettingsState();
}

class _PersonReminderSettingsState
    extends ConsumerState<_PersonReminderSettings> {
  bool? _enabled;
  bool _busy = false;
  bool _failed = false;

  bool get _current {
    if (!mounted) return false;
    final current = ref.read(workspaceContextProvider);
    return !current.isLoading &&
        !current.hasError &&
        identical(current.asData?.value, widget.captured);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await widget.repository.getDeviceRemindersEnabled(
        widget.person.id,
      );
      if (!_current) return;
      setState(() {
        switch (result) {
          case Ok(:final value):
            _enabled = value;
          case Err():
            _failed = true;
        }
      });
    } on Object {
      if (_current) setState(() => _failed = true);
    }
  }

  Future<void> _save(bool value) async {
    if (_busy || !_current) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final result = await widget.repository.setDeviceRemindersEnabled(
        widget.person.id,
        value,
      );
      if (_current && result is Err<void>) setState(() => _failed = true);
    } on Object {
      if (_current) setState(() => _failed = true);
    } finally {
      // Reload even if the optional notification refresh failed after saving.
      if (_current) await _load();
      if (_current) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(workspaceContextProvider);
    final l = AppLocalizations.of(context);
    if (!_current) return CareState(title: l.t08_unavailable);
    final theme = Theme.of(context), colors = theme.colorScheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                PersonAvatar(
                  id: widget.person.id,
                  name: widget.person.name,
                  emoji: widget.person.avatarEmoji,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(
                        header: true,
                        child: Text(
                          l.t14_personReminders,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.person.name,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (_enabled == null && !_failed)
              const Center(child: CircularProgressIndicator()),
            if (_enabled != null)
              Material(
                color: colors.surfaceContainerLow,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: BorderSide(
                    color: colors.outlineVariant.withValues(alpha: .5),
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: SwitchListTile(
                  key: const ValueKey('person-device-reminders'),
                  contentPadding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
                  title: Text(
                    l.t14_personRemindersEnabled,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(l.t14_personRemindersBody),
                  ),
                  value: _enabled!,
                  onChanged: _busy ? null : _save,
                ),
              ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(),
              ),
            if (_failed) ...[
              const SizedBox(height: 12),
              CalmNotice(
                text: l.shared_somethingWentWrong,
                icon: Icons.error_outline_rounded,
                tone: StatusTone.problem,
                live: true,
              ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  onPressed: _busy
                      ? null
                      : () {
                          setState(() => _failed = false);
                          _load();
                        },
                  child: Text(l.shared_retry),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PersonCareRow extends ConsumerWidget {
  const _PersonCareRow({required this.person});
  final Profile person;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final day = ref.watch(
      careDayProvider(
        CareDayRequest(
          localDate: routineDateKey(DateTime.now()),
          personId: person.id,
        ),
      ),
    );
    return Pressable(
      onTap: () => _viewCare(context, ref, person.id),
      radius: BorderRadius.circular(20),
      child: Material(
        color: colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: colors.outlineVariant.withValues(alpha: .5)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('person-summary-${person.id}'),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
            child: LayoutBuilder(
              builder: (context, bounds) {
                final care = day.hasError ? null : day.valueOrNull;
                final avatar = PersonAvatar(
                  id: person.id,
                  name: person.name,
                  emoji: person.avatarEmoji,
                  size: 40,
                );
                final identity = Row(
                  children: [
                    if (care == null)
                      SizedBox.square(
                        dimension: PersonDayRing.extentFor(40),
                        child: Center(child: avatar),
                      )
                    else
                      PersonDayRing(
                        personId: person.id,
                        care: care,
                        locator: ref.read(personDayLocatorProvider),
                        child: avatar,
                      ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        person.name,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                );
                final facts = _PersonCareFacts(
                  personId: person.id,
                  day: day,
                  compact: true,
                );
                final chevron = ExcludeSemantics(
                  child: Icon(
                    Icons.chevron_right,
                    color: colors.onSurfaceVariant,
                  ),
                );
                if (bounds.maxWidth < 330 ||
                    MediaQuery.textScalerOf(context).scale(16) > 22) {
                  return Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            identity,
                            const SizedBox(height: 12),
                            facts,
                          ],
                        ),
                      ),
                      chevron,
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: identity),
                    const SizedBox(width: 12),
                    Expanded(child: facts),
                    chevron,
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// How a person's latest dose state should feel in a status chip. Missed is
/// worth a look, never an alarm; an open dose is simply still to come.
@visibleForTesting
StatusTone personDoseTone(String state) => switch (state) {
  'taken' => StatusTone.good,
  'missed' => StatusTone.attention,
  'skipped' => StatusTone.neutral,
  _ => StatusTone.working,
};

@visibleForTesting
IconData personDoseIcon(String state) => switch (state) {
  'taken' => Icons.check_circle_outline_rounded,
  'missed' => Icons.error_outline_rounded,
  'skipped' => Icons.redo_rounded,
  _ => Icons.schedule_rounded,
};

class _PersonCareFacts extends StatelessWidget {
  const _PersonCareFacts({
    required this.personId,
    required this.day,
    this.compact = false,
    this.preview = false,
    this.beside,
  });
  final String personId;
  final AsyncValue<CareDay> day;
  final bool compact, preview;

  /// Drawn on the line of the time-of-day chip, so it costs no height.
  final Widget? beside;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), theme = Theme.of(context);
    if (day.hasError) return Text(l.t08_unavailable);
    if (!day.hasValue) {
      return const LinearProgressIndicator();
    }
    final care = day.requireValue;
    final now = DateTime.now();
    final planned = care.entries.where((e) => e.occurrence.expected).toList();
    final entry =
        planned
            .where((e) => e.occurrence.plannedAt?.isAfter(now) == false)
            .lastOrNull ??
        planned.firstOrNull ??
        care.entries.lastOrNull;
    final next = planned
        .where(
          (e) =>
              e.occurrence.state == 'pending' &&
              e.occurrence.plannedAt?.isAfter(now) == true,
        )
        .firstOrNull;
    if (entry == null) {
      return Text(switch (care.state) {
        CareDayState.noPeople ||
        CareDayState.noMedications => l.t08_noMedications,
        CareDayState.noRoutine => l.t08_noRoutine,
        CareDayState.asNeeded => l.t08_asNeeded,
        _ => l.t08_dayOff,
      });
    }
    final row = entry.occurrence;
    final time = plannedTimeLabel(context, row);
    final hour = int.tryParse(row.plannedLocalTime?.split(':').first ?? '');
    final period = hour == null
        ? l.t08_asNeeded
        : hour < 12
        ? l.r07_morning
        : hour < 17
        ? l.r07_afternoon
        : hour < 22
        ? l.r07_evening
        : l.r07_night;
    final colors = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!compact) ...[
          Row(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: Text(
                    period,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: colors.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              if (beside != null) ...[
                const SizedBox(width: 14),
                Expanded(child: beside!),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Text(
            time,
            style: theme.textTheme.headlineLarge?.copyWith(
              fontSize: 42,
              height: 1.1,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            entry.snapshot.pillName,
            maxLines: preview ? 2 : null,
            overflow: preview ? TextOverflow.ellipsis : null,
            style: theme.textTheme.titleLarge?.copyWith(
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            careAmountLabel(l, entry.plannedAmount),
            style: theme.textTheme.bodyLarge?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
        ] else
          Text(
            '$period · $time',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        if (compact) const SizedBox(height: 6),
        StatusChip(
          label: careOutcomeLabel(
            l,
            row.state,
            late: isTakenLate(row.state, entry.head),
          ),
          tone: personDoseTone(row.state),
          icon: personDoseIcon(row.state),
          dense: compact,
        ),
        if (row.state != 'pending' && entry.head != null)
          _PersonRecordedBy(occurrenceId: row.id, preview: preview),
        if (compact && next != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '${l.t08_next} · ${plannedTimeLabel(context, next.occurrence)}',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

class _PersonRecordedBy extends ConsumerWidget {
  const _PersonRecordedBy({required this.occurrenceId, this.preview = false});
  final String occurrenceId;
  final bool preview;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(occurrenceDetailProvider(occurrenceId));
    final l = AppLocalizations.of(context);
    if (detail.hasError) return Text(l.t08_unavailable);
    if (detail.isLoading || detail.asData == null) {
      return Text(l.shared_loading);
    }
    final head = detail.requireValue.head;
    if (head == null) return const SizedBox.shrink();
    // A miss was written by the app: no author, no actual time.
    if (head.event.action == 'miss') {
      return Padding(
        padding: const EdgeInsets.only(top: 5),
        child: Text(
          l.dose_markedMissedAuto,
          maxLines: preview ? 2 : null,
          overflow: preview ? TextOverflow.ellipsis : null,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Text(
        [
          head.authorName ??
              (head.authorId == null
                  ? l.t10_unknownAuthor
                  : l.t10_unnamedAuthor),
          head.event.actualTimeKnown
              ? careInstantLabel(context, head.event.actualAt)
              : l.t08_unknownTime,
        ].join(' · '),
        maxLines: preview ? 2 : null,
        overflow: preview ? TextOverflow.ellipsis : null,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

// ── Profile list ──────────────────────────────────────────────────────────────

class _ProfileList extends StatelessWidget {
  const _ProfileList({required this.profiles});

  final List<ProfileWithCount> profiles;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: profiles.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (ctx, i) => StaggeredEntrance(
        index: i,
        identity: 'manage-person-${profiles[i].profile.id}',
        child: _ProfileCard(item: profiles[i]),
      ),
    );
  }
}

// ── Profile card ──────────────────────────────────────────────────────────────

class _ProfileCard extends ConsumerWidget {
  const _ProfileCard({required this.item});

  final ProfileWithCount item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final profile = item.profile;
    final primaryProfileId = ref.watch(primaryProfileIdProvider).valueOrNull;
    final isPrimary = primaryProfileId == profile.id;
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final shape = BorderRadius.circular(20);

    final card = Semantics(
      label:
          '${profile.name}, ${profile.isActive ? l.profiles_active : l.profiles_inactive}',
      child: Pressable(
        // Tap opens the edit sheet; long press (below) shows the medications.
        onTap: () =>
            showAddEditProfileSheet(context: context, profile: profile),
        radius: shape,
        child: Material(
          color: cs.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: shape,
            side: BorderSide(color: cs.outlineVariant.withValues(alpha: .5)),
          ),
          clipBehavior: Clip.antiAlias,
          child: GestureDetector(
            onLongPress: () =>
                _showPillsOverviewSheet(context, ref, profile.id, profile.name),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
              child: Row(
                children: [
                  PersonAvatar(
                    id: profile.id,
                    name: profile.name,
                    emoji: profile.avatarEmoji,
                    muted: !profile.isActive,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          profile.name,
                          style: text.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Consumer(
                          builder: (context, ref, _) {
                            final count =
                                ref
                                    .watch(
                                      pillCountByProfileProvider(profile.id),
                                    )
                                    .valueOrNull ??
                                item.pillCount;
                            return Text(
                              l.profiles_pillCount(count),
                              style: text.bodySmall?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            );
                          },
                        ),
                        const SizedBox(height: 8),
                        // The row's label already says active or inactive.
                        ExcludeSemantics(
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              StatusChip(
                                label: profile.isActive
                                    ? l.profiles_active
                                    : l.profiles_inactive,
                                tone: profile.isActive
                                    ? StatusTone.good
                                    : StatusTone.neutral,
                                icon: profile.isActive
                                    ? Icons.notifications_active_outlined
                                    : Icons.notifications_paused_outlined,
                                dense: true,
                              ),
                              if (isPrimary)
                                StatusChip(
                                  label: l.profiles_primary,
                                  tone: StatusTone.working,
                                  icon: Icons.star_outline_rounded,
                                  dense: true,
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: profile.isActive,
                    onChanged: (v) => ref
                        .read(profileRepositoryProvider)
                        .toggleActive(profile.id, v),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    final dismissible = Dismissible(
      key: ValueKey(profile.id),
      direction: DismissDirection.startToEnd,
      background: Container(
        alignment: AlignmentDirectional.centerStart,
        padding: const EdgeInsetsDirectional.only(start: 20),
        decoration: BoxDecoration(color: cs.error, borderRadius: shape),
        child: Icon(Icons.delete_outline, color: cs.onError),
      ),
      confirmDismiss: (_) => showConfirmDeleteDialog(
        context,
        title: l.profiles_deleteTitle(profile.name),
        message: l.profiles_deleteMessage(profile.name),
      ),
      onDismissed: (_) =>
          ref.read(profileRepositoryProvider).delete(profile.id),
      child: card,
    );

    // Inactive cards are visually muted with a smooth transition.
    return AnimatedOpacity(
      opacity: profile.isActive ? 1.0 : 0.55,
      duration: AppMotion.duration(context, milliseconds: 250),
      child: dismissible,
    );
  }

  void _showPillsOverviewSheet(
    BuildContext context,
    WidgetRef ref,
    String profileId,
    String profileName,
  ) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) =>
          _PillsOverviewSheet(profileId: profileId, profileName: profileName),
    );
  }
}

// ── Pills overview bottom sheet ───────────────────────────────────────────────

class _PillsOverviewSheet extends ConsumerWidget {
  const _PillsOverviewSheet({
    required this.profileId,
    required this.profileName,
  });

  final String profileId;
  final String profileName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final pillsAsync = ref.watch(pillsForProfileProvider(profileId));
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      minChildSize: 0.35,
      expand: false,
      builder: (_, scrollController) => Column(
        children: [
          // ── Drag handle ──────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: cs.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Semantics(
                header: true,
                child: Text(
                  l.profiles_pillsOverviewTitle(profileName),
                  style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: pillsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(
                child: Text(
                  l.profiles_couldNotLoadPills,
                  style: text.bodyMedium?.copyWith(color: cs.error),
                ),
              ),
              data: (entries) {
                if (entries.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        l.profiles_noPillsAssigned,
                        textAlign: TextAlign.center,
                        style: text.bodyLarge?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  );
                }
                return ListView.separated(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  itemCount: entries.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (ctx, i) {
                    final (:pill, :schedules) = entries[i];
                    // The first scheduled time on the phone's clock, or
                    // "No schedule".
                    String scheduleText = l.profiles_noSchedule;
                    if (schedules.isNotEmpty) {
                      final first = schedules.first;
                      scheduleText = clockTime(
                        ctx,
                        TimeOfDay(hour: first.hour, minute: first.minute),
                      );
                    }
                    return StaggeredEntrance(
                      index: i,
                      identity: 'person-pills-$profileId-${pill.id}',
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(10, 10, 16, 10),
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Row(
                          children: [
                            MedicationMark(
                              color: medicationTint(
                                id: pill.id,
                                color: pill.color,
                              ),
                              shape: medicationShapeOf(pill.dosage),
                              size: 40,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    pill.name,
                                    style: text.titleMedium?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  Text(
                                    pill.dosage != null
                                        ? '${pill.dosage!} · $scheduleText'
                                        : scheduleText,
                                    style: text.bodyMedium?.copyWith(
                                      color: cs.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(AppLocalizations.of(context).shared_close),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
