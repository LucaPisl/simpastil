import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/layouts/window_size.dart';
import '../../auth/auth_provider.dart';
import 'account_self_service_sheets.dart';
import 'change_password_sheet.dart';
import 'settings_overview.dart';
import 'settings_pane.dart';
import 'two_factor_sheet.dart';

/// The account's own actions as two groups: the everyday ones (password,
/// two-step sign-in, email, export) and, set apart below them, Delete account.
/// The phone's overview shows these groups; a wider window opens them in a
/// pane through [AccountActionsSection].
///
/// Change email, Export and Delete appear only against a server that offers
/// them.
class AccountActionsGroups extends ConsumerWidget {
  const AccountActionsGroups({super.key, this.index});

  /// The place of the first group in the overview's entrance, if it has one.
  final int? index;

  void _sheet(BuildContext context, WidgetBuilder builder) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: builder,
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final selfService =
        ref.watch(accountSelfServiceSupportedProvider).value ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsGroup(
          key: const ValueKey('account-group'),
          label: l.settings_account,
          index: index,
          identity: index == null ? null : 'settings-account',
          children: [
            SettingsNavigationRow(
              key: const ValueKey('change-password'),
              icon: Icons.key_outlined,
              title: l.settings_changePassword,
              subtitle: l.rva_changePasswordSubtitle,
              onTap: () =>
                  _sheet(context, (ctx) => const ChangePasswordSheet()),
            ),
            SettingsNavigationRow(
              key: const ValueKey('two-factor'),
              icon: Icons.security,
              title: l.settings_2faTitle,
              subtitle: l.settings_2faSubtitle,
              onTap: () => _sheet(context, (ctx) => const TwoFactorSheet()),
            ),
            if (selfService) ...[
              SettingsNavigationRow(
                key: const ValueKey('change-email'),
                icon: Icons.alternate_email,
                title: l.acct_changeEmail,
                subtitle: l.acct_changeEmailSubtitle,
                onTap: () => _sheet(context, (ctx) => const ChangeEmailSheet()),
              ),
              SettingsNavigationRow(
                key: const ValueKey('export-data'),
                icon: Icons.download_outlined,
                title: l.acct_exportData,
                subtitle: l.acct_exportDataSubtitle,
                onTap: () => _sheet(context, (ctx) => const ExportSheet()),
              ),
            ],
          ],
        ),
        if (selfService)
          SettingsGroup(
            key: const ValueKey('delete-group'),
            label: '',
            children: [
              SettingsNavigationRow(
                key: const ValueKey('delete-account'),
                icon: Icons.delete_outline,
                title: l.acct_deleteAccount,
                subtitle: l.acct_deleteAccountSubtitle,
                destructive: true,
                onTap: () =>
                    _sheet(context, (ctx) => const DeleteAccountSheet()),
              ),
            ],
          ),
      ],
    );
  }
}

/// The Account page of a wide window's Settings: the groups of
/// [AccountActionsGroups] in the pane. A sign-in still being checked shows a
/// neutral wait, and a signed-out device nothing to act on.
class AccountActionsSection extends ConsumerWidget {
  const AccountActionsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final auth = ref.watch(authNotifierProvider);
    return Scaffold(
      appBar: settingsDetailAppBar(
        context,
        SettingsSection.yourAccount.label(l),
      ),
      body: ContentListView(
        maxWidth: settingsContentWidth(context),
        padding: const EdgeInsets.all(16),
        children: [
          if (auth is AuthAuthenticated)
            const AccountActionsGroups()
          else if (auth is AuthLoading)
            const SignInCheckingIndicator()
          else
            Text(l.t15_notSignedInYet),
        ],
      ),
    );
  }
}

/// A neutral wait shown while the app is still finding out whether a sign-in
/// is in place, so no "not signed in" claim flashes first.
class SignInCheckingIndicator extends StatelessWidget {
  const SignInCheckingIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Semantics(
      liveRegion: true,
      label: l.rva_checkingSignIn,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Column(
          children: [
            const ExcludeSemantics(child: CircularProgressIndicator()),
            const SizedBox(height: 16),
            ExcludeSemantics(child: Text(l.rva_checkingSignIn)),
          ],
        ),
      ),
    );
  }
}
