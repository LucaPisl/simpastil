import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import 'server_trust_flow.dart';
import 'server_trust_sync.dart';

/// Lets the person look at the certificate of a server whose connection was
/// refused, and decide whether to trust its key.
///
/// This is the same fingerprint check as the first connect. Nothing is trusted
/// unless the person confirms it. [syncAfter] asks for a sync once the server
/// is trusted, for the places where an account is signed in.
Future<ServerTrustResult> reviewServerCertificate(
  BuildContext context,
  WidgetRef ref,
  String url, {
  bool syncAfter = false,
}) async {
  final l = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final result = await ensureServerTrusted(context, ref, url);
  switch (result) {
    case ServerTrustResult.proceed:
      if (syncAfter) requestSyncAfterServerTrust(ref);
    case ServerTrustResult.unreachable:
      messenger?.showSnackBar(
        SnackBar(content: Text(l.auth_couldNotReachServerShort)),
      );
    case ServerTrustResult.unreadable:
      messenger?.showSnackBar(SnackBar(content: Text(l.pin_unreadable)));
    case ServerTrustResult.cancelled:
      break;
  }
  return result;
}
