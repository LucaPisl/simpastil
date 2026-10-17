import 'package:flutter/widgets.dart';

import 'about_settings_section.dart';
import 'account_settings_section.dart';
import 'appearance_screen.dart';
import 'backup_settings_screen.dart';
import 'language_settings.dart';
import 'layout_chooser_screen.dart';
import 'medication_settings_section.dart';
import 'people_settings_section.dart';
import 'protection_settings_section.dart';
import 'reminder_settings_section.dart';
import 'settings_section.dart';
import 'storage_settings_screen.dart';
import 'sync_settings_section.dart';

/// The page for [section]: pushed over the overview on a phone, shown in the
/// pane beside the list on a wide window.
Widget settingsPageFor(SettingsSection section) => switch (section) {
  SettingsSection.reminders => const ReminderSettingsSection(),
  SettingsSection.account => const AccountSettingsSection(),
  SettingsSection.data => const SyncSettingsSection(),
  SettingsSection.people => const PeopleSettingsSection(),
  SettingsSection.protection => const ProtectionSettingsSection(),
  SettingsSection.medication => const MedicationSettingsSection(),
  SettingsSection.about => const AboutSettingsSection(),
  SettingsSection.backups => const BackupSettingsScreen(),
  SettingsSection.storage => const StorageSettingsScreen(),
  SettingsSection.layout => const LayoutChooserScreen(),
  SettingsSection.colors => const AppearanceScreen(),
  SettingsSection.accessibility => const AppearanceScreen(
    openDisplayOptions: true,
  ),
  SettingsSection.language => const LanguageSettingsPage(),
};
