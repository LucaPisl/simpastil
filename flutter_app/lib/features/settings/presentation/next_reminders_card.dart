import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/notifications/next_reminders.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/format/clock.dart';
import '../../../shared/widgets/capsule_mark.dart';
import '../../../shared/widgets/reminder_notification_preview.dart';
import 'reminder_privacy_settings.dart';
import 'settings_overview.dart';

/// How a reminder's time reads in the list: "Tonight 23:00", "Tomorrow
/// 08:00", "Sat 23:00", or the date from a week out.
///
/// [time] is the clock time already written the way this phone writes it.
/// "Tonight" starts at 18:00; the days are counted on the calendar, not in
/// 24-hour steps.
String reminderWhenLabel(
  AppLocalizations l, {
  required DateTime at,
  required DateTime now,
  required String time,
  required String locale,
}) {
  final days = DateTime(
    at.year,
    at.month,
    at.day,
  ).difference(DateTime(now.year, now.month, now.day)).inDays;
  if (days <= 0) {
    return at.hour >= 18 ? l.ts_whenTonight(time) : l.ts_whenToday(time);
  }
  if (days == 1) return l.ts_whenTomorrow(time);
  if (days < 7) return l.ts_whenDay(DateFormat.E(locale).format(at), time);
  return l.ts_whenDay(DateFormat.MMMd(locale).format(at), time);
}

/// The planned reminders for the cards below it, kept current while it is on
/// screen: it plans again when the data or a reminder choice changes, and
/// when the next reminder's time passes.
class NextRemindersScope extends ConsumerStatefulWidget {
  const NextRemindersScope({super.key, required this.child, this.clock});

  final Widget child;

  /// The time now; tests replace it.
  final DateTime Function()? clock;

  /// The plan the nearest scope holds. Loading and failed reads are values
  /// too, so a card can say what it knows.
  static AsyncValue<NextRemindersPlan> of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_NextRemindersData>();
    assert(scope != null, 'No NextRemindersScope above this widget');
    return scope?.plan ?? const AsyncLoading();
  }

  static DateTime nowOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_NextRemindersData>()?.now ??
      DateTime.now();

  @override
  ConsumerState<NextRemindersScope> createState() => _NextRemindersScopeState();
}

class _NextRemindersScopeState extends ConsumerState<NextRemindersScope> {
  Timer? _timer;

  DateTime _now() => (widget.clock ?? DateTime.now)();

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _armRefresh(NextRemindersPlan? plan) {
    _timer?.cancel();
    final first = plan?.first;
    if (first == null) {
      _timer = null;
      return;
    }
    // Plan again just after the first reminder has passed, but at least once
    // an hour so a long idle page never shows yesterday's "Tonight".
    final wait = first.at.difference(_now()) + const Duration(seconds: 1);
    final capped = wait > const Duration(hours: 1)
        ? const Duration(hours: 1)
        : wait;
    _timer = Timer(capped.isNegative ? Duration.zero : capped, () {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final source = ref.watch(nextRemindersSourceProvider);
    final now = _now();
    final plan = source.whenData(
      (value) => planNextReminders(value, now: now, localizations: l),
    );
    // Arm the timer after this frame: a build must not start side effects.
    final current = plan.valueOrNull;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _armRefresh(current);
    });
    return _NextRemindersData(plan: plan, now: now, child: widget.child);
  }
}

class _NextRemindersData extends InheritedWidget {
  const _NextRemindersData({
    required this.plan,
    required this.now,
    required super.child,
  });

  final AsyncValue<NextRemindersPlan> plan;
  final DateTime now;

  @override
  bool updateShouldNotify(_NextRemindersData old) =>
      old.plan != plan || old.now != now;
}

/// "Next reminders on this device": the next few planned reminders, nearest
/// first, with the time each fires.
class NextRemindersCard extends ConsumerWidget {
  const NextRemindersCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final plan = NextRemindersScope.of(context);
    final now = NextRemindersScope.nowOf(context);
    final locale = Localizations.localeOf(context).toString();
    final muted = theme.colorScheme.onSurfaceVariant;
    Widget message(String text, {Widget? action}) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text, style: theme.textTheme.bodyMedium?.copyWith(color: muted)),
          ?action,
        ],
      ),
    );
    return SettingsGroup(
      key: const ValueKey('next-reminders'),
      label: l.ts_nextTitle,
      children: [
        ...plan.when(
          loading: () => [
            const SizedBox(key: ValueKey('next-loading'), height: 56),
          ],
          error: (_, _) => [
            message(
              l.ts_nextLoadFailed,
              action: TextButton(
                onPressed: () => ref.invalidate(nextRemindersSourceProvider),
                child: Text(l.shared_retry),
              ),
            ),
          ],
          data: (data) => data.upcoming.isEmpty
              ? [
                  message(
                    data.peopleCount == 0
                        ? l.ts_nextEmptyNobody
                        : l.ts_nextEmpty,
                  ),
                ]
              : [
                  for (final reminder in data.upcoming)
                    _ReminderRow(
                      key: ValueKey('next-${reminder.occurrenceId}'),
                      reminder: reminder,
                      showPerson: data.peopleCount > 1,
                      when: reminderWhenLabel(
                        l,
                        at: reminder.at,
                        now: now,
                        time: clockAt(context, reminder.at),
                        locale: locale,
                      ),
                    ),
                ],
        ),
      ],
    );
  }
}

class _ReminderRow extends StatelessWidget {
  const _ReminderRow({
    super.key,
    required this.reminder,
    required this.showPerson,
    required this.when,
  });

  final UpcomingReminder reminder;
  final bool showPerson;
  final String when;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final detail = [
      if (reminder.dosage case final String dosage when dosage.isNotEmpty)
        dosage,
      if (showPerson) reminder.profileName,
    ].join(' · ');
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            const CapsuleMark(size: 26),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    reminder.pillName,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (detail.isNotEmpty)
                    Text(
                      detail,
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 132),
              child: Text(
                when,
                textAlign: TextAlign.end,
                style: theme.textTheme.bodyMedium?.copyWith(color: muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// How the next reminder will look on this device. It is that reminder's own
/// wording, made with the privacy choice, so it changes when the choice does.
/// Without a planned reminder it shows an example, and says so.
class ReminderPreviewCard extends ConsumerWidget {
  const ReminderPreviewCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final plan = NextRemindersScope.of(context).valueOrNull;
    final saved = ref
        .watch(reminderDisplayPreferencesProvider)
        .valueOrNull
        ?.fullDetails;
    final fullDetails = plan?.fullDetails ?? saved ?? true;
    final first = plan?.first;
    return SettingsGroup(
      label: l.ts_previewTitle,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (first == null)
                ReminderNotificationPreview.sample(
                  l,
                  key: const ValueKey('reminder-preview'),
                  fullDetails: fullDetails,
                  elevated: false,
                )
              else
                ReminderNotificationPreview.planned(
                  l,
                  key: const ValueKey('reminder-preview'),
                  copy: first.copy,
                  when: clockAt(context, first.at),
                  fullDetails: fullDetails,
                  elevated: false,
                ),
              const SizedBox(height: 10),
              Text(
                first == null ? l.ts_previewSample : l.ts_previewNext,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
