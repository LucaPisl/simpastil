import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/medication/medication_amount.dart';
import '../../../core/medication/medication_detail_provider.dart';
import '../../../core/medication/medication_detail_repository.dart';
import '../../../core/workspace/workspace_provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/layouts/window_size.dart';
import '../../../shared/widgets/status_chip.dart';
import '../../dashboard/care_record_form.dart' show careAmountLabel;
import '../../setup/setup_state.dart';
import 'settings_overview.dart';
import 'settings_pane.dart';

/// What accepting one row does. Nothing here ever replaces an amount a person
/// already set: legacy wording is evidence, never an authority over a review.
enum MedicationAmountOutcome {
  /// The original text reads as one amount, and none is set yet.
  setAmount,

  /// An amount is already set; only the review reminder is cleared.
  keepAmount,

  /// The original text does not read as one amount, so a person decides.
  needsPerson,
}

/// One medicine whose original dosage text has not been reviewed.
@immutable
class MedicationAmountCandidate {
  const MedicationAmountCandidate({required this.detail, required this.amount});

  final MedicationCareDetail detail;

  /// The amount the original text reads as, or null when it does not read as
  /// one and when an amount is already set.
  final MedicationAmount? amount;

  MedicationAmountOutcome get outcome => !detail.review.amount.isUnknown
      ? MedicationAmountOutcome.keepAmount
      : amount == null
      ? MedicationAmountOutcome.needsPerson
      : MedicationAmountOutcome.setAmount;

  /// Accepting in bulk covers everything a person does not have to decide.
  bool get acceptable => outcome != MedicationAmountOutcome.needsPerson;

  /// The review to save, with the original wording preserved exactly.
  MedicationReview get reviewed => MedicationReview(
    name: detail.review.name,
    packageStrength: detail.review.packageStrength,
    form: detail.review.form,
    notes: detail.review.notes,
    amount: amount ?? detail.review.amount,
    originalDosage: detail.review.originalDosage,
    legacyDosageReviewed: true,
  );
}

/// Medicines still carrying unreviewed original dosage text.
final medicationAmountReviewProvider =
    Provider<AsyncValue<List<MedicationAmountCandidate>>>(
      (ref) => ref
          .watch(medicationListProvider)
          .whenData(
            (details) => [
              for (final detail in details)
                if (detail.review.originalDosage != null &&
                    !detail.review.legacyDosageReviewed)
                  MedicationAmountCandidate(
                    detail: detail,
                    amount: detail.review.amount.isUnknown
                        ? MedicationAmount.fromLegacyText(
                            detail.review.originalDosage!,
                          )
                        : null,
                  ),
            ],
          ),
    );

/// How many medicines the Data screen should offer to review. A failed or
/// still-loading list offers nothing rather than a wrong count.
final medicationAmountReviewCountProvider = Provider<int>(
  (ref) => ref.watch(medicationAmountReviewProvider).asData?.value.length ?? 0,
);

/// Reviews the original dosage text of every medicine in one pass.
///
/// A medicine is listed with the amount its own wording reads as, so a person
/// confirms what they are about to save instead of trusting a count.
class MedicationAmountReviewScreen extends ConsumerStatefulWidget {
  const MedicationAmountReviewScreen({super.key});

  @override
  ConsumerState<MedicationAmountReviewScreen> createState() =>
      _MedicationAmountReviewScreenState();
}

class _MedicationAmountReviewScreenState
    extends ConsumerState<MedicationAmountReviewScreen> {
  bool _busy = false;
  String? _message;
  bool _failed = false;

  Future<void> _acceptAll(List<MedicationAmountCandidate> candidates) async {
    final l = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _message = null;
      _failed = false;
    });
    var saved = 0;
    try {
      final repository = await ref.read(
        medicationDetailRepositoryProvider.future,
      );
      for (final candidate in candidates) {
        try {
          await repository.updateReviewed(
            expected: candidate.detail,
            review: candidate.reviewed,
          );
          saved++;
        } on MedicationDetailConflict {
          // Changed under us; it stays listed for the next pass.
        }
      }
    } on Object {
      if (mounted) {
        setState(() {
          _busy = false;
          _failed = true;
          _message = l.amountReview_error;
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _failed = saved != candidates.length;
      _message = saved == candidates.length
          ? l.amountReview_saved(saved)
          : l.amountReview_partial(saved, candidates.length);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final state = ref.watch(medicationAmountReviewProvider);
    final selection = ref.watch(protectedWorkspaceSelectionProvider);
    final partial = selection.asData?.value.viewEveryone == false;
    final candidates =
        state.asData?.value ?? const <MedicationAmountCandidate>[];
    final acceptable = [
      for (final candidate in candidates)
        if (candidate.acceptable) candidate,
    ];
    final manual = [
      for (final candidate in candidates)
        if (!candidate.acceptable) candidate,
    ];
    return Scaffold(
      appBar: settingsDetailAppBar(context, l.amountReview_title),
      body: ContentListView(
        maxWidth: settingsContentWidth(context),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          Text(l.amountReview_intro, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 16),
          if (partial) ...[
            CalmNotice(
              text: l.amountReview_selectedPerson,
              icon: Icons.people_outline,
              tone: StatusTone.neutral,
            ),
            const SizedBox(height: 16),
          ],
          if (_message != null) ...[
            CalmNotice(
              key: const ValueKey('amount-review-message'),
              text: _message!,
              icon: _failed
                  ? Icons.error_outline
                  : Icons.check_circle_outline_rounded,
              tone: _failed ? StatusTone.attention : StatusTone.good,
            ),
            const SizedBox(height: 16),
          ],
          if (state.isLoading)
            const Center(child: CircularProgressIndicator())
          else if (candidates.isEmpty)
            CalmNotice(
              key: const ValueKey('amount-review-empty'),
              text: l.amountReview_empty,
              icon: Icons.check_circle_outline_rounded,
              tone: StatusTone.good,
            ),
          if (acceptable.isNotEmpty) ...[
            SettingsGroup(
              label: l.amountReview_readable,
              children: [
                for (final candidate in acceptable) _row(candidate, l),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                l.amountReview_readableHint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            FilledButton(
              key: const ValueKey('amount-review-accept'),
              onPressed: _busy ? null : () => _acceptAll(acceptable),
              child: _busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(l.amountReview_accept(acceptable.length)),
            ),
            const SizedBox(height: 24),
          ],
          if (manual.isNotEmpty) ...[
            SettingsGroup(
              label: l.amountReview_manual,
              children: [for (final candidate in manual) _row(candidate, l)],
            ),
            Text(
              l.amountReview_manualHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(MedicationAmountCandidate candidate, AppLocalizations l) {
    final theme = Theme.of(context);
    final detail = candidate.detail;
    final outcome = switch (candidate.outcome) {
      MedicationAmountOutcome.setAmount => l.amountReview_willSet(
        careAmountLabel(l, candidate.amount!),
      ),
      MedicationAmountOutcome.keepAmount => l.amountReview_willKeep(
        careAmountLabel(l, detail.review.amount),
      ),
      MedicationAmountOutcome.needsPerson => null,
    };
    return Padding(
      key: ValueKey('amount-review-${detail.pill.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${detail.pill.name} · ${detail.person.name}',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            l.amountReview_original(detail.review.originalDosage!),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (outcome != null) ...[
            const SizedBox(height: 3),
            Text(outcome, style: theme.textTheme.bodyMedium),
          ],
        ],
      ),
    );
  }
}
