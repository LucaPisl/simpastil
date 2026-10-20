import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/api_client.dart';
import '../../../core/network/pinned_connection.dart';
import '../../../core/sync/capabilities_client.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/router/app_router.dart';
import '../../../shared/widgets/capsule_mark.dart';
import '../../../shared/widgets/status_chip.dart';
import 'arrival.dart';
import 'server_key_changed_screen.dart';

class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  ConsumerState<ForgotPasswordScreen> createState() =>
      _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();

  bool _loading = false;
  bool _submitted = false;
  bool _done = false;

  /// The last request was stopped because the server's key changed. The
  /// key-changed screen may already be dismissed, so this is shown inline.
  bool _keyBlocked = false;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
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

  Future<void> _submit() async {
    setState(() {
      _submitted = true;
    });
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _loading = true;
      _keyBlocked = false;
    });
    var blockedByKey = false;
    try {
      await ref
          .read(apiClientProvider)
          .dio
          .post<void>(
            '/auth/forgot-password',
            data: {'email': _emailController.text.trim()},
          );
    } on DioException catch (error) {
      // Intentionally absorb — always show the same success message
      // regardless of server response (anti-enumeration). A changed server
      // key is not a server response: nothing was sent, so no success is
      // claimed; the key-changed screen explains why.
      blockedByKey = pinMismatchOf(error) != null;
    } catch (_) {
      // Absorb all errors.
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _keyBlocked = blockedByKey;
          _done = !blockedByKey;
        });
      }
    }
  }

  Future<void> _reviewServerKey() async {
    final outcome = await Navigator.of(context).push<ServerKeyOutcome>(
      MaterialPageRoute(builder: (_) => const ServerKeyChangedScreen()),
    );
    if (!mounted) return;
    if (outcome == ServerKeyOutcome.trustedNewKey ||
        outcome == ServerKeyOutcome.normalChecking) {
      setState(() => _keyBlocked = false);
    }
  }

  void _backToLogin() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppPaths.login);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context);
    // Until the server answers the form is shown, so a slow or unreachable
    // server never holds the screen back; only a definite "unavailable"
    // replaces it.
    final availability =
        ref.watch(emailResetAvailabilityProvider).value ??
        EmailResetAvailability.unknown;
    final unknownHint = availability == EmailResetAvailability.unknown
        ? l.auth_resetUnknownHint
        : null;

    return Scaffold(
      body: ArrivalBackdrop(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
            child: Column(
              children: [
                const CapsuleMark(size: 64),
                const SizedBox(height: 12),
                Text(l.appTitle, style: text.headlineMedium),
                const SizedBox(height: 4),
                Text(l.appSubtitle, style: text.bodySmall),
                const SizedBox(height: 32),

                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: availability == EmailResetAvailability.unavailable
                        ? _UnavailableCard(onBack: _backToLogin)
                        : _done
                        ? Column(
                            children: [
                              Icon(
                                Icons.mark_email_read_outlined,
                                size: 48,
                                color: cs.primary,
                              ),
                              const SizedBox(height: 16),
                              Text(l.auth_checkEmail, style: text.titleMedium),
                              const SizedBox(height: 8),
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: _bodyMaxWidth,
                                ),
                                child: Text(
                                  l.auth_resetLinkSent,
                                  style: text.bodySmall,
                                  textAlign: TextAlign.center,
                                ),
                              ),
                              if (unknownHint != null) ...[
                                const SizedBox(height: 8),
                                Text(
                                  unknownHint,
                                  style: text.bodySmall?.copyWith(
                                    color: cs.onSurfaceVariant,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ],
                              const SizedBox(height: 20),
                              TextButton(
                                onPressed: _backToLogin,
                                child: Text(l.auth_backToLogin),
                              ),
                            ],
                          )
                        : Form(
                            key: _formKey,
                            autovalidateMode: _submitted
                                ? AutovalidateMode.onUserInteraction
                                : AutovalidateMode.disabled,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  l.auth_resetPassword,
                                  style: text.titleMedium,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  l.auth_enterEmailForReset,
                                  style: text.bodySmall,
                                ),
                                if (unknownHint != null) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    unknownHint,
                                    key: const ValueKey('reset-unknown-hint'),
                                    style: text.bodySmall?.copyWith(
                                      color: cs.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 20),
                                if (_keyBlocked) ...[
                                  CalmNotice(
                                    key: const ValueKey('reset-key-blocked'),
                                    tone: StatusTone.attention,
                                    icon: Icons.gpp_maybe_outlined,
                                    live: true,
                                    text:
                                        '${l.pin_changedTitle}. '
                                        '${l.sync_errorKeyChanged}',
                                  ),
                                  Align(
                                    alignment: AlignmentDirectional.centerStart,
                                    child: TextButton(
                                      key: const ValueKey(
                                        'reset-review-server-key',
                                      ),
                                      onPressed: _reviewServerKey,
                                      child: Text(l.pin_reviewAction),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                ],

                                TextFormField(
                                  controller: _emailController,
                                  keyboardType: TextInputType.emailAddress,
                                  textInputAction: TextInputAction.done,
                                  autofillHints: const [AutofillHints.email],
                                  enabled: !_loading,
                                  onFieldSubmitted: (_) => _submit(),
                                  validator: _validateEmail,
                                  decoration: InputDecoration(
                                    labelText: l.auth_emailAddress,
                                  ),
                                ),
                                const SizedBox(height: 20),

                                SizedBox(
                                  width: double.infinity,
                                  child: FilledButton(
                                    onPressed: _loading ? null : _submit,
                                    child: _loading
                                        ? SizedBox(
                                            height: 20,
                                            width: 20,
                                            child:
                                                CircularProgressIndicator.adaptive(
                                                  strokeWidth: 2,
                                                  valueColor:
                                                      AlwaysStoppedAnimation(
                                                        cs.onPrimary,
                                                      ),
                                                ),
                                          )
                                        : Text(l.auth_sendResetLink),
                                  ),
                                ),
                                const SizedBox(height: 12),

                                Center(
                                  child: TextButton(
                                    onPressed: _backToLogin,
                                    child: Text(l.auth_backToLogin),
                                  ),
                                ),
                              ],
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The server cannot send reset emails: say so, and who can help, instead of
/// offering a form that could never deliver.
/// Keeps centred explanatory text readable on wide (tablet) cards.
const double _bodyMaxWidth = 520;

class _UnavailableCard extends StatelessWidget {
  const _UnavailableCard({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context);
    return Column(
      key: const ValueKey('reset-unavailable'),
      children: [
        Icon(Icons.link_rounded, size: 48, color: cs.primary),
        const SizedBox(height: 16),
        Text(
          l.auth_resetUnavailableTitle,
          style: text.titleMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _bodyMaxWidth),
          child: Text(
            l.auth_resetUnavailableBody,
            style: text.bodySmall,
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 20),
        TextButton(onPressed: onBack, child: Text(l.auth_backToLogin)),
      ],
    );
  }
}
