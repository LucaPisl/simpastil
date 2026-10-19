import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flutter/services.dart';

import '../../../core/errors/app_error_l10n.dart';
import '../../../core/errors/app_error.dart';
import '../../auth/auth_repository.dart';

import '../../../shared/widgets/drag_handle.dart';
import '../../../l10n/app_localizations.dart';

enum _TwoFactorStep { initial, setup, confirm, backupCodes, disable }

class TwoFactorSheet extends ConsumerStatefulWidget {
  const TwoFactorSheet({super.key});

  @override
  ConsumerState<TwoFactorSheet> createState() => _TwoFactorSheetState();
}

class _TwoFactorSheetState extends ConsumerState<TwoFactorSheet> {
  _TwoFactorStep _step = _TwoFactorStep.initial;
  bool _loading = false;
  String? _error;
  String? _secret;
  List<String>? _backupCodes;
  final _codeController = TextEditingController();

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _startSetup() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final repo = ref.read(authRepositoryProvider);
    final result = await repo.setup2fa();
    if (!mounted) return;
    switch (result) {
      case Ok(:final value):
        setState(() {
          _secret = value.secret;
          _step = _TwoFactorStep.setup;
          _loading = false;
        });
      case Err(:final error):
        setState(() {
          _error = localizedAppErrorMessage(
            AppLocalizations.of(context),
            error,
          );
          _loading = false;
        });
    }
  }

  Future<void> _confirmEnable() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      setState(
        () => _error = AppLocalizations.of(context).settings_2faCodeRequired,
      );
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final repo = ref.read(authRepositoryProvider);
    final result = await repo.enable2fa(code);
    if (!mounted) return;
    switch (result) {
      case Ok(:final value):
        setState(() {
          _backupCodes = value;
          _step = _TwoFactorStep.backupCodes;
          _loading = false;
        });
      case Err(:final error):
        setState(() {
          _error = localizedAppErrorMessage(
            AppLocalizations.of(context),
            error,
          );
          _loading = false;
        });
    }
  }

  Future<void> _disable() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      setState(
        () => _error = AppLocalizations.of(
          context,
        ).settings_2faCodeRequiredDisable,
      );
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final repo = ref.read(authRepositoryProvider);
    final result = await repo.disable2fa(code);
    if (!mounted) return;
    switch (result) {
      case Ok():
        if (mounted) Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context).settings_2faDisabled),
          ),
        );
      case Err(:final error):
        setState(() {
          _error = localizedAppErrorMessage(
            AppLocalizations.of(context),
            error,
          );
          _loading = false;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const DragHandle(),
              const SizedBox(height: 16),
              Text(
                l.settings_2faFlowTitle,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 24),
              switch (_step) {
                _TwoFactorStep.initial => _buildInitial(cs),
                _TwoFactorStep.setup => _buildSetup(cs),
                _TwoFactorStep.confirm => const SizedBox.shrink(),
                _TwoFactorStep.backupCodes => _buildBackupCodes(cs),
                _TwoFactorStep.disable => _buildDisable(cs),
              },
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInitial(ColorScheme cs) {
    final l = AppLocalizations.of(context);
    return Column(
      children: [
        Text(
          l.settings_2faDescription,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 24),
        if (_error != null) ...[
          Text(_error!, style: TextStyle(color: cs.error)),
          const SizedBox(height: 12),
        ],
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _loading ? null : _startSetup,
            icon: const Icon(Icons.security),
            label: _loading
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                  )
                : Text(l.settings_2faSetupButton),
          ),
        ),
      ],
    );
  }

  Widget _buildSetup(ColorScheme cs) {
    final l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l.settings_2faStep1Label,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        Text(
          l.settings_2faManualKeyLabel,
          style: Theme.of(context).textTheme.labelSmall,
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Expanded(
                child: SelectableText(
                  _secret ?? '',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy, size: 18),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: _secret ?? ''));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l.shared_copiedToClipboard)),
                  );
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Text(
          l.settings_2faStep2Label,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _codeController,
          keyboardType: TextInputType.number,
          maxLength: 6,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 24,
            letterSpacing: 4,
          ),
          decoration: InputDecoration(
            labelText: l.settings_2faCodeLabel,
            border: const OutlineInputBorder(),
            counterText: '',
            errorText: _error,
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _loading ? null : _confirmEnable,
            child: _loading
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                  )
                : Text(l.settings_2faVerifyButton),
          ),
        ),
      ],
    );
  }

  Widget _buildBackupCodes(ColorScheme cs) {
    final l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: cs.tertiaryContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(Icons.check_circle, color: cs.onTertiaryContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l.settings_2faSuccess,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: cs.onTertiaryContainer,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Text(
          l.settings_2faBackupCodesDescription,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            children: (_backupCodes ?? [])
                .map(
                  (code) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      code,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 16,
                        letterSpacing: 2,
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () {
                  final text = (_backupCodes ?? []).join('\n');
                  Clipboard.setData(ClipboardData(text: text));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l.settings_2faBackupCodesCopied)),
                  );
                },
                icon: const Icon(Icons.copy),
                label: Text(l.settings_2faBackupCodesCopyButton),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l.settings_2faBackupCodesDoneButton),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDisable(ColorScheme cs) {
    final l = AppLocalizations.of(context);
    return Column(
      children: [
        Text(
          l.settings_2faDisableDescription,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _codeController,
          keyboardType: TextInputType.number,
          maxLength: 8,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 24,
            letterSpacing: 4,
          ),
          decoration: InputDecoration(
            labelText: l.settings_2faDisableCodeLabel,
            border: const OutlineInputBorder(),
            counterText: '',
            errorText: _error,
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _loading ? null : _disable,
            style: FilledButton.styleFrom(
              backgroundColor: cs.error,
              foregroundColor: cs.onError,
            ),
            child: _loading
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                  )
                : Text(l.settings_2faDisableButton),
          ),
        ),
      ],
    );
  }
}
