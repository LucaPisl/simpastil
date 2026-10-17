import 'package:flutter/material.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';

/// Fictional, presentation-only content. No care providers, intents or callbacks.
class AppearancePreview extends StatelessWidget {
  const AppearancePreview({
    super.key,
    required this.theme,
    required this.textScaler,
  });
  final ThemeData theme;
  final TextScaler textScaler;

  @override
  Widget build(BuildContext context) => _PreviewFrame(
    theme: theme,
    textScaler: textScaler,
    builder: (context) {
      final l = AppLocalizations.of(context), c = theme.colorScheme;
      final semantic = theme.extension<AppSemanticColors>()!;
      return Container(
        key: const ValueKey('appearance-preview'),
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: c.surface,
          border: Border.all(color: c.outline, width: .75),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    l.r16_examplePerson,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: c.onSurfaceVariant,
                      height: 1.35,
                    ),
                  ),
                ),
                Icon(Icons.more_vert, size: 22, color: c.onSurfaceVariant),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              l.r16_exampleMedication,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                fontSize: 20,
                height: 1.25,
              ),
            ),
            const SizedBox(height: 6),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '${l.r16_exampleAmount} · '),
                  TextSpan(
                    text: l.t11_unrecorded,
                    style: TextStyle(color: semantic.statusUnrecorded),
                  ),
                ],
              ),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: c.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
              decoration: BoxDecoration(
                color: c.primary,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                l.t08_takenNow,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: c.onPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// Additional semantic roles are visible on demand without enlarging the deck.
class AppearanceFormsPreview extends StatelessWidget {
  const AppearanceFormsPreview({
    super.key,
    required this.theme,
    required this.textScaler,
  });
  final ThemeData theme;
  final TextScaler textScaler;

  @override
  Widget build(BuildContext context) => _PreviewFrame(
    theme: theme,
    textScaler: textScaler,
    builder: (context) {
      final l = AppLocalizations.of(context), c = theme.colorScheme;
      final semantic = theme.extension<AppSemanticColors>()!;
      Widget sampleLabel(String text, Color background, Color foreground) =>
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              text,
              style: theme.textTheme.labelLarge?.copyWith(color: foreground),
            ),
          );
      return Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l.t11_exampleOnly, style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                Text(
                  '✓ ${l.t11_taken}',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: semantic.statusTaken,
                  ),
                ),
                Text(
                  '— ${l.t11_skipped}',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: semantic.statusSkipped,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Material(
              color: c.surface,
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    InputDecorator(
                      decoration: InputDecoration(
                        labelText: l.t11_exampleField,
                      ),
                      child: Text(l.t11_examplePerson),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        sampleLabel(
                          l.t11_activePerson,
                          c.primaryContainer,
                          c.onPrimaryContainer,
                        ),
                        sampleLabel(
                          l.t11_secondary,
                          c.secondary,
                          c.onSecondary,
                        ),
                        sampleLabel(l.t11_tertiary, c.tertiary, c.onTertiary),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      l.t11_activePerson,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: semantic.profileActive,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l.t11_inactivePerson,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: semantic.profileInactive,
                      ),
                    ),
                    const SizedBox(height: 12),
                    sampleLabel(l.t11_exampleError, c.error, c.onError),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _PreviewFrame extends StatelessWidget {
  const _PreviewFrame({
    required this.theme,
    required this.textScaler,
    required this.builder,
  });
  final ThemeData theme;
  final TextScaler textScaler;
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) => Theme(
    data: theme,
    child: MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: textScaler),
      child: Semantics(
        label: AppLocalizations.of(context).t11_exampleOnly,
        child: AbsorbPointer(
          child: ExcludeFocus(
            child: Material(
              color: theme.scaffoldBackgroundColor,
              borderRadius: BorderRadius.circular(10),
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Builder(builder: builder),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
