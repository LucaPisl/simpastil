import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/api/api_client.dart';
import 'package:simpastil/core/server/server_config_notifier.dart';
import 'package:simpastil/core/storage/shared_preferences_provider.dart';
import 'package:simpastil/core/sync/capabilities_client.dart';
import 'package:simpastil/features/updates/data/github_release_check.dart';
import 'package:simpastil/features/updates/data/update_hint.dart';
import 'package:simpastil/features/updates/update_status_provider.dart';

const _url = 'https://github.com/LucaPisl/simpastil/releases/tag/v1.2.0';
const _newer = simpastilClientBuild + 1;

class _Server extends ServerConfigNotifier {
  _Server(this.url);
  final String? url;
  @override
  String? build() => url;
}

Future<ProviderContainer> _container(
  Map<String, Object> values, {
  String? server,
}) async {
  SharedPreferences.setMockInitialValues(values);
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      serverConfigProvider.overrideWith(() => _Server(server)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Map<String, Object> _hint(int build, String source) => {
  UpdateHint.latestBuildKey: build,
  UpdateHint.releaseUrlKey: _url,
  UpdateHint.sourceKey: source,
  updateCheckEnabledKey: true,
};

void main() {
  test('a higher build from the matching source is announced', () async {
    final c = await _container(_hint(_newer, 'github'));
    final status = await c.read(updateStatusProvider.future);
    expect(status?.build, _newer);
    expect(status?.releaseUrl.toString(), _url);
    expect(status?.version, '1.2.0');
  });

  test('the same or an older build is not announced', () async {
    final c = await _container(_hint(simpastilClientBuild, 'github'));
    expect(await c.read(updateStatusProvider.future), isNull);
  });

  test('dismissing hides it and a later build shows it again', () async {
    final c = await _container(_hint(_newer, 'github'));
    expect(await c.read(updateStatusProvider.future), isNotNull);
    await c.read(updateStatusProvider.notifier).dismiss();
    expect(c.read(updateStatusProvider).valueOrNull, isNull);

    final prefs = c.read(sharedPreferencesProvider);
    await UpdateHint.recordFromGitHub(_newer + 1, _url);
    await Future<void>.delayed(Duration.zero);
    expect(prefs.getInt(updateDismissedBuildKey), _newer);
    expect((await c.read(updateStatusProvider.future))?.build, _newer + 1);
  });

  test('an already dismissed build stays hidden', () async {
    final c = await _container({
      ..._hint(_newer, 'github'),
      updateDismissedBuildKey: _newer,
    });
    expect(await c.read(updateStatusProvider.future), isNull);
  });

  test('update required wins over the soft card', () async {
    final c = await _container(
      _hint(_newer, 'server'),
      server: 'https://example.invalid',
    );
    expect(await c.read(updateStatusProvider.future), isNotNull);
    await UpdateHint.recordFromServer(
      const CapabilitySnapshot.updateRequired(),
    );
    expect(await c.read(updateStatusProvider.future), isNull);

    // Same when the server's minimum build is above this app.
    await UpdateHint.recordFromGitHub(_newer, _url);
    await UpdateHint.recordFromServer(
      const CapabilitySnapshot.present(
        ServerCapabilities(
          medicationLedgerActive: false,
          minimumClientBuild: simpastilClientBuild + 1,
          serverRelease: 'r',
          latestClientBuild: _newer,
          latestReleaseUrl: _url,
        ),
      ),
    );
    expect(await c.read(updateStatusProvider.future), isNull);
  });

  test('a stale source is not shown', () async {
    final noServer = await _container(_hint(_newer, 'server'));
    expect(await noServer.read(updateStatusProvider.future), isNull);
    final withServer = await _container(
      _hint(_newer, 'github'),
      server: 'https://example.invalid',
    );
    expect(await withServer.read(updateStatusProvider.future), isNull);
    final fromServer = await _container(
      _hint(_newer, 'server'),
      server: 'https://example.invalid',
    );
    expect(await fromServer.read(updateStatusProvider.future), isNotNull);
  });

  test('a github result stays hidden until the switch is turned on', () async {
    final c = await _container(
      {..._hint(_newer, 'github')}..remove(updateCheckEnabledKey),
    );
    expect(await c.read(updateStatusProvider.future), isNull);
  });

  test('switching the direct check off hides a github result', () async {
    final c = await _container({
      ..._hint(_newer, 'github'),
      updateCheckEnabledKey: false,
    });
    expect(await c.read(updateStatusProvider.future), isNull);
  });
}
