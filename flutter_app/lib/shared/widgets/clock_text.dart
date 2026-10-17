import 'package:flutter/material.dart';

/// A time set large: the digits at [style] and, on a 12-hour clock, the AM/PM
/// mark smaller and lighter beside them, so the number stays what you read.
///
/// [text] is already on the phone's clock (see `clockTime`); a 24-hour time
/// is shown as it is. The plain text, and what a screen reader hears, is
/// [text] unchanged.
class ClockText extends StatelessWidget {
  const ClockText(this.text, {super.key, this.style, this.textAlign});

  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;

  /// The mark's size against the digits.
  static const markScale = .42;

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    for (final mark in [
      localizations.anteMeridiemAbbreviation,
      localizations.postMeridiemAbbreviation,
    ]) {
      final at = text.indexOf(mark);
      if (mark.isEmpty || at < 0) continue;
      final leads = at == 0;
      final digits =
          (leads ? text.substring(mark.length) : text.substring(0, at)).trim();
      final base = DefaultTextStyle.of(context).style.merge(style);
      final small = TextStyle(
        fontSize: (base.fontSize ?? 14) * markScale,
        fontWeight: FontWeight.w600,
        letterSpacing: .6,
        color: base.color?.withValues(alpha: base.color!.a * .72),
      );
      final markSpan = TextSpan(text: mark, style: small);
      return Text.rich(
        TextSpan(
          children: leads
              ? [markSpan, const TextSpan(text: ' '), TextSpan(text: digits)]
              : [TextSpan(text: digits), const TextSpan(text: ' '), markSpan],
        ),
        style: style,
        textAlign: textAlign,
        semanticsLabel: text,
      );
    }
    return Text(text, style: style, textAlign: textAlign);
  }
}
