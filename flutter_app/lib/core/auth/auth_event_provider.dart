import 'package:flutter_riverpod/flutter_riverpod.dart';
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
