import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'pinned_connection.dart';
import 'server_pin_store.dart';

/// The only place in `lib/` that constructs a `Dio` or an `HttpClient`
/// (`test/core/network/http_client_ban_test.dart` enforces it).

/// A client for the user's own Simpastil server: the API, token refresh,
/// sign-out, the health check and background sync.
///
/// Every connection it opens goes through [PinningConnector], so a pinned
/// server must present its pinned key before any request byte is written and
/// an unpinned server gets ordinary strict TLS. Proxies are not used.
///
/// [pins] defaults to the secure-storage pins every isolate can read.
/// [unpinnedContext] replaces the trust store for unpinned hosts; tests only.
Dio createServerDio({
  BaseOptions? options,
  ServerPinStore? pins,
  SecurityContext? unpinnedContext,
}) {
  final connector = PinningConnector(
    pins: pins,
    unpinnedContext: unpinnedContext,
  );
  final dio = Dio(options ?? BaseOptions());
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () => HttpClient()
      ..idleTimeout = const Duration(seconds: 3)
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = connector.connect,
  );
  return dio;
}

/// A client for a third-party service (the GitHub release check). It never
/// reads or applies server pins: ordinary strict TLS against the default trust
/// store.
Dio createNonPinningExternalDio({BaseOptions? options}) =>
    Dio(options ?? BaseOptions());
