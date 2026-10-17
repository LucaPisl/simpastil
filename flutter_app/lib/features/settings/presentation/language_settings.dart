import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/locale_provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/layouts/window_size.dart';
import 'settings_overview.dart';
import 'settings_pane.dart';

/// The name of the language choice [locale] in the settings list: null follows
/// the phone.
String languageChoiceName(AppLocalizations l, Locale? locale) => locale == null
    ? l.settings_languageSystem
    : locale.languageCode == 'ro'
    ? l.settings_languageRomanian
    : l.settings_languageEnglish;

/// The three language choices on one soft surface. A choice is saved at once;
/// [onChosen] runs after it (the sheet closes itself there).
class LanguageChoiceList extends ConsumerWidget {
  const LanguageChoiceList({super.key, this.onChosen});

  final VoidCallback? onChosen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final divider = Divider(
      height: 1,
      indent: 16,
      endIndent: 16,
      color: cs.outlineVariant.withValues(alpha: .5),
    );
    return RadioGroup<Locale?>(
      groupValue: ref.watch(localeOverrideProvider),
      onChanged: (value) {
        ref.read(localeNotifierProvider.notifier).setLocale(value);
        onChosen?.call();
      },
      child: Material(
        color: cs.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: cs.outlineVariant.withValues(alpha: .5)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            RadioListTile<Locale?>(
              value: null,
              title: Text(l.settings_languageSystem),
            ),
            divider,
            RadioListTile<Locale?>(
              value: const Locale('en'),
              title: Text(l.settings_languageEnglish),
            ),
            divider,
            RadioListTile<Locale?>(
              value: const Locale('ro'),
              title: Text(l.settings_languageRomanian),
            ),
          ],
        ),
      ),
    );
  }
}

/// The language choice as a page, for the wide Settings' pane. A phone opens
/// the same choices in a sheet.
class LanguageSettingsPage extends StatelessWidget {
  const LanguageSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      appBar: settingsDetailAppBar(context, SettingsSection.language.label(l)),
      body: ContentListView(
        maxWidth: settingsContentWidth(context),
        padding: const EdgeInsets.all(16),
        children: const [LanguageChoiceList()],
      ),
    );
  }
}
