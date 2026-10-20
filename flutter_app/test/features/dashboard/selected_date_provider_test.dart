import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/utils/app_clock.dart';
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
  group('across local midnight', () {
    late DateTime now;
    late ProviderContainer container;
    setUp(() {
      now = DateTime(2026, 10, 20, 23, 30);
      container = ProviderContainer(
        overrides: [appClockProvider.overrideWithValue(() => now)],
      );
      addTearDown(container.dispose);
    });

    void midnight() {
      now = DateTime(2026, 10, 21, 0, 0, 5);
      container.read(todayProvider.notifier).state = '2026-10-21';
    }

    test('starts on the clock day', () {
      expect(container.read(selectedDateProvider), DateTime(2026, 10, 20));
    });

    test('a selection on today moves to the new day', () {
      expect(container.read(selectedDateProvider), DateTime(2026, 10, 20));
      midnight();
      expect(container.read(selectedDateProvider), DateTime(2026, 10, 21));
    });

    test('an earlier day stays where it was chosen', () {
      container.read(selectedDateProvider.notifier).previousDay();
      midnight();
      expect(container.read(selectedDateProvider), DateTime(2026, 10, 19));
    });

    test('nextDay, select and backToToday use the clock', () {
      final notifier = container.read(selectedDateProvider.notifier);
      notifier.previousDay();
      midnight();
      notifier.nextDay();
      expect(container.read(selectedDateProvider), DateTime(2026, 10, 20));
      notifier.nextDay();
      expect(container.read(selectedDateProvider), DateTime(2026, 10, 21));
      notifier.select(DateTime(2026, 10, 30));
      expect(container.read(selectedDateProvider), DateTime(2026, 10, 21));
      notifier.previousDay();
      notifier.backToToday();
      expect(container.read(selectedDateProvider), DateTime(2026, 10, 21));
    });
  });
}
