import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';

/// What the account holds, shown before anything is deleted.
class AccountSummary {
  const AccountSummary({
    required this.email,
    required this.twoFactorEnabled,
    required this.people,
    required this.medications,
    required this.routines,
    required this.doses,
    required this.devices,
  });

  final String email;
  final bool twoFactorEnabled;
  final int people;
  final int medications;
  final int routines;
  final int doses;
  final int devices;

  /// Reads the summary tolerantly: a missing count is zero, a missing email is
  /// empty. The body comes from our own server, but a newer server may add
  /// fields and an older one may lack some.
  factory AccountSummary.fromJson(Map<String, dynamic> json) {
    final counts = json['counts'];
    int count(String key) =>
        counts is Map && counts[key] is int ? counts[key] as int : 0;
    return AccountSummary(
      email: json['email'] is String ? json['email'] as String : '',
      twoFactorEnabled: json['twoFactorEnabled'] == true,
      people: count('people'),
      medications: count('medications'),
      routines: count('routines'),
      doses: count('doses'),
      devices: count('devices'),
    );
  }
}

/// How a change of email went. [confirmationSent] means the new address must
/// be confirmed from a link first; [changed] means it is already the address.
enum EmailChangeOutcome { confirmationSent, changed }

/// A failed account call, reduced to what the screens decide on.
class AccountCallFailure implements Exception {
  const AccountCallFailure({this.statusCode, this.code, this.retryAfter});

  final int? statusCode;

  /// The server's stable error code, when it sent one.
  final String? code;
  final int? retryAfter;

  bool get isOffline => statusCode == null;
  bool get isRateLimited => statusCode == 429;

  /// Reads both error shapes the server uses: `{error: {code}}` and
  /// `{error, code}`.
  factory AccountCallFailure.from(Object error) {
    if (error is! DioException) return const AccountCallFailure();
    final data = error.response?.data;
    String? code;
    if (data is Map) {
      final nested = data['error'];
      if (nested is Map && nested['code'] is String) {
        code = nested['code'] as String;
      } else if (data['code'] is String) {
        code = data['code'] as String;
      }
    }
    final retry = int.tryParse(
      error.response?.headers.value('retry-after') ?? '',
    );
    return AccountCallFailure(
      statusCode: error.response?.statusCode,
      code: code,
      retryAfter: retry,
    );
  }

  @override
  String toString() => 'AccountCallFailure($statusCode, $code)';
}

/// The account's own routes: summary, export, delete and change email. They
/// need the capability `accountSelfService`; the screens check it first.
class AccountClient {
  AccountClient(this._dio);

  final Dio _dio;

  Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on DioException catch (error) {
      throw AccountCallFailure.from(error);
    }
  }

  Future<AccountSummary> summary() => _guard(() async {
    final response = await _dio.get<Map<String, dynamic>>('/account/summary');
    final data = response.data;
    if (data == null) throw const AccountCallFailure(statusCode: 200);
    return AccountSummary.fromJson(data);
  });

  /// Downloads the whole export as bytes. It is only kept in memory long
  /// enough to build the zip; it never touches the cache or a temp file.
  Future<Uint8List> exportBytes() => _guard(() async {
    final response = await _dio.get<List<int>>(
      '/account/export',
      options: Options(
        responseType: ResponseType.bytes,
        receiveTimeout: const Duration(minutes: 5),
      ),
    );
    final data = response.data;
    if (data == null || data.isEmpty) {
      throw const AccountCallFailure(statusCode: 200);
    }
    return Uint8List.fromList(data);
  });

  Future<void> deleteAccount({required String password, String? code}) =>
      _guard(
        () => _dio.post<void>(
          '/account/delete',
          data: {'password': password, 'code': ?code},
        ),
      );

  Future<EmailChangeOutcome> changeEmail({
    required String password,
    required String newEmail,
    String? code,
  }) => _guard(() async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/auth/change-email',
      data: {'password': password, 'newEmail': newEmail, 'code': ?code},
    );
    return response.data?['status'] == 'changed'
        ? EmailChangeOutcome.changed
        : EmailChangeOutcome.confirmationSent;
  });
}

final accountClientProvider = Provider<AccountClient>(
  (ref) => AccountClient(ref.watch(apiClientProvider).dio),
);
