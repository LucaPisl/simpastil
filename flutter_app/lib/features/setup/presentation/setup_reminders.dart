import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/notifications/reminder_provider.dart';
import '../../../core/notifications/reminder_readiness.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/durable_save_feedback.dart';
import '../../../shared/widgets/capsule_mark.dart';
import '../../../shared/widgets/reminder_notification_preview.dart';
import '../../../shared/widgets/status_chip.dart';
import '../../settings/presentation/reminder_privacy_settings.dart';

class SetupReminders extends ConsumerStatefulWidget {
  const SetupReminders({super.key, required this.onContinue});
  final VoidCallback onContinue;
  @override
  ConsumerState<SetupReminders> createState() => _SetupRemindersState();
}

class _SetupRemindersState extends ConsumerState<SetupReminders> {
  /// How long a delivered check can reasonably take on a slow phone.
  static const _waitSeconds = 15;
  ReminderReadinessService? _lastService;
  ReminderReadiness? _result;
  bool _busy = false, _failed = false, _notSeen = false;
  Timer? _ticker;
  String? _trackedTest;
  int _ticks = 0;

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// Counts seconds while a scheduled check is pending, once per check.
  void _track(ReminderTestFacts? test) {
    if (test == null || !test.scheduled || test.observed) {
      _ticker?.cancel();
      _ticker = null;
      return;
    }
    if (_trackedTest == test.testId) return;
    _trackedTest = test.testId;
    _ticks = 0;
    _notSeen = false;
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return timer.cancel();
      setState(() => _ticks++);
      if (_ticks >= _waitSeconds) timer.cancel();
    });
  }

  int _elapsed(ReminderTestFacts test) {
    final real = DateTime.now().toUtc().difference(test.requestedAt).inSeconds;
    return real > _ticks ? real : _ticks;
  }

  Future<void> _act(
    ReminderReadinessService service,
    Future<ReminderReadiness> Function() action,
  ) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    bool owns() =>
        mounted &&
        identical(
          ref.read(reminderReadinessServiceProvider).asData?.value,
          service,
        );
    try {
      final result = await action();
      if (owns()) setState(() => _result = result);
    } on Object {
      if (owns()) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final serviceState = ref.watch(reminderReadinessServiceProvider);
    final readiness = ref.watch(reminderReadinessProvider);
    final service = serviceState.isLoading || serviceState.hasError
        ? null
        : serviceState.asData?.value;
    if (!identical(service, _lastService)) {
      _lastService = service;
      _result = null;
    }
    final facts =
        _result ??
        (readiness.isLoading || readiness.hasError
            ? null
            : readiness.asData?.value);
    final colors = Theme.of(context).colorScheme;
    final fullDetails = ref
        .watch(reminderDisplayPreferencesProvider)
        .valueOrNull
        ?.fullDetails;
    final allowed = facts?.permissions.notificationsAllowed == true;
    final confirmed = facts?.deliveryConfirmed == true;
    _track(facts?.test);
    Widget status(String label, bool checked) => StatusChip(
      label: label,
      tone: checked ? StatusTone.good : StatusTone.neutral,
      icon: checked ? Icons.check_circle_outline_rounded : Icons.schedule,
    );
    Widget why(String label) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const CapsuleMark(size: 24),
          const SizedBox(width: 12),
          Expanded(child: Text(label, style: text.bodyLarge)),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The reminder itself, as the lock screen will show it with the
        // current privacy choice: what will arrive, before asking.
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
          child: allowed
              ? ReminderNotificationPreview.check(l)
              : ReminderNotificationPreview.sample(
                  l,
                  fullDetails: fullDetails ?? true,
                ),
        ),
        const SizedBox(height: 24),
        Text(
          allowed ? l.r08_checkTitle : l.r08_remindersTitle,
          style: text.headlineMedium?.copyWith(
            height: 1.15,
            fontWeight: FontWeight.w700,
            letterSpacing: -.5,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          l.r6_permBody,
          style: text.bodyLarge?.copyWith(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 18),
        if (!allowed) ...[
          why(l.r6_whyNudge),
          why(l.r6_whyActions),
          why(l.r6_whyPrivacy),
          why(l.r6_whyNothingRecorded),
          const SizedBox(height: 6),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            status(
              facts == null
                  ? l.shared_loading
                  : allowed
                  ? l.r08_notificationsAllowed
                  : l.r08_notificationsNotAllowed,
              allowed,
            ),
            if (allowed)
              status(
                confirmed ? l.r08_testConfirmed : l.r08_testNotConfirmed,
                confirmed,
              ),
          ],
        ),
        const SizedBox(height: 14),
        if (confirmed)
          DurableSaveFeedback(label: l.t09_deliveryConfirmed)
        // A pending check can only be seen while notifications are allowed.
        else if (allowed && facts?.test?.scheduled == true) ...[
          if (_elapsed(facts!.test!) < _waitSeconds) ...[
            Semantics(
              liveRegion: true,
              child: Text(
                l.r09_checkWaiting(_elapsed(facts.test!)),
                style: text.bodyLarge,
              ),
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              key: const ValueKey('reminder-wait'),
              value: _elapsed(facts.test!) / _waitSeconds,
            ),
            const SizedBox(height: 8),
            Text(
              l.r09_checkWaitingHint,
              style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            // Seeing it early is enough; nobody has to wait out the timer.
            OutlinedButton(
              key: const ValueKey('confirm-reminder-seen'),
              onPressed: _busy || service == null
                  ? null
                  : () => _act(
                      service,
                      () => service.confirmObserved(facts.test!.testId),
                    ),
              child: Text(l.t09_sawReminder),
            ),
          ] else ...[
            Text(
              l.r09_checkQuestion,
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('confirm-reminder-seen'),
                    onPressed: _busy || service == null
                        ? null
                        : () => _act(
                            service,
                            () => service.confirmObserved(facts.test!.testId),
                          ),
                    child: Text(l.r09_checkYes),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    key: const ValueKey('reminder-not-seen'),
                    onPressed: () => setState(() => _notSeen = true),
                    child: Text(l.r09_checkNo),
                  ),
                ),
              ],
            ),
            if (_notSeen) ...[
              const SizedBox(height: 12),
              CalmNotice(
                key: const ValueKey('reminder-help'),
                text: l.r09_checkNoHelp,
                tone: StatusTone.attention,
                live: true,
              ),
            ],
          ],
        ] else if (allowed)
          Text(
            l.r08_checkHelp,
            style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
          ),
        if (allowed && facts?.permissions.canSchedule != true) ...[
          const SizedBox(height: 12),
          Text(l.t09_remindersUnavailable, style: text.bodyMedium),
        ],
        const SizedBox(height: 20),
        if (facts?.permissions.canSchedule != true)
          FilledButton(
            key: const ValueKey('allow-reminders'),
            onPressed: _busy || service == null
                ? null
                : () => _act(service, service.requestAccess),
            child: Text(_busy ? l.shared_loading : l.t09_allowReminders),
          )
        else
          OutlinedButton(
            key: const ValueKey('check-reminders'),
            onPressed: _busy || service == null
                ? null
                : () => _act(
                    service,
                    () => service.requestTest(localizations: l),
                  ),
            child: Text(_busy ? l.shared_loading : l.t09_checkReminders),
          ),
        if (_failed) ...[
          const SizedBox(height: 12),
          CalmNotice(
            text: l.t09_remindersUnavailable,
            tone: StatusTone.attention,
            live: true,
          ),
        ],
        const SizedBox(height: 12),
        if (confirmed)
          FilledButton(
            key: const ValueKey('reminders-continue'),
            onPressed: widget.onContinue,
            child: Text(l.shared_continue),
          )
        else
          TextButton(
            key: const ValueKey('reminders-continue'),
            onPressed: widget.onContinue,
            child: Text(l.t09_remindersLater),
          ),
      ],
    );
  }
}
