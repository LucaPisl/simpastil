import 'package:dio/dio.dart';

import '../utils/safe_diagnostics.dart';
import 'account_setting_codec.dart';
import 'settings_store.dart';

/// Called with the keys written into this device's stores by a pull, so the
/// running app can reload what it shows.
typedef AccountSettingsApplied = Future<void> Function(Set<String> keys);

/// One item of a settings page the client can read.
class AccountSettingItem {
  const AccountSettingItem(this.key, this.value, this.revision);
  final String key;
  final Object? value;
  final int revision;
}

/// A page of `GET /account/settings`. Items for an unknown key, or with a
/// value the client cannot read, are dropped and listed in [ignored]: one
/// setting a newer server knows about must never fail the pull.
class AccountSettingsPage {
  AccountSettingsPage(
    this.items,
    this.ignored,
    this.revision,
    this.hasMore,
    this.lastRevision,
  );

  final List<AccountSettingItem> items;
  final List<String> ignored;
  final int revision;
  final bool hasMore;

  /// The highest revision on the page, ignored items included.
  final int lastRevision;

  static AccountSettingsPage parse(Object? body) {
    final map = body is Map ? body : const {};
    final raw = map['items'];
    final items = <AccountSettingItem>[];
    final ignored = <String>[];
    var last = 0;
    for (final item in raw is List ? raw : const []) {
      if (item is! Map || item['key'] is! String || item['revision'] is! int) {
        continue;
      }
      final key = item['key'] as String;
      final revision = item['revision'] as int;
      if (revision > last) last = revision;
      final parsed = AccountSettingCodec.parse(key, item['value']);
      if (!parsed.ok) {
        ignored.add(key);
        continue;
      }
      items.add(AccountSettingItem(key, parsed.value, revision));
    }
    return AccountSettingsPage(
      items,
      ignored,
      map['revision'] is int ? map['revision'] as int : last,
      map['hasMore'] == true,
      last,
    );
  }
}

/// What the server answered for one key of a PUT.
class AccountSettingPutResult {
  const AccountSettingPutResult(
    this.key,
    this.status,
    this.revision, {
    this.currentValue,
    this.hasCurrent = false,
  });
  final String key;
  final String status;
  final int revision;
  final Object? currentValue;
  final bool hasCurrent;
}

/// The wire of the account settings: `GET` and `PUT /account/settings`.
class AccountSettingsApi {
  const AccountSettingsApi(this._dio);
  final Dio _dio;

  Future<AccountSettingsPage> pull(int afterRevision) async {
    final response = await _dio.get<Object?>(
      '/account/settings',
      queryParameters: {'afterRevision': afterRevision},
    );
    return AccountSettingsPage.parse(response.data);
  }

  Future<List<AccountSettingPutResult>> put(
    List<Map<String, Object?>> changes,
  ) async {
    final response = await _dio.put<Object?>(
      '/account/settings',
      data: {'changes': changes},
    );
    final body = response.data;
    final results = <AccountSettingPutResult>[];
    for (final r
        in body is Map && body['results'] is List
            ? body['results'] as List
            : const []) {
      if (r is! Map || r['key'] is! String || r['status'] is! String) continue;
      final current = r['current'];
      if (current is Map) {
        final revision = current['revision'];
        if (revision is! int) continue;
        final parsed = AccountSettingCodec.parse(
          r['key'] as String,
          current['value'],
        );
        results.add(
          AccountSettingPutResult(
            r['key'] as String,
            r['status'] as String,
            revision,
            // A value the client cannot read counts as no value to apply.
            currentValue: parsed.ok ? parsed.value : null,
            hasCurrent: parsed.ok && current['value'] != null,
          ),
        );
      } else if (r['revision'] is int) {
        results.add(
          AccountSettingPutResult(
            r['key'] as String,
            r['status'] as String,
            r['revision'] as int,
          ),
        );
      }
    }
    return results;
  }
}

/// Keeps one user's account settings in step with the server. Runs inside the
/// flush-then-pull path: [flush] sends unsent edits, [pull] reads the account's
/// changes, joins the account the first time, and writes what came along into
/// the local stores.
class AccountSettingsSync {
  AccountSettingsSync({required this.store, required this.api, this.onApplied});

  final SettingsStore store;
  final AccountSettingsApi api;
  final AccountSettingsApplied? onApplied;

  static const _batch = 100;

  /// Sends what changed on this device since the last send. A device that has
  /// not joined yet sends nothing here: [pull] sends its first snapshot.
  Future<void> flush() async {
    if (!await store.isJoined()) return;
    await store.queueLocalChanges();
    final applied = await _sendPending(seeding: false);
    if (applied.isNotEmpty) await onApplied?.call(applied);
  }

  /// Reads the account's changes and applies them. The first time, it then
  /// sends the settings this device's user chose (never plain defaults) for every key the account has never held.
  Future<void> pull() async {
    final joined = await store.isJoined();
    final changed = <String>{};
    final cameAlong = <String>{};
    await _pullChanges(joined: joined, changed: changed, cameAlong: cameAlong);
    if (!joined) {
      final held = await store.mirror();
      final snapshot = await store.local.readExplicit();
      for (final entry in snapshot.entries) {
        if (held.containsKey(entry.key)) continue;
        await store.queue(
          entry.key,
          entry.value,
          baseRevision: 0,
          ifAbsent: true,
        );
      }
      changed.addAll(await _sendPending(seeding: true, cameAlong: cameAlong));
      await store.markJoined();
      await store.addNoteGroups({
        for (final key in cameAlong) AccountSettingKeys.groupOf(key),
      });
    }
    if (changed.isNotEmpty) await onApplied?.call(changed);
  }

  Future<void> _pullChanges({
    required bool joined,
    required Set<String> changed,
    required Set<String> cameAlong,
  }) async {
    final local = store.local;
    var after = await store.pullCursor();
    var more = true;
    while (more) {
      final page = await api.pull(after);
      final held = await store.mirror();
      final waiting = await store.pending();
      final here = await local.readAll();
      for (final item in page.items) {
        final key = item.key;
        final old = held[key];
        if (waiting.containsKey(key)) {
          // An unsent edit is never overwritten. It goes out against its old
          // base, loses to this newer value, and the answer is applied then.
          await store.putMirror(key, item.value, item.revision);
          continue;
        }
        final mine = here[key];
        final localEdit =
            joined &&
            old != null &&
            old.value != null &&
            mine != null &&
            AccountSettingCodec.canonicalText(
                  await local.comparable(key, old.value),
                ) !=
                AccountSettingCodec.canonicalText(mine);
        if (localEdit) continue; // queued with its base on the next flush
        await store.putMirror(key, item.value, item.revision);
        if (await _differs(local, key, item.value, mine)) {
          if (await local.apply(key, item.value)) {
            changed.add(key);
            if (!joined && item.value != null) cameAlong.add(key);
          }
        }
      }
      if (page.lastRevision > after) {
        after = page.lastRevision;
        await store.savePullCursor(after);
        more = page.hasMore;
      } else {
        more = false;
      }
    }
    // Per-record keys whose record arrived after the key did.
    final held = await store.mirror();
    final waiting = await store.pending();
    final here = await local.readAll();
    for (final entry in held.entries) {
      if (!AccountSettingKeys.isEntityKey(entry.key) ||
          entry.value.value == null ||
          waiting.containsKey(entry.key) ||
          here.containsKey(entry.key)) {
        continue;
      }
      if (await local.apply(entry.key, entry.value.value)) {
        changed.add(entry.key);
        if (!joined) cameAlong.add(entry.key);
      }
    }
  }

  Future<bool> _differs(
    dynamic local,
    String key,
    Object? serverValue,
    Object? mine,
  ) async {
    if (serverValue == null) return true;
    final form = await local.comparable(key, serverValue);
    return AccountSettingCodec.canonicalText(form) !=
        AccountSettingCodec.canonicalText(mine);
  }

  static bool _refusedAsWhole(DioException error) {
    final status = error.response?.statusCode;
    return status == 400 || status == 413;
  }

  /// Sends the queue in batches. Returns the keys written into local stores
  /// because the account held a different value. When [seeding], the keys the
  /// account already held are added to [cameAlong].
  Future<Set<String>> _sendPending({
    required bool seeding,
    Set<String>? cameAlong,
  }) async {
    final applied = <String>{};
    while (true) {
      final waiting = await store.pending();
      if (waiting.isEmpty) return applied;
      final keys = waiting.keys.take(_batch).toList()..sort();
      final changes = [
        for (final key in keys)
          {
            'key': key,
            'value': waiting[key]!.value,
            'baseRevision': waiting[key]!.baseRevision,
            if (waiting[key]!.ifAbsent) 'ifAbsent': true,
          },
      ];
      List<AccountSettingPutResult> results;
      try {
        results = await api.put(changes);
      } on DioException catch (error) {
        if (!_refusedAsWhole(error)) rethrow;
        // The server refuses a whole PUT when one value is bad. Retry key by
        // key and drop only the key the server refuses; the others still go.
        results = [];
        for (final change in changes) {
          try {
            results.addAll(await api.put([change]));
          } on DioException catch (single) {
            if (!_refusedAsWhole(single)) rethrow;
            SafeDiagnostics.logSyncFailure(
              component: 'accountSettings',
              phase: SyncFailurePhase.stageRun,
              error: single,
            );
            // The local value stays and is not offered again until it, or the
            // account's value, changes.
            await store.markRefused(
              change['key']! as String,
              change['value'],
              (await store.mirror())[change['key']]?.revision ?? 0,
            );
            await store.clearPending([change['key']! as String]);
          }
        }
      }
      for (final result in results) {
        final sent = waiting[result.key];
        if (sent == null) continue;
        if (result.status == 'applied') {
          await store.putMirror(result.key, sent.value, result.revision);
          continue;
        }
        // kept or conflict: the account's value wins.
        await store.putMirror(
          result.key,
          result.hasCurrent ? result.currentValue : null,
          result.revision,
        );
        if (!result.hasCurrent) continue;
        final mine = (await store.local.readAll())[result.key];
        if (await _differs(
          store.local,
          result.key,
          result.currentValue,
          mine,
        )) {
          if (await store.local.apply(result.key, result.currentValue)) {
            applied.add(result.key);
            if (seeding) cameAlong?.add(result.key);
          }
        }
      }
      // A key the answer left out is dropped from the queue too, or the same
      // batch would be sent forever.
      await store.clearPending(keys);
    }
  }
}
