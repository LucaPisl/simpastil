import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/api_client.dart';

import '../../../core/sync/auto_sync_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../auth/auth_provider.dart';

class ChangePasswordSheet extends ConsumerStatefulWidget {
  const ChangePasswordSheet({super.key});

  @override
  ConsumerState<ChangePasswordSheet> createState() =>
      _ChangePasswordSheetState();
}

class _ChangePasswordSheetState extends ConsumerState<ChangePasswordSheet> {
  final _formKey = GlobalKey<FormState>();
  final _currentPasswordController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _currentVisible = false;
  bool _newVisible = false;
  bool _confirmVisible = false;
  bool _loading = false;
  bool _submitted = false;
  String? _currentPasswordError;

  @override
  void dispose() {
    _currentPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  String? _validateCurrent(String? value, AppLocalizations l) {
    if (value == null || value.isEmpty) {
      return l.settings_currentPasswordRequired;
    }
    return null;
  }

  String? _validateNew(String? value, AppLocalizations l) {
    if (value == null || value.isEmpty) return l.settings_newPasswordRequired;
    if (value.length < 10) return l.settings_passwordMinLength;
    if (value == _currentPasswordController.text) {
      return l.settings_passwordMustDiffer;
    }
    return null;
  }

  String? _validateConfirm(String? value, AppLocalizations l) {
    if (value == null || value.isEmpty) {
      return l.settings_confirmPasswordRequired;
    }
    if (value != _newPasswordController.text) {
      return l.settings_passwordsDoNotMatch;
    }
    return null;
  }

  Future<void> _submit() async {
    setState(() {
      _submitted = true;
      _currentPasswordError = null;
    });
    if (!_formKey.currentState!.validate()) return;

    setState(() => _loading = true);
    try {
      await ref
          .read(apiClientProvider)
          .dio
          .post<void>(
            '/auth/change-password',
            data: {
              'currentPassword': _currentPasswordController.text,
              'newPassword': _newPasswordController.text,
            },
          );

      if (!mounted) return;
      Navigator.of(context).pop();
      // Server revokes all refresh tokens on password change. Log out
      // immediately so the user re-authenticates with the new password
      // instead of hitting a surprise session expiry later.
      ref.read(autoSyncServiceProvider).stop();
      await ref.read(authNotifierProvider.notifier).clearSession();
      if (mounted) context.go('/login');
    } on DioException catch (e) {
      if (!mounted) return;
      if (e.response?.statusCode == 400) {
        final errorData = e.response?.data;
        final msg = (errorData is Map && errorData['error'] is String)
            ? errorData['error'] as String
            : AppLocalizations.of(context).settings_currentPasswordIncorrect;
        setState(() => _currentPasswordError = msg);
        _formKey.currentState!.validate();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context).shared_somethingWentWrong,
            ),
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).shared_somethingWentWrong),
        ),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context);

    return FocusTraversalGroup(
      child: Padding(
        padding: EdgeInsets.only(
          left: 24,
          right: 24,
          top: 24,
          bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        ),
        child: Form(
          key: _formKey,
          autovalidateMode: _submitted
              ? AutovalidateMode.onUserInteraction
              : AutovalidateMode.disabled,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.settings_changePasswordTitle, style: text.titleMedium),
              const SizedBox(height: 20),

              // Current password
              TextFormField(
                controller: _currentPasswordController,
                obscureText: !_currentVisible,
                textInputAction: TextInputAction.next,
                enabled: !_loading,
                validator: (v) =>
                    _currentPasswordError ?? _validateCurrent(v, l),
                onChanged: (_) {
                  if (_currentPasswordError != null) {
                    setState(() => _currentPasswordError = null);
                  }
                },
                decoration: InputDecoration(
                  labelText: l.settings_currentPassword,
                  suffixIcon: IconButton(
                    icon: Icon(
                      _currentVisible ? Icons.visibility_off : Icons.visibility,
                      color: cs.onSurfaceVariant,
                    ),
                    onPressed: () =>
                        setState(() => _currentVisible = !_currentVisible),
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // New password
              TextFormField(
                controller: _newPasswordController,
                obscureText: !_newVisible,
                textInputAction: TextInputAction.next,
                enabled: !_loading,
                validator: (v) => _validateNew(v, l),
                decoration: InputDecoration(
                  labelText: l.settings_newPassword,
                  suffixIcon: IconButton(
                    icon: Icon(
                      _newVisible ? Icons.visibility_off : Icons.visibility,
                      color: cs.onSurfaceVariant,
                    ),
                    onPressed: () => setState(() => _newVisible = !_newVisible),
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // Confirm new password
              TextFormField(
                controller: _confirmPasswordController,
                obscureText: !_confirmVisible,
                textInputAction: TextInputAction.done,
                enabled: !_loading,
                onFieldSubmitted: (_) => _submit(),
                validator: (v) => _validateConfirm(v, l),
                decoration: InputDecoration(
                  labelText: l.settings_confirmNewPassword,
                  suffixIcon: IconButton(
                    icon: Icon(
                      _confirmVisible ? Icons.visibility_off : Icons.visibility,
                      color: cs.onSurfaceVariant,
                    ),
                    onPressed: () =>
                        setState(() => _confirmVisible = !_confirmVisible),
                  ),
                ),
              ),
              const SizedBox(height: 24),

              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _loading ? null : _submit,
                  child: _loading
                      ? SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator.adaptive(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation(cs.onPrimary),
                          ),
                        )
                      : Text(l.settings_updatePassword),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Two-Factor Authentication Sheet ─────────────────────────────────────────
