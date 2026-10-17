import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/storage/low_stock_dismissal_preference.dart';
import 'package:simpastil/core/storage/shared_preferences_provider.dart';

Future<ProviderContainer> _container([
  Map<String, Object> seed = const {},
]) async {
  SharedPreferences.setMockInitialValues(seed);
  final preferences = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  final morning = DateTime(2026, 10, 16, 9);

  test('nothing is hidden at first', () async {
    final container = await _container();
    expect(container.read(lowStockDismissalsProvider), isEmpty);
    expect(
      container
          .read(lowStockDismissalsProvider.notifier)
          .isHidden('p', now: morning),
      isFalse,
    );
  });

  test('Later hides a notice until tomorrow and survives a restart', () async {
    final container = await _container();
    await container
        .read(lowStockDismissalsProvider.notifier)
        .dismiss('p', now: morning);
    final notifier = container.read(lowStockDismissalsProvider.notifier);
    expect(notifier.isHidden('p', now: morning), isTrue);
    expect(notifier.isHidden('q', now: morning), isFalse);
    expect(notifier.isHidden('p', now: DateTime(2026, 10, 17, 0, 1)), isFalse);

    final preferences = await SharedPreferences.getInstance();
    final restarted = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
    );
    addTearDown(restarted.dispose);
    expect(restarted.read(lowStockDismissalsProvider), {'p': '2026-10-17'});
  });

  test('putting off a second medication keeps the first', () async {
    final container = await _container();
    final notifier = container.read(lowStockDismissalsProvider.notifier);
    await notifier.dismiss('p', now: morning);
    await notifier.dismiss('q', now: morning);
    expect(container.read(lowStockDismissalsProvider), {
      'p': '2026-10-17',
      'q': '2026-10-17',
    });
  });

  test('expired entries are dropped when a new one is saved', () async {
    final container = await _container({
      kLowStockDismissedPreferenceKey: ['old|2026-10-10', 'keep|2026-10-20'],
    });
    final notifier = container.read(lowStockDismissalsProvider.notifier);
    expect(container.read(lowStockDismissalsProvider), hasLength(2));
    await notifier.dismiss('p', now: morning);
    expect(container.read(lowStockDismissalsProvider), {
      'keep': '2026-10-20',
      'p': '2026-10-17',
    });
  });

  test('a malformed entry is ignored', () async {
    final container = await _container({
      kLowStockDismissedPreferenceKey: [
        'broken',
        '|2026-10-20',
        'p|2026-10-20',
      ],
    });
    expect(container.read(lowStockDismissalsProvider), {'p': '2026-10-20'});
  });
}
