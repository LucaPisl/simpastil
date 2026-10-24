import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/account/account_client.dart';
import '../../../core/account/account_data_wipe.dart';
import '../../../core/account/account_export_builder.dart';
import '../../../core/backup/backup_providers.dart';
import '../../../core/db/database.dart';
import '../../../core/storage/shared_preferences_provider.dart';
import '../../../core/sync/capabilities_client.dart';
import '../../../core/sync/ledger_mode_hint.dart';
import '../../../core/sync/sync_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../auth/auth_provider.dart';
import '../../profiles/profile_provider.dart';

/// Whether the server this device uses offers change email, export and delete.
/// Until it says so, none of them is shown.
final accountSelfServiceSupportedProvider = FutureProvider.autoDispose<bool>(
  (ref) => LedgerModeHint.readAccountSelfService(),
);

final emailChangeModeProvider = FutureProvider.autoDispose<EmailChangeMode>(
  (ref) => LedgerModeHint.readEmailChangeMode(),
);

/// The plain-language message for a failed account call.
String accountFailureMessage(AppLocalizations l, AccountCallFailure failure) {
  if (failure.isOffline) return l.acct_offline;
  if (failure.isRateLimited) return l.acct_tooManyTries;
  return switch (failure.code) {
    'AUTH_INVALID_CREDENTIALS' => l.acct_wrongPassword,
    'TOTP_REQUIRED' => l.acct_codeRequired,
    'TOTP_INVALID_CODE' => l.acct_wrongCode,
    'AUTH_EMAIL_TAKEN' => l.error_emailTaken,
    _ => l.shared_somethingWentWrong,
  };
}

class _SheetFrame extends StatelessWidget {
  const _SheetFrame({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 24,
          right: 24,
          top: 24,
          bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(title, style: text.titleMedium),
            ),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _PasswordField extends StatefulWidget {
  const _PasswordField({
    required this.controller,
    required this.enabled,
    this.errorText,
    this.onChanged,
    this.textInputAction,
    this.onSubmitted,
  });
  final TextEditingController controller;
  final bool enabled;
  final String? errorText;
  final VoidCallback? onChanged;
  final TextInputAction? textInputAction;
  final VoidCallback? onSubmitted;

  @override
  State<_PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<_PasswordField> {
  bool _visible = false;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return TextField(
      controller: widget.controller,
      enabled: widget.enabled,
      obscureText: !_visible,
      autofillHints: const [AutofillHints.password],
      textInputAction: widget.textInputAction,
      onChanged: (_) => widget.onChanged?.call(),
      onSubmitted: (_) => widget.onSubmitted?.call(),
      decoration: InputDecoration(
        labelText: l.settings_currentPassword,
        errorText: widget.errorText,
        suffixIcon: IconButton(
          tooltip: _visible ? l.auth_hidePassword : l.auth_showPassword,
          icon: Icon(_visible ? Icons.visibility_off : Icons.visibility),
          onPressed: () => setState(() => _visible = !_visible),
        ),
      ),
    );
  }
}

class _CodeField extends StatelessWidget {
  const _CodeField({
    required this.controller,
    required this.enabled,
    this.errorText,
    this.onChanged,
  });
  final TextEditingController controller;
  final bool enabled;
  final String? errorText;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return TextField(
      controller: controller,
      enabled: enabled,
      keyboardType: TextInputType.number,
      textInputAction: TextInputAction.done,
      autofillHints: const [AutofillHints.oneTimeCode],
      onChanged: (_) => onChanged?.call(),
      decoration: InputDecoration(
        labelText: l.acct_codeLabel,
        errorText: errorText,
      ),
    );
  }
}

/// How many changes were never sent to the server. Deleting the account
/// discards them, so the confirm step says so. Unknown counts as none.
final unsentChangesProvider = FutureProvider.autoDispose<int>(
  (ref) => ref
      .read(syncServiceProvider)
      .countPending()
      .timeout(const Duration(seconds: 2), onTimeout: () => 0)
      .catchError((_) => 0),
);

/// Reads the account summary once; the sheets need the email, the counts and
/// whether a verification code is asked for.
final accountSummaryProvider = FutureProvider.autoDispose<AccountSummary>(
  (ref) => ref.read(accountClientProvider).summary(),
);

// ── Change email ──────────────────────────────────────────────────────────

class ChangeEmailSheet extends ConsumerStatefulWidget {
  const ChangeEmailSheet({super.key});

  @override
  ConsumerState<ChangeEmailSheet> createState() => _ChangeEmailSheetState();
}

class _ChangeEmailSheetState extends ConsumerState<ChangeEmailSheet> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false;
  String? _emailError;
  String? _passwordError;
  String? _codeError;
  String? _failure;

  static final _emailShape = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit(AccountSummary? summary) async {
    final l = AppLocalizations.of(context);
    final email = _email.text.trim();
    final needsCode = summary?.twoFactorEnabled ?? false;
    setState(() {
      _failure = null;
      _emailError = _emailShape.hasMatch(email) ? null : l.acct_emailInvalid;
      _passwordError = _password.text.isEmpty
          ? l.settings_currentPasswordRequired
          : null;
      _codeError = needsCode && _code.text.trim().isEmpty
          ? l.acct_codeRequired
          : null;
    });
    if (_emailError != null || _passwordError != null || _codeError != null) {
      return;
    }
    setState(() => _busy = true);
    try {
      final outcome = await ref
          .read(accountClientProvider)
          .changeEmail(
            password: _password.text,
            newEmail: email,
            code: needsCode ? _code.text.trim() : null,
          );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      if (outcome == EmailChangeOutcome.changed) {
        final userId = ref.read(currentUserIdProvider);
        final db = ref.read(databaseProvider);
        await (db.update(db.users)..where((u) => u.id.equals(userId))).write(
          UsersCompanion(email: Value(email.toLowerCase())),
        );
        messenger.showSnackBar(
          SnackBar(content: Text(l.acct_emailChanged(email))),
        );
      } else {
        messenger.showSnackBar(SnackBar(content: Text(l.acct_changeEmailSent)));
      }
      ref.invalidate(accountSummaryProvider);
      if (mounted) Navigator.of(context).pop();
    } on AccountCallFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        switch (failure.code) {
          case 'AUTH_INVALID_CREDENTIALS':
            _passwordError = l.acct_wrongPassword;
          case 'TOTP_INVALID_CODE' || 'TOTP_REQUIRED':
            _codeError = failure.code == 'TOTP_REQUIRED'
                ? l.acct_codeRequired
                : l.acct_wrongCode;
          case 'AUTH_EMAIL_TAKEN':
            _emailError = l.error_emailTaken;
          default:
            _failure = accountFailureMessage(l, failure);
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final summary = ref.watch(accountSummaryProvider).value;
    final mode = ref.watch(emailChangeModeProvider).value;
    final immediate = mode == EmailChangeMode.immediate;
    final colors = Theme.of(context).colorScheme;
    return _SheetFrame(
      title: l.acct_changeEmailTitle,
      children: [
        Text(
          immediate
              ? l.acct_changeEmailImmediateNote
              : l.acct_changeEmailConfirmNote,
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _email,
          enabled: !_busy,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          autofillHints: const [AutofillHints.email],
          onChanged: (_) {
            if (_emailError != null) setState(() => _emailError = null);
          },
          decoration: InputDecoration(
            labelText: l.acct_newEmail,
            errorText: _emailError,
          ),
        ),
        const SizedBox(height: 12),
        _PasswordField(
          controller: _password,
          enabled: !_busy,
          errorText: _passwordError,
          textInputAction: summary?.twoFactorEnabled ?? false
              ? TextInputAction.next
              : TextInputAction.done,
          onChanged: () {
            if (_passwordError != null) setState(() => _passwordError = null);
          },
          onSubmitted: () => _submit(summary),
        ),
        if (summary?.twoFactorEnabled ?? false) ...[
          const SizedBox(height: 12),
          _CodeField(
            controller: _code,
            enabled: !_busy,
            errorText: _codeError,
            onChanged: () {
              if (_codeError != null) setState(() => _codeError = null);
            },
          ),
        ],
        if (_failure != null) ...[
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            child: Text(_failure!, style: TextStyle(color: colors.error)),
          ),
        ],
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            key: const ValueKey('change-email-submit'),
            onPressed: _busy ? null : () => _submit(summary),
            child: Text(
              immediate ? l.acct_changeEmailSave : l.acct_changeEmailSend,
            ),
          ),
        ),
      ],
    );
  }
}

// ── Export ────────────────────────────────────────────────────────────────

/// Downloads the account export, builds the zip and asks where to save it.
/// Returns the saved file's display name, or null when the person cancelled.
Future<String?> saveAccountExport(WidgetRef ref) async {
  final bytes = await ref.read(accountClientProvider).exportBytes();
  final zip = const AccountExportBuilder().buildZip(bytes);
  final files = ref.read(backupFileAccessProvider);
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final name =
      'simpastil-export-${now.year}-${two(now.month)}-${two(now.day)}.zip';
  final location = await files.chooseSave(name);
  if (location == null) return null;
  await files.write(location, zip);
  return location.displayName;
}

class ExportSheet extends ConsumerStatefulWidget {
  const ExportSheet({super.key});

  @override
  ConsumerState<ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends ConsumerState<ExportSheet> {
  bool _busy = false;
  String? _failure;
  String? _saved;

  Future<void> _save() async {
    final l = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _failure = null;
      _saved = null;
    });
    try {
      final name = await saveAccountExport(ref);
      if (mounted && name != null) setState(() => _saved = name);
    } on AccountCallFailure catch (failure) {
      if (mounted) {
        setState(() => _failure = accountFailureMessage(l, failure));
      }
    } on Object {
      if (mounted) setState(() => _failure = l.acct_exportFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    return _SheetFrame(
      title: l.acct_exportTitle,
      children: [
        Text(l.acct_exportBody),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.lock_open_outlined, size: 20, color: colors.onSurface),
            const SizedBox(width: 8),
            Expanded(child: Text(l.acct_exportWarning)),
          ],
        ),
        if (_saved != null) ...[
          const SizedBox(height: 12),
          Semantics(liveRegion: true, child: Text(l.acct_exportSaved(_saved!))),
        ],
        if (_failure != null) ...[
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            child: Text(_failure!, style: TextStyle(color: colors.error)),
          ),
        ],
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            key: const ValueKey('export-save'),
            onPressed: _busy ? null : _save,
            child: _busy
                ? Semantics(
                    label: l.acct_exportWorking,
                    child: const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : Text(l.acct_exportSave),
          ),
        ),
      ],
    );
  }
}

// ── Delete account ────────────────────────────────────────────────────────

class DeleteAccountSheet extends ConsumerStatefulWidget {
  const DeleteAccountSheet({super.key});

  @override
  ConsumerState<DeleteAccountSheet> createState() => _DeleteAccountSheetState();
}

class _DeleteAccountSheetState extends ConsumerState<DeleteAccountSheet> {
  final _password = TextEditingController();
  final _code = TextEditingController();
  bool _confirming = false;
  bool _busy = false;
  bool _exporting = false;
  bool _backedUp = false;
  String? _passwordError;
  String? _codeError;
  String? _failure;
  String? _exportNote;
  @override
  void dispose() {
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  /// Opens the Backups flow on top of this sheet, which makes a copy that can
  /// be restored. Going back from it returns to this same step, with the
  /// Continue button next to a note, so deleting never has to be found again.
  Future<void> _openBackups() async {
    final router = GoRouter.of(context);
    await router.push<void>('/backups');
    if (!mounted) return;
    setState(() => _backedUp = true);
  }

  Future<void> _exportFirst() async {
    final l = AppLocalizations.of(context);
    setState(() {
      _exporting = true;
      _exportNote = null;
    });
    try {
      final name = await saveAccountExport(ref);
      if (mounted && name != null) {
        setState(() => _exportNote = l.acct_exportSaved(name));
      }
    } on AccountCallFailure catch (failure) {
      if (mounted) {
        setState(() => _exportNote = accountFailureMessage(l, failure));
      }
    } on Object {
      if (mounted) setState(() => _exportNote = l.acct_exportFailed);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _delete(AccountSummary summary) async {
    final l = AppLocalizations.of(context);
    setState(() {
      _failure = null;
      _passwordError = _password.text.isEmpty
          ? l.settings_currentPasswordRequired
          : null;
      _codeError = summary.twoFactorEnabled && _code.text.trim().isEmpty
          ? l.acct_codeRequired
          : null;
    });
    if (_passwordError != null || _codeError != null) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final auth = ref.read(authNotifierProvider.notifier);
    final userId = ref.read(currentUserIdProvider);
    final db = ref.read(databaseProvider);
    final prefs = ref.read(sharedPreferencesProvider);
    try {
      await ref
          .read(accountClientProvider)
          .deleteAccount(
            password: _password.text,
            code: summary.twoFactorEnabled ? _code.text.trim() : null,
          );
    } on AccountCallFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        switch (failure.code) {
          case 'AUTH_INVALID_CREDENTIALS':
            _passwordError = l.acct_wrongPassword;
          case 'TOTP_INVALID_CODE':
            _codeError = l.acct_wrongCode;
          case 'TOTP_REQUIRED':
            _codeError = l.acct_codeRequired;
          default:
            _failure = accountFailureMessage(l, failure);
        }
      });
      return;
    } on Object {
      // Anything unexpected must not leave the button disabled for good.
      if (!mounted) return;
      setState(() {
        _busy = false;
        _failure = l.acct_deleteFailed;
      });
      return;
    }
    // The server no longer has the account; from here the phone only cleans up.
    try {
      await completeAccountDeletion(
        signOut: auth.logout,
        db: db,
        prefs: prefs,
        accountUserId: userId,
      );
    } on Object {
      // The account is gone from the server; failing to tidy this phone must
      // not strand the sheet in its busy state.
      if (mounted) setState(() => _busy = false);
    }
    messenger.showSnackBar(SnackBar(content: Text(l.acct_deleteDone)));
    router.go('/login');
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final summaryState = ref.watch(accountSummaryProvider);
    final summary = summaryState.value;
    return _SheetFrame(
      title: _confirming ? l.acct_deleteConfirmTitle : l.acct_deleteTitle,
      children: [
        if (!_confirming) ...[
          Text(l.acct_deleteBody),
          const SizedBox(height: 12),
          if (summary != null) ...[
            Text(
              l.acct_deleteHolds,
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 4),
            for (final line in [
              l.acct_countPeople(summary.people),
              l.acct_countMedications(summary.medications),
              l.acct_countRoutines(summary.routines),
              l.acct_countDoses(summary.doses),
              if (summary.devices > 0) l.acct_countDevices(summary.devices),
            ])
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(line),
              ),
          ] else if (summaryState.hasError) ...[
            Text(
              accountFailureMessage(
                l,
                summaryState.error is AccountCallFailure
                    ? summaryState.error! as AccountCallFailure
                    : const AccountCallFailure(statusCode: 500),
              ),
              style: TextStyle(color: colors.error),
            ),
          ] else
            const LinearProgressIndicator(),
          if (_exportNote != null) ...[
            const SizedBox(height: 12),
            Semantics(liveRegion: true, child: Text(_exportNote!)),
          ],
          const SizedBox(height: 20),
          Text(
            l.rva_deleteBackupHint,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const ValueKey('delete-backup-first'),
              onPressed: _openBackups,
              icon: const Icon(Icons.file_download_outlined),
              label: Text(l.rva_deleteBackupFirst),
            ),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              key: const ValueKey('delete-export-first'),
              onPressed: _exporting ? null : _exportFirst,
              child: Text(l.rva_deleteExportLink),
            ),
          ),
          if (_backedUp) ...[
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              child: Text(
                l.rvu_deleteBackFromBackups,
                key: const ValueKey('delete-back-from-backups'),
              ),
            ),
          ],
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              key: const ValueKey('delete-continue'),
              onPressed: summary == null
                  ? null
                  : () => setState(() => _confirming = true),
              child: Text(l.acct_deleteContinue),
            ),
          ),
        ] else if (summary != null) ...[
          Text(l.acct_deleteOthers),
          if ((ref.watch(unsentChangesProvider).value ?? 0) > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                l.acct_deleteUnsent(ref.watch(unsentChangesProvider).value!),
              ),
            ),
          const SizedBox(height: 16),
          _PasswordField(
            controller: _password,
            enabled: !_busy,
            errorText: _passwordError,
            textInputAction: summary.twoFactorEnabled
                ? TextInputAction.next
                : TextInputAction.done,
            onChanged: () {
              if (_passwordError != null) {
                setState(() => _passwordError = null);
              }
            },
            onSubmitted: () => _delete(summary),
          ),
          if (summary.twoFactorEnabled) ...[
            const SizedBox(height: 12),
            _CodeField(
              controller: _code,
              enabled: !_busy,
              errorText: _codeError,
              onChanged: () {
                if (_codeError != null) setState(() => _codeError = null);
              },
            ),
          ],
          if (_failure != null) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(_failure!, style: TextStyle(color: colors.error)),
            ),
          ],
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const ValueKey('delete-account-confirm'),
              style: FilledButton.styleFrom(
                backgroundColor: colors.error,
                foregroundColor: colors.onError,
              ),
              onPressed: _busy ? null : () => _delete(summary),
              child: Text(l.acct_deleteAction),
            ),
          ),
        ],
      ],
    );
  }
}
