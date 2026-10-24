import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simpastil/core/db/database.dart';
import 'package:simpastil/core/settings/account_setting_codec.dart';
import 'package:simpastil/core/settings/account_settings_sync.dart';
import 'package:simpastil/core/settings/local_account_settings.dart';
import 'package:simpastil/core/settings/setting_scope_registry.dart';
import 'package:simpastil/core/settings/settings_store.dart';
import 'package:simpastil/core/storage/portable_preference_writer.dart';
import 'package:simpastil/core/storage/preference_keys.dart';
import 'package:simpastil/core/storage/recorded_by_preference.dart';
import 'package:simpastil/core/storage/appearance_preferences.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';

const _uid = 'user-1';

Map<String, Object?> _fixtures() =>
    jsonDecode(
          File(
            '../contracts/fixtures/account-settings-v1.json',
          ).readAsStringSync(),
        )
        as Map<String, Object?>;

/// An in-memory account: the server side of GET and PUT /account/settings.
class _Account {
  final values = <String, Object?>{};
  final revisions = <String, int>{};
  var head = 0;
  var puts = 0;

  /// A key the server refuses with 400, as it refuses a value it cannot hold.
  String? badKey;

  Dio dio() {
    final dio = Dio(BaseOptions(baseUrl: 'https://x.test'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.method == 'GET') {
            final after = options.queryParameters['afterRevision'] as int;
            final items =
                [
                  for (final k in revisions.keys)
                    if (revisions[k]! > after)
                      {
                        'key': k,
                        'value': values[k],
                        'revision': revisions[k],
                        'updatedAt': '2026-10-22T08:00:00.000Z',
                      },
                ]..sort(
                  (a, b) => (a['revision']! as int) - (b['revision']! as int),
                );
            return handler.resolve(
              Response(
                data: {'revision': head, 'hasMore': false, 'items': items},
                statusCode: 200,
                requestOptions: options,
              ),
            );
          }
          puts++;
          final changes = (options.data as Map)['changes'] as List;
          if (badKey != null &&
              changes.any((c) => (c as Map)['key'] == badKey)) {
            return handler.reject(
              DioException(
                requestOptions: options,
                response: Response(statusCode: 400, requestOptions: options),
                type: DioExceptionType.badResponse,
              ),
            );
          }
          final results = <Map<String, Object?>>[];
          for (final c in changes.cast<Map>()) {
            final key = c['key'] as String;
            final held = revisions.containsKey(key);
            Map<String, Object?> current() => {
              'value': values[key],
              'revision': revisions[key],
            };
            if (c['ifAbsent'] == true && held) {
              results.add({'key': key, 'status': 'kept', 'current': current()});
            } else if (held && c['baseRevision'] != revisions[key]) {
              results.add({
                'key': key,
                'status': 'conflict',
                'current': current(),
              });
            } else {
              values[key] = c['value'];
              revisions[key] = ++head;
              results.add({'key': key, 'status': 'applied', 'revision': head});
            }
          }
          handler.resolve(
            Response(
              data: {'results': results},
              statusCode: 200,
              requestOptions: options,
            ),
          );
        },
      ),
    );
    return dio;
  }
}

/// One phone: its own database and its own preferences.
class _Device {
  _Device(this.account, {this.older = false});
  final _Account account;
  final bool older;
  final db = AppDatabase.forTesting();
  Map<String, Object> prefs = {kCurrentUserIdKey: _uid};

  Future<T> _write<T>(Future<T> Function() a) => db.transaction(a);

  Future<void> use() async {
    SharedPreferences.setMockInitialValues(Map.of(prefs));
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    prefs = {for (final k in p.getKeys()) k: p.get(k)!};
  }

  SettingsStore get store => SettingsStore(
    db: db,
    userId: _uid,
    write: _write,
    local: LocalAccountSettings(db: db, userId: _uid, write: _write),
  );

  AccountSettingsSync get sync =>
      AccountSettingsSync(store: store, api: AccountSettingsApi(account.dio()));

  /// A flush then a pull, as the sync service runs them. An older server has no
  /// settings stage at all, so nothing runs.
  Future<void> syncOnce() async {
    await use();
    if (!older) {
      await sync.flush();
      await sync.pull();
    }
    await save();
  }

  Future<void> setPref(String key, Object value) async {
    await use();
    final p = await SharedPreferences.getInstance();
    if (value is int) await p.setInt(key, value);
    if (value is bool) await p.setBool(key, value);
    if (value is String) await p.setString(key, value);
    await save();
  }

  /// A value set through a settings control, as the screens write it.
  Future<void> choosePref(String key, Object? value) async {
    await use();
    final p = await SharedPreferences.getInstance();
    await PortablePreferenceWriter(p).write(key, value);
    await save();
  }

  Future<Map<String, Object?>> read() async {
    await use();
    return store.local.readAll();
  }

  Future<void> close() => db.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory root;
  setUpAll(() {
    root = Directory.systemTemp.createTempSync('account-settings-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('simpastil_storage'),
          (_) async => root.path,
        );
  });
  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('simpastil_storage'),
          null,
        );
    root.deleteSync(recursive: true);
  });

  group('contract fixture', () {
    test('every valid value parses and re-parses to itself', () {
      for (final v in (_fixtures()['valid']! as List).cast<Map>()) {
        final parsed = AccountSettingCodec.parse(
          v['key'] as String,
          v['value'],
        );
        expect(parsed.ok, isTrue, reason: v['name'] as String);
        final again = AccountSettingCodec.parse(
          v['key'] as String,
          parsed.value,
        );
        expect(
          AccountSettingCodec.canonicalText(again.value),
          AccountSettingCodec.canonicalText(parsed.value),
          reason: v['name'] as String,
        );
      }
    });

    test('every invalid value, unknown key and oversized value is refused', () {
      for (final v in (_fixtures()['invalid']! as List).cast<Map>()) {
        final parsed = AccountSettingCodec.parse(
          v['key'] as String,
          v['value'],
        );
        expect(parsed.ok, isFalse, reason: v['name'] as String);
      }
    });

    test('pages apply known items and ignore unknown or invalid ones', () {
      for (final p in (_fixtures()['pages']! as List).cast<Map>()) {
        final page = AccountSettingsPage.parse(p['page']);
        expect(
          {for (final i in page.items) i.key: i.value},
          {
            for (final e in (p['expectedApplied']! as Map).entries)
              e.key as String: e.value,
          },
          reason: p['name'] as String,
        );
        expect(page.ignored, p['expectedIgnored'], reason: p['name'] as String);
      }
    });

    test('every fixed key is declared in the scope registry as account', () {
      for (final key in AccountSettingKeys.fixed) {
        expect(SettingScopeRegistry.accountKeys, contains(key));
      }
    });
  });

  group('scope registry', () {
    test('declares each setting once', () {
      final ids = SettingScopeRegistry.all.map((d) => d.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('the widget keys and per-device switches stay on the device', () {
      for (final id in [
        'themeMode',
        'wallpaperColors',
        'asNeededInWidget',
        'autoMiss',
        'remindOnThisDevice',
        'appLock',
        'deviceName',
      ]) {
        expect(SettingScopeRegistry.isDeviceOnly(id), isTrue, reason: id);
      }
      expect(SettingScopeRegistry.isDeviceOnly('language'), isFalse);
    });

    test('an undeclared setting is an error, not a default', () {
      expect(() => SettingScopeRegistry.scopeOf('nope'), throwsA(anything));
    });
  });

  group('seeding', () {
    late _Account account;
    late _Device a;
    late _Device b;
    setUp(() {
      account = _Account();
      a = _Device(account);
      b = _Device(account);
    });
    tearDown(() async {
      await a.close();
      await b.close();
    });

    test(
      'the first device seeds an empty account with what it holds',
      () async {
        await a.setPref('snooze_duration_minutes_$_uid', 30);
        await a.syncOnce();
        expect(account.values[AccountSettingKeys.snoozeMinutes], 30);
        expect(
          account.values.containsKey(AccountSettingKeys.language),
          isFalse,
          reason: 'a default nobody chose is not seeded',
        );
        expect(await a.store.isJoined(), isTrue);
      },
    );

    test('a stored default is not a choice and is not seeded', () async {
      // Older builds and the Reminders page stored the defaults themselves.
      await a.setPref('snooze_duration_minutes_$_uid', 15);
      await a.setPref('sibling_detection_mode_$_uid', 'nameAndDosage');
      await a.setPref('prn_in_stats_$_uid', false);
      await a.syncOnce();
      expect(
        account.values.containsKey(AccountSettingKeys.snoozeMinutes),
        isFalse,
      );
      expect(
        account.values.containsKey(AccountSettingKeys.siblingDetection),
        isFalse,
      );
      expect(
        account.values.containsKey(AccountSettingKeys.asNeededInStats),
        isFalse,
      );
      // A customised device is not beaten by a defaults-only one.
      await b.setPref('snooze_duration_minutes_$_uid', 45);
      await b.syncOnce();
      await a.syncOnce();
      expect((await a.read())[AccountSettingKeys.snoozeMinutes], 45);
    });

    test('a changed value still seeds', () async {
      await a.setPref('snooze_duration_minutes_$_uid', 15);
      await a.setPref('sibling_detection_mode_$_uid', 'nameOnly');
      await a.syncOnce();
      expect(account.values[AccountSettingKeys.siblingDetection], 'nameOnly');
      expect(
        account.values.containsKey(AccountSettingKeys.snoozeMinutes),
        isFalse,
      );
    });

    test(
      'a later device keeps the account values and fills missing keys',
      () async {
        await a.setPref('snooze_duration_minutes_$_uid', 30);
        await a.syncOnce();
        account.values.remove(AccountSettingKeys.siblingDetection);
        account.revisions.remove(AccountSettingKeys.siblingDetection);

        await b.setPref('snooze_duration_minutes_$_uid', 5);
        await b.setPref('sibling_detection_mode_$_uid', 'perPill');
        await b.syncOnce();

        expect((await b.read())[AccountSettingKeys.snoozeMinutes], 30);
        expect(account.values[AccountSettingKeys.snoozeMinutes], 30);
        // The key the account never held is filled from the second device.
        expect(account.values[AccountSettingKeys.siblingDetection], 'perPill');
        await b.use();
        expect(await b.store.pendingNote(), contains('reminders'));
      },
    );

    test(
      'an untouched device first never overwrites a customised one',
      () async {
        await b.setPref('snooze_duration_minutes_$_uid', 45);
        await b.setPref('app_locale', 'ro');
        await a.syncOnce(); // all defaults, joins first
        expect(account.values, isEmpty);
        await b.syncOnce();
        final held = await b.read();
        expect(held[AccountSettingKeys.snoozeMinutes], 45);
        expect(held[AccountSettingKeys.language], 'ro');
        expect(account.values[AccountSettingKeys.snoozeMinutes], 45);
        expect(account.values[AccountSettingKeys.language], 'ro');
        await a.syncOnce();
        expect((await a.read())[AccountSettingKeys.snoozeMinutes], 45);
      },
    );

    test('a customised device first, an untouched one adopts it', () async {
      await a.setPref('snooze_duration_minutes_$_uid', 45);
      await a.syncOnce();
      await b.syncOnce();
      expect((await b.read())[AccountSettingKeys.snoozeMinutes], 45);
      expect(account.values[AccountSettingKeys.snoozeMinutes], 45);
    });

    test('a joined device never fills the account with its defaults', () async {
      await a.syncOnce();
      await a.syncOnce();
      expect(account.values, isEmpty);
    });

    test('two devices seeding at once leave one consistent account', () async {
      await a.setPref('snooze_duration_minutes_$_uid', 20);
      await b.setPref('snooze_duration_minutes_$_uid', 40);
      await a.syncOnce();
      await b.syncOnce();
      await a.syncOnce();
      final v = account.values[AccountSettingKeys.snoozeMinutes];
      expect(v, 20, reason: 'the first to arrive wins');
      expect((await a.read())[AccountSettingKeys.snoozeMinutes], v);
      expect((await b.read())[AccountSettingKeys.snoozeMinutes], v);
    });

    test('an older server queues nothing', () async {
      final old = _Device(account, older: true);
      await old.setPref('snooze_duration_minutes_$_uid', 30);
      await old.syncOnce();
      expect(account.puts, 0);
      await old.use();
      expect(await old.store.pending(), isEmpty);
      await old.close();
    });
  });

  group('a refused batch', () {
    test('drops only the key the server refuses', () async {
      final account = _Account();
      final a = _Device(account);
      addTearDown(a.close);
      await a.syncOnce(); // joins, nothing to seed
      account.badKey = AccountSettingKeys.siblingDetection;
      await a.setPref('snooze_duration_minutes_$_uid', 30);
      await a.setPref('sibling_detection_mode_$_uid', 'perPill');
      await a.syncOnce();
      expect(account.values[AccountSettingKeys.snoozeMinutes], 30);
      expect(
        account.values.containsKey(AccountSettingKeys.siblingDetection),
        isFalse,
      );
      await a.use();
      expect(await a.store.pending(), isEmpty);
      expect((await a.read())[AccountSettingKeys.siblingDetection], 'perPill');
    });
  });

  group('a refused setting', () {
    test('is not offered again on later syncs until it changes', () async {
      final account = _Account();
      final a = _Device(account);
      addTearDown(a.close);
      await a.syncOnce();
      account.badKey = AccountSettingKeys.siblingDetection;
      await a.setPref('sibling_detection_mode_$_uid', 'perPill');
      await a.syncOnce(); // refused once
      final afterFirst = account.puts;
      expect(afterFirst, greaterThan(0));
      for (var i = 0; i < 4; i++) {
        await a.syncOnce();
        await a.use();
        expect(await a.store.pending(), isEmpty);
      }
      expect(account.puts, afterFirst, reason: 'no retry on later cycles');
      // A different value is a new edit and is tried.
      await a.setPref('sibling_detection_mode_$_uid', 'nameOnly');
      await a.syncOnce();
      expect(account.puts, greaterThan(afterFirst));
    });

    test('stays held while other settings keep syncing', () async {
      final account = _Account();
      final a = _Device(account);
      final b = _Device(account);
      addTearDown(a.close);
      addTearDown(b.close);
      await a.syncOnce();
      await b.syncOnce();
      account.badKey = AccountSettingKeys.siblingDetection;
      await a.setPref('sibling_detection_mode_$_uid', 'perPill');
      await a.syncOnce();
      final putsBefore = account.puts;
      account.badKey = null;
      await b.setPref('snooze_duration_minutes_$_uid', 45);
      await b.syncOnce();
      await a.syncOnce();
      // The key's account state did not change, so the refusal still holds.
      expect(
        account.values.containsKey(AccountSettingKeys.siblingDetection),
        isFalse,
      );
      expect(account.puts, putsBefore + 1, reason: 'only b sent a setting');
    });
  });

  group('the refused memory', () {
    test('keeps a fingerprint, never the value', () async {
      final account = _Account();
      final a = _Device(account);
      addTearDown(a.close);
      await a.syncOnce();
      account.badKey = AccountSettingKeys.recordedBy;
      await a.setPref('recorded_by_mode_$_uid', 'custom');
      await a.setPref('recorded_by_name_$_uid', 'Fictional Carer');
      await a.syncOnce();
      final raw = a.prefs[accountSettingsRefusedPreferenceKey(_uid)]! as String;
      expect(raw, isNot(contains('Fictional')));
      await a.use();
      expect(
        (await a.store.refused())[AccountSettingKeys.recordedBy]?.fingerprint,
        hasLength(64),
      );
    });

    test('a refused value tried again after a stop at the account value is '
        'sent again', () async {
      final account = _Account();
      final a = _Device(account);
      addTearDown(a.close);
      await a.syncOnce();
      await a.setPref('sibling_detection_mode_$_uid', 'nameOnly');
      await a.syncOnce();
      expect(account.values[AccountSettingKeys.siblingDetection], 'nameOnly');

      account.badKey = AccountSettingKeys.siblingDetection;
      await a.setPref('sibling_detection_mode_$_uid', 'perPill'); // V
      await a.syncOnce(); // refused
      await a.setPref('sibling_detection_mode_$_uid', 'nameOnly'); // W
      await a.syncOnce();
      final before = account.puts;
      await a.setPref('sibling_detection_mode_$_uid', 'perPill'); // V again
      await a.syncOnce();
      expect(account.puts, greaterThan(before), reason: 'V is a new edit');
    });

    test('belongs to one account: another signed in here starts '
        'clean', () async {
      final account = _Account();
      final a = _Device(account);
      addTearDown(a.close);
      await a.syncOnce();
      account.badKey = AccountSettingKeys.siblingDetection;
      await a.setPref('sibling_detection_mode_$_uid', 'perPill');
      await a.syncOnce();
      await a.use();
      expect(await a.store.refused(), isNotEmpty);
      final other = SettingsStore(
        db: a.db,
        userId: 'user-2',
        write: a._write,
        local: LocalAccountSettings(
          db: a.db,
          userId: 'user-2',
          write: a._write,
        ),
      );
      expect(await other.refused(), isEmpty);
    });

    test('an older plain-text entry becomes a keyed fingerprint on the first '
        'read, and still holds', () async {
      final account = _Account();
      final a = _Device(account);
      addTearDown(a.close);
      await a.syncOnce();
      account.badKey = AccountSettingKeys.recordedBy;
      await a.setPref('recorded_by_mode_$_uid', 'custom');
      await a.setPref('recorded_by_name_$_uid', 'Fictional Carer');
      await a.syncOnce(); // refused, in the current format
      await a.use();
      final current = await a.store.refused();
      final revision = current[AccountSettingKeys.recordedBy]!.revision;
      // An older build kept the refused canonical text itself.
      await a.use();
      final canonical = AccountSettingCodec.canonicalText(
        (await a.store.local.readAll())[AccountSettingKeys.recordedBy],
      );
      expect(canonical, contains('Fictional'));
      await a.setPref(
        accountSettingsRefusedPreferenceKey(_uid),
        jsonEncode({
          AccountSettingKeys.recordedBy: {
            'value': canonical,
            'revision': revision,
          },
          'settings.unreadable': {'value': 3, 'revision': 0},
        }),
      );

      await a.use();
      final migrated = await a.store.refused();
      await a.save();
      expect(migrated.keys, [AccountSettingKeys.recordedBy]);
      expect(
        migrated[AccountSettingKeys.recordedBy]!.fingerprint,
        await a.store.refusalFingerprint(
          (await a.store.local.readAll())[AccountSettingKeys.recordedBy],
        ),
      );
      final raw = a.prefs[accountSettingsRefusedPreferenceKey(_uid)]! as String;
      expect(raw, isNot(contains('Fictional')));
      expect(raw, isNot(contains('settings.unreadable')));

      // The migrated refusal still holds: the same value is not resent.
      account.badKey = null;
      final before = account.puts;
      await a.syncOnce();
      expect(account.puts, before);
    });

    test('an unkeyed fingerprint or unreadable memory is dropped', () async {
      final account = _Account();
      final a = _Device(account);
      addTearDown(a.close);
      await a.setPref(
        accountSettingsRefusedPreferenceKey(_uid),
        jsonEncode({
          AccountSettingKeys.siblingDetection: {
            'fingerprint': 'a' * 64,
            'revision': 0,
          },
        }),
      );
      await a.use();
      expect(await a.store.refused(), isEmpty);
      await a.save();
      expect(
        a.prefs.containsKey(accountSettingsRefusedPreferenceKey(_uid)),
        isFalse,
      );

      await a.setPref(accountSettingsRefusedPreferenceKey(_uid), 'not json');
      await a.use();
      expect(await a.store.refused(), isEmpty);
      await a.save();
      expect(
        a.prefs.containsKey(accountSettingsRefusedPreferenceKey(_uid)),
        isFalse,
      );
    });

    test('fingerprints are keyed per account on this device', () async {
      final account = _Account();
      final a = _Device(account);
      addTearDown(a.close);
      await a.use();
      final mine = await a.store.refusalFingerprint('Fictional Carer');
      expect(mine, await a.store.refusalFingerprint('Fictional Carer'));
      expect(
        mine,
        isNot(
          sha256
              .convert(
                utf8.encode(
                  AccountSettingCodec.canonicalText('Fictional Carer'),
                ),
              )
              .toString(),
        ),
        reason: 'a plain hash could be matched against a list of names',
      );
      final other = SettingsStore(
        db: a.db,
        userId: 'user-2',
        write: a._write,
        local: LocalAccountSettings(
          db: a.db,
          userId: 'user-2',
          write: a._write,
        ),
      );
      expect(await other.refusalFingerprint('Fictional Carer'), isNot(mine));
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(accountSettingsRefusalKeyPreferenceKey(_uid)),
        isNotEmpty,
      );
    });
  });

  group('a default chosen on purpose', () {
    test('is sent when the account never held the key', () async {
      final account = _Account();
      final a = _Device(account);
      final b = _Device(account);
      addTearDown(a.close);
      addTearDown(b.close);
      await a.syncOnce();
      await b.syncOnce();
      await a.choosePref(
        'snooze_duration_minutes_$_uid',
        accountSnoozeDefaultMinutes,
      );
      await a.syncOnce();
      expect(
        account.values[AccountSettingKeys.snoozeMinutes],
        accountSnoozeDefaultMinutes,
      );
      // The other device now holds the account's value, so a customisation
      // there is an ordinary edit of it rather than a fill-in.
      await b.syncOnce();
      expect(
        (await b.read())[AccountSettingKeys.snoozeMinutes],
        accountSnoozeDefaultMinutes,
      );
      await b.setPref('snooze_duration_minutes_$_uid', 30);
      await b.syncOnce();
      expect(
        account.values[AccountSettingKeys.snoozeMinutes],
        30,
        reason: 'b edits the held value against its revision',
      );
    });

    test('a stored default nobody chose is still not sent', () async {
      final account = _Account();
      final a = _Device(account);
      addTearDown(a.close);
      await a.syncOnce();
      await a.setPref(
        'snooze_duration_minutes_$_uid',
        accountSnoozeDefaultMinutes,
      );
      await a.syncOnce();
      expect(account.values, isEmpty);
    });

    for (final (name, accountKey, prefKey, value) in [
      ('language', AccountSettingKeys.language, 'app_locale', null),
      (
        'sibling',
        AccountSettingKeys.siblingDetection,
        'sibling_detection_mode_$_uid',
        'nameAndDosage',
      ),
      (
        'as-needed',
        AccountSettingKeys.asNeededInStats,
        prnInStatsPreferenceKey(_uid),
        false,
      ),
      (
        'recorded-by',
        AccountSettingKeys.recordedBy,
        recordedByModePreferenceKey(_uid),
        RecordedByMode.primaryProfile.name,
      ),
    ]) {
      test('once refused, is not sent again ($name)', () async {
        final account = _Account();
        final a = _Device(account);
        addTearDown(a.close);
        await a.syncOnce();
        account.badKey = accountKey;
        await a.choosePref(prefKey, value);
        await a.use();
        expect(
          (await a.store.local.readExplicit()).containsKey(accountKey),
          isTrue,
          reason: 'the default was chosen on purpose',
        );
        final before = account.puts;
        await a.syncOnce();
        expect(account.puts, greaterThan(before), reason: 'sent and refused');
        await a.use();
        expect((await a.store.refused()).containsKey(accountKey), isTrue);
        final refusedAt = account.puts;
        account.badKey = null;
        await a.syncOnce();
        await a.syncOnce();
        expect(account.puts, refusedAt, reason: 'not resent');
        expect(account.values.containsKey(accountKey), isFalse);
      });
    }

    test('belongs to the account that chose it', () async {
      final account = _Account();
      final a = _Device(account);
      addTearDown(a.close);
      await a.choosePref('app_locale', null);
      await a.use();
      expect(
        (await a.store.local.readExplicit()).containsKey(
          AccountSettingKeys.language,
        ),
        isTrue,
      );
      // A second account signs in on the same phone: the language the first
      // chose is the phone's, not this account's choice.
      final other = LocalAccountSettings(
        db: a.db,
        userId: 'user-2',
        write: a._write,
      );
      expect(
        (await other.readExplicit()).containsKey(AccountSettingKeys.language),
        isFalse,
      );
    });

    test('is not remembered with nobody signed in', () async {
      final account = _Account();
      final a = _Device(account)..prefs = {};
      addTearDown(a.close);
      await a.choosePref('app_locale', null);
      expect(
        a.prefs.keys.where((k) => k.startsWith('chosen_setting')),
        isEmpty,
      );
    });
  });

  group('after joining', () {
    late _Account account;
    late _Device a;
    late _Device b;
    setUp(() async {
      account = _Account();
      a = _Device(account);
      b = _Device(account);
      await a.syncOnce();
      await b.syncOnce();
    });
    tearDown(() async {
      await a.close();
      await b.close();
    });

    test('an edit on one device reaches the other', () async {
      await a.setPref('snooze_duration_minutes_$_uid', 45);
      await a.syncOnce();
      await b.syncOnce();
      expect((await b.read())[AccountSettingKeys.snoozeMinutes], 45);
    });

    test('a pull does not overwrite a pending local edit', () async {
      await a.setPref('snooze_duration_minutes_$_uid', 45);
      await a.syncOnce();
      // B edits but has not synced; then A changes it again and B pulls first.
      await b.setPref('snooze_duration_minutes_$_uid', 90);
      await b.use();
      await b.store.queueLocalChanges();
      await a.setPref('snooze_duration_minutes_$_uid', 60);
      await a.syncOnce();
      await b.use();
      await b.sync.pull();
      await b.save();
      expect((await b.read())[AccountSettingKeys.snoozeMinutes], 90);
      expect(
        (await b.store.pending())[AccountSettingKeys.snoozeMinutes],
        isNotNull,
      );
    });

    test('a conflict leaves the server value on the losing device', () async {
      await b.setPref('snooze_duration_minutes_$_uid', 90);
      await b.use();
      await b.store.queueLocalChanges();
      await a.setPref('snooze_duration_minutes_$_uid', 60);
      await a.syncOnce();
      await b.syncOnce();
      expect(account.values[AccountSettingKeys.snoozeMinutes], 60);
      expect((await b.read())[AccountSettingKeys.snoozeMinutes], 60);
      await b.use();
      expect(await b.store.pending(), isEmpty);
    });

    test(
      'a restored backup is sent as normal edits, server-wins decides',
      () async {
        await a.setPref('snooze_duration_minutes_$_uid', 60);
        await a.syncOnce();
        await b.syncOnce();
        // The restore writes the allowlisted preference straight into the store.
        await b.setPref('snooze_duration_minutes_$_uid', 120);
        await b.use();
        await b.store.queueLocalChanges();
        final queued = (await b.store
            .pending())[AccountSettingKeys.snoozeMinutes]!;
        expect(queued.value, 120);
        expect(
          queued.baseRevision,
          (await b.store.mirror())[AccountSettingKeys.snoozeMinutes]!.revision,
        );
        // Someone else changed the account since: the backup loses.
        await a.setPref('snooze_duration_minutes_$_uid', 75);
        await a.syncOnce();
        await b.syncOnce();
        expect((await b.read())[AccountSettingKeys.snoozeMinutes], 75);
      },
    );
  });

  group('the refused memory and a session', () {
    SettingsStore storeWith(
      _Device device,
      Future<T> Function<T>(Future<T> Function() action) write,
    ) => SettingsStore(
      db: device.db,
      userId: _uid,
      write: write,
      local: LocalAccountSettings(db: device.db, userId: _uid, write: write),
    );

    test('two first fingerprints at once share one key', () async {
      final a = _Device(_Account());
      addTearDown(a.close);
      await a.use();
      final both = await Future.wait([
        a.store.refusalFingerprint('Fictional Carer'),
        a.store.refusalFingerprint('Fictional Carer'),
      ]);
      expect(both[0], both[1]);
      expect(await a.store.refusalFingerprint('Fictional Carer'), both[0]);
    });

    test('a refusal saved as the session ends is forgotten again', () async {
      final a = _Device(_Account());
      addTearDown(a.close);
      await a.use();
      final prefs = await SharedPreferences.getInstance();
      // The grant is rechecked after the write and the session has ended in
      // between: sign-out already forgot this account's refusals, and the
      // write has just saved one again.
      final ending = storeWith(a, <T>(action) async {
        await a.db.transaction(action);
        await prefs.reload();
        expect(
          prefs.containsKey(accountSettingsRefusedPreferenceKey(_uid)),
          isTrue,
        );
        throw const WorkspaceAccessFailure(
          WorkspaceAccessFailureCode.staleGrant,
        );
      });

      await expectLater(
        ending.markRefused(AccountSettingKeys.siblingDetection, 'perPill', 0),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
      await prefs.reload();
      expect(
        prefs.containsKey(accountSettingsRefusedPreferenceKey(_uid)),
        isFalse,
      );
      expect(
        prefs.containsKey(accountSettingsRefusalKeyPreferenceKey(_uid)),
        isFalse,
      );
    });

    test('a refusal after the session ended writes nothing', () async {
      final a = _Device(_Account());
      addTearDown(a.close);
      await a.use();
      final ended = storeWith(
        a,
        <T>(_) async => throw const WorkspaceAccessFailure(
          WorkspaceAccessFailureCode.staleGrant,
        ),
      );
      await expectLater(
        ended.markRefused(AccountSettingKeys.siblingDetection, 'perPill', 0),
        throwsA(isA<WorkspaceAccessFailure>()),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.containsKey(accountSettingsRefusedPreferenceKey(_uid)),
        isFalse,
      );
      expect(
        prefs.containsKey(accountSettingsRefusalKeyPreferenceKey(_uid)),
        isFalse,
      );
    });
  });

  group('device-wide choices and two accounts', () {
    const second = 'user-2';
    LocalAccountSettings localOf(_Device device, String userId) =>
        LocalAccountSettings(
          db: device.db,
          userId: userId,
          write: device._write,
        );

    Future<bool> explicit(_Device device, String userId, String key) async {
      await device.use();
      return (await localOf(device, userId).readExplicit()).containsKey(key);
    }

    test('a language one account chose is not another account\'s, even when '
        'it is not the default', () async {
      final a = _Device(_Account());
      addTearDown(a.close);
      await a.choosePref('app_locale', 'ro');
      expect(await explicit(a, _uid, AccountSettingKeys.language), isTrue);
      expect(await explicit(a, second, AccountSettingKeys.language), isFalse);
    });

    test('appearance one account chose is not another account\'s', () async {
      final a = _Device(_Account());
      addTearDown(a.close);
      await a.use();
      await AppearancePreferencesRepository(
        SharedAppearancePreferenceStorage(
          await SharedPreferences.getInstance(),
        ),
      ).save(AppearancePreferences(highContrast: true));
      await a.save();
      expect(
        await explicit(a, _uid, AccountSettingKeys.appearanceText),
        isTrue,
      );
      expect(
        await explicit(a, second, AccountSettingKeys.appearanceText),
        isFalse,
      );
    });

    test('a snooze one account chose stays that account\'s', () async {
      final a = _Device(_Account());
      addTearDown(a.close);
      await a.choosePref('snooze_duration_minutes_$_uid', 30);
      expect(await explicit(a, _uid, AccountSettingKeys.snoozeMinutes), isTrue);
      expect(
        await explicit(a, second, AccountSettingKeys.snoozeMinutes),
        isFalse,
      );
    });

    test('the account value applied here is not taken as the previous '
        'account\'s choice', () async {
      final a = _Device(_Account());
      addTearDown(a.close);
      await a.choosePref('app_locale', 'ro');
      // The second account signs in and its own language is applied.
      a.prefs[kCurrentUserIdKey] = second;
      await a.use();
      await PortablePreferenceWriter(
        await SharedPreferences.getInstance(),
        announce: false,
      ).write('app_locale', 'en');
      await a.save();
      expect(await explicit(a, _uid, AccountSettingKeys.language), isFalse);
    });

    test('a language chosen before sign-in is the choice of the account that '
        'signs in, even the default', () async {
      final a = _Device(_Account())..prefs = {};
      addTearDown(a.close);
      await a.choosePref('app_locale', null);
      expect(await explicit(a, _uid, AccountSettingKeys.language), isFalse);

      await a.use();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kCurrentUserIdKey, _uid);
      await claimSignedOutSettingChoices(prefs, _uid);
      await a.save();
      expect(await explicit(a, _uid, AccountSettingKeys.language), isTrue);

      // Adopted once: a later account does not take it too.
      await a.use();
      await claimSignedOutSettingChoices(
        await SharedPreferences.getInstance(),
        second,
      );
      await a.save();
      expect(await explicit(a, second, AccountSettingKeys.language), isFalse);
      expect(await explicit(a, _uid, AccountSettingKeys.language), isTrue);
    });

    test('a language an older build stored still counts on a one-account '
        'phone', () async {
      final a = _Device(_Account());
      addTearDown(a.close);
      await a.setPref('app_locale', 'ro');
      expect(await explicit(a, _uid, AccountSettingKeys.language), isTrue);
    });
  });
}
