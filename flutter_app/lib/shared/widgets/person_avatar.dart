import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/focus_tokens.dart';

/// Calm tints a person can wear. Violet and sage come from the brand palette;
/// the others are softened neighbours that stay distinct from each other.
const kPersonTints = <Color>[
  FocusTokens.violet,
  FocusTokens.sage,
  Color(0xFFE0877A), // clay
  Color(0xFF5B9BD5), // sky
  Color(0xFFD9A443), // honey
  Color(0xFFAD7BC9), // heather
  Color(0xFF4FA39A), // lagoon
];

/// The emoji every person gets when none was chosen.
const kDefaultPersonEmoji = '\u{1F464}';

/// A stable tint for a person, derived only from their id: the same person
/// wears the same colour on every screen, in backups and after renaming.
/// No new stored field is needed.
Color personTint(String id) {
  final hash = id.codeUnits.fold<int>(17, (a, c) => (a * 37 + c) & 0x7fffffff);
  return kPersonTints[hash % kPersonTints.length];
}

/// What an avatar shows: the chosen emoji, otherwise the first letter.
String personAvatarGlyph(String name, String? emoji) {
  final chosen = emoji?.trim() ?? '';
  if (chosen.isNotEmpty && chosen != kDefaultPersonEmoji) return chosen;
  return name.trim().characters.firstOrNull?.toUpperCase() ?? '?';
}

/// Colours of a tinted avatar on the current theme: a soft wash of the tint,
/// a ring in the tint and a letter that keeps at least 4.5:1 on the wash.
({Color fill, Color ring, Color ink}) personAvatarColors(
  ThemeData theme,
  Color tint,
) {
  final cs = theme.colorScheme;
  final dark = theme.brightness == Brightness.dark;
  final fill = Color.alphaBlend(
    tint.withValues(alpha: dark ? .30 : .18),
    cs.surface,
  );
  final ring = tint.withValues(alpha: dark ? .75 : .60);
  final ink = AppTheme.readable(
    Color.lerp(tint, cs.onSurface, dark ? .55 : .50)!,
    [fill],
    minimum: 4.5,
  );
  return (fill: fill, ring: ring, ink: ink);
}

/// A person's face: their emoji or initial on a wash of their own tint.
/// Decorative; the name is always printed next to it.
class PersonAvatar extends StatelessWidget {
  const PersonAvatar({
    super.key,
    required this.id,
    required this.name,
    this.emoji,
    this.size = 46,
    this.muted = false,
  });

  final String id;
  final String name;
  final String? emoji;
  final double size;

  /// Inactive people keep their tint but lose its strength.
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = personTint(id);
    final tint = muted
        ? Color.lerp(base, theme.colorScheme.onSurfaceVariant, .65)!
        : base;
    final colors = personAvatarColors(theme, tint);
    final glyph = personAvatarGlyph(name, emoji);
    final isLetter =
        glyph.length == 1 && glyph.toUpperCase() != glyph.toLowerCase();
    return ExcludeSemantics(
      child: Container(
        key: ValueKey('person-avatar-$id'),
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: colors.fill,
          shape: BoxShape.circle,
          border: Border.all(color: colors.ring, width: 1.5),
        ),
        alignment: Alignment.center,
        // The glyph never grows with text scale: the avatar is a fixed mark
        // and the name beside it carries the readable text.
        child: Text(
          glyph,
          textScaler: TextScaler.noScaling,
          style: TextStyle(
            fontSize: size * (isLetter ? .44 : .5),
            height: 1,
            fontWeight: FontWeight.w700,
            color: colors.ink,
          ),
        ),
      ),
    );
  }
}

/// A few faces overlapping, for "everyone" entries. Shows up to [max] and a
/// "+N" for the rest.
class PersonAvatarStack extends StatelessWidget {
  const PersonAvatarStack({
    super.key,
    required this.people,
    this.size = 32,
    this.max = 3,
  });

  final List<({String id, String name, String? emoji})> people;
  final double size;
  final int max;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final shown = people.take(max).toList();
    final extra = people.length - shown.length;
    final step = size * .62;
    final count = shown.length + (extra > 0 ? 1 : 0);
    if (count == 0) return const SizedBox.shrink();
    return ExcludeSemantics(
      child: SizedBox(
        width: size + step * (count - 1) + 4,
        height: size + 4,
        child: Stack(
          children: [
            for (var i = 0; i < shown.length; i++)
              Positioned(
                left: step * i,
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: cs.surface,
                    shape: BoxShape.circle,
                  ),
                  child: PersonAvatar(
                    id: shown[i].id,
                    name: shown[i].name,
                    emoji: shown[i].emoji,
                    size: size,
                  ),
                ),
              ),
            if (extra > 0)
              Positioned(
                left: step * shown.length,
                child: Container(
                  width: size + 4,
                  height: size + 4,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    shape: BoxShape.circle,
                    border: Border.all(color: cs.surface, width: 2),
                  ),
                  child: Text(
                    '+$extra',
                    textScaler: TextScaler.noScaling,
                    style: TextStyle(
                      fontSize: size * .38,
                      fontWeight: FontWeight.w700,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
