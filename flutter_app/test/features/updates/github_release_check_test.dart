import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/features/updates/data/github_release_check.dart';
import 'package:simpastil/features/updates/data/update_hint.dart';

const _releaseUrl = 'https://github.com/LucaPisl/simpastil/releases/tag/v1.2.0';
const _manifestUrl =
    'https://github.com/LucaPisl/simpastil/releases/download/v1.2.0/release-manifest.json';

final _release = {
  'tag_name': 'v1.2.0',
  'html_url': _releaseUrl,
  'assets': [
    {'name': 'release-manifest.json', 'browser_download_url': _manifestUrl},
  ],
};

class _Fixture {
  _Fixture(Map<String, Response<String> Function(RequestOptions)> routes) {
    dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options.uri.toString());
          final route = routes[options.uri.toString()];
          if (route == null) {
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response(requestOptions: options, statusCode: 404),
                type: DioExceptionType.badResponse,
              ),
            );
          } else {
            handler.resolve(route(options));
          }
        },
      ),
    );
  }
  late final Dio dio;
  final requests = <String>[];
}

Response<String> Function(RequestOptions) _json(Object body) =>
    (o) => Response<String>(
      data: jsonEncode(body),
      statusCode: 200,
      requestOptions: o,
    );

const _api = 'https://api.github.com/repos/LucaPisl/simpastil/releases/latest';

_Fixture _good({String build = '5'}) => _Fixture({
  _api: _json(_release),
  _manifestUrl: _json({
    'source': {'appBuild': build, 'appVersion': '1.2.0'},
  }),
});

void main() {
  final now = DateTime.utc(2026, 10, 17, 12);

  setUp(
    () => SharedPreferences.setMockInitialValues({updateCheckEnabledKey: true}),
  );

  test(
    'a fresh install makes no request until the switch is turned on',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final fx = _good();
      await GitHubReleaseCheck(fx.dio, now: () => now).runIfDue(prefs);
      expect(fx.requests, isEmpty);
      expect(prefs.getInt(updateLastCheckedKey), isNull);
    },
  );

  test('the disabled switch makes no request', () async {
    SharedPreferences.setMockInitialValues({updateCheckEnabledKey: false});
    final prefs = await SharedPreferences.getInstance();
    final fx = _good();
    await GitHubReleaseCheck(fx.dio, now: () => now).runIfDue(prefs);
    expect(fx.requests, isEmpty);
  });

  test('a check two hours ago makes no request', () async {
    SharedPreferences.setMockInitialValues({
      updateCheckEnabledKey: true,
      updateLastCheckedKey: now
          .subtract(const Duration(hours: 2))
          .millisecondsSinceEpoch,
    });
    final prefs = await SharedPreferences.getInstance();
    final fx = _good();
    await GitHubReleaseCheck(fx.dio, now: () => now).runIfDue(prefs);
    expect(fx.requests, isEmpty);
  });

  test('a check 25 hours ago runs and records build and url', () async {
    SharedPreferences.setMockInitialValues({
      updateCheckEnabledKey: true,
      updateLastCheckedKey: now
          .subtract(const Duration(hours: 25))
          .millisecondsSinceEpoch,
    });
    final prefs = await SharedPreferences.getInstance();
    final fx = _good();
    await GitHubReleaseCheck(fx.dio, now: () => now).runIfDue(prefs);
    expect(fx.requests, [_api, _manifestUrl]);
    expect(prefs.getInt(UpdateHint.latestBuildKey), 5);
    expect(prefs.getString(UpdateHint.releaseUrlKey), _releaseUrl);
    expect(prefs.getString(UpdateHint.sourceKey), 'github');
    expect(prefs.getInt(updateLastCheckedKey), now.millisecondsSinceEpoch);
  });

  test('a stored time in the future counts as due', () async {
    SharedPreferences.setMockInitialValues({
      updateCheckEnabledKey: true,
      updateLastCheckedKey: now
          .add(const Duration(days: 400))
          .millisecondsSinceEpoch,
    });
    final prefs = await SharedPreferences.getInstance();
    final fx = _good();
    await GitHubReleaseCheck(fx.dio, now: () => now).runIfDue(prefs);
    expect(fx.requests, isNotEmpty);
    expect(prefs.getInt(updateLastCheckedKey), now.millisecondsSinceEpoch);
  });

  test(
    'a manifest without a build changes nothing but the attempt time',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final fx = _Fixture({
        _api: _json(_release),
        _manifestUrl: _json({'source': {}}),
      });
      await GitHubReleaseCheck(fx.dio, now: () => now).runIfDue(prefs);
      expect(prefs.getInt(UpdateHint.latestBuildKey), isNull);
      expect(prefs.getInt(updateLastCheckedKey), now.millisecondsSinceEpoch);
    },
  );

  test('a 404 changes nothing but the attempt time', () async {
    final prefs = await SharedPreferences.getInstance();
    final fx = _Fixture({});
    await GitHubReleaseCheck(fx.dio, now: () => now).runIfDue(prefs);
    expect(prefs.getInt(UpdateHint.latestBuildKey), isNull);
    expect(prefs.getInt(updateLastCheckedKey), now.millisecondsSinceEpoch);
  });
}
