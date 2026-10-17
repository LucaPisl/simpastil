import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import 'today_layout.dart';

/// "Day overview", the button every layout carries beside its count, or null
/// where [TodayLayoutData.onOpenOverview] is not set.
Widget? todayOverviewButton(BuildContext context, TodayLayoutData data) {
  final open = data.onOpenOverview;
  if (open == null) return null;
  return TextButton.icon(
    key: const ValueKey('today-overview'),
    onPressed: data.busy ? null : open,
    style: TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      textStyle: Theme.of(context).textTheme.labelLarge,
    ),
    icon: const Icon(Icons.view_list_outlined, size: 19),
    label: Text(AppLocalizations.of(context).t08_overview),
  );
}

/// The line every Today layout opens with: how many doses still need
/// recording, with Day overview and Select doses beside it.
///
/// Beside the count when everything fits, under it (right aligned) when the
/// window is narrow or the text is large, so nothing wraps into a column of
/// words.
class TodayCountHeader extends StatelessWidget {
  const TodayCountHeader({
    super.key,
    required this.count,
    this.select,
    this.overview,
    required this.stacked,
  });

  /// The count label, already wrapped in its settle halo.
  final Widget count;
  final Widget? select;
  final Widget? overview;

  /// The layout's own large-text decision: count and buttons on separate
  /// lines.
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final actions = [?overview, ?select];
    if (actions.isEmpty) return count;
    return LayoutBuilder(
      builder: (context, box) {
        final roomForBoth = box.maxWidth >= 400;
        final inline = !stacked && (actions.length == 1 || roomForBoth);
        if (!inline) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              count,
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Wrap(alignment: WrapAlignment.end, children: actions),
              ),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: count),
            Flexible(
              child: actions.length == 1
                  ? actions.first
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [for (final a in actions) Flexible(child: a)],
                    ),
            ),
          ],
        );
      },
    );
  }
}
