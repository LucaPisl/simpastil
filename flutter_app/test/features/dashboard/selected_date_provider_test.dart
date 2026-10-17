import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/features/dashboard/selected_date_provider.dart';

void main() {
  ProviderContainer makeContainer() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  DateTime today() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  group('dateOnly', () {
    test('floors a timestamp to local midnight', () {
      expect(dateOnly(DateTime(2026, 6, 11, 23, 59)), DateTime(2026, 6, 11));
      expect(dateOnly(DateTime(2026, 6, 11)), DateTime(2026, 6, 11));
    });
  });

  group('SelectedDateNotifier', () {
    test('initial state is today at local midnight', () {
      final container = makeContainer();
      expect(container.read(selectedDateProvider), today());
    });

    test('previousDay moves back one calendar day', () {
      final container = makeContainer();
      container.read(selectedDateProvider.notifier).previousDay();
      final t = today();
      expect(
        container.read(selectedDateProvider),
        DateTime(t.year, t.month, t.day - 1),
      );
    });

    test('nextDay is a no-op when today is selected', () {
      final container = makeContainer();
      container.read(selectedDateProvider.notifier).nextDay();
      expect(container.read(selectedDateProvider), today());
    });

    test('nextDay advances when a past day is selected', () {
      final container = makeContainer();
      final notifier = container.read(selectedDateProvider.notifier);
      notifier.previousDay();
      notifier.previousDay();
      notifier.nextDay();
      final t = today();
      expect(
        container.read(selectedDateProvider),
        DateTime(t.year, t.month, t.day - 1),
      );
    });

    test('nextDay from yesterday advances to today', () {
      final container = makeContainer();
      final notifier = container.read(selectedDateProvider.notifier);
      notifier.previousDay();
      notifier.nextDay();
      expect(container.read(selectedDateProvider), today());
    });

    test('select floors the given date to midnight', () {
      final container = makeContainer();
      container
          .read(selectedDateProvider.notifier)
          .select(DateTime(2026, 1, 5, 15, 30));
      expect(container.read(selectedDateProvider), DateTime(2026, 1, 5));
    });

    test('select clamps future dates to today', () {
      final container = makeContainer();
      final future = DateTime.now().add(const Duration(days: 10));
      container.read(selectedDateProvider.notifier).select(future);
      expect(container.read(selectedDateProvider), today());
    });

    test('backToToday returns to today from a past day', () {
      final container = makeContainer();
      final notifier = container.read(selectedDateProvider.notifier);
      notifier.previousDay();
      notifier.previousDay();
      notifier.backToToday();
      expect(container.read(selectedDateProvider), today());
    });
  });
}
