import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pinned_connection.dart';
import 'server_pin_store.dart';

/// Where certificate pins are kept. Background isolates use the same store
/// through [defaultServerPinStore]; tests override this provider.
final serverPinStoreProvider = Provider<ServerPinStore>(
  (_) => defaultServerPinStore,
);

typedef ServerCertificateProber =
    Future<ServerCertificateProbe> Function(ServerAuthority authority);

/// Credential-free TLS handshake used before the first connection to a
/// server. Overridden in tests so no widget test touches the network.
final serverCertificateProbeProvider = Provider<ServerCertificateProber>(
  (_) =>
      (authority) => probeServerCertificate(authority),
);
