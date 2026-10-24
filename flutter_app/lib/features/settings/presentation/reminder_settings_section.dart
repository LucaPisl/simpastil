import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../../core/device/battery_optimization.dart';
import '../../../core/l10n/locale_provider.dart';
import '../../../core/notifications/notification_plugin.dart';
import '../../../core/projections/projection_reconciler.dart';
import '../../../core/session/session_generation_repository.dart';
import '../../../core/notifications/notification_service.dart';
import '../../../core/storage/portable_preference_writer.dart';
import '../../../core/storage/preference_keys.dart';
import '../../../core/sync/ledger_mode_hint.dart';
import '../../../core/workspace/workspace_provider.dart';
import 'account_follow_widgets.dart';
import 'next_reminders_card.dart';
import 'settings_overview.dart';
import 'settings_pane.dart';
import 'reminder_overview_cards.dart';
import 'reminder_privacy_settings.dart';
import 'reminder_reset_action.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/layouts/window_size.dart';
import '../../profiles/profile_provider.dart';

const _kSnoozeDefaultMinutes = 15;
const _kMinutesMin = 1;
const _kMinutesMax = 1439;
const _kMinutesStep = 5;

class ReminderSettingsSection extends ConsumerStatefulWidget {
  const ReminderSettingsSection({super.key});
  @override
  ConsumerState<ReminderSettingsSection> createState() =>
      _ReminderSettingsSectionState();
}

class _ReminderSettingsSectionState
    extends ConsumerState<ReminderSettingsSection>
    with WidgetsBindingObserver {
  bool _autoMissEnabled = false;

  /// A connected workspace whose server cannot store missed doses (yet): the
  /// setting is saved, but nothing is recorded until the server is updated.
  bool _serverCannotRecordMisses = false;
  bool _notificationSound = true;
  bool _remindOnThisDevice = true;
  int _snoozeDurationMinutes = _kSnoozeDefaultMinutes;
  int _autoMissDelayMinutes = autoMissDefaultDelayMinutes;
  PermissionStatus _notifPermStatus = PermissionStatus.denied;
  bool _canScheduleExact = true;

  /// Whether battery saving limits Simpastil in the background; null until
  /// read.
  bool? _batteryRestricted;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadPrefs();
    });
    _refreshBattery();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the system dialog or Android settings: read it again.
    if (state == AppLifecycleState.resumed) _refreshBattery();
  }

  Future<void> _refreshBattery() async {
    final restricted = await ref
        .read(batteryOptimizationProvider)
        .isRestricted();
    if (mounted) setState(() => _batteryRestricted = restricted);
  }

  Future<void> _allowBackground() async {
    await ref.read(batteryOptimizationProvider).requestUnrestricted();
    await _refreshBattery();
  }

  Future<void> _loadPrefs() async {
    final userId = ref.read(currentUserIdProvider);
    // Read only: a settings page never writes a default. It does wait for a
    // restore that holds the preference barrier, so it shows the restored values.
    await ref.read(portablePreferenceGateProvider).run(() async {});
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final status = await Permission.notification.status;
    final canExact = await NotificationService.canScheduleExact();
    final snoozeKey = 'snooze_duration_minutes_$userId';
    final autoMissDelayKey = autoMissDelayPreferenceKey(userId);
    final snoozeDurationMinutes = _clampMinutes(
      prefs.getInt(snoozeKey) ?? _kSnoozeDefaultMinutes,
    );
    final autoMissDelayMinutes = _clampMinutes(
      prefs.getInt(autoMissDelayKey) ?? autoMissDefaultDelayMinutes,
    );
    final workspace = ref.read(workspaceContextProvider).asData?.value;
    final serverCannotRecordMisses =
        workspace != null &&
        !workspace.isLocal &&
        !(await LedgerModeHint.read() == true &&
            await LedgerModeHint.readRecordedMiss());
    if (!mounted) return;
    setState(() {
      _serverCannotRecordMisses = serverCannotRecordMisses;
      // On by default, matching AutoMissSweeper: only an explicit answer of
      // `false` shows the switch off.
      _autoMissEnabled =
          prefs.getBool(autoMissEnabledPreferenceKey(userId)) ?? true;
      _notificationSound = prefs.getBool('notification_sound_$userId') ?? true;
      _remindOnThisDevice =
          prefs.getBool(remindOnThisDevicePreferenceKey(userId)) ?? true;
      _snoozeDurationMinutes = snoozeDurationMinutes;
      _autoMissDelayMinutes = autoMissDelayMinutes;
      _notifPermStatus = status;
      _canScheduleExact = canExact;
    });
  }

  Future<void> _setAutoMiss(bool value) async {
    final userId = ref.read(currentUserIdProvider);
    final gate = ref.read(portablePreferenceGateProvider);
    final prefs = await SharedPreferences.getInstance();
    // Only doses due after this moment can be recorded as missed, so switching
    // the setting on never reaches back into the history. The marker is
    // device-local and is not part of a backup.
    if (value) {
      await prefs.setInt(
        autoMissSincePreferenceKey(userId),
        DateTime.now().toUtc().millisecondsSinceEpoch,
      );
    }
    final saved = await PortablePreferenceWriter(
      prefs,
      gate: gate,
    ).write(autoMissEnabledPreferenceKey(userId), value);
    if (!saved) return;
    if (!value) await prefs.remove(autoMissSincePreferenceKey(userId));
    if (!mounted) return;
    setState(() => _autoMissEnabled = value);
  }

  /// Per device on purpose: the switch is not backed up and never syncs, so
  /// turning reminders off on one phone leaves the others alone. The
  /// reconcile cancels this account's reminders here or schedules them again.
  Future<void> _setRemindOnThisDevice(bool value) async {
    final userId = ref.read(currentUserIdProvider);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(remindOnThisDevicePreferenceKey(userId), value);
    if (!mounted) return;
    setState(() => _remindOnThisDevice = value);
    try {
      final identity = await ref
          .read(sessionGenerationRepositoryProvider)
          .currentIdentity();
      if (identity == null) return;
      final locale = await ref.read(localeNotifierProvider.future);
      await ref
          .read(projectionReconcilerProvider)
          .reconcile(identity: identity, locale: locale);
    } on Object {
      // Saved; the next reconcile applies it.
    }
  }

  Future<void> _setNotifSound(bool value) async {
    final userId = ref.read(currentUserIdProvider);
    final gate = ref.read(portablePreferenceGateProvider);
    final prefs = await SharedPreferences.getInstance();
    final saved = await PortablePreferenceWriter(
      prefs,
      gate: gate,
    ).write('notification_sound_$userId', value);
    if (!saved || !mounted) return;
    setState(() => _notificationSound = value);
  }

  Future<void> _setSnoozeDuration(int value) async {
    final userId = ref.read(currentUserIdProvider);
    final gate = ref.read(portablePreferenceGateProvider);
    final prefs = await SharedPreferences.getInstance();
    final clamped = _clampMinutes(value);
    final saved = await PortablePreferenceWriter(
      prefs,
      gate: gate,
    ).write('snooze_duration_minutes_$userId', clamped);
    if (!saved || !mounted) return;
    setState(() => _snoozeDurationMinutes = clamped);
  }

  Future<void> _setAutoMissDelay(int value) async {
    final userId = ref.read(currentUserIdProvider);
    final gate = ref.read(portablePreferenceGateProvider);
    final prefs = await SharedPreferences.getInstance();
    final clamped = _clampMinutes(value);
    final saved = await PortablePreferenceWriter(
      prefs,
      gate: gate,
    ).write(autoMissDelayPreferenceKey(userId), clamped);
    if (!saved || !mounted) return;
    setState(() => _autoMissDelayMinutes = clamped);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final notifications = SettingsGroup(
      label: l.settings_notifications,
      children: [
        Column(
          children: [
            SwitchListTile(
              key: const ValueKey('remind-on-this-device'),
              title: Text(l.account_remindOnDevice),
              subtitle: Text(l.account_remindOnDeviceBody),
              value: _remindOnThisDevice,
              onChanged: _setRemindOnThisDevice,
            ),
            const DeviceOnlyLabel('remindOnThisDevice'),
            SwitchListTile(
              title: Text(l.settings_autoMissRecordTitle),
              subtitle: Text(l.settings_autoMissRecordSubtitle),
              value: _autoMissEnabled,
              onChanged: _setAutoMiss,
            ),
            const DeviceOnlyLabel('autoMiss'),
            if (_autoMissEnabled && _serverCannotRecordMisses)
              ListTile(
                key: const ValueKey('auto-miss-server-unsupported'),
                leading: Icon(
                  Icons.info_outline,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                title: Text(l.settings_autoMissServerUnsupported),
              ),
            if (_autoMissEnabled)
              _MinutesPickerRow(
                title: l.settings_autoMissRecordAfter,
                subtitle: l.settings_autoMissRecordDelaySubtitle,
                value: _autoMissDelayMinutes,
                minMinutes: _kMinutesMin,
                maxMinutes: _kMinutesMax,
                stepMinutes: _kMinutesStep,
                onChanged: _setAutoMissDelay,
              ),
            _MinutesPickerRow(
              title: l.settings_snoozeDuration,
              subtitle: l.settings_snoozeSubtitle,
              value: _snoozeDurationMinutes,
              minMinutes: _kMinutesMin,
              maxMinutes: _kMinutesMax,
              stepMinutes: _kMinutesStep,
              onChanged: _setSnoozeDuration,
            ),
            SwitchListTile(
              title: Text(l.settings_notificationSound),
              value: _notificationSound,
              onChanged: _setNotifSound,
            ),
            const DeviceOnlyLabel('notificationSound'),
            ListTile(
              title: Text(l.settings_notificationPermission),
              subtitle: Text(
                _notifPermStatus.isGranted
                    ? l.settings_permGranted
                    : _notifPermStatus.isDenied
                    ? l.settings_permDenied
                    : l.settings_permNotDetermined,
              ),
              trailing: _notifPermStatus.isGranted
                  ? Icon(
                      Icons.check_circle,
                      color: Theme.of(context).colorScheme.tertiary,
                    )
                  : _notifPermStatus.isPermanentlyDenied
                  ? TextButton(
                      onPressed: () async {
                        await openAppSettings();
                        if (!mounted) return;
                        final status = await Permission.notification.status;
                        if (!mounted) return;
                        setState(() => _notifPermStatus = status);
                      },
                      child: Text(l.settings_openSettings),
                    )
                  : TextButton(
                      onPressed: () async {
                        final status = await Permission.notification.request();
                        if (!mounted) return;
                        setState(() => _notifPermStatus = status);
                      },
                      child: Text(l.shared_grant),
                    ),
            ),
            ListTile(
              title: Text(l.settings_exactAlarmPermission),
              subtitle: Text(
                _canScheduleExact
                    ? l.settings_permGranted
                    : l.settings_exactAlarmDenied,
              ),
              trailing: _canScheduleExact
                  ? Icon(
                      Icons.check_circle,
                      color: Theme.of(context).colorScheme.tertiary,
                    )
                  : TextButton(
                      onPressed: () async {
                        await notificationsPlugin
                            .resolvePlatformSpecificImplementation<
                              AndroidFlutterLocalNotificationsPlugin
                            >()
                            ?.requestExactAlarmsPermission();
                        if (!mounted) return;
                        final ok = await NotificationService.canScheduleExact();
                        if (!mounted) return;
                        setState(() => _canScheduleExact = ok);
                      },
                      child: Text(l.shared_grant),
                    ),
            ),
            ListTile(
              leading: Icon(
                Icons.battery_saver_outlined,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              title: Text(l.settings_batteryRestriction),
              // The button sits under the text: beside it, a long label at
              // large text would take the whole row from the explanation.
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_batteryRestricted case final restricted?) ...[
                    Text(
                      restricted
                          ? l.onb_batteryLimited
                          : l.onb_batteryUnlimited,
                      key: const ValueKey('battery-status'),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                  ],
                  Text(l.settings_batteryRestrictionSubtitle),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Wrap(
                      children: [
                        if (_batteryRestricted == true)
                          TextButton(
                            key: const ValueKey('battery-allow'),
                            onPressed: _allowBackground,
                            child: Text(l.onb_batteryAllow),
                          ),
                        TextButton(
                          onPressed: () async => openAppSettings(),
                          child: Text(l.settings_appSettings),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              isThreeLine: true,
            ),
          ],
        ),
      ],
    );
    final reset = SettingsGroup(
      label: l.reminders_resetGroup,
      children: const [ResetRemindersRow(key: ValueKey('reset-reminders'))],
    );
    return NextRemindersScope(
      child: Scaffold(
        appBar: settingsDetailAppBar(
          context,
          SettingsSection.reminders.label(l),
        ),
        body: LayoutBuilder(
          builder: (context, box) {
            // Beside the list the page has room for the settings and, next to
            // them, how a reminder will look.
            final wide =
                SettingsPaneScope.isEmbedded(context) &&
                box.maxWidth >= settingsTwoColumnFrom;
            return ContentListView(
              maxWidth: settingsContentWidth(context),
              padding: const EdgeInsets.all(16),
              children: wide
                  ? [
                      const ReminderStatusCard(),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                const ReminderDayCard(),
                                const NextRemindersCard(),
                                const ReminderPrivacySettings(
                                  part: ReminderPrivacyPart.choices,
                                ),
                                notifications,
                                reset,
                              ],
                            ),
                          ),
                          const SizedBox(width: 20),
                          const SizedBox(
                            width: 300,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                ReminderPreviewCard(),
                                ReminderPrivacySettings(
                                  part: ReminderPrivacyPart.test,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ]
                  : [
                      const ReminderStatusCard(),
                      const ReminderDayCard(),
                      const NextRemindersCard(),
                      const ReminderPrivacySettings(
                        part: ReminderPrivacyPart.choices,
                      ),
                      const ReminderPreviewCard(),
                      const ReminderPrivacySettings(
                        part: ReminderPrivacyPart.test,
                      ),
                      notifications,
                      reset,
                    ],
            );
          },
        ),
      ),
    );
  }
}

int _clampMinutes(int value) {
  if (value < _kMinutesMin) return _kMinutesMin;
  if (value > _kMinutesMax) return _kMinutesMax;
  return value;
}

class _MinutesPickerRow extends StatelessWidget {
  const _MinutesPickerRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.minMinutes,
    required this.maxMinutes,
    required this.stepMinutes,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final int value;
  final int minMinutes;
  final int maxMinutes;
  final int stepMinutes;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canDecrement = value > minMinutes;
    final canIncrement = value < maxMinutes;
    final step = stepMinutes <= 0 ? 1 : stepMinutes;

    final l = AppLocalizations.of(context);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      onTap: () => _showCustomMinutesDialog(context),
      title: Text(title),
      subtitle: Text(
        '$subtitle\n${l.settings_rangeMin(minMinutes, maxMinutes)}',
      ),
      isThreeLine: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: l.settings_decreaseTooltip(title),
            onPressed: canDecrement
                ? () => onChanged(_clampValue(value - step))
                : null,
            icon: const Icon(Icons.remove_circle_outline),
          ),
          SizedBox(
            width: 54,
            child: Text(
              l.settings_valueMin(value),
              textAlign: TextAlign.center,
              style: theme.textTheme.labelLarge,
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: l.settings_increaseTooltip(title),
            onPressed: canIncrement
                ? () => onChanged(_clampValue(value + step))
                : null,
            icon: const Icon(Icons.add_circle_outline),
          ),
        ],
      ),
    );
  }

  int _clampValue(int next) {
    if (next < minMinutes) return minMinutes;
    if (next > maxMinutes) return maxMinutes;
    return next;
  }

  Future<void> _showCustomMinutesDialog(BuildContext context) async {
    final controller = TextEditingController(text: value.toString());
    String? errorText;

    final result = await showDialog<int>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final dl = AppLocalizations.of(dialogContext);
          return AlertDialog(
            title: Text(title),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(subtitle),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: dl.settings_minutesLabel,
                      hintText: '$minMinutes..$maxMinutes',
                      errorText: errorText,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(dl.shared_cancel),
              ),
              FilledButton(
                onPressed: () {
                  final parsed = int.tryParse(controller.text.trim());
                  if (parsed == null ||
                      parsed < minMinutes ||
                      parsed > maxMinutes) {
                    setDialogState(() {
                      errorText = dl.settings_minutesRange(
                        minMinutes,
                        maxMinutes,
                      );
                    });
                    return;
                  }
                  Navigator.of(dialogContext).pop(parsed);
                },
                child: Text(dl.shared_save),
              ),
            ],
          );
        },
      ),
    );

    if (result != null) {
      onChanged(_clampValue(result));
    }
  }
}
