import 'dart:math' as math;

import 'package:flutter/material.dart';

/// How much room the window gives the app, by width in logical pixels.
///
/// The three classes follow the Material window-size classes, trimmed to what
/// Simpastil lays out differently:
///
/// | Class | Width | Navigation | Body |
/// | --- | --- | --- | --- |
/// | [compact] | under 600 | bottom bar | phone layouts |
/// | [medium] | 600 to 839 | side rail | one column |
/// | [expanded] | 840 and up | side rail | two panes (later phases) |
///
/// The class follows the window, not the pane a widget happens to sit in, so
/// every screen of one window agrees on it. A rail that takes 80 dp does not
/// turn an expanded window into a medium one.
enum WindowClass {
  compact,
  medium,
  expanded;

  /// The narrowest width of a [medium] window.
  static const mediumFrom = 600.0;

  /// The narrowest width of an [expanded] window.
  static const expandedFrom = 840.0;

  /// The class of a window [width] dp wide.
  static WindowClass forWidth(double width) {
    if (width >= expandedFrom) return WindowClass.expanded;
    if (width >= mediumFrom) return WindowClass.medium;
    return WindowClass.compact;
  }

  /// The class of the window [context] lives in.
  static WindowClass of(BuildContext context) =>
      forWidth(MediaQuery.sizeOf(context).width);

  /// Whether navigation moves from the bottom bar to a side rail.
  bool get showsRail => this != WindowClass.compact;

  /// Whether the body has room for two panes side by side.
  bool get isExpanded => this == WindowClass.expanded;

  /// The widest a page column may grow: one token for every screen, so column
  /// edges line up from Today to Settings. Phones fill their width.
  double get contentWidth => switch (this) {
    WindowClass.compact => double.infinity,
    WindowClass.medium => 640,
    WindowClass.expanded => 720,
  };

  /// The width of the navigation rail, or zero where the bottom bar is used.
  /// Wide enough for the longest tab label ("Medications", "Medicamente") on
  /// one line.
  double get railWidth => showsRail ? 88 : 0;
}

/// The space to add on each side of a page so that a column [maxWidth] wide
/// sits centered in [available].
///
/// Add it to a scroll view's own padding rather than constraining the scroll
/// view: the scroll view then spans the whole pane, so a swipe in the side
/// margins scrolls the page, and the content still keeps its column.
double contentGutter(double available, double maxWidth) =>
    maxWidth.isFinite && available.isFinite
    ? math.max(0, (available - maxWidth) / 2)
    : 0;

/// Gives [builder] the extra horizontal padding that keeps a page's content in
/// a centered column of [maxWidth] (by default the window class's
/// [WindowClass.contentWidth]), whatever width its pane has.
///
/// ```dart
/// ContentColumn(
///   builder: (context, gutter) => ListView(
///     padding: const EdgeInsets.all(20) + gutter,
///     children: [...],
///   ),
/// )
/// ```
///
/// On a phone the gutter is zero and nothing changes.
class ContentColumn extends StatelessWidget {
  const ContentColumn({super.key, this.maxWidth, required this.builder});

  /// The widest the content may grow; defaults to the window class's token.
  final double? maxWidth;

  /// Builds the scrollable; [gutter] is the extra side padding to add to it.
  final Widget Function(BuildContext context, EdgeInsets gutter) builder;

  @override
  Widget build(BuildContext context) {
    final width = maxWidth ?? WindowClass.of(context).contentWidth;
    return LayoutBuilder(
      builder: (context, box) => builder(
        context,
        EdgeInsets.symmetric(horizontal: contentGutter(box.maxWidth, width)),
      ),
    );
  }
}

/// Centers a fixed (non-scrolling) [child], such as a bottom action bar, in
/// the same column [ContentListView] gives the page, so its edges line up with
/// the content above it. It is as tall as [child]; use it for a bar, not for a
/// body that should fill the pane.
class ContentFrame extends StatelessWidget {
  const ContentFrame({super.key, this.maxWidth, required this.child});

  /// The widest the child may grow; defaults to the window class's token.
  final double? maxWidth;
  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
    heightFactor: 1,
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: maxWidth ?? WindowClass.of(context).contentWidth,
      ),
      child: child,
    ),
  );
}

/// A [ListView] across the full width of its pane whose content keeps a
/// centered column: the usual page body. Side margins scroll with it.
class ContentListView extends StatelessWidget {
  const ContentListView({
    super.key,
    this.maxWidth,
    this.controller,
    this.padding = EdgeInsets.zero,
    this.physics,
    this.keyboardDismissBehavior = ScrollViewKeyboardDismissBehavior.manual,
    required this.children,
  });

  final double? maxWidth;
  final ScrollController? controller;

  /// The page's own padding, inside the column.
  final EdgeInsets padding;
  final ScrollPhysics? physics;
  final ScrollViewKeyboardDismissBehavior keyboardDismissBehavior;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ContentColumn(
    maxWidth: maxWidth,
    builder: (context, gutter) => ListView(
      controller: controller,
      padding: padding + gutter,
      physics: physics,
      keyboardDismissBehavior: keyboardDismissBehavior,
      children: children,
    ),
  );
}

/// A [SingleChildScrollView] across the full width of its pane whose child
/// keeps a centered column. Side margins scroll with it.
class ContentScrollView extends StatelessWidget {
  const ContentScrollView({
    super.key,
    this.maxWidth,
    this.controller,
    this.padding = EdgeInsets.zero,
    this.physics,
    this.keyboardDismissBehavior = ScrollViewKeyboardDismissBehavior.manual,
    required this.child,
  });

  final double? maxWidth;
  final ScrollController? controller;

  /// The page's own padding, inside the column.
  final EdgeInsets padding;
  final ScrollPhysics? physics;
  final ScrollViewKeyboardDismissBehavior keyboardDismissBehavior;
  final Widget child;

  @override
  Widget build(BuildContext context) => ContentColumn(
    maxWidth: maxWidth,
    builder: (context, gutter) => SingleChildScrollView(
      controller: controller,
      padding: padding + gutter,
      physics: physics,
      keyboardDismissBehavior: keyboardDismissBehavior,
      child: child,
    ),
  );
}

/// Two panes side by side with a [gap] between them, for the expanded layouts.
///
/// Give [endWidth] to fix the end pane (the other then takes the rest);
/// otherwise the panes share the width by [startFlex] and [endFlex]. Both
/// panes get the full height. Order follows the reading direction.
class TwoPane extends StatelessWidget {
  const TwoPane({
    super.key,
    required this.start,
    required this.end,
    this.endWidth,
    this.startFlex = 1,
    this.endFlex = 1,
    this.gap = defaultGap,
    this.crossAxisAlignment = CrossAxisAlignment.stretch,
  });

  static const defaultGap = 16.0;

  final Widget start, end;
  final double? endWidth;
  final int startFlex, endFlex;
  final double gap;
  final CrossAxisAlignment crossAxisAlignment;

  @override
  Widget build(BuildContext context) {
    final fixed = endWidth;
    return Row(
      crossAxisAlignment: crossAxisAlignment,
      children: [
        Expanded(flex: startFlex, child: start),
        SizedBox(width: gap),
        if (fixed != null)
          SizedBox(width: fixed, child: end)
        else
          Expanded(flex: endFlex, child: end),
      ],
    );
  }
}
