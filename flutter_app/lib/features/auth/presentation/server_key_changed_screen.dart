import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/network/pinned_connection.dart';
import '../../../core/network/server_pin_controller.dart';
import '../../../core/network/server_pin_providers.dart';
import '../../../core/network/server_pin_store.dart';
import '../../../core/server/server_config_notifier.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/layouts/window_size.dart';
import '../../../shared/widgets/status_chip.dart';
import '../../settings/presentation/settings_pane.dart';
import 'fingerprint_block.dart';

/// How the person left the key-changed screen.
enum ServerKeyOutcome {
  /// Nothing changed: traffic to the server stays blocked.
  keptBlocked,

  /// The new key was pinned.
  trustedNewKey,

  /// The pin was removed; the server is checked like any website.
  normalChecking,

  /// The server presented the pinned key again and the notice was cleared.
  dismissed,
}

/// Blocking explanation for a pinned server that presented a different key.
///
/// It asks the server again, live, what it presents now, so the person
/// compares real values: a stale record from a background sync is never the
/// only evidence. Nothing here sends credentials or data to the server.
class ServerKeyChangedScreen extends ConsumerStatefulWidget {
  const ServerKeyChangedScreen({super.key, this.authority});

  /// The server to review; the configured one when null.
  final ServerAuthority? authority;

  @override
  ConsumerState<ServerKeyChangedScreen> createState() =>
      _ServerKeyChangedScreenState();
}

class _ServerKeyChangedScreenState
    extends ConsumerState<ServerKeyChangedScreen> {
  ServerAuthority? _authority;
  ServerPin? _pin;
  ServerCertificateProbe? _probe;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  ServerAuthority? _resolveAuthority() {
    if (widget.authority != null) return widget.authority;
    final url = ref.read(serverConfigProvider);
    if (url == null) return null;
    try {
      return ServerAuthority.parse(url);
    } on ArgumentError {
      return null;
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    final authority = _resolveAuthority();
    ServerPin? pin;
    ServerCertificateProbe? probe;
    if (authority != null) {
      try {
        pin = await ref.read(serverPinStoreProvider).read(authority);
      } on ServerPinUnreadable {
        pin = null;
      }
      if (pin != null) {
        try {
          probe = await ref.read(serverCertificateProbeProvider)(authority);
        } on Object {
          probe = null;
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _authority = authority;
      _pin = pin;
      _probe = probe;
      _loading = false;
    });
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String action,
  }) async {
    final l = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l.shared_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _run(
    Future<void> Function() change,
    ServerKeyOutcome outcome,
  ) async {
    setState(() => _busy = true);
    try {
      await change();
      if (mounted) Navigator.of(context).pop(outcome);
    } on Object {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).shared_somethingWentWrong),
        ),
      );
    }
  }

  Future<void> _trustNewKey() async {
    final authority = _authority;
    final probe = _probe;
    if (authority == null || probe == null) return;
    final l = AppLocalizations.of(context);
    if (!await _confirm(
      title: l.pin_confirmTrustTitle,
      body: l.pin_confirmTrustBody,
      action: l.pin_confirmTrustAction,
    )) {
      return;
    }
    await _run(
      () => ref
          .read(serverPinControllerProvider.notifier)
          .trust(authority, probe.fingerprint),
      ServerKeyOutcome.trustedNewKey,
    );
  }

  Future<void> _useNormalChecking() async {
    final authority = _authority;
    if (authority == null) return;
    final l = AppLocalizations.of(context);
    if (!await _confirm(
      title: l.pin_confirmNormalTitle,
      body: l.pin_confirmNormalBody,
      action: l.pin_confirmNormalAction,
    )) {
      return;
    }
    await _run(
      () => ref
          .read(serverPinControllerProvider.notifier)
          .useNormalChecking(authority),
      ServerKeyOutcome.normalChecking,
    );
  }

  Future<void> _dismiss() async {
    final authority = _authority;
    if (authority == null) return;
    await _run(
      () => ref
          .read(serverPinControllerProvider.notifier)
          .dismissMismatch(authority),
      ServerKeyOutcome.dismissed,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final language = Localizations.localeOf(context).languageCode;
    final authority = _authority;
    final pin = _pin;
    final probe = _probe;
    final host = authority?.host ?? '';

    final resolved =
        pin != null && probe != null && probe.fingerprint == pin.fingerprint;
    final different = pin != null && probe != null && !resolved;
    final noticed = pin?.mismatch?.at;
    final recordedFingerprint = pin?.mismatch?.presented;

    return Scaffold(
      appBar: settingsDetailAppBar(context, l.pin_changedTitle),
      body: ContentListView(
        maxWidth: settingsContentWidth(context),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          if (_loading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 48),
              child: Column(
                children: [
                  const CircularProgressIndicator.adaptive(),
                  const SizedBox(height: 16),
                  Text(l.pin_checking, style: text.bodyMedium),
                ],
              ),
            )
          else if (pin == null)
            // Pinned no more (resolved elsewhere): nothing to review.
            Padding(
              padding: const EdgeInsets.only(top: 24),
              child: FilledButton(
                onPressed: () =>
                    Navigator.of(context).pop(ServerKeyOutcome.dismissed),
                child: Text(l.shared_close),
              ),
            )
          else ...[
            CalmNotice(
              key: const ValueKey('server-key-lead'),
              text: resolved
                  ? l.pin_resolvedLead(host)
                  : l.pin_changedLead(host),
              icon: resolved
                  ? Icons.verified_user_outlined
                  : Icons.gpp_maybe_outlined,
              tone: resolved ? StatusTone.good : StatusTone.problem,
              live: true,
            ),
            if (!resolved) ...[
              const SizedBox(height: 16),
              Text(l.pin_changedWhy, style: text.bodyMedium),
            ],
            const SizedBox(height: 20),
            FingerprintBlock(
              label: l.pin_pinnedLabel,
              fingerprint: pin.fingerprint,
            ),
            if (!resolved) ...[
              const SizedBox(height: 16),
              if (probe != null)
                FingerprintBlock(
                  label: l.pin_presentedLabel,
                  fingerprint: probe.fingerprint,
                )
              else if (recordedFingerprint != null)
                FingerprintBlock(
                  label: l.pin_presentedLabel,
                  fingerprint: recordedFingerprint,
                  note: noticed == null
                      ? null
                      : l.pin_noticedAt(
                          DateFormat(
                            'd MMM yyyy, HH:mm',
                            language,
                          ).format(noticed.toLocal()),
                        ),
                )
              else
                Text(
                  l.pin_presentedNone,
                  style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
            ],
            if (probe == null) ...[
              const SizedBox(height: 16),
              CalmNotice(
                text: l.pin_probeFailed,
                icon: Icons.cloud_off_outlined,
                tone: StatusTone.neutral,
              ),
            ],
            const SizedBox(height: 24),
            if (resolved)
              FilledButton(
                key: const ValueKey('server-key-dismiss'),
                onPressed: _busy ? null : _dismiss,
                child: Text(l.pin_dismiss),
              )
            else ...[
              FilledButton(
                key: const ValueKey('server-key-keep'),
                onPressed: _busy
                    ? null
                    : () => Navigator.of(
                        context,
                      ).pop(ServerKeyOutcome.keptBlocked),
                child: Text(l.pin_keepBlocked),
              ),
              if (probe == null) ...[
                const SizedBox(height: 8),
                OutlinedButton(
                  key: const ValueKey('server-key-check-again'),
                  onPressed: _busy ? null : _load,
                  child: Text(l.pin_checkAgain),
                ),
              ],
              if (different) ...[
                const SizedBox(height: 8),
                OutlinedButton(
                  key: const ValueKey('server-key-trust'),
                  onPressed: _busy ? null : _trustNewKey,
                  child: Text(l.pin_trustNewKey),
                ),
                if (probe.chainValid) ...[
                  const SizedBox(height: 20),
                  Text(
                    l.pin_normalAvailable,
                    style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    key: const ValueKey('server-key-normal'),
                    onPressed: _busy ? null : _useNormalChecking,
                    child: Text(l.pin_useNormal),
                  ),
                ],
              ],
            ],
          ],
        ],
      ),
    );
  }
}
