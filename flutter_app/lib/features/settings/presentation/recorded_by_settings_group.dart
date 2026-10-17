import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/recorded_by_preference.dart';
import '../../../l10n/app_localizations.dart';
import '../../profiles/profile_provider.dart';
import 'settings_overview.dart';

/// Chooses whose name is stamped on each newly recorded dose.
class RecordedBySettingsGroup extends ConsumerStatefulWidget {
  const RecordedBySettingsGroup({super.key, required this.index});
  final int index;

  @override
  ConsumerState<RecordedBySettingsGroup> createState() =>
      _RecordedBySettingsGroupState();
}

class _RecordedBySettingsGroupState
    extends ConsumerState<RecordedBySettingsGroup> {
  TextEditingController? _name;

  @override
  void dispose() {
    _name?.dispose();
    super.dispose();
  }

  Future<void> _apply(String userId, RecordedBySetting next) async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ref.read(recordedByProvider(userId).notifier).apply(next);
      messenger?.showSnackBar(SnackBar(content: Text(l.recordedBy_saved)));
    } on RecordedByPersistenceFailure {
      messenger?.showSnackBar(SnackBar(content: Text(l.recordedBy_saveFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final String userId;
    try {
      userId = ref.watch(currentUserIdProvider);
    } on Object {
      return const SizedBox.shrink();
    }
    final setting = ref.watch(recordedByProvider(userId));
    final name = _name ??= TextEditingController(text: setting.customName);
    final note = setting.mode == RecordedByMode.personTakingIt
        ? '${l.recordedBy_explainer} ${l.recordedBy_personNote}'
        : l.recordedBy_explainer;
    return SettingsGroup(
      label: l.recordedBy_title,
      index: widget.index,
      identity: 'people-recorded-by',
      children: [
        RadioGroup<RecordedByMode>(
          groupValue: setting.mode,
          onChanged: (mode) {
            if (mode == null) return;
            _apply(
              userId,
              RecordedBySetting(mode: mode, customName: setting.customName),
            );
          },
          child: Column(
            children: [
              RadioListTile<RecordedByMode>(
                key: const ValueKey('recorded-by-primary'),
                value: RecordedByMode.primaryProfile,
                title: Text(l.recordedBy_primary),
              ),
              RadioListTile<RecordedByMode>(
                key: const ValueKey('recorded-by-custom'),
                value: RecordedByMode.custom,
                title: Text(l.recordedBy_custom),
              ),
              RadioListTile<RecordedByMode>(
                key: const ValueKey('recorded-by-person'),
                value: RecordedByMode.personTakingIt,
                title: Text(l.recordedBy_person),
              ),
            ],
          ),
        ),
        if (setting.mode == RecordedByMode.custom)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            // Stacked: the app's filled buttons are full width, which a Row
            // cannot lay out.
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: const ValueKey('recorded-by-name'),
                  controller: name,
                  maxLength: 60,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(
                    labelText: l.recordedBy_nameLabel,
                    counterText: '',
                  ),
                  onSubmitted: (value) => _apply(
                    userId,
                    RecordedBySetting(
                      mode: RecordedByMode.custom,
                      customName: value,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  key: const ValueKey('recorded-by-save'),
                  onPressed: () => _apply(
                    userId,
                    RecordedBySetting(
                      mode: RecordedByMode.custom,
                      customName: name.text,
                    ),
                  ),
                  child: Text(l.recordedBy_save),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Text(
            note,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
