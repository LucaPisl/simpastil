import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/network/http_clients.dart';
import 'update_hint.dart';

/// Whether a phone with no server may ask GitHub for the latest release.
/// Dart-only, device-local; off unless the person switches it on.
const updateCheckEnabledKey = 'update_check_enabled';

/// Epoch milliseconds of the last direct check, successful or not.
const updateLastCheckedKey = 'update_last_checked';

const _releaseApiUrl =
    'https://api.github.com/repos/LucaPisl/simpastil/releases/latest';
const _manifestAssetName = 'release-manifest.json';
const _checkInterval = Duration(hours: 24);
const _manifestHosts = {'github.com', 'objects.githubusercontent.com'};
final _versionPattern = RegExp(r'^\d+\.\d+\.\d+$');

/// Asks GitHub once a day for the newest release, for phones that have no
/// server to ask. Never throws; a failed or odd answer changes nothing except
/// the time of the attempt.
class GitHubReleaseCheck {
  GitHubReleaseCheck(this._dio, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final Dio _dio;
  final DateTime Function() _now;

  Future<void> runIfDue(SharedPreferences prefs) async {
    if (prefs.getBool(updateCheckEnabledKey) != true) return;
    final nowMs = _now().millisecondsSinceEpoch;
    final last = prefs.getInt(updateLastCheckedKey);
    // A stored time in the future (a clock that was wrong) counts as due, so
    // the check can neither run on every resume nor never run again.
    if (last != null &&
        last <= nowMs &&
        nowMs - last < _checkInterval.inMilliseconds) {
      return;
    }
    await prefs.setInt(updateLastCheckedKey, nowMs);
    try {
      final release = _parseRelease(await _getJson(_releaseApiUrl));
      if (release == null) return;
      final build = _parseBuild(await _getJson(release.manifestUrl));
      if (build == null) return;
      await UpdateHint.recordFromGitHub(build, release.releaseUrl);
    } on Object {
      // Offline or GitHub unhappy: try again tomorrow.
    }
  }

  Future<Object?> _getJson(String url) async {
    final response = await _dio.get<String>(
      url,
      options: Options(
        responseType: ResponseType.plain,
        headers: {'Accept': 'application/vnd.github+json'},
      ),
    );
    final data = response.data;
    if (data == null) return null;
    return jsonDecode(data);
  }

  ({String releaseUrl, String manifestUrl})? _parseRelease(Object? body) {
    if (body is! Map) return null;
    final tag = body['tag_name'];
    final htmlUrl = body['html_url'];
    final assets = body['assets'];
    if (tag is! String || htmlUrl is! String || assets is! List) return null;
    final version = tag.startsWith('v') ? tag.substring(1) : tag;
    if (!_versionPattern.hasMatch(version) || !isValidReleaseUrl(htmlUrl)) {
      return null;
    }
    for (final asset in assets) {
      if (asset is! Map || asset['name'] != _manifestAssetName) continue;
      final url = asset['browser_download_url'];
      final uri = url is String ? Uri.tryParse(url) : null;
      if (uri != null &&
          uri.scheme == 'https' &&
          _manifestHosts.contains(uri.host)) {
        return (releaseUrl: htmlUrl, manifestUrl: url as String);
      }
    }
    return null;
  }

  int? _parseBuild(Object? body) {
    if (body is! Map) return null;
    final source = body['source'];
    if (source is! Map) return null;
    final raw = source['appBuild'];
    final build = raw is int
        ? raw
        : raw is String && RegExp(r'^\d{1,15}$').hasMatch(raw)
        ? int.parse(raw)
        : null;
    return build != null && build > 0 ? build : null;
  }
}

final gitHubReleaseCheckProvider = Provider<GitHubReleaseCheck>((ref) {
  final dio = createNonPinningExternalDio(
    options: BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 10),
    ),
  );
  ref.onDispose(dio.close);
  return GitHubReleaseCheck(dio);
});
