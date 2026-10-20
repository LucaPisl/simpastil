import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/device/battery_optimization.dart';
import '../../../core/errors/app_error.dart';
import '../../../core/notifications/reminder_provider.dart';
import '../../../core/notifications/reminder_readiness.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/durable_save_feedback.dart';
import '../../../shared/widgets/capsule_mark.dart';
import '../../../shared/widgets/reminder_notification_preview.dart';
import '../../../shared/widgets/status_chip.dart';
import '../../profiles/profile_provider.dart';
import '../../settings/presentation/reminder_privacy_settings.dart';

class SetupReminders extends ConsumerStatefulWidget {
  const SetupReminders({super.key, required this.onContinue, this.personId});
  final VoidCallback onContinue;

  /// The person just added, when there is one: this step then offers a switch
  /// for that person's reminders on this device.
  final String? personId;
  @override
  ConsumerState<SetupReminders> createState() => _SetupRemindersState();
}

class _SetupRemindersState extends ConsumerState<SetupReminders>
    with WidgetsBindingObserver {
  /// How long a delivered check can reasonably take on a slow phone.
  static const _waitSeconds = 15;
  ReminderReadinessService? _lastService;
  ReminderReadiness? _result;
  bool _busy = false, _failed = false, _notSeen = false;
  Timer? _ticker;
  String? _trackedTest;
  int _ticks = 0;

  /// Whether battery saving limits Simpastil in the background; null until
  /// read. "Not now" hides the card for this visit only.
  bool? _batteryRestricted;
  bool _batteryDismissed = false, _batteryBusy = false;
  bool _choiceFailed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshBattery();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The request opens a system dialog; read the answer again on return.
    if (state == AppLifecycleState.resumed) _refreshBattery();
  }

  Future<void> _refreshBattery() async {
    final restricted = await ref
        .read(batteryOptimizationProvider)
        .isRestricted();
    if (mounted) setState(() => _batteryRestricted = restricted);
  }

  Future<void> _allowBackground() async {
    if (_batteryBusy) return;
    setState(() => _batteryBusy = true);
    try {
      await ref.read(batteryOptimizationProvider).requestUnrestricted();
    } finally {
      if (mounted) setState(() => _batteryBusy = false);
    }
    await _refreshBattery();
  }

  Future<void> _setDetails(bool fullDetails) async {
    setState(() => _choiceFailed = false);
    try {
      await ref.read(setReminderFullDetailsProvider)(fullDetails);
      ref.invalidate(reminderDisplayPreferencesProvider);
      ref.invalidate(reminderCoverageProvider);
    } on Object {
      if (mounted) setState(() => _choiceFailed = true);
    }
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
        .value
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
          // Once a check is on its way, the preview is that very notification;
          // before, it follows the lock-screen choice made just below.
          child: allowed && facts?.test?.scheduled == true
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
        const SizedBox(height: 18),
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
            if (allowed && _batteryRestricted == false)
              status(l.onb_batteryNoLimits, true),
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
        const SizedBox(height: 28),
        // Optional choices, all changeable later: after the main flow, so the
        // way through the step stays short and obvious.
        Semantics(
          header: true,
          child: Text(
            l.onb_choicesTitle,
            style: text.titleSmall?.copyWith(
              color: colors.onSurfaceVariant,
              fontWeight: FontWeight.w700,
              letterSpacing: .2,
            ),
          ),
        ),
        const SizedBox(height: 10),
        if (widget.personId case final personId?) ...[
          _PersonRemindersSwitch(
            key: ValueKey('person-reminders-$personId'),
            personId: personId,
            onFailed: () => setState(() => _choiceFailed = true),
            onChanged: () => setState(() => _choiceFailed = false),
          ),
          const SizedBox(height: 10),
        ],
        _ChoiceCard(
          child: SwitchListTile(
            key: const ValueKey('reminder-details-switch'),
            contentPadding: _choicePadding,
            title: Text(l.onb_detailsTitle, style: _choiceTitle(text)),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(l.onb_detailsBody),
            ),
            value: fullDetails ?? true,
            onChanged: fullDetails == null ? null : _setDetails,
          ),
        ),
        if (_choiceFailed) ...[
          const SizedBox(height: 10),
          CalmNotice(
            key: const ValueKey('choice-failed'),
            text: l.onb_choiceFailed,
            tone: StatusTone.attention,
            live: true,
          ),
        ],
        if (allowed && _batteryRestricted == true && !_batteryDismissed) ...[
          const SizedBox(height: 10),
          _BatteryCard(
            busy: _batteryBusy,
            onAllow: _allowBackground,
            onNotNow: () => setState(() => _batteryDismissed = true),
          ),
        ],
        const SizedBox(height: 20),
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

const _choicePadding = EdgeInsets.fromLTRB(16, 6, 12, 6);

TextStyle? _choiceTitle(TextTheme text) =>
    text.titleMedium?.copyWith(fontWeight: FontWeight.w600);

/// A quiet rounded surface for one choice, like the person reminder sheet.
class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({required this.child});
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
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// "Remind me about {name} on this device": this device's reminder choice for
/// the person just added. It shows once the name and the choice are known, and
/// stays out of the way when they cannot be read: the step still works
/// without it.
class _PersonRemindersSwitch extends ConsumerStatefulWidget {
  const _PersonRemindersSwitch({
    super.key,
    required this.personId,
    required this.onFailed,
    required this.onChanged,
  });
  final String personId;
  final VoidCallback onFailed, onChanged;

  @override
  ConsumerState<_PersonRemindersSwitch> createState() =>
      _PersonRemindersSwitchState();
}

class _PersonRemindersSwitchState
    extends ConsumerState<_PersonRemindersSwitch> {
  bool? _enabled;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await ref
          .read(profileRepositoryProvider)
          .getDeviceRemindersEnabled(widget.personId);
      if (!mounted) return;
      if (result case Ok(:final value)) setState(() => _enabled = value);
    } on Object {
      // Optional: without the answer the switch simply stays out of the way.
    }
  }

  Future<void> _save(bool value) async {
    if (_busy) return;
    setState(() => _busy = true);
    widget.onChanged();
    try {
      final result = await ref
          .read(profileRepositoryProvider)
          .setDeviceRemindersEnabled(widget.personId, value);
      if (mounted && result is Err<void>) widget.onFailed();
    } on Object {
      if (mounted) widget.onFailed();
    } finally {
      // Show what is stored, even if a later refresh failed after saving.
      await _load();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _enabled;
    final name = ref
        .watch(profileMembershipProvider)
        .value
        ?.where((p) => p.id == widget.personId)
        .firstOrNull
        ?.name;
    if (enabled == null || name == null) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    return _ChoiceCard(
      child: SwitchListTile(
        key: const ValueKey('person-reminders-switch'),
        contentPadding: _choicePadding,
        title: Text(
          l.onb_personRemindersTitle(name),
          style: _choiceTitle(Theme.of(context).textTheme),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(l.onb_personRemindersBody),
        ),
        value: enabled,
        onChanged: _busy ? null : _save,
      ),
    );
  }
}

/// Plain words about battery savers, one button that asks Android to leave
/// Simpastil alone, and a way to skip it.
class _BatteryCard extends StatelessWidget {
  const _BatteryCard({
    required this.busy,
    required this.onAllow,
    required this.onNotNow,
  });
  final bool busy;
  final VoidCallback onAllow, onNotNow;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context), text = theme.textTheme;
    final colors = theme.colorScheme;
    return _ChoiceCard(
      child: Padding(
        key: const ValueKey('battery-card'),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ExcludeSemantics(
                  child: Icon(
                    Icons.battery_saver_outlined,
                    color: colors.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      l.onb_batteryTitle,
                      style: text.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(l.onb_batteryBody, style: text.bodyMedium),
            const SizedBox(height: 14),
            FilledButton.tonalIcon(
              key: const ValueKey('battery-allow'),
              onPressed: busy ? null : onAllow,
              icon: const Icon(Icons.battery_charging_full_rounded),
              label: Text(l.onb_batteryAllow),
            ),
            TextButton(
              key: const ValueKey('battery-not-now'),
              onPressed: onNotNow,
              child: Text(l.onb_batteryNotNow),
            ),
            const SizedBox(height: 4),
            Text(
              l.onb_batterySamsungTip,
              style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
