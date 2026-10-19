import 'package:flutter/material.dart';

/// A certificate fingerprint laid out for comparing by eye: the 32 byte pairs
/// in four short rows, selectable so it can be copied into a message.
class FingerprintBlock extends StatelessWidget {
  const FingerprintBlock({
    super.key,
    required this.label,
    required this.fingerprint,
    this.note,
  });

  final String label;

  /// Uppercase hex pairs joined by colons, as the server shows them.
  final String fingerprint;

  /// A line under the fingerprint, for example when it was seen.
  final String? note;

  /// The fingerprint split into rows of eight pairs.
  static List<String> rows(String fingerprint) {
    final pairs = fingerprint.split(':');
    return [
      for (var i = 0; i < pairs.length; i += 8)
        pairs.sublist(i, i + 8 > pairs.length ? pairs.length : i + 8).join(':'),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: text.labelSmall?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: cs.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        DecoratedBox(
          decoration: BoxDecoration(
            color: cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: SizedBox(
              width: double.infinity,
              child: SelectableText(
                rows(fingerprint).join('\n'),
                style: text.bodyMedium?.copyWith(
                  fontFamily: 'monospace',
                  height: 1.45,
                ),
              ),
            ),
          ),
        ),
        if (note != null) ...[
          const SizedBox(height: 4),
          Text(
            note!,
            style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}
