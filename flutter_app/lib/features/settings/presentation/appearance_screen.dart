import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'account_follow_widgets.dart';
import '../../../core/storage/appearance_preferences.dart';
import '../../../core/storage/as_needed_shortcut_preference.dart';
import '../../../core/storage/layout_family_preference.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/layouts/window_size.dart';
import '../../../shared/router/back_policy.dart';
import 'theme_mode_switch.dart';
import '../../../shared/motion/app_motion.dart';
import '../../../shared/motion/theme_reveal.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/theme/focus_tokens.dart';
import '../../dashboard/today_layout/layout_preview.dart';
import '../../dashboard/today_layout/today_layouts.dart';
import 'appearance_color_editor.dart';
import 'layout_chooser_screen.dart';
import 'appearance_preview.dart';
import 'settings_pane.dart';
import 'settings_section.dart';

ThemeData _editorTheme(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? AppTheme.dark(highContrast: true)
    : AppTheme.light(highContrast: true);

/// This entry stays readable even after applying difficult custom colors.
class AppearanceEntry extends StatelessWidget {
  const AppearanceEntry({super.key});
  @override
  Widget build(BuildContext context) => Theme(
    data: _editorTheme(context),
    child: Builder(
      builder: (context) => Material(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        child: ListTile(
          key: const ValueKey('appearance-entry'),
          leading: const Icon(Icons.palette_outlined),
          title: Text(AppLocalizations.of(context).t11_entry),
          subtitle: Text(AppLocalizations.of(context).t11_scope),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/appearance'),
        ),
      ),
    ),
  );
}

/// The theme editor: mode, palette colors, display options, with a live
/// preview, applied only by its Apply button.
///
/// On a phone it is a page of its own. In the wide Settings' pane
/// ([SettingsPaneScope]) it is the pane's page: options on the left, the
/// preview on the right, and Cancel and Apply in the header. Cancel there puts
/// the draft back to what is applied, since no page is left.
class AppearanceScreen extends ConsumerStatefulWidget {
  const AppearanceScreen({super.key, this.openDisplayOptions = false});

  /// Opens with the display options (text size, dynamic color, contrast)
  /// expanded and in view: the Accessibility row's way in.
  final bool openDisplayOptions;
  @override
  ConsumerState<AppearanceScreen> createState() => _AppearanceScreenState();
}

class _AppearanceScreenState extends ConsumerState<AppearanceScreen> {
  AppearancePreferences? _draft;

  /// The editor's own, fixed theme. It does not move with the app's theme
  /// while that changes (see [_followAppTheme]); it follows once it is still.
  ThemeData? _safeEditorTheme;
  Timer? _followTheme;

  /// How long the app's theme must stand still before the editor follows it:
  /// the app's own change takes 200 ms and the controls' own colour and text
  /// animations about as long, so the editor waits for all of it.
  static const _themeSettle = Duration(milliseconds: 300);
  Brightness _editing = Brightness.light;
  final _optionsController = ExpansibleController();
  final _optionsKey = GlobalKey();
  final _applyAnchor = GlobalKey();
  bool _initialized = false, _saving = false;
  String? _error, _saved;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _followAppTheme();
  }

  @override
  void dispose() {
    _followTheme?.cancel();
    super.dispose();
  }

  /// Puts the editor on the app's light or dark theme once the app has
  /// settled on it. The editor keeps one fixed theme while the app's changes
  /// under it (so its text never loses contrast against a surface that is
  /// still moving) but it must not keep it for good: the pane of the wide
  /// Settings stays on screen after the app goes from light to dark, or back.
  void _followAppTheme() {
    final brightness = Theme.of(context).brightness;
    final safe = _safeEditorTheme;
    _followTheme?.cancel();
    if (safe == null || safe.brightness == brightness) return;
    _followTheme = Timer(_themeSettle, () {
      if (!mounted) return;
      setState(() => _safeEditorTheme = _editorTheme(context));
    });
  }

  /// Whether a save is under way. While it is, a page in the Settings' pane
  /// also asks the screen around it not to leave.
  void _setSaving(bool value) {
    _saving = value;
    SettingsPaneScope.maybeOf(context)?.leaveBlocked.value = value;
  }

  /// Cancel in the pane: nothing is left, so the draft goes back to what is
  /// applied.
  void _cancelDraft() {
    final applied = ref.read(appearanceNotifierProvider).value;
    if (applied == null) return;
    setState(() {
      _draft = applied;
      _editing = _brightnessOf(applied.mode);
      _error = null;
      _saved = null;
    });
  }

  void _change(AppearancePreferences value) => setState(() {
    _draft = value;
    _error = null;
    _saved = null;
  });

  Future<void> _apply() async {
    if (_saving || _draft == null) return;
    final reviewed = _draft!;
    setState(() {
      _setSaving(true);
      _error = null;
      _saved = null;
    });
    try {
      Future<void> save() =>
          ref.read(appearanceNotifierProvider.notifier).apply(reviewed);
      final applied = ref.read(appearanceNotifierProvider).value;
      final reveal = ThemeReveal.maybeOf(context);
      final changes =
          applied == null ||
          jsonEncode(applied.toJson()) != jsonEncode(reviewed.toJson());
      // The new look spreads out from Apply over the whole app.
      if (reveal != null && changes) {
        await reveal.reveal(
          from: _applyAnchor.currentContext ?? context,
          change: save,
        );
      } else {
        await save();
      }
      if (mounted) {
        setState(() => _saved = AppLocalizations.of(context).t11_applied);
      }
    } on Object {
      if (mounted) {
        setState(() => _error = AppLocalizations.of(context).t11_saveError);
      }
    } finally {
      if (mounted) setState(() => _setSaving(false));
    }
  }

  Future<void> _reset(BuildContext safeContext) async {
    final l = AppLocalizations.of(safeContext),
        safeTheme = Theme.of(safeContext);
    final accepted = await showDialog<bool>(
      context: safeContext,
      builder: (context) => Theme(
        data: safeTheme,
        child: AlertDialog(
          title: Text(l.t11_resetQuestion),
          content: Text(l.t11_resetExplanation),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l.shared_cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l.t11_reset),
            ),
          ],
        ),
      ),
    );
    if (accepted != true || !mounted) return;
    setState(() {
      _setSaving(true);
      _error = null;
      _saved = null;
    });
    try {
      await ref.read(appearanceNotifierProvider.notifier).reset();
      if (mounted) {
        setState(() {
          _draft = ref.read(appearanceNotifierProvider).requireValue;
          _saved = AppLocalizations.of(context).t11_resetSaved;
        });
      }
    } on Object {
      if (mounted) {
        setState(() => _error = AppLocalizations.of(context).t11_saveError);
      }
    } finally {
      if (mounted) setState(() => _setSaving(false));
    }
  }

  Future<void> _editColor(
    BuildContext context,
    AppearanceColorRole role,
    Color current,
  ) async {
    final safeTheme = Theme.of(context), editing = _editing;
    final result = await showModalBottomSheet<AppearanceColorChoice>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: safeTheme.colorScheme.surface,
      builder: (context) => Theme(
        data: safeTheme,
        child: FractionallySizedBox(
          heightFactor: .9,
          child: AppearanceColorEditor(role: role, initial: current),
        ),
      ),
    );
    if (result == null || !mounted || _draft == null) return;
    final colors = Map<AppearanceColorRole, int>.of(
      editing == Brightness.light ? _draft!.lightColors : _draft!.darkColors,
    );
    if (result.argb == null) {
      colors.remove(role);
    } else {
      colors[role] = result.argb!;
    }
    _change(
      editing == Brightness.light
          ? _draft!.copyWith(lightColors: colors)
          : _draft!.copyWith(darkColors: colors),
    );
  }

  Color _outline(BuildContext context) =>
      Theme.of(context).colorScheme.primary.withValues(alpha: .28);

  /// The outline is painted over [child] and the child is clipped to it: a
  /// child with a fill of its own (the forms preview) would otherwise cover
  /// the sides and corners of an outline painted underneath.
  Widget _frame(BuildContext context, Widget child) => DecoratedBox(
    position: DecorationPosition.foreground,
    decoration: BoxDecoration(
      border: Border.all(color: _outline(context)),
      borderRadius: BorderRadius.circular(10),
    ),
    child: ClipRRect(borderRadius: BorderRadius.circular(10), child: child),
  );

  Widget _role(
    BuildContext context,
    AppearanceColorRole role,
    ThemeData preview, {
    String? label,
  }) {
    final theme = Theme.of(context), l = AppLocalizations.of(context);
    final overrides = _editing == Brightness.light
        ? _draft!.lightColors
        : _draft!.darkColors;
    final color = overrides.containsKey(role)
        ? Color(overrides[role]!)
        : AppTheme.roleColors(preview)[role]!;
    return Semantics(
      value: overrides.containsKey(role)
          ? l.t11_customColor
          : l.t11_defaultColor,
      child: InkWell(
        key: ValueKey('appearance-role-${role.name}'),
        onTap: _saving ? null : () => _editColor(context, role, color),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final stacked =
                  MediaQuery.textScalerOf(context).scale(14) > 20 ||
                  constraints.maxWidth < 300;
              final name = Text(
                label ?? appearanceRoleLabel(l, role),
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              );
              final hex = Text(
                appearanceHex(color),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w400,
                ),
              );
              return Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: color,
                      border: Border.all(color: theme.colorScheme.outline),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: stacked
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [name, const SizedBox(height: 4), hex],
                          )
                        : name,
                  ),
                  if (!stacked) ...[const SizedBox(width: 8), hex],
                  const SizedBox(width: 10),
                  const Icon(Icons.chevron_right, size: 22),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _section(
    BuildContext context, {
    required Key key,
    required String title,
    required List<Widget> children,
    IconData? icon,
    bool bordered = true,
    bool initiallyExpanded = false,
    ExpansibleController? controller,
  }) {
    final tile = ExpansionTile(
      key: key,
      controller: controller,
      initiallyExpanded: initiallyExpanded,
      dense: true,
      minTileHeight: 48,
      tilePadding: const EdgeInsets.symmetric(horizontal: 14),
      childrenPadding: const EdgeInsets.only(bottom: 12),
      shape: const Border(),
      collapsedShape: const Border(),
      expansionAnimationStyle: AnimationStyle(
        duration: AppMotion.duration(context),
      ),
      leading: icon == null ? null : Icon(icon, size: 22),
      title: Text(
        title,
        style: Theme.of(
          context,
        ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
      ),
      children: children,
    );
    return bordered ? _frame(context, tile) : tile;
  }

  Widget _roles(
    BuildContext context,
    String title,
    List<AppearanceColorRole> roles,
    ThemeData preview,
  ) => _section(
    context,
    key: ValueKey('appearance-group-$title'),
    title: title,
    bordered: false,
    children: [for (final role in roles) _role(context, role, preview)],
  );

  Widget _paletteTabs(BuildContext context) {
    final l = AppLocalizations.of(context), theme = Theme.of(context);
    final selectedColor = theme.brightness == Brightness.light
        ? FocusTokens.violet
        : theme.colorScheme.primary;
    final tabs = [
      for (final brightness in [Brightness.light, Brightness.dark])
        Semantics(
          selected: _editing == brightness,
          child: TextButton(
            key: ValueKey('appearance-preview-${brightness.name}'),
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 42),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              backgroundColor: _editing == brightness
                  ? selectedColor
                  : Colors.transparent,
              foregroundColor: _editing == brightness
                  ? FocusTokens.ink
                  : theme.colorScheme.onSurface,
              // Large, bold text keeps the reference brand fill readable.
              textStyle: theme.textTheme.titleLarge?.copyWith(
                fontSize: 20,
                height: 1.2,
                fontWeight: FontWeight.w700,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: _saving
                ? null
                : () => setState(() => _editing = brightness),
            child: Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 10,
              runSpacing: 4,
              children: [
                Icon(
                  brightness == Brightness.light
                      ? Icons.light_mode_outlined
                      : Icons.dark_mode_outlined,
                  size: 24,
                ),
                Text(
                  brightness == Brightness.light
                      ? l.settings_themeLight
                      : l.settings_themeDark,
                ),
              ],
            ),
          ),
        ),
    ];
    return _frame(
      context,
      Padding(
        padding: const EdgeInsets.all(3),
        child: MediaQuery.textScalerOf(context).scale(20) > 28
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: tabs,
              )
            : Row(children: [for (final tab in tabs) Expanded(child: tab)]),
      ),
    );
  }

  bool _hasLowContrast(ThemeData theme) {
    final c = theme.colorScheme;
    return [
      (c.onSurface, theme.scaffoldBackgroundColor),
      (c.onSurface, c.surface),
      (c.onSurface, c.surfaceContainerLow),
      (c.onSurfaceVariant, c.surfaceContainerLow),
      (c.onPrimary, c.primary),
      (c.onPrimaryContainer, c.primaryContainer),
      (c.onSecondary, c.secondary),
      (c.onTertiary, c.tertiary),
      (c.onError, c.error),
    ].any((pair) => AppTheme.contrast(pair.$1, pair.$2) < 4.5);
  }

  Brightness _brightnessOf(AppearanceMode mode) => switch (mode) {
    AppearanceMode.dark => Brightness.dark,
    AppearanceMode.light => Brightness.light,
    AppearanceMode.system => MediaQuery.platformBrightnessOf(context),
  };

  /// Cancel and Apply for the header of the wide pane, where no bottom bar is.
  List<Widget> _headerActions(BuildContext context, AppLocalizations l) {
    final colors = Theme.of(context).colorScheme;
    return [
      TextButton(
        key: const ValueKey('appearance-cancel'),
        style: TextButton.styleFrom(
          foregroundColor: colors.onSurface,
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 16),
        ),
        onPressed: _saving ? null : _cancelDraft,
        child: Text(l.shared_cancel),
      ),
      const SizedBox(width: 8),
      KeyedSubtree(
        key: _applyAnchor,
        child: FilledButton(
          key: const ValueKey('appearance-apply'),
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 44),
            padding: const EdgeInsets.symmetric(horizontal: 20),
          ),
          onPressed: _saving || _draft == null ? null : _apply,
          child: Text(_saving ? l.t08_saving : l.t11_apply),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final applied = ref.watch(appearanceNotifierProvider);
    // The app theme is chosen above and applies at once. Keep the draft on it,
    // so a later Apply never puts the previous choice back, and edit the
    // palette the person is now looking at.
    ref.listen(appearanceNotifierProvider, (previous, next) {
      final mode = next.value?.mode;
      final draft = _draft;
      if (mode == null || draft == null || mode == draft.mode) return;
      setState(() {
        _draft = draft.copyWith(mode: mode);
        _editing = _brightnessOf(mode);
      });
    });
    if (!_initialized && applied.asData != null && !applied.isLoading) {
      _draft = applied.requireValue;
      _initialized = true;
      _editing = _brightnessOf(_draft!.mode);
      if (widget.openDisplayOptions) {
        // Bring the options into view once the page has been laid out.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final target = _optionsKey.currentContext;
          if (mounted && target != null) {
            Scrollable.ensureVisible(target, alignment: .1);
          }
        });
      }
    }
    final embedded = SettingsPaneScope.isEmbedded(context);
    // Keep controls stable while Apply changes the app behind this editor.
    // Material text otherwise animates independently of the changed surface,
    // briefly losing contrast even when the root theme has reduced motion.
    return Theme(
      data: _safeEditorTheme ??= _editorTheme(context),
      child: Builder(
        builder: (context) {
          final l = AppLocalizations.of(context);
          final page = LayoutBuilder(
            builder: (context, box) {
              // Beside the list a wide pane puts the preview next to the
              // options, with Cancel and Apply in its header.
              final wide = embedded && box.maxWidth >= settingsTwoColumnFrom;
              final side = embedded ? 16.0 : 20.0;
              return Scaffold(
                appBar: embedded
                    ? settingsDetailAppBar(
                        context,
                        widget.openDisplayOptions
                            ? l.t15_accessibility
                            : l.t15_colors,
                        actions: wide ? _headerActions(context, l) : null,
                      )
                    : AppBar(title: Text(l.r16_editTheme)),
                body: SafeArea(
                  child: DynamicColorBuilder(
                    builder: (light, dark) {
                      if (_draft == null) {
                        return ContentListView(
                          maxWidth: settingsContentWidth(context),
                          padding: const EdgeInsets.all(24),
                          children: [
                            if (applied.isLoading)
                              const LinearProgressIndicator()
                            else
                              Text(l.t11_loadError),
                            if (!applied.isLoading) ...[
                              TextButton(
                                onPressed: () =>
                                    ref.invalidate(appearanceNotifierProvider),
                                child: Text(l.shared_retry),
                              ),
                              OutlinedButton(
                                onPressed: _saving
                                    ? null
                                    : () => _reset(context),
                                child: Text(l.t11_reset),
                              ),
                            ],
                            if (_error != null) Text(_error!),
                          ],
                        );
                      }
                      final draft = _draft!;
                      final preview = AppTheme.appearance(
                        draft,
                        _editing,
                        dynamicScheme: _editing == Brightness.light
                            ? light
                            : dark,
                      );
                      final appliedScale =
                          applied.value?.fontSize.multiplier ?? 1;
                      final previewScale = TextScaler.linear(
                        MediaQuery.textScalerOf(context).scale(1) *
                            draft.fontSize.multiplier /
                            appliedScale,
                      );
                      final safe = Theme.of(context);
                      final divider = Divider(
                        height: 1,
                        thickness: 1,
                        color: _outline(context),
                      );
                      // The editor's parts, in the order a phone reads them.
                      // The wide pane splits them: [intro], [colors] and
                      // [rest] on the left, the preview and forms on the right.
                      final intro = <Widget>[
                        Text(
                          l.r16_scope,
                          key: const ValueKey('appearance-scope'),
                          style: safe.textTheme.bodyMedium?.copyWith(
                            color: safe.colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                        const SizedBox(height: 8),
                        _frame(context, const ThemeModeRow()),
                        const DeviceOnlyLabel('themeMode'),
                        const SizedBox(height: 10),
                        Text(
                          l.r8_editingPalette,
                          key: const ValueKey('appearance-editing-label'),
                          style: safe.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        _paletteTabs(context),
                        const SizedBox(height: 4),
                        Text(
                          l.r8_paletteNote,
                          key: const ValueKey('appearance-palette-note'),
                          style: safe.textTheme.bodySmall?.copyWith(
                            color: safe.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 12),
                      ];
                      final previewHead = <Widget>[
                        Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 12,
                          runSpacing: 4,
                          children: [
                            Text(
                              l.t11_preview,
                              style: safe.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              l.r16_example,
                              style: safe.textTheme.bodySmall?.copyWith(
                                color: safe.colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                      ];
                      // Wide, the preview is a pane of its own and says whose.
                      final wideHead = <Widget>[
                        Text(
                          l.ts_previewOnDevice,
                          key: const ValueKey('appearance-preview-heading'),
                          style: safe.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                      ];
                      final previewBody = <Widget>[
                        AppearancePreview(
                          theme: preview,
                          textScaler: previewScale,
                        ),
                        if (_hasLowContrast(preview))
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Semantics(
                              liveRegion: true,
                              child: Text(l.t11_contrastWarning),
                            ),
                          ),
                      ];
                      final colors = <Widget>[
                        Text(
                          l.t11_colors,
                          style: safe.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        // The colours are what follows the account; the
                        // theme row above stays on this device.
                        const AccountFollowsLabel(
                          textKey: ValueKey('appearance-follows-account'),
                          padding: EdgeInsets.only(top: 4),
                        ),
                        const SizedBox(height: 6),
                        _frame(
                          context,
                          Column(
                            children: [
                              _role(
                                context,
                                AppearanceColorRole.primary,
                                preview,
                                label: l.r16_accent,
                              ),
                              divider,
                              _role(
                                context,
                                AppearanceColorRole.background,
                                preview,
                                label: l.r16_background,
                              ),
                              divider,
                              _role(
                                context,
                                AppearanceColorRole.text,
                                preview,
                                label: l.r16_text,
                              ),
                              divider,
                              _section(
                                context,
                                key: const ValueKey('appearance-all-colors'),
                                title: l.r16_allColors,
                                bordered: false,
                                children: [
                                  _roles(context, l.t11_surfaces, [
                                    AppearanceColorRole.surface,
                                    AppearanceColorRole.surfaceVariant,
                                    AppearanceColorRole.mutedText,
                                    AppearanceColorRole.border,
                                  ], preview),
                                  _roles(context, l.t11_actions, [
                                    AppearanceColorRole.onPrimary,
                                    AppearanceColorRole.primaryContainer,
                                    AppearanceColorRole.onPrimaryContainer,
                                    AppearanceColorRole.secondary,
                                    AppearanceColorRole.onSecondary,
                                    AppearanceColorRole.tertiary,
                                    AppearanceColorRole.onTertiary,
                                    AppearanceColorRole.error,
                                    AppearanceColorRole.onError,
                                  ], preview),
                                  _roles(context, l.t11_states, [
                                    AppearanceColorRole.taken,
                                    AppearanceColorRole.skipped,
                                    AppearanceColorRole.unrecorded,
                                    AppearanceColorRole.activePerson,
                                    AppearanceColorRole.inactivePerson,
                                  ], preview),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ];
                      final forms = _section(
                        context,
                        key: const ValueKey('appearance-forms-preview'),
                        title: l.r16_formsPreview,
                        icon: Icons.visibility_outlined,
                        // Beside the editor the preview pane has the room: the
                        // forms and states answer each colour change at once.
                        initiallyExpanded: wide,
                        children: [
                          AppearanceFormsPreview(
                            theme: preview,
                            textScaler: previewScale,
                          ),
                        ],
                      );
                      final layoutFamily = effectiveLayoutFamily(
                        ref.watch(layoutFamilyProvider),
                      );
                      final rest = <Widget>[
                        ListTile(
                          key: const ValueKey('appearance-layout'),
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.layers_outlined),
                          title: Text(l.t15_layout),
                          subtitle: Text(layoutFamilyName(l, layoutFamily)),
                          trailing: const Icon(Icons.chevron_right),
                          // Beside the list the chooser opens in the pane too.
                          onTap: embedded
                              ? () => SettingsPaneScope.maybeOf(
                                  context,
                                )?.onSelect(SettingsSection.layout)
                              : () => openLayoutChooser(context),
                        ),
                        if (layoutFamily == LayoutFamily.focusDeck)
                          SwitchListTile.adaptive(
                            key: const ValueKey(
                              'appearance-as-needed-shortcut',
                            ),
                            contentPadding: EdgeInsets.zero,
                            secondary: const Icon(Icons.arrow_downward_rounded),
                            title: Text(l.asn_shortcutTitle),
                            subtitle: Text(l.asn_shortcutSubtitle),
                            value: ref.watch(asNeededShortcutProvider),
                            onChanged: (value) => ref
                                .read(asNeededShortcutProvider.notifier)
                                .setEnabled(value),
                          ),
                        if (layoutFamily == LayoutFamily.focusDeck)
                          const DeviceOnlyLabel('focusAsNeededShortcut'),
                        divider,
                        const SizedBox(height: 12),
                        KeyedSubtree(
                          key: _optionsKey,
                          child: _section(
                            context,
                            controller: _optionsController,
                            key: const ValueKey('appearance-options'),
                            title: l.r16_displayOptions,
                            icon: Icons.tune,
                            initiallyExpanded: widget.openDisplayOptions,
                            children: [
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    const SizedBox(height: 4),
                                    DropdownButtonFormField<AppearanceFontSize>(
                                      key: ValueKey(
                                        'appearance-font-${draft.fontSize.name}',
                                      ),
                                      initialValue: draft.fontSize,
                                      isExpanded: true,
                                      decoration: InputDecoration(
                                        labelText: l.settings_fontSize,
                                      ),
                                      items: [
                                        DropdownMenuItem(
                                          value: AppearanceFontSize.defaultSize,
                                          child: Text(l.settings_fontDefault),
                                        ),
                                        DropdownMenuItem(
                                          value: AppearanceFontSize.large,
                                          child: Text(l.settings_fontLarge),
                                        ),
                                        DropdownMenuItem(
                                          value: AppearanceFontSize.extraLarge,
                                          child: Text(l.settings_fontXL),
                                        ),
                                      ],
                                      onChanged: _saving
                                          ? null
                                          : (value) => _change(
                                              draft.copyWith(fontSize: value),
                                            ),
                                    ),
                                    const SizedBox(height: 8),
                                    SwitchListTile.adaptive(
                                      contentPadding: EdgeInsets.zero,
                                      key: const ValueKey('appearance-dynamic'),
                                      title: Text(l.settings_dynamicColor),
                                      subtitle: Text(l.t11_dynamicHint),
                                      value: draft.dynamicColor,
                                      onChanged: _saving
                                          ? null
                                          : (value) => _change(
                                              draft.copyWith(
                                                dynamicColor: value,
                                              ),
                                            ),
                                    ),
                                    const DeviceOnlyLabel('wallpaperColors'),
                                    if (draft.dynamicColor &&
                                        (light == null || dark == null))
                                      Text(l.t11_dynamicUnavailable),
                                    SwitchListTile.adaptive(
                                      contentPadding: EdgeInsets.zero,
                                      key: const ValueKey(
                                        'appearance-contrast',
                                      ),
                                      title: Text(l.settings_highContrast),
                                      subtitle: Text(l.t11_contrastHint),
                                      value: draft.highContrast,
                                      onChanged: _saving
                                          ? null
                                          : (value) => _change(
                                              draft.copyWith(
                                                highContrast: value,
                                              ),
                                            ),
                                    ),
                                    Text(
                                      l.t11_scope,
                                      style: safe.textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            key: const ValueKey('appearance-reset'),
                            style: TextButton.styleFrom(
                              foregroundColor: safe.colorScheme.onSurface,
                            ),
                            onPressed: _saving ? null : () => _reset(context),
                            child: Text(l.t11_reset),
                          ),
                        ),
                      ];
                      if (!wide) {
                        return ContentScrollView(
                          key: const ValueKey('appearance-scroll'),
                          maxWidth: settingsContentWidth(context),
                          padding: EdgeInsets.fromLTRB(side, 8, side, 20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              ...intro,
                              ...previewHead,
                              ...previewBody,
                              const SizedBox(height: 20),
                              ...colors,
                              const SizedBox(height: 12),
                              forms,
                              const SizedBox(height: 12),
                              ...rest,
                            ],
                          ),
                        );
                      }
                      final message = _error ?? _saved;
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: ContentScrollView(
                              key: const ValueKey('appearance-scroll'),
                              maxWidth: double.infinity,
                              padding: EdgeInsets.fromLTRB(side, 8, 12, 20),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (message != null)
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: 12,
                                      ),
                                      child: Semantics(
                                        liveRegion: true,
                                        child: Text(message),
                                      ),
                                    ),
                                  ...intro,
                                  ...colors,
                                  const SizedBox(height: 12),
                                  ...rest,
                                ],
                              ),
                            ),
                          ),
                          SizedBox(
                            width: math.min(360, box.maxWidth * .44),
                            child: SingleChildScrollView(
                              key: const ValueKey('appearance-preview-scroll'),
                              padding: EdgeInsets.fromLTRB(12, 8, side, 20),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  ...wideHead,
                                  ...previewBody,
                                  const SizedBox(height: 16),
                                  forms,
                                ],
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                bottomNavigationBar: wide
                    ? null
                    : SafeArea(
                        top: false,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border(
                              top: BorderSide(color: _outline(context)),
                            ),
                          ),
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(side, 12, side, 12),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (_error != null || _saved != null)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 12),
                                    child: Semantics(
                                      liveRegion: true,
                                      child: Text(_error ?? _saved!),
                                    ),
                                  ),
                                LayoutBuilder(
                                  builder: (context, constraints) {
                                    final cancel = OutlinedButton(
                                      key: const ValueKey('appearance-cancel'),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: Theme.of(
                                          context,
                                        ).colorScheme.onSurface,
                                        side: BorderSide(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.outline,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                        ),
                                      ),
                                      onPressed: _saving
                                          ? null
                                          : embedded
                                          ? _cancelDraft
                                          : () => Navigator.of(
                                              context,
                                            ).maybePop(),
                                      child: Text(l.shared_cancel),
                                    );
                                    final apply = FilledButton(
                                      key: const ValueKey('appearance-apply'),
                                      style: FilledButton.styleFrom(
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                        ),
                                      ),
                                      onPressed: _saving || _draft == null
                                          ? null
                                          : _apply,
                                      child: Text(
                                        _saving ? l.t08_saving : l.t11_apply,
                                      ),
                                    );
                                    if (MediaQuery.textScalerOf(
                                              context,
                                            ).scale(14) >
                                            22 ||
                                        constraints.maxWidth < 330) {
                                      return Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          KeyedSubtree(
                                            key: _applyAnchor,
                                            child: apply,
                                          ),
                                          const SizedBox(height: 8),
                                          cancel,
                                        ],
                                      );
                                    }
                                    return Row(
                                      children: [
                                        Expanded(child: cancel),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: KeyedSubtree(
                                            key: _applyAnchor,
                                            child: apply,
                                          ),
                                        ),
                                      ],
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
              );
            },
          );
          // Beside the list, Back belongs to the Settings screen, which stays
          // put while a save is under way.
          if (embedded) return page;
          return PopScope(
            canPop: !_saving && !isOnlyPage(context),
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop && !_saving) leaveToToday(context);
            },
            child: page,
          );
        },
      ),
    );
  }
}
