import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/notifications/reminder_preferences.dart';
import '../../../core/notifications/reminder_provider.dart';
import '../../../core/protection/app_lock_controller.dart';
import '../../../l10n/app_localizations.dart';
import 'settings_overview.dart';

final reminderDisplayPreferencesProvider =
    FutureProvider.autoDispose<ReminderPreferences>((ref) async {
      final lease = ref
          .read(appLockControllerProvider.notifier)
          .captureAccess();
      final repository = await ref.watch(
        reminderPreferencesRepositoryProvider.future,
      );
      final preferences = await repository.load();
      lease.requireCurrent();
      return preferences;
    });

/// Which cards of the privacy settings a [ReminderPrivacySettings] shows.
/// Wide windows split them: the choices go with the settings, and the test
/// goes under the preview.
enum ReminderPrivacyPart { all, choices, test }

class ReminderPrivacySettings extends ConsumerStatefulWidget {
  const ReminderPrivacySettings({
    super.key,
    this.part = ReminderPrivacyPart.all,
  });
  final ReminderPrivacyPart part;
  @override
  ConsumerState<ReminderPrivacySettings> createState() =>
      _ReminderPrivacySettingsState();
}

class _ReminderPrivacySettingsState
    extends ConsumerState<ReminderPrivacySettings> {
  bool _busy = false;
  String? _message;
  bool? _routeWasCurrent;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final routeIsCurrent = ModalRoute.isCurrentOf(context) ?? true;
    final returnedToSettings = _routeWasCurrent == false && routeIsCurrent;
    _routeWasCurrent = routeIsCurrent;
    if (!returnedToSettings) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !(ModalRoute.isCurrentOf(context) ?? false)) return;
      ref.invalidate(reminderCoverageProvider);
    });
  }

  Future<void> _change(bool fullDetails) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await ref.read(setReminderFullDetailsProvider)(fullDetails);
      ref.invalidate(reminderDisplayPreferencesProvider);
      ref.invalidate(reminderCoverageProvider);
    } on AppLockRequired {
      if (mounted) {
        setState(
          () => _message = AppLocalizations.of(context).t15_accessExpired,
        );
      }
    } on Object {
      if (mounted) {
        setState(() => _message = AppLocalizations.of(context).t15_loadFailed);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _test({String? observedId}) async {
    final l = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final lease = ref
          .read(appLockControllerProvider.notifier)
          .captureAccess();
      final service = await ref.read(reminderReadinessServiceProvider.future);
      lease.requireCurrent();
      if (observedId == null) {
        await service.requestTest(localizations: l);
      } else {
        await service.confirmObserved(observedId);
      }
      lease.requireCurrent();
      ref.invalidate(reminderReadinessProvider);
      ref.invalidate(reminderCoverageProvider);
    } on AppLockRequired {
      if (mounted) setState(() => _message = l.t15_accessExpired);
    } on Object {
      if (mounted) setState(() => _message = l.t15_testFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final preferences = ref.watch(reminderDisplayPreferencesProvider);
    final readiness = ref.watch(reminderReadinessProvider).valueOrNull;
    final coverageState = ref.watch(reminderCoverageProvider);
    final coverage = coverageState.isLoading || coverageState.hasError
        ? null
        : coverageState.valueOrNull;
    final coverageMessage = coverage?.degraded == true
        ? l.t15_coverageDegraded
        : coverage?.coverageShortened == true &&
              coverage!.scheduledCount == 0 &&
              coverage.availableCount > 0
        ? l.t15_coverageNone
        : coverage?.coverageShortened == true
        ? l.t15_coverageShortened
        : null;
    final test = readiness?.test;
    final choices = widget.part != ReminderPrivacyPart.test;
    final testCard = widget.part != ReminderPrivacyPart.choices;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (choices)
          preferences.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.t15_loadFailed),
                TextButton(
                  onPressed: () =>
                      ref.invalidate(reminderDisplayPreferencesProvider),
                  child: Text(l.shared_retry),
                ),
              ],
            ),
            data: (preferences) => SettingsGroup(
              label: l.t15_remindersSubtitle,
              children: [
                RadioGroup<bool>(
                  groupValue: preferences.fullDetails,
                  onChanged: (value) {
                    if (!_busy && value != null) _change(value);
                  },
                  child: Column(
                    children: [
                      RadioListTile<bool>(
                        value: true,
                        title: Text(l.t15_fullDetails),
                        subtitle: Text(l.t15_fullDetailsBody),
                      ),
                      RadioListTile<bool>(
                        value: false,
                        title: Text(l.t15_privateReminders),
                        subtitle: Text(l.t15_privateBody),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        if (choices && coverageMessage != null)
          SettingsGroup(
            label: l.t15_reminderCoverage,
            children: [
              ListTile(
                leading: Icon(
                  coverage?.degraded == true
                      ? Icons.warning_amber_rounded
                      : Icons.info_outline,
                  color: coverage?.degraded == true
                      ? Theme.of(context).colorScheme.error
                      : null,
                ),
                title: Text(coverageMessage),
              ),
            ],
          ),
        if (choices)
          SettingsGroup(
            label: l.t15_reminderPeople,
            children: [
              ListTile(
                leading: const Icon(Icons.people_outline),
                title: Text(l.t15_reminderPeopleBody),
              ),
              ListTile(
                title: Text(l.t15_openPeople),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/people/manage'),
              ),
            ],
          ),
        if (testCard)
          SettingsGroup(
            label: l.t15_reminderTest,
            children: [
              ListTile(
                title: Text(l.t15_reminderTestBody),
                subtitle: test == null
                    ? null
                    : Text(
                        test.observed
                            ? l.t15_testObserved
                            : test.scheduled
                            ? l.t15_testScheduled
                            : l.t15_testFailed,
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    OutlinedButton(
                      onPressed: _busy ? null : () => _test(),
                      child: Text(l.t15_sendTest),
                    ),
                    if (test?.scheduled == true && test?.observed == false)
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => _test(observedId: test!.testId),
                        child: Text(l.t15_confirmObserved),
                      ),
                  ],
                ),
              ),
            ],
          ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Semantics(liveRegion: true, child: Text(_message!)),
          ),
      ],
    );
  }
}
