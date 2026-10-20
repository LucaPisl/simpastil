import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/app_error.dart';
import '../../core/notifications/reminder_provider.dart';
import '../../core/storage/preference_keys.dart';
import '../../core/storage/shared_preferences_provider.dart';
import '../../core/workspace/workspace_provider.dart';
import '../../l10n/app_localizations.dart';
import '../profiles/profile_provider.dart';
import '../settings/presentation/reminder_overview_cards.dart';

/// Whether the "Reminders are off" card was closed on this device. Reads as
/// closed while the workspace is not known, so the card never flashes.
class RemindersOffDismissedNotifier extends Notifier<bool> {
  @override
  bool build() {
    final owner = ref.watch(
      workspaceContextProvider.select((v) => v.value?.ownerUserId),
    );
    if (owner == null) return true;
    return ref
            .watch(sharedPreferencesProvider)
            .getBool(remindersOffNoticeDismissedPreferenceKey(owner)) ??
        false;
  }

  /// Hides the card for good on this device.
  Future<void> dismiss() async {
    final owner = ref.read(workspaceContextProvider).value?.ownerUserId;
    state = true;
    if (owner == null) return;
    try {
      await ref
          .read(sharedPreferencesProvider)
          .setBool(remindersOffNoticeDismissedPreferenceKey(owner), true);
    } on Object {
      // Still hidden for this session.
    }
  }
}

final remindersOffDismissedProvider =
    NotifierProvider<RemindersOffDismissedNotifier, bool>(
      RemindersOffDismissedNotifier.new,
    );

/// "Reminders are off on this device": shown on Today when people exist but
/// none of them gets dose reminders here, with one button to switch them on
/// and a close button that hides it for good. Hides itself otherwise.
class RemindersOffCard extends ConsumerStatefulWidget {
  const RemindersOffCard({super.key, this.margin = EdgeInsets.zero});

  final EdgeInsetsGeometry margin;

  @override
  ConsumerState<RemindersOffCard> createState() => _RemindersOffCardState();
}

class _RemindersOffCardState extends ConsumerState<RemindersOffCard> {
  bool _busy = false;

  Future<void> _turnOn() async {
    if (_busy) return;
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _busy = true);
    var failed = false;
    try {
      final people = (await ref.read(
        profileListProvider.future,
      )).where((p) => p.profile.isActive);
      final repository = ref.read(profileRepositoryProvider);
      for (final person in people) {
        final result = await repository.setDeviceRemindersEnabled(
          person.profile.id,
          true,
        );
        if (result is Err<void>) failed = true;
      }
    } on Object {
      failed = true;
    }
    if (!failed) {
      // Reminders need the device's permission too: ask now, while the person
      // has just asked for them. A refusal is shown in Settings, not here.
      try {
        final service = await ref.read(reminderReadinessServiceProvider.future);
        final readiness = await service.inspect();
        if (readiness.permissions.notificationsAllowed != true) {
          await service.requestAccess();
        }
      } on Object {
        // The reminder settings keep saying what is true.
      }
    }
    if (!mounted) return;
    ref.invalidate(reminderPeopleOnDeviceProvider);
    ref.invalidate(reminderReadinessProvider);
    setState(() => _busy = false);
    if (failed) {
      messenger?.showSnackBar(
        SnackBar(content: Text(l.onb_remindersOffFailed)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final people = ref.watch(reminderPeopleOnDeviceProvider).value;
    final dismissed = ref.watch(remindersOffDismissedProvider);
    if (dismissed || people == null || people.total == 0 || people.on > 0) {
      return const SizedBox.shrink();
    }
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: widget.margin,
      child: Material(
        key: const ValueKey('reminders-off-card'),
        color: colors.secondaryContainer,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 4, 8),
          child: Row(
            children: [
              Icon(
                Icons.notifications_off_outlined,
                color: colors.onSecondaryContainer,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.onb_remindersOffTitle,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: colors.onSecondaryContainer,
                      ),
                    ),
                    Text(
                      l.onb_remindersOffBody,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSecondaryContainer,
                      ),
                    ),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton(
                        key: const ValueKey('reminders-off-turn-on'),
                        // Line the label up with the title and body text.
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          alignment: AlignmentDirectional.centerStart,
                        ),
                        onPressed: _busy ? null : _turnOn,
                        child: Text(l.onb_remindersOffAction),
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                key: const ValueKey('reminders-off-dismiss'),
                tooltip: l.onb_remindersOffDismiss,
                icon: Icon(Icons.close, color: colors.onSecondaryContainer),
                onPressed: () =>
                    ref.read(remindersOffDismissedProvider.notifier).dismiss(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
