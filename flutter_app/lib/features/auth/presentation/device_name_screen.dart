import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/errors/app_error.dart';
import '../auth_repository.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/router/app_router.dart';

/// Shown once after first successful login to name the current device session.
/// A failed request stays retryable; the user can explicitly skip instead.
class DeviceNameScreen extends ConsumerStatefulWidget {
  /// Pre-filled name override (used in tests to skip device_info_plus).
  final String? prefill;

  /// Reads the suggested name when none is saved (used in tests to skip
  /// device_info_plus); defaults to the device model.
  final Future<String> Function()? deviceModel;
  const DeviceNameScreen({super.key, this.prefill, this.deviceModel});

  @override
  ConsumerState<DeviceNameScreen> createState() => _DeviceNameScreenState();
}

class _DeviceNameScreenState extends ConsumerState<DeviceNameScreen> {
  late final TextEditingController _controller;
  bool _saving = false;

  /// The name this device already carries (it survives logging out and still
  /// shows in Settings), or '' when it was never named.
  String _savedName = '';

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.prefill ?? '');
    _loadDeviceName();
  }

  static Future<String> _readDeviceModel() async {
    final info = DeviceInfoPlugin();
    if (Platform.isAndroid) return (await info.androidInfo).model;
    if (Platform.isIOS) return (await info.iosInfo).name;
    return '';
  }

  /// Offers the saved name when there is one, and the device model only for a
  /// device that was never named.
  Future<void> _loadDeviceName() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _savedName = (prefs.getString('simpastil_device_name') ?? '').trim();
    } catch (_) {
      // Nothing saved is readable; fall back to the suggestion below.
    }
    if (widget.prefill != null) return;
    var name = _savedName;
    if (name.isEmpty) {
      try {
        name = (await (widget.deviceModel ?? _readDeviceModel)()).trim();
      } catch (_) {
        // The device name is only a suggestion; an empty field is acceptable.
      }
    }
    if (mounted && _controller.text.isEmpty) _controller.text = name;
  }

  /// Leaving the prompt unanswered keeps the name Settings already shows: it is
  /// sent for this new session so the server does not list it unnamed. The
  /// request is best effort; the person is never held here.
  Future<void> _skip() async {
    if (_savedName.isNotEmpty) {
      setState(() => _saving = true);
      await ref.read(authRepositoryProvider).setDeviceName(_savedName);
      if (!mounted) return;
      setState(() => _saving = false);
    }
    if (mounted) context.go(AppPaths.home);
  }

  Future<void> _confirm() async {
    final name = _controller.text.trim();
    if (name.isEmpty) {
      await _skip();
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
              onPressed: _saving ? null : _skip,
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
