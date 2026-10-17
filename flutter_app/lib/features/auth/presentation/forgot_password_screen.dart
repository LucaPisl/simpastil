import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/api_client.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/router/app_router.dart';

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

    setState(() => _loading = true);
    try {
      await ref
          .read(apiClientProvider)
          .dio
          .post<void>(
            '/auth/forgot-password',
            data: {'email': _emailController.text.trim()},
          );
    } on DioException catch (_) {
      // Intentionally absorb — always show the same success message
      // regardless of server response (anti-enumeration).
    } catch (_) {
      // Absorb all errors.
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _done = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context);

    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFE8F5E9), Color(0xFFE0F2F1), Color(0xFFFBE9E7)],
            stops: [0.0, 0.55, 1.0],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
            child: Column(
              children: [
                // Logo ring
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: cs.surface,
                    boxShadow: [
                      BoxShadow(
                        color: cs.primary.withValues(alpha: 0.22),
                        blurRadius: 20,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: const Center(
                    child: Text('💊', style: TextStyle(fontSize: 32)),
                  ),
                ),
                const SizedBox(height: 16),
                Text(l.appTitle, style: text.headlineMedium),
                const SizedBox(height: 4),
                Text(l.appSubtitle, style: text.bodySmall),
                const SizedBox(height: 32),

                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: _done
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
                              Text(
                                l.auth_resetLinkSent,
                                style: text.bodySmall,
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 20),
                              TextButton(
                                onPressed: () {
                                  if (context.canPop()) {
                                    context.pop();
                                  } else {
                                    context.go(AppPaths.login);
                                  }
                                },
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
                                const SizedBox(height: 20),

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
                                    onPressed: () {
                                      if (context.canPop()) {
                                        context.pop();
                                      } else {
                                        context.go(AppPaths.login);
                                      }
                                    },
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
