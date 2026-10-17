import 'dart:convert';

import 'package:home_widget/home_widget.dart';

import '../projections/projection_effects_gate.dart';
import '../projections/projection_identity.dart';
import '../storage/preference_keys.dart';
import '../workspace/workspace_access_repository.dart';
import '../workspace/workspace_context.dart';

const widgetProjectionIdentityKey = 'widget_projection_identity_v2';
const widgetProjectionRetirementKey = 'widget_projection_retirement_v2';

abstract interface class WidgetProjectionPlatform {
  Future<String?> read(String key);
  Future<void> save(String key, Object? value);
  Future<void> refresh();
}

class NativeWidgetProjectionPlatform implements WidgetProjectionPlatform {
  @override
  Future<String?> read(String key) => HomeWidget.getWidgetData<String>(key);
  @override
  Future<void> save(String key, Object? value) async {
    if (await HomeWidget.saveWidgetData<Object>(key, value) != true) {
      throw StateError('Could not persist widget projection');
    }
  }

  @override
  Future<void> refresh() async {
    await HomeWidget.updateWidget(
      name: 'DoseWidgetProvider',
      qualifiedAndroidName: 'com.simpastil.simpastil.DoseWidgetProvider',
    );
  }
}

/// One device widget slot. Ownership metadata is a display cache, never an
/// action grant. Account activation and all publishers share the effects gate.
class ProtectedWidgetPublisher {
  ProtectedWidgetPublisher({
    required this.access,
    required this.effectsGate,
    required this.platform,
    required this.build,
  });
  final WorkspaceAccessRepository access;
  final ProjectionEffectsGate effectsGate;
  final WidgetProjectionPlatform platform;
  final Future<Map<String, dynamic>> Function(WorkspaceContext context) build;

  ProjectionIdentity? _decodeIdentity(String? raw) {
    if (raw == null) return null;
    try {
      return ProjectionIdentity.fromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  Future<bool> _current(ProjectionIdentity identity, String content) async {
    final context = await identity.resolve(access);
    if (context == null ||
        (await access.workspaces.deviceState()).selectedWorkspaceId !=
            identity.workspaceId) {
      return false;
    }
    try {
      return jsonEncode(await build(context)) == content;
    } on WorkspaceAccessFailure {
      return false;
    }
  }

  Future<void> publish(ProjectionIdentity identity, {String? themeMode}) =>
      effectsGate.run(() async {
        final context = await identity.resolve(access);
        if (context == null) return;
        final snapshot = await build(context);
        if (!identity.owns(snapshot['projectionIdentity'])) {
          throw StateError('Widget snapshot ownership mismatch');
        }
        final content = jsonEncode(snapshot);
        if (!await _current(identity, content)) return;
        await _readRetirementIntent();
        final priorMarker = await platform.read(widgetProjectionIdentityKey);
        if (priorMarker != null && _decodeIdentity(priorMarker) == null) {
          throw const FormatException('Unrecognized widget identity');
        }
        final priorContent = await platform.read(kTodayDosesKey);
        final priorTheme = await platform.read(kAppThemeModeKey);
        if (!await _current(identity, content)) return;
        Future<void> abandon() =>
            _restoreOrClear(identity, priorMarker, priorContent, priorTheme);
        // Reject stale work before touching an existing widget. A null marker
        // makes partial publication unavailable to native rendering.
        await platform.save(widgetProjectionIdentityKey, null);
        await platform.save(kActiveUserIdKey, null);
        if (!await _current(identity, content)) return abandon();
        await platform.save(kSessionGenerationKey, identity.grantEpoch);
        await platform.save(kTodayDosesKey, content);
        await platform.save(kSnapshotDayKey, snapshot['day']);
        await platform.save(kAppThemeModeKey, themeMode);
        if (!await _current(identity, content)) return abandon();
        await platform.save(kActiveUserIdKey, identity.ownerId);
        if (!await _current(identity, content)) return abandon();
        await platform.save(
          widgetProjectionIdentityKey,
          jsonEncode(identity.toJson()),
        );
        if (!await _current(identity, content)) return abandon();
        await platform.refresh();
        if (!await _current(identity, content)) {
          await abandon();
        } else {
          await platform.save(widgetProjectionRetirementKey, null);
        }
      });

  /// Retire only the exact captured grant. A delayed A teardown cannot blank B
  /// or local care. An interrupted publication can be identified by its body.
  Future<void> retire(ProjectionIdentity identity) => effectsGate.run(() async {
    final raw = await platform.read(widgetProjectionIdentityKey);
    if (raw != null && _decodeIdentity(raw) != identity) return;
    if (raw == null) {
      final snapshot = await platform.read(kTodayDosesKey);
      try {
        final decoded = snapshot == null ? null : jsonDecode(snapshot);
        if (decoded is! Map || !identity.owns(decoded['projectionIdentity'])) {
          return;
        }
      } on FormatException {
        return;
      }
    }
    await _clearUnpublished(identity);
  });

  /// A restart may have no in-memory retired target. Resolve the persisted full
  /// identity against protected metadata before clearing this single slot.
  Future<void> retireUnavailable() => effectsGate.run(() async {
    final intent = await _readRetirementIntent();
    final marker = await platform.read(widgetProjectionIdentityKey);
    ProjectionIdentity? identity;
    if (marker != null) {
      identity = _decodeIdentity(marker);
      if (identity == null) {
        throw const FormatException('Unrecognized widget identity');
      }
    } else {
      final raw = await platform.read(kTodayDosesKey);
      if (raw != null) {
        final body = jsonDecode(raw);
        if (body is! Map) {
          throw const FormatException('Unrecognized widget snapshot');
        }
        final hint = body['projectionIdentity'];
        if (hint == null) return; // Legacy hints cannot establish a grant.
        identity = ProjectionIdentity.fromJson(hint);
        if (identity == null) {
          throw const FormatException('Unrecognized widget identity');
        }
      }
    }
    if (identity == null) {
      if (intent != null) await _clearUnpublished(intent);
      return;
    }
    if (await identity.retirementRequired(access)) {
      await _clearUnpublished(identity);
    } else if (intent != null) {
      // A later valid publication replaced the retired body. Refresh that body
      // and consume the old intent without blanking the new workspace.
      await platform.refresh();
      if (await identity.retirementRequired(access)) {
        await _clearUnpublished(identity);
      } else {
        await platform.save(widgetProjectionRetirementKey, null);
      }
    }
  });

  Future<ProjectionIdentity?> _readRetirementIntent() async {
    final raw = await platform.read(widgetProjectionRetirementKey);
    if (raw == null) return null;
    final identity = _decodeIdentity(raw);
    if (identity == null) {
      throw const FormatException('Unrecognized widget retirement');
    }
    await identity.retirementRequired(access); // Positive known metadata only.
    return identity;
  }

  Future<void> _restoreOrClear(
    ProjectionIdentity candidate,
    String? marker,
    String? content,
    String? theme,
  ) async {
    final previous = _decodeIdentity(marker);
    if (previous == null ||
        content == null ||
        !await _current(previous, content)) {
      return _clearUnpublished(candidate);
    }
    final decoded = jsonDecode(content) as Map<String, dynamic>;
    await platform.save(widgetProjectionIdentityKey, null);
    await platform.save(kActiveUserIdKey, null);
    await platform.save(kSessionGenerationKey, previous.grantEpoch);
    await platform.save(kTodayDosesKey, content);
    await platform.save(kSnapshotDayKey, decoded['day']);
    await platform.save(kAppThemeModeKey, theme);
    if (!await _current(previous, content)) return _clearUnpublished(previous);
    await platform.save(kActiveUserIdKey, previous.ownerId);
    await platform.save(widgetProjectionIdentityKey, marker);
    if (!await _current(previous, content)) return _clearUnpublished(previous);
    await platform.refresh();
    if (!await _current(previous, content)) {
      await _clearUnpublished(previous);
    } else {
      await platform.save(widgetProjectionRetirementKey, null);
    }
  }

  Future<void> _clearUnpublished(ProjectionIdentity identity) async {
    await _readRetirementIntent();
    await platform.save(
      widgetProjectionRetirementKey,
      jsonEncode(identity.toJson()),
    );
    await platform.save(widgetProjectionIdentityKey, null);
    await platform.save(kActiveUserIdKey, null);
    await platform.save(kTodayDosesKey, null);
    await platform.save(kSnapshotDayKey, null);
    await platform.refresh();
    await platform.save(widgetProjectionRetirementKey, null);
  }
}
