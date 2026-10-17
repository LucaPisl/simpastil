import 'package:flutter/material.dart';
import '../../core/db/database.dart';
import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';

class CarePersonSelector extends StatelessWidget {
  const CarePersonSelector({
    super.key,
    required this.people,
    required this.selectedId,
    required this.onChanged,
    this.focusDeckPresentation = false,
  });
  final List<Profile> people;
  final String? selectedId;
  final ValueChanged<String?> onChanged;
  final bool focusDeckPresentation;
  @override
  Widget build(BuildContext context) {
    if (people.length < 2) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    final semantic = Theme.of(context).extension<AppSemanticColors>();
    final current = people.where((p) => p.id == selectedId).firstOrNull;
    if (focusDeckPresentation) {
      final theme = Theme.of(context), colors = theme.colorScheme;
      final active = semantic?.profileActive ?? colors.primary;
      final name = current?.name ?? l.t08_everyone;
      final selector = PopupMenuButton<String>(
        tooltip: l.t08_viewPerson,
        initialValue: selectedId ?? '',
        onSelected: (id) => onChanged(id.isEmpty ? null : id),
        itemBuilder: (context) => [
          PopupMenuItem(value: '', child: Text(l.t08_everyone)),
          for (final person in people)
            PopupMenuItem(value: person.id, child: Text(person.name)),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: active,
                foregroundColor: AppTheme.readable(colors.onPrimary, [
                  active,
                ], minimum: 4.5),
                child: current == null
                    ? const Icon(Icons.people_outline, size: 25)
                    : Text(
                        name.trim().isEmpty
                            ? '?'
                            : name.trim().characters.first.toUpperCase(),
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
              const SizedBox(width: 14),
              Flexible(
                child: Text(
                  name,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.expand_more, size: 22),
            ],
          ),
        ),
      );
      // The shortcut back to everyone only exists while a person is chosen;
      // otherwise the selector already reads "Everyone" and a disabled twin
      // would say it twice.
      final showEveryone = selectedId != null;
      final everyone = TextButton.icon(
        onPressed: () => onChanged(null),
        icon: const Icon(Icons.people_outline, size: 21),
        label: Text(l.t08_everyone),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          minimumSize: const Size(48, 48),
        ),
      );
      Widget panel(Widget child) => Container(
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: colors.outlineVariant.withValues(alpha: .5),
          ),
          boxShadow: [
            BoxShadow(
              color: colors.shadow.withValues(alpha: .035),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: child,
      );
      if (!showEveryone) return panel(selector);
      return panel(
        LayoutBuilder(
          builder: (context, bounds) {
            if (bounds.maxWidth < 310 ||
                MediaQuery.textScalerOf(context).scale(16) > 22) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  selector,
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: everyone,
                  ),
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: selector),
                Container(
                  width: 1,
                  height: 28,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  color: colors.outlineVariant.withValues(alpha: .5),
                ),
                everyone,
              ],
            );
          },
        ),
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: PopupMenuButton<String>(
        tooltip: l.t08_viewPerson,
        initialValue: selectedId ?? '',
        onSelected: (id) => onChanged(id.isEmpty ? null : id),
        itemBuilder: (context) => [
          PopupMenuItem(value: '', child: Text(l.t08_everyone)),
          for (final person in people)
            PopupMenuItem(
              value: person.id,
              child: Text(
                person.name,
                style: TextStyle(
                  color: person.id == selectedId
                      ? semantic?.profileActive
                      : semantic?.profileInactive,
                ),
              ),
            ),
        ],
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    current?.name ?? l.t08_everyone,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: semantic?.profileActive,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.expand_more, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
