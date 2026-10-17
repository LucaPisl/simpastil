import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/medication/care_day.dart';
import '../../core/medication/late_dose.dart';
import '../../core/utils/app_clock.dart';
import '../../l10n/app_localizations.dart';
import 'care_record_form.dart';
import '../../shared/theme/app_theme.dart';
import 'today_layout/today_layout.dart';
import 'today_side/coming_up.dart';
import 'today_side/today_side_column.dart' show ComingUpRow;

/// The day's doses in a sheet; choosing one returns its occurrence id.
///
/// [localDate] is the day the entries belong to. When it is today the sheet
/// ends with Coming up, the next planned doses after today, as the tablet's
/// side column shows them; for any other day it is left out.
Future<String?> showDayOverview(
  BuildContext context,
  List<CareDayEntry> entries,
  String? selectedId, {
  String? localDate,
}) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) => SafeArea(
    child: DraggableScrollableSheet(
      expand: false,
      initialChildSize: .65,
      minChildSize: .3,
      maxChildSize: .9,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        children: [
          Text(
            AppLocalizations.of(context).t08_overview,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 18),
          for (final entry in entries)
            ListTile(
              key: ValueKey('overview-${entry.occurrence.id}'),
              contentPadding: EdgeInsets.zero,
              selected: entry.occurrence.id == selectedId,
              leading: Icon(
                color: Theme.of(context)
                    .extension<AppSemanticColors>()
                    ?.forState(entry.occurrence.state),
                entry.occurrence.state == 'taken'
                    ? Icons.check_circle_outline
                    : entry.occurrence.state == 'missed'
                    ? Icons.error_outline_rounded
                    : Icons.schedule_outlined,
              ),
              title: Text(entry.snapshot.pillName),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${entry.person.name} · ${plannedTimeLabel(context, entry.occurrence)}',
                  ),
                  Text(
                    careAmountLabel(
                      AppLocalizations.of(context),
                      entry.plannedAmount,
                    ),
                  ),
                  Text(
                    careOutcomeLabel(
                      AppLocalizations.of(context),
                      entry.occurrence.state,
                      late: isTakenLate(entry.occurrence.state, entry.head),
                    ),
                  ),
                ],
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).pop(entry.occurrence.id),
            ),
          if (localDate != null) _OverviewComingUp(localDate: localDate),
        ],
      ),
    ),
  ),
);

/// Coming up for the sheet: a heading and the next planned doses, flat. Nothing
/// is drawn while it loads, when nothing is planned, or for a day that is not
/// today, so the sheet never shows an empty section.
class _OverviewComingUp extends ConsumerWidget {
  const _OverviewComingUp({required this.localDate});
  final String localDate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today = ref.watch(todayProvider);
    if (localDate != today) return const SizedBox.shrink();
    final doses = ref.watch(comingUpProvider(today)).asData?.value;
    if (doses == null || doses.isEmpty) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    return Column(
      key: const ValueKey('overview-coming-up'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 18),
        Semantics(
          header: true,
          child: Text(
            l.tt_comingUp,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: 4),
        for (final dose in doses)
          ComingUpRow(dose: dose, today: today, framed: false),
      ],
    );
  }
}
