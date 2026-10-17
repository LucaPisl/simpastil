import 'package:flutter/material.dart';
import '../../../core/storage/appearance_preferences.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/focus_tokens.dart';

String appearanceRoleLabel(AppLocalizations l, AppearanceColorRole role) =>
    switch (role) {
      AppearanceColorRole.primary => l.t11_primary,
      AppearanceColorRole.onPrimary => l.t11_onPrimary,
      AppearanceColorRole.primaryContainer => l.t11_primaryContainer,
      AppearanceColorRole.onPrimaryContainer => l.t11_onPrimaryContainer,
      AppearanceColorRole.background => l.t11_background,
      AppearanceColorRole.text => l.t11_text,
      AppearanceColorRole.surface => l.t11_surface,
      AppearanceColorRole.surfaceVariant => l.t11_surfaceVariant,
      AppearanceColorRole.mutedText => l.t11_mutedText,
      AppearanceColorRole.border => l.t11_border,
      AppearanceColorRole.secondary => l.t11_secondary,
      AppearanceColorRole.onSecondary => l.t11_onSecondary,
      AppearanceColorRole.tertiary => l.t11_tertiary,
      AppearanceColorRole.onTertiary => l.t11_onTertiary,
      AppearanceColorRole.error => l.t11_error,
      AppearanceColorRole.onError => l.t11_onError,
      AppearanceColorRole.taken => l.t11_taken,
      AppearanceColorRole.skipped => l.t11_skipped,
      AppearanceColorRole.unrecorded => l.t11_unrecorded,
      AppearanceColorRole.activePerson => l.t11_activePerson,
      AppearanceColorRole.inactivePerson => l.t11_inactivePerson,
    };

String appearanceHex(Color color) =>
    '#${(color.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0').toUpperCase()}';

class AppearanceColorChoice {
  const AppearanceColorChoice(this.argb);
  final int? argb; // Null explicitly removes this role override.
}

class AppearanceColorEditor extends StatefulWidget {
  const AppearanceColorEditor({
    super.key,
    required this.role,
    required this.initial,
  });
  final AppearanceColorRole role;
  final Color initial;
  @override
  State<AppearanceColorEditor> createState() => _AppearanceColorEditorState();
}

class _AppearanceColorEditorState extends State<AppearanceColorEditor> {
  late HSVColor _color;
  late TextEditingController _hex;
  bool _valid = true;
  @override
  void initState() {
    super.initState();
    _color = HSVColor.fromColor(widget.initial);
    _hex = TextEditingController(text: appearanceHex(widget.initial));
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _choose(HSVColor value) => setState(() {
    _color = value;
    _valid = true;
    _hex.text = appearanceHex(value.toColor());
  });
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              appearanceRoleLabel(l, widget.role),
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 20),
            Container(
              height: 72,
              decoration: BoxDecoration(
                color: _color.toColor(),
                border: Border.all(color: theme.colorScheme.outline),
                borderRadius: BorderRadius.circular(18),
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              key: const ValueKey('appearance-color-hex'),
              controller: _hex,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: l.t11_hex,
                errorText: _valid ? null : l.t11_hexError,
              ),
              onChanged: (value) => setState(() {
                final digits = value.trim().replaceFirst('#', '');
                _valid = RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(digits);
                if (_valid) {
                  _color = HSVColor.fromColor(
                    Color(0xff000000 | int.parse(digits, radix: 16)),
                  );
                }
              }),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final color in [
                  FocusTokens.violet,
                  FocusTokens.sage,
                  FocusTokens.lavender,
                  Colors.white,
                  FocusTokens.ink,
                  const Color(0xffb3261e),
                  const Color(0xff006875),
                  const Color(0xffffc400),
                ])
                  Semantics(
                    label: appearanceHex(color),
                    button: true,
                    child: InkWell(
                      onTap: () => _choose(HSVColor.fromColor(color)),
                      borderRadius: BorderRadius.circular(24),
                      child: Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(color: theme.colorScheme.outline),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            Text(l.t11_hue),
            Slider(
              value: _color.hue,
              max: 360,
              label: '${_color.hue.round()}°',
              onChanged: (v) => _choose(_color.withHue(v)),
            ),
            Text(l.t11_saturation),
            Slider(
              value: _color.saturation,
              label: '${(_color.saturation * 100).round()}%',
              onChanged: (v) => _choose(_color.withSaturation(v)),
            ),
            Text(l.t11_value),
            Slider(
              value: _color.value,
              label: '${(_color.value * 100).round()}%',
              onChanged: (v) => _choose(_color.withValue(v)),
            ),
            const SizedBox(height: 12),
            FilledButton(
              key: const ValueKey('appearance-use-color'),
              onPressed: _valid
                  ? () => Navigator.pop(
                      context,
                      AppearanceColorChoice(_color.toColor().toARGB32()),
                    )
                  : null,
              child: Text(l.t11_useColor),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () =>
                  Navigator.pop(context, const AppearanceColorChoice(null)),
              child: Text(l.t11_useDefault),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l.shared_cancel),
            ),
          ],
        ),
      ),
    );
  }
}
