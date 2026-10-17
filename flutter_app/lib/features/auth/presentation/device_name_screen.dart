import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/errors/app_error.dart';
import '../auth_repository.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/router/app_router.dart';

/// Shown once after first successful login to name the current device session.
/// A failed request stays retryable; the user can explicitly skip instead.
class DeviceNameScreen extends ConsumerStatefulWidget {
  /// Pre-filled name override (used in tests to skip device_info_plus).
  final String? prefill;
  const DeviceNameScreen({super.key, this.prefill});

  @override
  ConsumerState<DeviceNameScreen> createState() => _DeviceNameScreenState();
}

class _DeviceNameScreenState extends ConsumerState<DeviceNameScreen> {
  late final TextEditingController _controller;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.prefill ?? '');
    if (widget.prefill == null) _loadDeviceName();
  }

  Future<void> _loadDeviceName() async {
    String name = '';
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        name = (await info.androidInfo).model;
      } else if (Platform.isIOS) {
        name = (await info.iosInfo).name;
      }
    } catch (_) {
      // The device name is only a suggestion; an empty field is acceptable.
    }
    if (mounted) _controller.text = name;
  }

  Future<void> _confirm() async {
    final name = _controller.text.trim();
    if (name.isEmpty) {
      context.go(AppPaths.home);
      return;
    }
    setState(() => _saving = true);

    final result = await ref.read(authRepositoryProvider).setDeviceName(name);
    if (!mounted) return;
    setState(() => _saving = false);
    switch (result) {
      case Ok():
        context.go(AppPaths.home);
      case Err():
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context).shared_syncFailed),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.auth_nameThisDevice)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.auth_whatShouldDeviceBeCalled,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              l.auth_deviceNameHelp,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _controller,
              decoration: InputDecoration(
                labelText: l.auth_deviceNameLabel,
                border: const OutlineInputBorder(),
              ),
              textCapitalization: TextCapitalization.words,
              maxLength: 100,
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _saving ? null : _confirm,
                child: _saving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l.shared_continue),
              ),
            ),
            TextButton(
              onPressed: _saving ? null : () => context.go(AppPaths.home),
              child: Text(l.shared_skip),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
