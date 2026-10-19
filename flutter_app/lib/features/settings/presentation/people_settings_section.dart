import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/widgets/drag_handle.dart';
import 'settings_overview.dart';
import 'settings_pane.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/layouts/window_size.dart';
import '../../../shared/widgets/confirm_delete_dialog.dart';
import '../../profiles/profile_provider.dart';
import '../../../shared/motion/pressable.dart';
import '../../../shared/widgets/person_avatar.dart';
import '../../../shared/widgets/status_chip.dart';

import 'recorded_by_settings_group.dart';
import 'settings_widgets.dart';

class PeopleSettingsSection extends ConsumerStatefulWidget {
  const PeopleSettingsSection({super.key});
  @override
  ConsumerState<PeopleSettingsSection> createState() =>
      _PeopleSettingsSectionState();
}

class _PeopleSettingsSectionState extends ConsumerState<PeopleSettingsSection> {
  Future<void> _showDeleteProfileSheet(BuildContext context) async {
    final l = AppLocalizations.of(context);
    final profiles = ref.read(profileListProvider).valueOrNull ?? const [];
    if (profiles.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.settings_noProfilesToDelete)));
      return;
    }

    final selected = <String>{};
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final cs = Theme.of(ctx).colorScheme;
          final text = Theme.of(ctx).textTheme;
          return DraggableScrollableSheet(
            initialChildSize: 0.55,
            maxChildSize: 0.9,
            minChildSize: 0.35,
            expand: false,
            builder: (_, scrollController) => Column(
              children: [
                const DragHandle(),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      AppLocalizations.of(ctx).settings_deleteAProfile,
                      style: text.titleLarge,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    itemCount: profiles.length,
                    itemBuilder: (_, i) {
                      final item = profiles[i];
                      final id = item.profile.id;
                      return CheckboxListTile(
                        value: selected.contains(id),
                        onChanged: (checked) {
                          setSheetState(() {
                            if (checked == true) {
                              selected.add(id);
                            } else {
                              selected.remove(id);
                            }
                          });
                        },
                        title: Text(item.profile.name),
                        subtitle: Text(
                          item.profile.isActive
                              ? AppLocalizations.of(ctx).shared_enabled
                              : AppLocalizations.of(ctx).shared_disabled,
                        ),
                        secondary: PersonAvatar(
                          id: id,
                          name: item.profile.name,
                          emoji: item.profile.avatarEmoji,
                          size: 40,
                          muted: !item.profile.isActive,
                        ),
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          child: Text(AppLocalizations.of(ctx).shared_cancel),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: cs.error,
                            foregroundColor: cs.onError,
                          ),
                          onPressed: selected.isEmpty
                              ? null
                              : () async {
                                  final dl = AppLocalizations.of(ctx);
                                  final selectedNames = profiles
                                      .where(
                                        (p) => selected.contains(p.profile.id),
                                      )
                                      .map((p) => p.profile.name)
                                      .join(', ');
                                  final messenger = ScaffoldMessenger.of(
                                    context,
                                  );
                                  final deletedMessage = AppLocalizations.of(
                                    ctx,
                                  ).settings_profilesDeleted;
                                  final confirmed =
                                      await showConfirmDeleteDialog(
                                        ctx,
                                        title: dl.settings_deleteProfileCount(
                                          selected.length,
                                        ),
                                        message: dl
                                            .settings_deleteProfileConfirm(
                                              selectedNames,
                                            ),
                                      );
                                  if (!confirmed) return;
                                  if (!mounted || !ctx.mounted) return;

                                  final repo = ref.read(
                                    profileRepositoryProvider,
                                  );
                                  for (final id in selected) {
                                    await repo.delete(id);
                                  }

                                  if (ctx.mounted) Navigator.of(ctx).pop();
                                  if (mounted && messenger.mounted) {
                                    messenger.showSnackBar(
                                      SnackBar(content: Text(deletedMessage)),
                                    );
                                  }
                                },
                          child: Text(
                            AppLocalizations.of(ctx).settings_deleteSelected,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final profilesAsync = ref.watch(profileListProvider);
    final primaryAsync = ref.watch(primaryProfileIdProvider);
    final people = profilesAsync.valueOrNull ?? const <ProfileWithCount>[];
    return Scaffold(
      appBar: settingsDetailAppBar(context, SettingsSection.people.label(l)),
      body: ContentListView(
        maxWidth: settingsContentWidth(context),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          SettingsGroup(
            label: l.r8_peopleManageGroup,
            index: 0,
            identity: 'people-manage',
            children: [
              SettingsNavigationRow(
                icon: Icons.person_add_alt,
                title: l.profiles_addTooltip,
                onTap: () => context.push('/setup?purpose=person'),
              ),
              SettingsNavigationRow(
                icon: Icons.people_outline,
                title: l.t08_people,
                accessory: PersonAvatarStack(
                  size: 28,
                  people: [
                    for (final p in people)
                      (
                        id: p.profile.id,
                        name: p.profile.name,
                        emoji: p.profile.avatarEmoji,
                      ),
                  ],
                ),
                onTap: () => context.push('/people/manage'),
              ),
            ],
          ),
          if (people.length > 1)
            SettingsGroup(
              label: l.settings_primaryProfile,
              index: 1,
              identity: 'people-primary',
              children: [
                primaryAsync.when(
                  loading: () => Padding(
                    padding: const EdgeInsets.all(16),
                    child: CircularProgressIndicator(
                      semanticsLabel: l.semantics_loading,
                    ),
                  ),
                  error: (_, _) => SettingsErrorTile(
                    label: l.settings_couldNotLoadPrimary,
                    onRetry: () => ref.invalidate(primaryProfileIdProvider),
                  ),
                  data: (primaryId) => RadioGroup<String>(
                    groupValue: primaryId,
                    onChanged: (value) => ref
                        .read(primaryProfileIdProvider.notifier)
                        .setPrimary(value),
                    child: Column(
                      children: [
                        for (final item in people)
                          RadioListTile<String>(
                            value: item.profile.id,
                            title: Text(
                              item.profile.name,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: StatusChip(
                                label: item.profile.isActive
                                    ? l.profiles_active
                                    : l.profiles_inactive,
                                tone: item.profile.isActive
                                    ? StatusTone.good
                                    : StatusTone.neutral,
                                icon: item.profile.isActive
                                    ? Icons.notifications_active_outlined
                                    : Icons.notifications_paused_outlined,
                                dense: true,
                              ),
                            ),
                            secondary: PersonAvatar(
                              id: item.profile.id,
                              name: item.profile.name,
                              emoji: item.profile.avatarEmoji,
                              size: 40,
                              muted: !item.profile.isActive,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          const RecordedBySettingsGroup(index: 2),
          SettingsGroup(
            label: l.r8_peopleRemoveGroup,
            index: 3,
            identity: 'people-remove',
            children: [
              Pressable(
                child: InkWell(
                  key: const ValueKey('people-delete-row'),
                  onTap: () => _showDeleteProfileSheet(context),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        SettingsIcon(
                          icon: Icons.delete_forever_outlined,
                          color: theme.colorScheme.error,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l.settings_deleteAProfile,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: theme.colorScheme.error,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                l.settings_deleteAProfileSubtitle,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
