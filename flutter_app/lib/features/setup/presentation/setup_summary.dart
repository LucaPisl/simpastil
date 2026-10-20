import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/device/battery_optimization.dart';
import '../../../core/errors/app_error.dart';
import '../../../core/notifications/reminder_provider.dart';
import '../../../core/workspace/workspace_provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/status_chip.dart';
import '../../profiles/profile_provider.dart';
import '../../settings/presentation/reminder_privacy_settings.dart';

/// The end of setup, in a few plain lines: what is switched on for reminders
/// and where to change anything that is off. A line whose answer cannot be
/// read is left out rather than guessed, and on a device with no account one
/// calm line says backups are not automatic.
class SetupSummary extends ConsumerStatefulWidget {
  const SetupSummary({super.key, required this.personId, this.personName});

  final String? personId;
  final String? personName;

  @override
  ConsumerState<SetupSummary> createState() => _SetupSummaryState();
}

class _SetupSummaryState extends ConsumerState<SetupSummary> {
  bool? _personReminders;
  bool? _batteryRestricted;

  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    final id = widget.personId;
    if (id != null) {
      try {
        final result = await ref
            .read(profileRepositoryProvider)
            .getDeviceRemindersEnabled(id);
        if (mounted) {
          if (result case Ok(:final value)) {
            setState(() => _personReminders = value);
          }
        }
      } on Object {
        // Left out of the list when it cannot be read.
      }
    }
    try {
      final restricted = await ref
          .read(batteryOptimizationProvider)
          .isRestricted();
      if (mounted) setState(() => _batteryRestricted = restricted);
    } on Object {
      // Left out of the list when it cannot be read.
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    final readiness = ref.watch(reminderReadinessProvider).value;
    final notifications = readiness?.permissions.notificationsAllowed;
    final fullDetails = ref
        .watch(reminderDisplayPreferencesProvider)
        .value
        ?.fullDetails;
    final local = ref.watch(workspaceContextProvider).value?.isLocal == true;
    final name = widget.personName?.trim();
    final rows = <Widget>[
      if (_personReminders != null && name != null && name.isNotEmpty)
        _SummaryRow(
          key: const ValueKey('summary-person-reminders'),
          on: _personReminders!,
          icon: Icons.notifications_active_outlined,
          offIcon: Icons.notifications_off_outlined,
          label: _personReminders!
              ? l.onb_summaryRemindersOn(name)
              : l.onb_summaryRemindersOff(name),
          change: l.onb_summaryChangePeople,
        ),
      if (notifications != null)
        _SummaryRow(
          key: const ValueKey('summary-notifications'),
          on: notifications,
          icon: Icons.check_circle_outline_rounded,
          offIcon: Icons.error_outline_rounded,
          label: notifications
              ? l.onb_summaryNotificationsOn
              : l.onb_summaryNotificationsOff,
          change: l.onb_summaryChangeReminders,
        ),
      if (_batteryRestricted != null)
        _SummaryRow(
          key: const ValueKey('summary-battery'),
          on: !_batteryRestricted!,
          icon: Icons.battery_charging_full_rounded,
          offIcon: Icons.battery_alert_rounded,
          label: _batteryRestricted!
              ? l.onb_batteryLimited
              : l.onb_batteryUnlimited,
          change: l.onb_summaryChangeReminders,
        ),
      if (fullDetails != null)
        _SummaryRow(
          key: const ValueKey('summary-lock-screen'),
          on: fullDetails,
          icon: Icons.visibility_outlined,
          offIcon: Icons.visibility_off_outlined,
          label: fullDetails
              ? l.onb_summaryNamesShown
              : l.onb_summaryNamesHidden,
          change: l.onb_summaryChangeReminders,
          offTone: StatusTone.neutral,
        ),
    ];
    return Column(
      key: const ValueKey('setup-summary'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (rows.isNotEmpty)
          _SummaryCard(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    l.onb_summaryTitle,
                    style: text.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                ...rows,
              ],
            ),
          ),
        if (local) ...[
          if (rows.isNotEmpty) const SizedBox(height: 12),
          _SummaryCard(
            key: const ValueKey('summary-backups'),
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(
                  child: Icon(
                    Icons.save_alt_rounded,
                    size: 22,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(l.onb_summaryBackups, style: text.bodyLarge),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// The quiet rounded surface shared by the reminders list and the backups
/// line, the same family as the choice cards of the reminders step.
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({super.key, required this.padding, required this.child});
  final EdgeInsets padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: .5)),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

/// One line: an icon, what is true, and, when it is off, where to change it.
class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    super.key,
    required this.on,
    required this.icon,
    required this.offIcon,
    required this.label,
    required this.change,
    this.offTone = StatusTone.attention,
  });

  /// How "off" reads: worth a look for reminders, plain fact for a privacy
  /// choice that was made on purpose.
  final StatusTone offTone;
  final bool on;
  final IconData icon, offIcon;
  final String label, change;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context), text = theme.textTheme;
    final tone = on ? StatusTone.good : offTone;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: Icon(
              on ? icon : offIcon,
              size: 22,
              color: statusToneColor(theme, tone),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: text.bodyLarge),
                if (!on)
                  Text(
                    change,
                    style: text.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
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
