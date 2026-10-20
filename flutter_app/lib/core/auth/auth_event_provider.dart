import 'package:flutter_riverpod/legacy.dart';
import '../workspace/workspace_context.dart';

/// Auth lifecycle events emitted by the networking layer.
///
/// The API interceptor writes to this provider; the UI shell reacts by
/// navigating. This keeps routing logic out of the data layer entirely.
enum AuthEvent { none, sessionExpired }

final authEventProvider = StateProvider<AuthEvent>((ref) => AuthEvent.none);

final authFailureCapabilityProvider = StateProvider<NetworkCapability?>(
  (ref) => null,
);

/// True after the server ended the session (for example after a password
/// reset elsewhere). The sign-in step shows a persistent note until the person
/// tries to sign in again. The client cannot tell a reset from any other
/// revocation, so the note stays generic.
final signedOutNoticeProvider = StateProvider<bool>((ref) => false);
