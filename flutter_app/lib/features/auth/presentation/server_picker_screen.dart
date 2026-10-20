import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/errors/app_error_l10n.dart';
import '../../../core/api/api_client.dart';
import '../../../core/auth/auth_event_provider.dart';
import '../../../core/auth/installation_key_repository.dart';
import '../../../core/auth/scoped_token_service.dart';
import '../../../core/network/pinned_connection.dart';
import '../../../core/network/server_pin_controller.dart';
import '../../../core/errors/app_error.dart';
import '../../../core/server/server_config_notifier.dart';
import '../../../core/workspace/workspace_context.dart';
import '../../../core/workspace/workspace_provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/motion/app_motion.dart';
import '../../../shared/router/app_router.dart';
import '../../../shared/widgets/capsule_mark.dart';
import '../../../shared/widgets/status_chip.dart';
import '../auth_provider.dart';
import 'arrival.dart';
import 'server_certificate_review.dart';
import 'server_key_changed_screen.dart';
import 'server_trust_flow.dart';

enum _Phase { url, apiKey, credentials, totp }

class ServerPickerScreen extends ConsumerStatefulWidget {
  const ServerPickerScreen({super.key});

  @override
  ConsumerState<ServerPickerScreen> createState() => _ServerPickerScreenState();
}

class _ServerPickerScreenState extends ConsumerState<ServerPickerScreen> {
  final _urlController = TextEditingController();
  _Phase _phase = _Phase.url;

  /// The phase drawn last frame, so a step change knows its direction.
  _Phase _shownPhase = _Phase.url;
  bool _isConnecting = false;
  String? _urlError;
  String? _confirmedHostname;
  int _phaseRequest = 0;

  // Credentials phase state
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _passwordVisible = false;
  bool _submitted = false;
  AppError? _loginError;

  // Phase 2 — API key
  final _apiKeyController = TextEditingController();
  String? _apiKeyError;

  /// The last key check was refused because the server's certificate does not
  /// validate and has not been trusted; the person can review it.
  bool _apiKeyCertRejected = false;

  /// The last key check was refused because the pinned server now presents
  /// another key; the key review is the one screen that can pin it again.
  bool _apiKeyKeyChanged = false;
  bool _isVerifyingKey = false;
  String _keyStatus = 'unclaimed'; // 'unclaimed' | 'owned'

  // Phase 4 — TOTP challenge
  final _totpController = TextEditingController();
  String? _totpError;

  /// The user's explicit Create account / Sign in choice; null = follow the
  /// verified key's status.
  bool? _signInOverride;

  bool get _isSignIn => _signInOverride ?? (_keyStatus == 'owned');

  @override
  void initState() {
    super.initState();
    final pin = ref.read(serverPinControllerProvider).value;
    _pinHadProblem =
        pin != null && (pin.hasMismatch || pin.certificateRejected);
    final stored = ref.read(serverConfigProvider);
    if (stored != null) {
      _urlController.text = stored;
    }
    // Restore the correct phase so returning users land on Phase 2 or 3
    // instead of having to re-enter the URL they already confirmed.
    WidgetsBinding.instance.addPostFrameCallback((_) => _restorePhase());
  }

  Future<void> _restorePhase() async {
    if (!mounted) return;
    final request = ++_phaseRequest;
    final serverUrl = ref.read(serverConfigProvider);
    if (serverUrl == null) return;
    final access = ref.read(workspaceAccessRepositoryProvider);
    final keys = ref.read(installationKeyRepositoryProvider);
    try {
      final scope = await access.captureInstallation(serverUrl);
      if (scope == null || !_ownsRequest(request)) return;
      final status = await keys.readVerifiedStatusFor(scope);
      if (!await _installationIsCurrent(request, scope)) return;
      setState(() {
        _confirmedHostname = Uri.parse(scope.endpoint).host;
        if (status == 'owned' || status == 'unclaimed') {
          _keyStatus = status!;
          _phase = _Phase.credentials;
        } else {
          _phase = _Phase.apiKey;
        }
      });
    } on Object {
      // A retained URL or legacy key alone cannot establish installation access.
    }
  }

  bool _ownsRequest(int request) => mounted && request == _phaseRequest;

  Future<bool> _installationIsCurrent(
    int request,
    InstallationCapability scope,
  ) async {
    if (!_ownsRequest(request) ||
        ref.read(serverConfigProvider) != scope.endpoint) {
      return false;
    }
    try {
      final current = await ref
          .read(workspaceAccessRepositoryProvider)
          .installationIsCurrent(scope);
      return current &&
          _ownsRequest(request) &&
          ref.read(serverConfigProvider) == scope.endpoint;
    } on Object {
      return false;
    }
  }

  void _showServerPhase() => setState(() {
    _phaseRequest++;
    _phase = _Phase.url;
    _isConnecting = false;
    _isVerifyingKey = false;
  });

  @override
  void dispose() {
    _urlController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _apiKeyController.dispose();
    _totpController.dispose();
    super.dispose();
  }

  bool get _isValidHttpsUrl {
    final text = _urlController.text.trim();
    return text.startsWith('https://') && text.length > 'https://'.length;
  }

  String? get _inlineUrlError {
    final text = _urlController.text.trim();
    if (text.isEmpty) return null;
    if (!text.startsWith('https://')) {
      return AppLocalizations.of(context).auth_serverMustUseHttps;
    }
    return null;
  }

  Future<void> _onConnect() async {
    final request = ++_phaseRequest;
    final url = _urlController.text.trim();
    final l = AppLocalizations.of(context);
    setState(() {
      _isConnecting = true;
      _urlError = null;
    });

    try {
      // Before anything is sent: read the server's key, and pin it or stop.
      final trust = await ensureServerTrusted(context, ref, url);
      if (!_ownsRequest(request)) return;
      switch (trust) {
        case ServerTrustResult.proceed:
          break;
        case ServerTrustResult.cancelled:
          return;
        case ServerTrustResult.unreachable:
          setState(() => _urlError = l.auth_couldNotReachServer);
          return;
        case ServerTrustResult.unreadable:
          setState(() => _urlError = l.pin_unreadable);
          return;
      }
      final healthCheck = ref.read(serverHealthCheckProvider);
      final ok = await healthCheck(url);
      if (!_ownsRequest(request)) return;

      if (ok) {
        await ref.read(serverConfigProvider.notifier).setUrl(url);
        if (!_ownsRequest(request)) return;
        final scope = await ref
            .read(workspaceAccessRepositoryProvider)
            .captureInstallation(url);
        if (scope == null || !await _installationIsCurrent(request, scope)) {
          return;
        }
        final uri = Uri.parse(scope.endpoint);
        setState(() {
          _confirmedHostname = uri.host;
          _phase = _Phase.apiKey;
        });
      } else {
        setState(() {
          _urlError = l.auth_couldNotReachServer;
        });
      }
    } catch (_) {
      if (!_ownsRequest(request)) return;
      setState(() {
        _urlError = AppLocalizations.of(context).auth_couldNotReachServer;
      });
    } finally {
      if (_ownsRequest(request)) setState(() => _isConnecting = false);
    }
  }

  Future<void> _onVerifyKey({bool retried = false}) async {
    final l = AppLocalizations.of(context);
    final rawKey = _apiKeyController.text.trim();
    if (rawKey.isEmpty) {
      setState(() => _apiKeyError = l.auth_pleaseEnterApiKey);
      return;
    }
    final request = ++_phaseRequest;
    InstallationCapability? scope;
    setState(() {
      _isVerifyingKey = true;
      _apiKeyError = null;
      _apiKeyCertRejected = false;
      _apiKeyKeyChanged = false;
    });

    try {
      final client = ref.read(apiClientProvider);
      scope = await client.scopedTokens?.installation;
      if (scope == null || !await _installationIsCurrent(request, scope)) {
        if (!_ownsRequest(request)) return;
        // The connection carries a scope the installation has moved past.
        // Rebuild it once and try again before saying anything; a second miss
        // is a real problem and is reported as one.
        ref.invalidate(connectionDeviceStateProvider);
        ref.invalidate(scopedTokenServiceProvider);
        ref.invalidate(apiClientProvider);
        if (!retried) {
          // Let the rebuilt connection learn its scope before the retry reads
          // it. The retry starts a request of its own and ends the spinner.
          await ref.read(connectionDeviceStateProvider.future);
          if (!_ownsRequest(request)) return;
          return await _onVerifyKey(retried: true);
        }
        setState(() => _apiKeyError = l.auth_connectionNotReady);
        return;
      }
      final verified = await client.verifyAndSaveInstallationKey(rawKey);
      if (!await _installationIsCurrent(request, verified.installation)) return;
      setState(() {
        _keyStatus = verified.status;
        _signInOverride = null;
        _loginError = null;
        _submitted = false;
        _phase = _Phase.credentials;
      });
    } on InstallationKeyRevoked {
      await _showKeyError(request, scope, l.auth_keyRevoked);
    } on FormatException {
      await _showKeyError(request, scope, l.auth_unexpectedServerResponse);
    } on DioException catch (e) {
      final keyChanged = pinMismatchOf(e) != null;
      final rejected = !keyChanged && isCertificateRejection(e);
      final msg = keyChanged
          ? l.sync_errorKeyChanged
          : e.response?.statusCode == 401
          ? l.auth_invalidApiKey
          : rejected
          ? l.auth_certificateNotTrusted
          : l.auth_couldNotReachServerShort;
      await _showKeyError(
        request,
        scope,
        msg,
        certificateRejected: rejected,
        keyChanged: keyChanged,
      );
    } catch (_) {
      await _showKeyError(request, scope, l.auth_unexpectedError);
    } finally {
      if (_ownsRequest(request)) setState(() => _isVerifyingKey = false);
    }
  }

  /// Opens the same fingerprint check as the first connect for a server whose
  /// certificate did not validate, then tries the key again once it is trusted.
  Future<void> _reviewCertificate() async {
    final url = ref.read(serverConfigProvider);
    if (url == null) return;
    final result = await reviewServerCertificate(context, ref, url);
    if (!mounted) return;
    if (result == ServerTrustResult.proceed) {
      setState(() {
        _apiKeyError = null;
        _apiKeyCertRejected = false;
        _apiKeyKeyChanged = false;
      });
      if (_apiKeyController.text.trim().isNotEmpty) await _onVerifyKey();
    }
  }

  /// The pinned server presented another key while the key was being checked.
  /// Once the person trusts the new key (or the server is back to normal), the
  /// check runs again with the key already typed in.
  Future<void> _reviewKeyChangeAtKeyStep() async {
    final outcome = await openServerKeyReview(context);
    if (!mounted) return;
    if (outcome == ServerKeyOutcome.trustedNewKey ||
        outcome == ServerKeyOutcome.normalChecking) {
      setState(() {
        _apiKeyError = null;
        _apiKeyKeyChanged = false;
      });
      if (_apiKeyController.text.trim().isNotEmpty) await _onVerifyKey();
    }
  }

  /// Same fingerprint check from the sign-in step. There is no account yet,
  /// so nothing syncs afterwards; the person just signs in again.
  Future<void> _reviewCertificateAtSignIn() async {
    final url = ref.read(serverConfigProvider);
    if (url == null) return;
    final result = await reviewServerCertificate(context, ref, url);
    if (!mounted) return;
    if (result == ServerTrustResult.proceed) {
      setState(() => _loginError = null);
    }
  }

  /// The pinned server presented another key. The review is the one screen
  /// that can pin it again; trusting it clears the error so sign-in can be
  /// tried again.
  Future<void> _reviewKeyChangeAtSignIn() async {
    final outcome = await openServerKeyReview(context);
    if (!mounted) return;
    if (outcome == ServerKeyOutcome.trustedNewKey ||
        outcome == ServerKeyOutcome.normalChecking) {
      setState(() => _loginError = null);
    }
  }

  Future<void> _showKeyError(
    int request,
    InstallationCapability? scope,
    String message, {
    bool certificateRejected = false,
    bool keyChanged = false,
  }) async {
    if (scope != null && await _installationIsCurrent(request, scope)) {
      setState(() {
        _apiKeyError = message;
        _apiKeyCertRejected = certificateRejected;
        _apiKeyKeyChanged = keyChanged;
      });
    }
  }

  String? _validateEmail(String? value) {
    final l = AppLocalizations.of(context);
    if (value == null || value.trim().isEmpty) {
      return l.auth_enterValidEmail;
    }
    final ok = RegExp(
      r'^[\w\.\-\+]+@[\w\-]+\.[a-zA-Z]{2,}$',
    ).hasMatch(value.trim());
    return ok ? null : l.auth_enterValidEmail;
  }

  String? _validatePassword(String? value) {
    final l = AppLocalizations.of(context);
    return (value == null || value.isEmpty) ? l.auth_passwordRequired : null;
  }

  String? _loginErrorMessage() {
    final err = _loginError;
    if (err == null) return null;
    final l = AppLocalizations.of(context);
    return switch (err) {
      UnauthorizedError() => l.auth_incorrectCredentials,
      RateLimitError() => l.auth_tooManyAttempts,
      NetworkError(serverKeyChanged: true) => l.sync_errorKeyChanged,
      NetworkError(certificateRejected: true) => l.auth_certificateNotTrusted,
      NetworkError() => l.auth_noConnection,
      ConflictError() when !_isSignIn => l.auth_emailAlreadyRegistered,
      ServerError(statusCode: 403) when _isSignIn =>
        l.auth_keyBelongsToDifferentAccount,
      ServerCodeError(:final userMessage) => userMessage,
      ConflictError() ||
      NotFoundError() ||
      ServerError() ||
      UnknownError() => l.shared_somethingWentWrong,
    };
  }

  Future<void> _onLogin() async {
    ref.read(signedOutNoticeProvider.notifier).state = false;
    setState(() {
      _submitted = true;
      _loginError = null;
    });
    if (!_formKey.currentState!.validate()) return;

    final result = await ref
        .read(authNotifierProvider.notifier)
        .login(_emailController.text.trim(), _passwordController.text);

    if (!mounted) return;
    if (result case Err(:final error)) {
      setState(() => _loginError = error);
    } else {
      final authState = ref.read(authNotifierProvider);
      if (authState is AuthRequires2fa) {
        setState(() {
          _phase = _Phase.totp;
          _totpError = null;
          _totpController.clear();
        });
      } else {
        TextInput.finishAutofillContext();
      }
    }
  }

  Future<void> _onVerifyTotp() async {
    final code = _totpController.text.trim();
    if (code.isEmpty) {
      setState(
        () => _totpError = AppLocalizations.of(context).auth_2faCodeRequired,
      );
      return;
    }
    setState(() => _totpError = null);

    final result = await ref
        .read(authNotifierProvider.notifier)
        .verify2fa(code);

    if (!mounted) return;
    if (result case Err(:final error)) {
      setState(
        () => _totpError = localizedAppErrorMessage(
          AppLocalizations.of(context),
          error,
        ),
      );
    }
  }

  Future<void> _onRegister() async {
    ref.read(signedOutNoticeProvider.notifier).state = false;
    setState(() {
      _submitted = true;
      _loginError = null;
    });
    if (!_formKey.currentState!.validate()) return;

    final result = await ref
        .read(authNotifierProvider.notifier)
        .register(_emailController.text.trim(), _passwordController.text);

    if (!mounted) return;
    if (result case Err(:final error)) {
      setState(() => _loginError = error);
    } else {
      TextInput.finishAutofillContext();
    }
  }

  /// The last settled pin state had a changed key or a refused certificate.
  bool _pinHadProblem = false;

  /// A key change or refused certificate was resolved somewhere else (the key
  /// review reached from forgot-password, the sync screen...): the error shown
  /// here is about a problem that is gone.
  void _forgetResolvedPinError(AsyncValue<ServerPinState> next) {
    final settled = next.value;
    if (next.isLoading || settled == null) return;
    final hasProblem = settled.hasMismatch || settled.certificateRejected;
    final resolved = _pinHadProblem && !hasProblem;
    _pinHadProblem = hasProblem;
    if (!resolved || !mounted) return;
    final loginIsPin = switch (_loginError) {
      NetworkError(:final serverKeyChanged, :final certificateRejected) =>
        serverKeyChanged || certificateRejected,
      _ => false,
    };
    if (!loginIsPin && !_apiKeyKeyChanged && !_apiKeyCertRejected) return;
    setState(() {
      if (loginIsPin) _loginError = null;
      if (_apiKeyKeyChanged || _apiKeyCertRejected) {
        _apiKeyError = null;
        _apiKeyKeyChanged = false;
        _apiKeyCertRejected = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<ServerPinState>>(
      serverPinControllerProvider,
      (_, next) => _forgetResolvedPinError(next),
    );
    ref.listen<AuthState>(authNotifierProvider, (_, next) {
      if (next is AuthAuthenticated && mounted) {
        _phaseRequest++;
        context.go(
          next.requiresOriginReview
              ? AppPaths.originReview
              : AppPaths.deviceName,
        );
      }
    });

    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final isLoading = ref.watch(authNotifierProvider) is AuthLoading;
    final previousPhase = _shownPhase;
    WidgetsBinding.instance.addPostFrameCallback((_) => _shownPhase = _phase);

    final l = AppLocalizations.of(context);
    final step = switch (_phase) {
      _Phase.url => l.auth_stepServer,
      _Phase.apiKey => l.auth_stepApiKey,
      _Phase.credentials => l.auth_stepAccount,
      _Phase.totp => l.auth_stepVerification,
    };

    return Scaffold(
      body: ArrivalBackdrop(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
            child: Column(
              children: [
                const CapsuleMark(size: 64),
                const SizedBox(height: 12),
                Text('Simpastil', style: text.headlineMedium),
                const SizedBox(height: 4),
                Text(l.auth_tagline, style: text.bodySmall),
                const SizedBox(height: 28),
                ConnectionPath(
                  reached: switch (_phase) {
                    _Phase.url => 0,
                    _Phase.apiKey => 1,
                    _Phase.credentials || _Phase.totp => 2,
                  },
                ),
                const SizedBox(height: 8),
                // Fade through: the old caption clears before the new one
                // appears, so the two never read as one garbled line.
                AnimatedSwitcher(
                  duration: AppMotion.duration(context, milliseconds: 360),
                  switchInCurve: const Interval(.5, 1),
                  switchOutCurve: const Interval(.5, 1),
                  child: Text(
                    step,
                    key: ValueKey(step),
                    textAlign: TextAlign.center,
                    style: text.labelSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                ArrivalStepSwitcher(
                  step: _phase,
                  forward: _phase.index >= previousPhase.index,
                  child: FocusTraversalGroup(
                    child: switch (_phase) {
                      _Phase.url => _buildUrlPhase(cs, text),
                      _Phase.apiKey => _buildApiKeyPhase(cs, text),
                      _Phase.credentials => _buildCredentialsPhase(
                        cs,
                        text,
                        isLoading,
                      ),
                      _Phase.totp => _buildTotpPhase(cs, text, isLoading),
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildUrlPhase(ColorScheme cs, TextTheme text) {
    final l = AppLocalizations.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.auth_connectToServer, style: text.titleMedium),
            const SizedBox(height: 2),
            Text(l.auth_enterServerAddress, style: text.bodySmall),
            const SizedBox(height: 20),
            Text(
              l.auth_serverAddressLabel,
              style: text.labelSmall?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
            const SizedBox(height: 4),
            ValueListenableBuilder(
              valueListenable: _urlController,
              builder: (_, _, _) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextFormField(
                      controller: _urlController,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.go,
                      enabled: !_isConnecting,
                      onFieldSubmitted: (_) {
                        if (_isValidHttpsUrl) _onConnect();
                      },
                      decoration: InputDecoration(
                        labelText: l.auth_serverAddress,
                        hintText: 'https://…',
                        hintStyle: const TextStyle(fontFamily: 'monospace'),
                        errorText: _inlineUrlError,
                      ),
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                    if (_urlError != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _urlError!,
                        style: text.bodySmall?.copyWith(color: cs.error),
                      ),
                    ],
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: (_isValidHttpsUrl && !_isConnecting)
                            ? _onConnect
                            : null,
                        child: _isConnecting
                            ? SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator.adaptive(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation(
                                    cs.onPrimary,
                                  ),
                                ),
                              )
                            : Text(l.auth_connect),
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildApiKeyPhase(ColorScheme cs, TextTheme text) {
    final l = AppLocalizations.of(context);
    return Column(
      children: [
        // Server badge
        Container(
          decoration: BoxDecoration(
            color: cs.primaryContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  l.auth_connectedTo(_confirmedHostname ?? ''),
                  style: text.labelSmall?.copyWith(
                    color: cs.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              TextButton(
                onPressed: _showServerPhase,
                child: Text(l.shared_change),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.auth_enterApiKey, style: text.titleMedium),
                const SizedBox(height: 2),
                Text(l.auth_apiKeyHint, style: text.bodySmall),
                const SizedBox(height: 20),
                TextField(
                  controller: _apiKeyController,
                  keyboardType: TextInputType.visiblePassword,
                  textInputAction: TextInputAction.go,
                  onSubmitted: (_) => _onVerifyKey(),
                  decoration: InputDecoration(
                    labelText: l.auth_apiKeyLabel,
                    border: const OutlineInputBorder(),
                    errorText: _apiKeyError,
                  ),
                  obscureText: true,
                ),
                if (_apiKeyCertRejected || _apiKeyKeyChanged)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton(
                      key: const ValueKey('auth-review-server-key'),
                      onPressed: _isVerifyingKey
                          ? null
                          : _apiKeyKeyChanged
                          ? _reviewKeyChangeAtKeyStep
                          : _reviewCertificate,
                      child: Text(l.pin_reviewAction),
                    ),
                  ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _isVerifyingKey ? null : _onVerifyKey,
                    child: _isVerifyingKey
                        ? SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator.adaptive(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation(cs.onPrimary),
                            ),
                          )
                        : Text(l.auth_verifyKey),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCredentialsPhase(
    ColorScheme cs,
    TextTheme text,
    bool isLoading,
  ) {
    final l = AppLocalizations.of(context);
    final isNewAccount = !_isSignIn;

    return Column(
      children: [
        // ── Server badge ─────────────────────────────────────────────────
        Container(
          decoration: BoxDecoration(
            color: cs.primaryContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  l.auth_connectedTo(_confirmedHostname ?? ''),
                  style: text.labelSmall?.copyWith(
                    color: cs.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              TextButton(
                onPressed: isLoading ? null : _showServerPhase,
                child: Text(l.shared_change),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (ref.watch(signedOutNoticeProvider)) ...[
          CalmNotice(
            key: const ValueKey('auth-signed-out-notice'),
            text: l.auth_signedOutNotice,
            live: true,
          ),
          const SizedBox(height: 16),
        ],

        // ── Sign in / Create account card ────────────────────────────────
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: AutofillGroup(
              onDisposeAction: AutofillContextAction.cancel,
              child: Form(
                key: _formKey,
                autovalidateMode: _submitted
                    ? AutovalidateMode.onUserInteraction
                    : AutovalidateMode.disabled,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SegmentedButton<bool>(
                      showSelectedIcon: false,
                      segments: [
                        ButtonSegment(
                          value: false,
                          label: Text(l.auth_createAccount),
                        ),
                        ButtonSegment(value: true, label: Text(l.auth_signIn)),
                      ],
                      selected: {_isSignIn},
                      onSelectionChanged: isLoading
                          ? null
                          : (selection) => setState(() {
                              _signInOverride = selection.first;
                              _loginError = null;
                              _submitted = false;
                            }),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      isNewAccount
                          ? l.auth_choosePassword
                          : l.auth_useCredentials,
                      style: text.bodySmall,
                    ),
                    const SizedBox(height: 20),
                    TextFormField(
                      key: const ValueKey('auth-email'),
                      controller: _emailController,
                      autocorrect: false,
                      enableSuggestions: false,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      enabled: !isLoading,
                      validator: _validateEmail,
                      autofillHints: isNewAccount
                          ? const [
                              AutofillHints.newUsername,
                              AutofillHints.email,
                            ]
                          : const [AutofillHints.username, AutofillHints.email],
                      decoration: InputDecoration(
                        labelText: l.auth_emailAddress,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      key: const ValueKey('auth-password'),
                      controller: _passwordController,
                      autocorrect: false,
                      enableSuggestions: false,
                      obscureText: !_passwordVisible,
                      textInputAction: TextInputAction.done,
                      enabled: !isLoading,
                      onFieldSubmitted: (_) =>
                          isNewAccount ? _onRegister() : _onLogin(),
                      validator: _validatePassword,
                      autofillHints: isNewAccount
                          ? const [AutofillHints.newPassword]
                          : const [AutofillHints.password],
                      decoration: InputDecoration(
                        labelText: l.auth_password,
                        suffixIcon: IconButton(
                          tooltip: _passwordVisible
                              ? l.auth_hidePassword
                              : l.auth_showPassword,
                          icon: Icon(
                            _passwordVisible
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                          ),
                          onPressed: () => setState(
                            () => _passwordVisible = !_passwordVisible,
                          ),
                        ),
                      ),
                    ),
                    if (_loginErrorMessage() case final msg?) ...[
                      const SizedBox(height: 8),
                      Text(
                        msg,
                        style: text.bodySmall?.copyWith(color: cs.error),
                      ),
                      if (_loginError case NetworkError(
                        certificateRejected: final rejected,
                        serverKeyChanged: final keyChanged,
                      ) when rejected || keyChanged)
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: TextButton(
                            key: const ValueKey('auth-login-review-server-key'),
                            onPressed: isLoading
                                ? null
                                : keyChanged
                                ? _reviewKeyChangeAtSignIn
                                : _reviewCertificateAtSignIn,
                            child: Text(l.pin_reviewAction),
                          ),
                        ),
                    ],
                    if (!isNewAccount)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () =>
                              context.push(AppPaths.forgotPassword),
                          child: Text(l.auth_forgotPassword),
                        ),
                      ),
                    const SizedBox(height: 4),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: isLoading
                            ? null
                            : (isNewAccount ? _onRegister : _onLogin),
                        child: isLoading
                            ? SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator.adaptive(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation(
                                    cs.onPrimary,
                                  ),
                                ),
                              )
                            : (isNewAccount
                                  ? Text(l.auth_createAccountButton)
                                  : Text(l.auth_logInButton)),
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: isLoading
              ? null
              : () => setState(() {
                  _phaseRequest++;
                  _phase = _Phase.apiKey;
                  _isVerifyingKey = false;
                  _apiKeyError = null;
                  _apiKeyCertRejected = false;
                  _apiKeyKeyChanged = false;
                  _signInOverride = null;
                  _loginError = null;
                }),
          child: Text(l.auth_useDifferentKey),
        ),
      ],
    );
  }

  Widget _buildTotpPhase(ColorScheme cs, TextTheme text, bool isLoading) {
    final l = AppLocalizations.of(context);
    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            color: cs.primaryContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.verified_user, size: 16, color: cs.onPrimaryContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l.auth_2faStepLabel,
                  style: text.labelSmall?.copyWith(
                    color: cs.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.auth_2faEnterCodeTitle, style: text.titleMedium),
                const SizedBox(height: 4),
                Text(l.auth_2faCodeDescription, style: text.bodySmall),
                const SizedBox(height: 20),
                TextField(
                  controller: _totpController,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.go,
                  autofocus: true,
                  maxLength: 8,
                  onSubmitted: (_) => _onVerifyTotp(),
                  decoration: InputDecoration(
                    labelText: l.auth_2faCodeLabel,
                    border: const OutlineInputBorder(),
                    errorText: _totpError,
                    counterText: '',
                  ),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 24,
                    letterSpacing: 4,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: isLoading ? null : _onVerifyTotp,
                    child: isLoading
                        ? SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator.adaptive(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation(cs.onPrimary),
                            ),
                          )
                        : Text(l.auth_2faVerifyButton),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
