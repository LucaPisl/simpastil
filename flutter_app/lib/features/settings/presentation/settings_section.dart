import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';

/// The pages Settings opens. On a phone the first group are pages pushed over
/// the overview; the last four ([layout], [colors], [accessibility] and
/// [language]) open as the layout chooser, the theme editor and a sheet there,
/// and as panes beside the list on a wide window.
enum SettingsSection {
  reminders,
  people,
  medication,
  account,
  data,
  about,
  protection,
  backups,
  storage,
  layout,
  colors,
  accessibility,
  language;

  String label(AppLocalizations l) => switch (this) {
    reminders => l.t15_reminders,
    people => l.t08_people,
    medication => l.settings_pillEditing,
    account => l.t15_serverConnection,
    data => l.settings_data,
    about => l.settings_about,
    protection => l.t15_protection,
    backups => l.t15_backups,
    storage => l.t15_storageRecovery,
    layout => l.t15_layout,
    colors => l.t15_colors,
    accessibility => l.t15_accessibility,
    language => l.settings_language,
  };

  IconData get icon => switch (this) {
    reminders => Icons.notifications_none_outlined,
    people => Icons.people_outline,
    medication => Icons.medication_outlined,
    account => Icons.dns_outlined,
    data => Icons.sync_outlined,
    about => Icons.info_outline,
    protection => Icons.lock_outline,
    backups => Icons.file_download_outlined,
    storage => Icons.storage_outlined,
    layout => Icons.layers_outlined,
    colors => Icons.palette_outlined,
    accessibility => Icons.accessibility_new_outlined,
    language => Icons.language_outlined,
  };
}
