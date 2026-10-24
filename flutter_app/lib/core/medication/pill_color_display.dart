// Pure colour-string mapping with no Flutter dependency, so the widget
// snapshot (core) and the UI (shared/theme) agree on one display colour.

/// Colours stored before the current palette, and the palette colour each one
/// is drawn in. Mint has no slot of its own any more and draws as Green.
const _legacyDisplayHex = {
  '#E57373': '#FD2B35',
  '#FFB74D': '#FB8B21',
  '#FFD54F': '#FFDF2E',
  '#81C784': '#54882D',
  '#4DD0E1': '#30ECF8',
  '#64B5F6': '#2DA2DE',
  '#BA68C8': '#C14BF7',
  '#90A4AE': '#AAA9B4',
  '#EC407A': '#E0157D',
  '#FF8A65': '#FFA070',
  '#66BB6A': '#54882D',
  '#5C6BC0': '#0E3DA7',
};

/// The hex a stored colour is drawn in: its palette equivalent when it is one
/// of the earlier palette's colours, otherwise the stored value unchanged.
String displayHexFor(String hex) =>
    _legacyDisplayHex[hex.trim().toUpperCase()] ?? hex;
