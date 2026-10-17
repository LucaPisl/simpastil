import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/sync/capabilities_client.dart';
import 'package:simpastil/features/updates/data/update_hint.dart';

const _url = 'https://github.com/LucaPisl/simpastil/releases/tag/v1.1.0';

CapabilitySnapshot _present({int? build, String? url}) =>
    CapabilitySnapshot.present(
      ServerCapabilities(
        medicationLedgerActive: false,
        minimumClientBuild: 1,
        serverRelease: 'r',
        latestClientBuild: build,
        latestReleaseUrl: url,
      ),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('isValidReleaseUrl accepts only the project release pages', () {
    expect(isValidReleaseUrl(_url), isTrue);
    expect(isValidReleaseUrl('https://evil.example/releases/x'), isFalse);
    expect(isValidReleaseUrl('$_url extra'), isFalse);
  });

  test(
    'a present snapshot with fields stores them as server sourced',
    () async {
      await UpdateHint.recordFromServer(_present(build: 4, url: _url));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(UpdateHint.latestBuildKey), 4);
      expect(prefs.getString(UpdateHint.releaseUrlKey), _url);
      expect(prefs.getString(UpdateHint.sourceKey), 'server');
    },
  );

  test('a present snapshot without fields clears the hint', () async {
    await UpdateHint.recordFromServer(_present(build: 4, url: _url));
    await UpdateHint.recordFromServer(_present());
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(UpdateHint.latestBuildKey), isNull);
    expect(prefs.getString(UpdateHint.sourceKey), isNull);
  });

  test('an unavailable snapshot leaves the hint alone', () async {
    await UpdateHint.recordFromServer(_present(build: 4, url: _url));
    await UpdateHint.recordFromServer(const CapabilitySnapshot.unavailable());
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(UpdateHint.latestBuildKey), 4);
  });

  test(
    'recordFromGitHub stores github sourced values, clear removes',
    () async {
      await UpdateHint.recordFromGitHub(6, _url);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(UpdateHint.sourceKey), 'github');
      await UpdateHint.clear();
      expect(prefs.getInt(UpdateHint.latestBuildKey), isNull);
    },
  );
}
