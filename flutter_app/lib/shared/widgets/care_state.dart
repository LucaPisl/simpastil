import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../theme/focus_tokens.dart';
import 'capsule_mark.dart';

class CareState extends StatelessWidget {
  const CareState({
    super.key,
    required this.title,
    this.body,
    this.action,
    this.actionLabel,
    this.loading = false,
  });
  final String title;
  final String? body;
  final VoidCallback? action;
  final String? actionLabel;
  final bool loading;

  /// A load that finishes within this grace never shows its placeholder, so
  /// pushes and tab switches do not flash "Loading…" over a fast local read.
  static const loadingGrace = Duration(milliseconds: 300);

  @override
  Widget build(BuildContext context) {
    final content = Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(FocusTokens.pageInset),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: FocusTokens.readingWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const CapsuleMark(size: 60),
              const SizedBox(height: 24),
              Text(title, style: Theme.of(context).textTheme.headlineMedium),
              if (body != null) ...[
                const SizedBox(height: 12),
                Text(body!, style: Theme.of(context).textTheme.bodyLarge),
              ],
              if (loading) ...[
                const SizedBox(height: 24),
                LinearProgressIndicator(
                  semanticsLabel: AppLocalizations.of(context).shared_loading,
                ),
              ],
              if (action != null) ...[
                const SizedBox(height: 28),
                FilledButton(onPressed: action, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
    return loading ? _GraceReveal(child: content) : content;
  }
}

/// Keeps a loading placeholder invisible for [CareState.loadingGrace], then
/// fades it in. The tree is built at once (only its paint waits), and it
/// never holds back older content: callers decide what is current.
class _GraceReveal extends StatefulWidget {
  const _GraceReveal({required this.child});
  final Widget child;
  @override
  State<_GraceReveal> createState() => _GraceRevealState();
}

class _GraceRevealState extends State<_GraceReveal>
    with SingleTickerProviderStateMixin {
  static const _fade = Duration(milliseconds: 160);
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: CareState.loadingGrace + _fade,
  )..forward();
  late final Animation<double> _opacity = CurvedAnimation(
    parent: _reveal,
    curve: Interval(
      CareState.loadingGrace.inMilliseconds /
          (CareState.loadingGrace + _fade).inMilliseconds,
      1,
    ),
  );

  @override
  void dispose() {
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _opacity,
    alwaysIncludeSemantics: true,
    child: widget.child,
  );
}
