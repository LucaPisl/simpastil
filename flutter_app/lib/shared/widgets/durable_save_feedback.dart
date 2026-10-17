import 'package:flutter/material.dart';
import '../motion/app_motion.dart';

/// Callers supply confirmed durable outcomes, never optimistic save claims.
class DurableSaveFeedback extends StatelessWidget {
  const DurableSaveFeedback({super.key, required this.label});
  final String label;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: CareTransition(
      child: Row(
        key: ValueKey(label),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.check_circle_outline,
            size: 20,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    ),
  );
}
