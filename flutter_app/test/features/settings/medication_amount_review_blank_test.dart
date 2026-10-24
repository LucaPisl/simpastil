import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/medication/medication_detail_provider.dart';
import 'package:simpastil/core/medication/medication_detail_repository.dart';
import 'package:simpastil/features/pills/presentation/medication_detail_sections.dart';
import 'package:simpastil/features/settings/presentation/medication_amount_review_screen.dart';
import 'package:simpastil/features/setup/setup_state.dart';

class _Detail extends Fake implements MedicationCareDetail {
  _Detail(this.review);
  @override
  final MedicationReview review;
}

/// A blank original dosage text is not a text to review: the review list, the
/// edit form and the dose details ask the same question as the badges.
void main() {
  test('the review list leaves out a blank original text', () async {
    final blank = _Detail(
      const MedicationReview(name: 'Blank', originalDosage: '  '),
    );
    final real = _Detail(
      const MedicationReview(name: 'Real', originalDosage: '1 pill'),
    );
    final reviewed = _Detail(
      const MedicationReview(
        name: 'Done',
        originalDosage: '1 pill',
        legacyDosageReviewed: true,
      ),
    );
    final container = ProviderContainer(
      overrides: [
        medicationListProvider.overrideWith(
          (ref) => Stream.value([blank, real, reviewed]),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen(medicationListProvider, (_, _) {});
    await container.read(medicationListProvider.future);

    final candidates = container.read(medicationAmountReviewProvider).value!;
    expect(candidates.map((c) => c.detail.review.name), ['Real']);
  });

  test('a blank original text is not shown', () {
    expect(hasOriginalDosageText(null), isFalse);
    expect(hasOriginalDosageText(' \n'), isFalse);
    expect(hasOriginalDosageText('1 pill'), isTrue);
  });
}
