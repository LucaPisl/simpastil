import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/medication/medication_activity.dart';
import '../../../core/medication/medication_detail_repository.dart';
import '../../../core/notifications/reminder_copy.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/format/clock.dart';
import '../../../shared/motion/app_motion.dart';
import '../../../shared/widgets/reminder_notification_preview.dart';
import '../../schedules/presentation/day_part.dart';
import '../../schedules/presentation/routine_presentation.dart';
import '../../settings/presentation/reminder_privacy_settings.dart';
import 'medication_form_kit.dart';
import 'medication_identity.dart';
import 'medication_routine_info.dart';
import 'stock_capsule.dart';
import 'supply_runway.dart';

/// What the medication being edited will look like where it matters: the dose
/// card on Today, the reminder notification and the stock once saved. It
/// follows the form while the person types and writes nothing.
///
/// Every value shown here is also in a labelled field, so the whole preview is
/// hidden from assistive technology, like the identity preview above the form.
class MedicationEditPreview extends ConsumerWidget {
  const MedicationEditPreview({
    super.key,
    required this.listenable,
    required this.detail,
    required this.local,
    required this.name,
    required this.form,
    required this.dosage,
    required this.stock,
    required this.tint,
  });

  /// Changes whenever a field the preview reads changes.
  final Listenable listenable;
  final MedicationCareDetail detail;
  final bool local;
  final String Function() name;
  final String Function() form;

  /// The amount per dose as typed ("1 tablet"), or null when it is unknown.
  final String? Function() dosage;

  /// The stock field's text.
  final String Function() stock;
  final Color tint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final fullDetails =
        ref.watch(reminderDisplayPreferencesProvider).value?.fullDetails ??
        true;
    final times = plannedTimesOf(detail, local: local);
    final asNeeded = detail.pill.isPrn;
    final routine = local ? currentRoutineOf(detail) : null;
    return ExcludeSemantics(
      child: ListenableBuilder(
        listenable: listenable,
        builder: (context, _) {
          final title = name().trim().isEmpty
              ? l.mf_previewPlaceholder
              : name().trim();
          final amount = dosage();
          final pattern = routine == null
              ? null
              : routinePatternLabel(context, routine);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _DoseCardPreview(
                name: title,
                shape: medicationShapeOf(form()),
                tint: tint,
                line: previewLine([amount, pattern]),
                time: times.isEmpty ? null : times.first,
                asNeeded: asNeeded,
                noRoutine: !asNeeded && times.isEmpty,
              ),
              if (!asNeeded && times.isNotEmpty) ...[
                const SizedBox(height: 12),
                ReminderNotificationPreview(
                  key: const ValueKey('edit-preview-reminder'),
                  elevated: false,
                  private: !fullDetails,
                  copy: doseReminderCopy(
                    l,
                    fullDetails: fullDetails,
                    pillName: title,
                    dosage: amount,
                  ),
                  header: fullDetails ? l.r6_notifSubText : null,
                  actions: fullDetails
                      ? [
                          l.core_notifActionTaken,
                          l.core_notifActionSnooze,
                          l.core_notifActionSkip,
                        ]
                      : [l.core_notifActionOpen],
                ),
              ],
              const SizedBox(height: 10),
              Text(
                l.tm_previewNote,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              if (local) ...[
                const SizedBox(height: 16),
                _StockAfterSaving(detail: detail, typed: stock(), tint: tint),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// A small copy of the dose card on Today: the part of the day, the time, the
/// mark and name, the amount and the button.
class _DoseCardPreview extends StatelessWidget {
  const _DoseCardPreview({
    required this.name,
    required this.shape,
    required this.tint,
    required this.line,
    required this.time,
    required this.asNeeded,
    required this.noRoutine,
  });

  final String name;
  final MedicationShape shape;
  final Color tint;
  final String line;
  final TimeOfDay? time;
  final bool asNeeded, noRoutine;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final text = theme.textTheme;
    final dark = theme.brightness == Brightness.dark;
    final at = time;
    final note = asNeeded
        ? l.asn_onlyWhenNeeded
        : (noRoutine ? l.t09_noRoutine : null);
    return AnimatedContainer(
      key: const ValueKey('edit-preview-dose-card'),
      duration: AppMotion.duration(context),
      curve: AppMotion.curve,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: dark ? cs.surfaceContainerHigh : cs.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: tint.withValues(alpha: .5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (at != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: cs.secondaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                dayPartLabel(l, dayPartOf(at)),
                style: text.labelMedium?.copyWith(
                  color: cs.onSecondaryContainer,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          if (at != null) const SizedBox(height: 10),
          Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: tint.withValues(alpha: dark ? .22 : .16),
                  borderRadius: BorderRadius.circular(16),
                ),
                alignment: Alignment.center,
                child: MedicationMark(color: tint, shape: shape, size: 36),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (at != null)
                      Text(
                        clockTime(context, at),
                        style: text.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          height: 1.05,
                        ),
                      ),
                    Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: (at != null ? text.titleMedium : text.titleLarge)
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (line.isNotEmpty || note != null) ...[
            const SizedBox(height: 10),
            Text(
              [if (line.isNotEmpty) line, ?note].join(' · '),
              style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 14),
          Container(
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: cs.primary,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              asNeeded ? l.asn_recordDose : l.t08_takenNow,
              style: text.labelLarge?.copyWith(
                color: cs.onPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The stock the medication will hold once the form is saved, and how long it
/// lasts along the routine.
class _StockAfterSaving extends StatelessWidget {
  const _StockAfterSaving({
    required this.detail,
    required this.typed,
    required this.tint,
  });

  final MedicationCareDetail detail;
  final String typed;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final text = theme.textTheme;
    final stored = detail.pill.currentStock;
    final after = stockAfterSaving(
      typed: typed,
      stored: stored,
      threshold: detail.pill.lowStockThreshold,
    );
    final count = after.stock;
    final forecast = count == null
        ? null
        : supplyForecastFor(
            detail,
            local: true,
            now: DateTime.now(),
            stockOverride: count,
          );
    return Column(
      key: const ValueKey('edit-preview-stock'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l.tm_stockAfterSaving,
          style: text.labelLarge?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              count == null ? l.tm_noCount : l.pills_stockLeft(count),
              key: const ValueKey('edit-preview-stock-count'),
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            if (after.changedBy != 0 && stored != null) ...[
              const SizedBox(width: 8),
              Text(
                l.tm_stockWas(stored),
                style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ],
        ),
        if (forecast != null) ...[
          const SizedBox(height: 2),
          Text(
            stockRunsOutLine(context, forecast),
            key: const ValueKey('edit-preview-stock-runs-out'),
            style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
        if (count != null) ...[
          const SizedBox(height: 10),
          StockCapsule(
            stock: count,
            threshold: detail.pill.lowStockThreshold,
            color: tint,
          ),
        ],
      ],
    );
  }
}
