import 'package:flutter/material.dart';

/// The surface the Today side cards share, matching the dose card.
class TodayCard extends StatelessWidget {
  const TodayCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
  });
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: .5)),
        boxShadow: [
          BoxShadow(
            color: colors.shadow.withValues(alpha: .045),
            blurRadius: 12,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}
