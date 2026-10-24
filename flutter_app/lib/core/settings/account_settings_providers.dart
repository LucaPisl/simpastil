import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/pills/pill_provider.dart';
import '../l10n/locale_provider.dart';
import '../projections/projection_reconciler.dart';
import '../session/session_generation_repository.dart';
import '../storage/low_stock_dismissal_preference.dart';
import '../storage/recorded_by_preference.dart';
import '../theme/theme_provider.dart';
import 'account_setting_codec.dart';
import 'account_settings_sync.dart';

/// What the running app does after a sync wrote account settings into this
/// device's stores: reload whatever shows them, and redo the reminders when
/// the language or a reminder choice changed (their text and schedule are
/// built from those). Best effort; the stored values are already correct.
final accountSettingsAppliedProvider = Provider<AccountSettingsApplied>((ref) {
  return (keys) async {
    try {
      if (keys.contains(AccountSettingKeys.language)) {
        ref.invalidate(localeNotifierProvider);
      }
      if (keys.any((k) => k.startsWith('appearance.'))) {
        ref.invalidate(appearanceRepositoryProvider);
      }
      if (keys.contains(AccountSettingKeys.recordedBy)) {
        ref.invalidate(recordedByProvider);
      }
      if (keys.contains(AccountSettingKeys.siblingDetection)) {
        ref.invalidate(siblingDetectionModeProvider);
      }
      if (keys.contains(AccountSettingKeys.asNeededInStats)) {
        ref.invalidate(prnInStatsProvider);
      }
      if (keys.contains(AccountSettingKeys.noticesLater)) {
        ref.invalidate(lowStockDismissalsProvider);
      }
      final remindersChanged = keys.any(
        (k) =>
            k == AccountSettingKeys.snoozeMinutes ||
            k == AccountSettingKeys.language ||
            AccountSettingKeys.isEntityKey(k),
      );
      if (!remindersChanged) return;
      final identity = await ref
          .read(sessionGenerationRepositoryProvider)
          .currentIdentity();
      if (identity == null) return;
      final locale = await ref.read(localeNotifierProvider.future);
      await ref
          .read(projectionReconcilerProvider)
          .reconcile(identity: identity, locale: locale);
    } on Object {
      // The values are saved; the screens pick them up on their next read.
    }
  };
});
