import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/errors/app_error.dart';
import '../../../core/medication/medication_detail_provider.dart';
import '../../../core/medication/medication_detail_repository.dart';
import '../../../core/medication/routine_definition.dart';
import '../../../core/medication/routine_repository.dart';
import '../../../core/notifications/reminder_provider.dart';
import '../../../core/notifications/reminder_status.dart';
import '../../../core/workspace/workspace_provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../profiles/profile_provider.dart';
import '../../../shared/format/clock.dart';
import '../../../shared/router/app_router.dart';
import '../../../shared/widgets/status_chip.dart';
import '../../schedules/presentation/day_part.dart';
import 'reminder_privacy_settings.dart';
import 'settings_overview.dart';

/// The distinct scheduled times of day across [details], earliest first.
///
/// Local routines use the version in effect now (or the next one when none
/// has started); connected medications use their active schedules. As-needed
/// medications have no times. A routine that cannot be read is skipped
/// rather than guessed.
List<TimeOfDay> reminderTimesOf(
  List<MedicationCareDetail> details, {
  required bool local,
  DateTime? now,
}) {
  final at = (now ?? DateTime.now()).toUtc();
  final minutes = <int>{};
  for (final detail in details) {
    if (local) {
      if (detail.routineVersions.isEmpty) continue;
      final active = detail.routineVersions
          .where((v) => !v.effectiveFrom.isAfter(at))
          .lastOrNull;
      final version = active ?? detail.routineVersions.last;
      try {
        final definition = RoutineDefinition.fromJson(
          jsonDecode(version.definitionJson) as Map<String, dynamic>,
        );
        for (final t in definition.times) {
          minutes.add(t.hour * 60 + t.minute);
        }
      } on Object {
        continue;
      }
    } else {
      if (detail.pill.isPrn) continue;
      for (final s in detail.schedules) {
        if (s.isActive && !s.isDeleted) minutes.add(s.hour * 60 + s.minute);
      }
    }
  }
  final sorted = minutes.toList()..sort();
  return [for (final m in sorted) TimeOfDay(hour: m ~/ 60, minute: m % 60)];
}

({String label, String body, StatusTone tone, IconData icon}) _statusWords(
  AppLocalizations l,
  ReminderStatusKind kind,
  String? degradedBody,
) => switch (kind) {
  ReminderStatusKind.checking => (
    label: l.r6_statusChecking,
    body: '',
    tone: StatusTone.neutral,
    icon: Icons.hourglass_empty_rounded,
  ),
  ReminderStatusKind.on => (
    label: l.r6_statusOn,
    body: l.r6_statusOnBody,
    tone: StatusTone.good,
    icon: Icons.notifications_active_outlined,
  ),
  ReminderStatusKind.needsPermission => (
    label: l.r6_statusNeedsPermission,
    body: l.r6_statusNeedsPermissionBody,
    tone: StatusTone.attention,
    icon: Icons.notifications_off_outlined,
  ),
  ReminderStatusKind.mayBeLate => (
    label: l.r6_statusMayBeLate,
    body: l.r6_statusMayBeLateBody,
    tone: StatusTone.attention,
    icon: Icons.schedule_rounded,
  ),
  ReminderStatusKind.someMissing => (
    label: l.r6_statusSomeMissing,
    body: degradedBody ?? l.t15_coverageDegraded,
    tone: StatusTone.attention,
    icon: Icons.error_outline_rounded,
  ),
  ReminderStatusKind.unavailable => (
    label: l.r6_statusUnavailable,
    body: l.r6_statusUnavailableBody,
    tone: StatusTone.neutral,
    icon: Icons.do_not_disturb_on_outlined,
  ),
};

/// How many active people are switched on for reminders and the widget on
/// this device ("Reminders on this device" in the person menu). Null when it
/// cannot be read, so the status card then says only what it knows.
final reminderPeopleOnDeviceProvider =
    FutureProvider.autoDispose<({int on, int total})?>((ref) async {
      try {
        final people = (await ref.watch(
          profileListProvider.future,
        )).where((p) => p.profile.isActive).toList(growable: false);
        if (people.isEmpty) return null;
        final repository = ref.watch(profileRepositoryProvider);
        var on = 0;
        for (final person in people) {
          final result = await repository.getDeviceRemindersEnabled(
            person.profile.id,
          );
          if (result case Ok(:final value)) {
            if (value) on++;
          } else {
            return null;
          }
        }
        return (on: on, total: people.length);
      } on Object {
        return null;
      }
    });

/// "This device": one status and the privacy choice in words. The preview of
/// a reminder with that choice is its own card.
class ReminderStatusCard extends ConsumerStatefulWidget {
  const ReminderStatusCard({super.key});

  @override
  ConsumerState<ReminderStatusCard> createState() => _ReminderStatusCardState();
}

class _ReminderStatusCardState extends ConsumerState<ReminderStatusCard>
    with WidgetsBindingObserver {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from Android settings: read permissions again.
    if (state == AppLifecycleState.resumed && mounted) {
      ref.invalidate(reminderReadinessProvider);
      ref.invalidate(reminderPeopleOnDeviceProvider);
    }
  }

  Future<void> _allow() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final service = await ref.read(reminderReadinessServiceProvider.future);
      await service.requestAccess();
    } on Object {
      // The status below keeps saying what is true; nothing to add here.
    } finally {
      if (mounted) {
        ref.invalidate(reminderReadinessProvider);
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final readiness = ref.watch(reminderReadinessProvider);
    final coverage = ref.watch(reminderCoverageProvider).valueOrNull;
    final fullDetails = ref
        .watch(reminderDisplayPreferencesProvider)
        .valueOrNull
        ?.fullDetails;
    final kind = readiness.hasError
        ? ReminderStatusKind.unavailable
        : reminderStatusOf(
            permissions: readiness.valueOrNull?.permissions,
            coverageDegraded: coverage?.degraded == true,
          );
    final people = ref.watch(reminderPeopleOnDeviceProvider).valueOrNull;
    // Permissions alone do not make reminders appear: a person must also be
    // switched on for this device, or nothing is scheduled and the widget
    // stays empty. Never show a green "on" when no one is switched on.
    final nobodyOn = people != null && people.on == 0;
    final someOff = people != null && people.on < people.total;
    final base = _statusWords(l, kind, null);
    final words = kind == ReminderStatusKind.on && nobodyOn
        ? (
            label: l.r10_statusNobodyOn,
            body: l.r10_statusNobodyOnBody,
            tone: StatusTone.attention,
            icon: Icons.person_off_outlined,
          )
        : base;
    return SettingsGroup(
      label: l.r6_statusTitle,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  Semantics(
                    liveRegion: true,
                    child: StatusChip(
                      key: const ValueKey('reminder-status'),
                      label: words.label,
                      tone: words.tone,
                      icon: words.icon,
                    ),
                  ),
                  if (fullDetails != null)
                    StatusChip(
                      key: const ValueKey('reminder-privacy'),
                      label: fullDetails
                          ? l.r6_privacyNames
                          : l.r6_privacyPrivate,
                      tone: StatusTone.neutral,
                      icon: fullDetails
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                ],
              ),
              if (words.body.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  words.body,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (someOff) ...[
                const SizedBox(height: 8),
                ListTile(
                  key: const ValueKey('reminder-people-hint'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.person_outline_rounded),
                  title: Text(
                    nobodyOn
                        ? l.r10_peopleHintNone
                        : l.r10_peopleHintSome(people.on, people.total),
                  ),
                  subtitle: Text(l.r10_peopleHintBody),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => context.push('/people/manage'),
                ),
              ],
              if (kind == ReminderStatusKind.needsPermission) ...[
                const SizedBox(height: 12),
                FilledButton.tonal(
                  key: const ValueKey('reminder-status-allow'),
                  onPressed: _busy ? null : _allow,
                  child: Text(l.t09_allowReminders),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// "Your reminder day": every scheduled time in words, and a way to the
/// routine where times change.
class ReminderDayCard extends ConsumerWidget {
  const ReminderDayCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final list = ref.watch(medicationListProvider).valueOrNull;
    final workspace = ref.watch(workspaceContextProvider).valueOrNull;
    if (list == null || workspace == null) return const SizedBox.shrink();
    final times = reminderTimesOf(list, local: workspace.isLocal);
    return SettingsGroup(
      label: l.r6_dayTitle,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                child: Text(
                  times.isEmpty ? l.r6_dayEmpty : l.r6_dayBody,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (times.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final t in times)
                        StatusChip(
                          dense: true,
                          tone: StatusTone.working,
                          icon: Icons.notifications_none_rounded,
                          label:
                              '${clockTime(context, t)} · ${dayPartLabel(l, dayPartOf(t))}',
                        ),
                    ],
                  ),
                ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  key: const ValueKey('reminder-day-edit'),
                  onPressed: () => context.go(AppPaths.schedules),
                  icon: const Icon(Icons.edit_calendar_outlined),
                  label: Text(l.r6_dayEdit),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
