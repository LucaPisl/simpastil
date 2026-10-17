import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/backup/backup_import_session.dart';
import '../../../core/backup/backup_manifest.dart';
import '../../../core/backup/backup_providers.dart';
import '../../../core/backup/backup_service.dart';
import '../../../core/backup/import_plan.dart';
import '../../../core/protection/app_lock_controller.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/layouts/window_size.dart';
import '../../../shared/router/back_policy.dart';
import '../../../shared/widgets/person_avatar.dart';
import '../../../shared/widgets/status_chip.dart';
import 'settings_overview.dart';
import 'settings_pane.dart';
import 'import_dose_conflict_card.dart';
import '../../../shared/format/clock.dart';

enum _BackupPage { overview, create, check, selection, review }

class BackupSettingsScreen extends ConsumerStatefulWidget {
  const BackupSettingsScreen({super.key});
  @override
  ConsumerState<BackupSettingsScreen> createState() =>
      _BackupSettingsScreenState();
}

class _BackupSettingsScreenState extends ConsumerState<BackupSettingsScreen> {
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  _BackupPage _page = _BackupPage.overview;
  BackupDestinationChoice? _destination;
  BackupSourceChoice? _source;
  CapturedBackup? _preview;
  BackupImportSession? _session;
  CheckedBackup? _checked;
  ImportPlan? _plan;
  ImportMode _mode = ImportMode.selected;
  final _selected = <String>{};
  bool _encrypted = true,
      _obscure = true,
      _busy = false,
      _replacementAcknowledged = false;
  int _epoch = 0;
  String? _message;
  DialogRoute<dynamic>? _dialogRoute;

  @override
  void dispose() {
    _session?.close();
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  void _expire() {
    // Only opaque file choices survive. Every care snapshot, password, checked
    // source and import plan belongs to the invalidated operation and is dropped.
    _epoch++;
    final dialog = _dialogRoute;
    _dialogRoute = null;
    if (dialog != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final navigator = dialog.navigator;
        if (navigator != null && dialog.isActive) navigator.removeRoute(dialog);
      });
    }
    _session?.close();
    _session = null;
    _checked = null;
    _preview = null;
    _plan = null;
    _password.clear();
    _confirmation.clear();
    _selected.clear();
    _replacementAcknowledged = false;
    if (_page == _BackupPage.selection || _page == _BackupPage.review) {
      _page = _BackupPage.check;
    }
    _message = AppLocalizations.of(context).t15_accessExpired;
  }

  Future<T?> _protectedDialog<T>({required WidgetBuilder builder}) async {
    final epoch = _epoch;
    try {
      final lease = ref
          .read(appLockControllerProvider.notifier)
          .captureAccess();
      final route = DialogRoute<T>(context: context, builder: builder);
      _dialogRoute = route;
      final result = await Navigator.of(context).push<T>(route);
      if (identical(_dialogRoute, route)) _dialogRoute = null;
      if (!mounted || epoch != _epoch) return null;
      lease.requireCurrent();
      return result;
    } on AppLockRequired {
      return null;
    }
  }

  Future<void> _run(
    Future<void> Function(int epoch) operation,
    String failure,
  ) async {
    if (_busy) return;
    final epoch = _epoch;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await operation(epoch);
    } on AppLockRequired {
      if (mounted) {
        setState(
          () => _message = AppLocalizations.of(context).t15_accessExpired,
        );
      }
    } on Object {
      if (mounted && epoch == _epoch) setState(() => _message = failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    setState(() {
      _page = _BackupPage.create;
      _message = null;
      _encrypted = true;
    });
    await _run((epoch) async {
      final snapshot = await ref.read(backupServiceProvider).captureFull();
      if (mounted && epoch == _epoch) setState(() => _preview = snapshot);
    }, AppLocalizations.of(context).t15_loadFailed);
  }

  Future<void> _chooseDestination() => _run((_) async {
    final service = ref.read(backupServiceProvider);
    // Validate capture before SAF creates a destination file. The save still
    // captures a fresh protected snapshot after returning from the chooser.
    await service.captureFull();
    final choice = await service.chooseDestination();
    // SAF may have invalidated the operation. This token grants no care access.
    if (mounted && choice != null) {
      setState(() {
        _destination = choice;
        _message = AppLocalizations.of(context).t15_afterChooser;
      });
    }
  }, AppLocalizations.of(context).t15_saveFailed);

  Future<void> _save() async {
    final l = AppLocalizations.of(context);
    if (_encrypted &&
        (_password.text.isEmpty || _password.text != _confirmation.text)) {
      setState(() => _message = l.t15_passwordMismatch);
      return;
    }
    if (!_encrypted) {
      final accepted = await _protectedDialog<bool>(
        builder: (context) => AlertDialog(
          title: Text(l.t15_unencrypted),
          content: Text(l.t15_unencryptedBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l.shared_cancel),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                minimumSize: const Size(0, 52),
              ),
              onPressed: () => Navigator.pop(context, true),
              child: Text(l.shared_continue),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
    }
    final destination = _destination;
    if (destination == null) return;
    // Explicit user action after SAF/unlock starts a new operation. Never reuse
    // the earlier overview snapshot or recapture access at disclosure time.
    await _run((epoch) async {
      final service = ref.read(backupServiceProvider);
      final snapshot = await service.captureFull();
      final result = await service.saveToDestination(
        snapshot,
        destination,
        password: _encrypted ? _password.text : null,
        allowClear: !_encrypted,
      );
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _preview = snapshot;
        _message = switch (result.status) {
          BackupSaveStatus.savedChecked =>
            '${l.t15_savedChecked}\n${result.location?.displayName ?? destination.displayName}\n${_date(result.capturedAt)} · ${_date(result.checkedAt)}',
          BackupSaveStatus.savedUnchecked ||
          BackupSaveStatus.savedCheckFailed =>
            '${l.t15_savedUnchecked}\n${result.location?.displayName ?? destination.displayName}',
          BackupSaveStatus.cancelled => l.t15_noFileSaved,
          BackupSaveStatus.saveFailedMayBePartial => l.t15_saveFailed,
        };
        _password.clear();
        _confirmation.clear();
      });
    }, l.t15_saveFailed);
  }

  Future<void> _chooseSource() => _run((_) async {
    final source = await ref.read(backupServiceProvider).chooseSource();
    if (mounted && source != null) {
      setState(() {
        _source = source;
        _message = AppLocalizations.of(context).t15_afterChooser;
      });
    }
  }, AppLocalizations.of(context).t15_checkFailed);

  Future<void> _check() => _run((epoch) async {
    final source = _source;
    if (source == null) return;
    final selected = await ref.read(backupServiceProvider).openSource(source);
    final session = await ref.read(openBackupImportProvider)(
      selected,
      password: _password.text.isEmpty ? null : _password.text,
    );
    if (!mounted || epoch != _epoch) {
      session.close();
      return;
    }
    setState(() {
      _session?.close();
      _session = session;
      _checked = session.checked;
      _selected.clear();
      _password.clear();
      _confirmation.clear();
    });
  }, AppLocalizations.of(context).t15_checkFailed);

  Future<void> _review() => _run((epoch) async {
    final session = _session;
    if (session == null) return;
    final plan = await session.preview(
      _mode == ImportMode.full
          ? const ImportSelection.full()
          : ImportSelection.profiles(_selected),
    );
    if (mounted && epoch == _epoch) {
      setState(() {
        _plan = plan;
        _page = _BackupPage.review;
        _replacementAcknowledged = false;
      });
    }
  }, AppLocalizations.of(context).t15_importFailed);

  Future<void> _apply() async {
    final l = AppLocalizations.of(context);
    final plan = _plan, session = _session;
    if (plan == null ||
        session == null ||
        (plan.mode == ImportMode.full && !_replacementAcknowledged)) {
      return;
    }
    final accepted = await _protectedDialog<bool>(
      builder: (context) => AlertDialog(
        title: Text(l.t15_confirmApply),
        content: Text(
          plan.mode == ImportMode.full
              ? l.t15_fullRestoreBody
              : l.t15_selectedImportBody,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.shared_cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              minimumSize: const Size(0, 52),
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              plan.mode == ImportMode.full
                  ? l.t15_applyRestore
                  : l.t15_applyImport,
            ),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    await _run((epoch) async {
      final result = await session.apply(plan);
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _page = _BackupPage.overview;
        _message =
            '${plan.mode == ImportMode.full ? l.t15_restoreDone : l.t15_importDone}${result.projectionsPending ? '\n${l.t15_projectionPending}' : ''}';
        _session?.close();
        _session = null;
        _checked = null;
        _plan = null;
      });
    }, l.t15_importFailed);
  }

  String _date(DateTime? value) =>
      value == null ? '' : clockDateTime(context, value.toLocal());

  Map<String, int> _counts(BackupDocument document, AppLocalizations l) => {
    l.t15_people: document.tables['profiles']!.length,
    l.t15_medications: document.tables['pills']!.length,
    l.t15_routines:
        (document.tables['local_routines']?.length ?? 0) +
        document.tables['schedules']!.length,
    l.t15_history:
        document.tables['dose_logs']!.length +
        (document.tables['care_events']?.length ?? 0),
    l.t15_preferences: document.preferences.length,
  };

  Widget _notice(String text, {StatusTone tone = StatusTone.working}) =>
      CalmNotice(text: text, tone: tone, icon: statusToneIcon(tone));

  Widget _sourceSummary(
    BackupDocument document,
    AppLocalizations l,
  ) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.insert_drive_file_outlined, size: 36),
    title: Text(
      '${l.t15_backups} · ${_date(document.capturedAt)}',
      style: const TextStyle(fontWeight: FontWeight.w600),
    ),
    subtitle: Text(
      '${l.t15_retainedPeopleCount(document.tables['profiles']!.length)} · ${l.t15_history}: ${_counts(document, l)[l.t15_history]}',
    ),
  );

  Widget _personChoice(
    Map<String, dynamic> person,
    BackupDocument document,
    AppLocalizations l,
  ) {
    final name = person['name'] as String;
    final pills = document.tables['pills']!
        .where((row) => row['profile_id'] == person['id'])
        .toList();
    final pillIds = pills.map((row) => row['id']).toSet();
    final routines = {
      for (final row
          in document.tables['local_routines'] ?? <Map<String, dynamic>>[])
        if (pillIds.contains(row['pill_id'])) 'local:${row['routine_id']}',
      for (final row in document.tables['schedules']!)
        if (pillIds.contains(row['pill_id'])) 'schedule:${row['id']}',
    };
    return CheckboxListTile(
      controlAffinity: ListTileControlAffinity.leading,
      title: Row(
        children: [
          PersonAvatar(
            id: person['id'] as String,
            name: name,
            emoji: person['avatar_emoji'] as String?,
            size: 40,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              name,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
      subtitle: Text(
        '${l.t15_medications}: ${pills.length} · ${l.t15_routines}: ${routines.length}',
      ),
      value: _selected.contains(person['id']),
      onChanged: _busy
          ? null
          : (value) => setState(() {
              if (value == true) {
                _selected.add(person['id'] as String);
              } else {
                _selected.remove(person['id']);
              }
            }),
    );
  }

  void _viewContents(BackupDocument document, AppLocalizations l) =>
      _protectedDialog<void>(
        builder: (context) => AlertDialog(
          title: Text(l.t15_contents),
          scrollable: true,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.t15_backupContents),
              const SizedBox(height: 16),
              for (final entry in _counts(document, l).entries)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(entry.key),
                  trailing: Text('${entry.value}'),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l.shared_close),
            ),
          ],
        ),
      );

  Widget _contents(
    BackupDocument document,
    AppLocalizations l, {
    bool fromFile = false,
  }) => SettingsGroup(
    label: fromFile ? l.t15_contents : l.t15_onDevice,
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PersonAvatarStack(
              people: [
                for (final p in document.tables['profiles']!)
                  (
                    id: '${p['id']}',
                    name: '${p['name'] ?? ''}',
                    emoji: p['avatar_emoji'] as String?,
                  ),
              ],
              size: 30,
              max: 2,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.t15_retainedPeopleCount(
                      document.tables['profiles']!.length,
                    ),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    document.tables['profiles']!
                        .map((p) => p['name'])
                        .join(', '),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l.t15_backupContentsShort,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      alignment: Alignment.centerLeft,
                    ),
                    onPressed: () => _viewContents(document, l),
                    child: Text(
                      l.t15_contents,
                      style: const TextStyle(
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _passwordField(AppLocalizations l, {bool confirmation = false}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                confirmation ? l.t15_confirmPassword : l.t15_backupPassword,
              ),
            ),
            TextField(
              controller: confirmation ? _confirmation : _password,
              obscureText: _obscure,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                filled: false,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(
                    color: Theme.of(context).colorScheme.primary,
                    width: 2,
                  ),
                ),

                suffixIcon: IconButton(
                  tooltip: l.t15_passwordVisibility,
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
          ],
        ),
      );

  /// One step back in the backup flow: review to selection to check to the
  /// first page.
  void _stepBack() {
    setState(() {
      _page = switch (_page) {
        _BackupPage.review => _BackupPage.selection,
        _BackupPage.selection => _BackupPage.check,
        _ => _BackupPage.overview,
      };
    });
  }

  /// Tells the wide Settings screen around this page when it must stay (busy)
  /// and what Back does on a later step. Runs after the frame: the screen
  /// listens to both and cannot change while it builds.
  void _syncPane(SettingsPaneScope pane) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      pane.leaveBlocked.value = _busy;
      pane.stepBack.value = _page == _BackupPage.overview ? null : _stepBack;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    ref.listen(appLockControllerProvider, (previous, next) {
      if (previous?.canAccess == true && !next.canAccess) setState(_expire);
    });
    final pane = SettingsPaneScope.maybeOf(context);
    if (pane != null) _syncPane(pane);
    final checked = _checked, plan = _plan;
    final title = switch (_page) {
      _BackupPage.overview => l.t15_backups,
      _BackupPage.create => l.t15_createBackup,
      _BackupPage.check => l.t15_checkBackup,
      _BackupPage.selection => l.t15_restoreSelection,
      _BackupPage.review => l.t15_reviewImport,
    };
    final scaffold = Scaffold(
      appBar: settingsDetailAppBar(
        context,
        title,
        leading: pane != null
            // Beside the list Back leaves Settings; the arrow is only for
            // the later steps of the flow.
            ? (_page == _BackupPage.overview
                  ? null
                  : BackButton(onPressed: _busy ? null : _stepBack))
            : BackButton(
                onPressed: _busy
                    ? null
                    : () {
                        if (_page == _BackupPage.overview) {
                          Navigator.pop(context);
                        } else {
                          _stepBack();
                        }
                      },
              ),
      ),
      body: ContentListView(
        maxWidth: settingsContentWidth(context),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          if (_page == _BackupPage.overview) ...[
            Text(
              l.t15_backupPurpose,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            SettingsGroup(
              label: l.t15_backups,
              index: 0,
              identity: 'backup-overview',
              children: [
                SettingsNavigationRow(
                  icon: Icons.save_outlined,
                  title: l.t15_createBackup,
                  subtitle: l.t15_createSubtitle,
                  onTap: _create,
                ),
                SettingsNavigationRow(
                  icon: Icons.fact_check_outlined,
                  title: l.t15_checkBackup,
                  subtitle: l.t15_checkSubtitle,
                  onTap: () => setState(() {
                    _page = _BackupPage.check;
                    _message = null;
                  }),
                ),
              ],
            ),
            CalmNotice(
              text: l.t15_transferBody,
              icon: Icons.phonelink_lock_outlined,
              tone: StatusTone.neutral,
            ),
          ],
          if (_page == _BackupPage.create) ...[
            if (_preview != null) _contents(_preview!.document, l),
            CalmNotice(
              text: l.backup_unattributed,
              icon: Icons.history_edu_outlined,
              tone: StatusTone.neutral,
            ),
            const SizedBox(height: 24),
            SettingsGroup(
              label: l.t15_backupProtection,
              children: [
                RadioGroup<bool>(
                  groupValue: _encrypted,
                  onChanged: (value) {
                    if (!_busy && value != null) {
                      setState(() => _encrypted = value);
                    }
                  },
                  child: Column(
                    children: [
                      RadioListTile<bool>(
                        radioScaleFactor: 1.25,
                        value: true,
                        title: Text(
                          l.t15_passwordProtected,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      Divider(
                        height: 1,
                        thickness: 1,
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                      RadioListTile<bool>(
                        radioScaleFactor: 1.25,
                        value: false,
                        title: Text(
                          l.t15_unencrypted,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(l.t15_unencryptedBody),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (_encrypted) ...[
              _passwordField(l),
              _passwordField(l, confirmation: true),
              Text(
                l.t15_passwordNeeded,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
            ],
            Text(_destination?.displayName ?? l.t15_noFileSaved),
            const SizedBox(height: 12),
            if (_destination != null)
              FilledButton(
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  minimumSize: const Size(0, 52),
                ),
                onPressed: _busy ? null : _save,
                child: Text(l.t15_saveChosen),
              ),
            if (_destination == null)
              FilledButton(
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  minimumSize: const Size(0, 52),
                ),
                onPressed: _busy ? null : _chooseDestination,
                child: Text(l.t15_chooseSave),
              )
            else
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  minimumSize: const Size(0, 52),
                ),
                onPressed: _busy ? null : _chooseDestination,
                child: Text(l.t15_chooseSave),
              ),
          ],
          if (_page == _BackupPage.check && checked == null) ...[
            Text(l.t15_checkSubtitle),
            const SizedBox(height: 24),
            if (_source != null) ...[
              Text(_source!.displayName),
              const SizedBox(height: 16),
              _passwordField(l),
              FilledButton(
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  minimumSize: const Size(0, 52),
                ),
                onPressed: _busy ? null : _check,
                child: Text(l.t15_openChosen),
              ),
            ],
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                minimumSize: const Size(0, 52),
              ),
              onPressed: _busy ? null : _chooseSource,
              child: Text(l.t15_chooseBackup),
            ),
          ],
          if (_page == _BackupPage.check && checked != null) ...[
            Text(checked.location.displayName),
            const SizedBox(height: 12),
            Row(
              children: [
                ExcludeSemantics(
                  child: Icon(
                    Icons.verified_outlined,
                    size: 32,
                    color: statusToneColor(Theme.of(context), StatusTone.good),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    l.t15_checksPassed,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(l.t15_supportedBackup),
            const SizedBox(height: 24),
            Container(
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: .08),
                borderRadius: BorderRadius.circular(16),
              ),
              child: ListTile(
                leading: Icon(
                  checked.passwordProtected
                      ? Icons.lock_outline
                      : Icons.lock_open_outlined,
                ),
                title: Text(
                  checked.passwordProtected
                      ? l.t15_passwordProtected
                      : l.t15_unencrypted,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '${l.t15_dataCaptured}: ${_date(checked.document.capturedAt)}\n${l.t15_checkedAt}: ${_date(checked.checkedAt)}',
            ),
            const SizedBox(height: 24),
            _contents(checked.document, l, fromFile: true),
            const Divider(height: 24),
            ListTile(
              leading: const Icon(Icons.verified_user_outlined),
              title: Text(l.t15_fileIntegrity),
              trailing: StatusChip(
                label: l.t15_passed,
                tone: StatusTone.good,
                dense: true,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: Text(l.t15_backupFormat),
              trailing: StatusChip(
                label: l.t15_supported,
                tone: StatusTone.good,
                dense: true,
              ),
            ),
            const Divider(height: 24),
            _notice(l.t15_currentUnchanged, tone: StatusTone.good),
            const SizedBox(height: 16),
            FilledButton(
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                minimumSize: const Size(0, 52),
              ),
              onPressed: _busy
                  ? null
                  : () => setState(() => _page = _BackupPage.selection),
              child: Text(l.t15_reviewRestore),
            ),
          ],
          if (_page == _BackupPage.selection && checked != null) ...[
            _sourceSummary(checked.document, l),
            const SizedBox(height: 24),
            RadioGroup<ImportMode>(
              groupValue: _mode,
              onChanged: (value) {
                if (!_busy && value != null) {
                  setState(() => _mode = value);
                }
              },
              child: SettingsGroup(
                label: l.t15_howRestore,
                children: [
                  RadioListTile<ImportMode>(
                    radioScaleFactor: 1.25,
                    value: ImportMode.selected,
                    title: Text(l.t15_selectedImport),
                    subtitle: Text(l.t15_selectedImportBody),
                  ),
                  RadioListTile<ImportMode>(
                    radioScaleFactor: 1.25,
                    value: ImportMode.full,
                    title: Text(l.t15_fullRestore),
                    subtitle: Text(l.t15_fullRestoreBody),
                  ),
                ],
              ),
            ),
            if (_mode == ImportMode.selected)
              SettingsGroup(
                label: l.t15_people,
                children: [
                  for (final person in checked.document.tables['profiles']!)
                    _personChoice(person, checked.document, l),
                ],
              ),
            if (_mode == ImportMode.selected)
              Text(l.t15_selectedPeopleCount(_selected.length)),
            const Divider(height: 32),
            Text(l.t15_noChangeBeforeApply),
            const SizedBox(height: 16),
            FilledButton(
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                minimumSize: const Size(0, 52),
              ),
              onPressed:
                  _busy || (_mode == ImportMode.selected && _selected.isEmpty)
                  ? null
                  : _review,
              child: Text(l.t15_reviewImport),
            ),
          ],
          if (_page == _BackupPage.review && plan != null) ...[
            if (checked != null) _sourceSummary(checked.document, l),
            const SizedBox(height: 16),
            Text(
              plan.mode == ImportMode.full
                  ? l.t15_fullRestoreBody
                  : l.t15_selectedImportBody,
            ),
            const SizedBox(height: 24),
            SettingsGroup(
              label: l.t15_people,
              children: [
                for (final person in plan.people)
                  ListTile(
                    title: Text(person.name),
                    subtitle: Text(
                      '${_outcome(person.outcome, l)} · ${l.t15_additions}: ${person.addedRows} · ${l.t15_conflicts}: ${person.conflictingRows}',
                    ),
                  ),
              ],
            ),
            if (plan.mode == ImportMode.full)
              SettingsGroup(
                label: l.t15_affectedPeople,
                children: [
                  for (final person in plan.affectedPeople)
                    ListTile(title: Text(person.name)),
                  for (final workspace in plan.replacedWorkspaces)
                    ListTile(
                      title: Text(
                        workspace.connected
                            ? l.t15_connectedCare
                            : l.t15_localCare,
                      ),
                      subtitle: Text(
                        '${l.t15_retained}: ${workspace.tableCounts.values.fold<int>(0, (a, b) => a + b)}',
                      ),
                    ),
                ],
              ),
            SettingsGroup(
              label: l.t15_reviewImport,
              children: [
                ListTile(
                  leading: const Icon(Icons.add_circle_outline),
                  title: Text(l.t15_additions),
                  trailing: Text('${plan.additions}'),
                ),
                ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: Text(l.t15_identical),
                  trailing: Text('${plan.identical}'),
                ),
                ListTile(
                  leading: const Icon(Icons.schedule_outlined),
                  title: Text(l.t15_conflicts),
                  trailing: Text('${plan.conflicts}'),
                ),
                ListTile(
                  title: Text(l.t15_retained),
                  trailing: Text('${plan.retainedWork}'),
                ),
                if (plan.preferenceChanges.isNotEmpty)
                  ExpansionTile(
                    title: Text(l.t15_preferencesChanged),
                    children: [
                      for (final change in plan.preferenceChanges)
                        ListTile(
                          title: Text(change.key),
                          subtitle: Text('${change.before} → ${change.after}'),
                        ),
                    ],
                  ),
              ],
            ),
            for (final difference in plan.doseConflicts)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: ImportDoseConflictCard(
                  conflict: difference,
                  onReview: () => _protectedDialog<void>(
                    builder: (context) =>
                        ImportDoseDifferenceDialog(conflict: difference),
                  ),
                ),
              ),
            const SizedBox(height: 16),
            CalmNotice(
              text: _busy ? l.t15_applying : l.t15_notImported,
              icon: Icons.info_outline_rounded,
              live: true,
            ),
            const SizedBox(height: 16),
            if (plan.alreadyApplied) Text(l.t15_alreadyApplied),
            if (plan.mode == ImportMode.full)
              CheckboxListTile(
                value: _replacementAcknowledged,
                title: Text(l.t15_confirmReplace),
                onChanged: _busy
                    ? null
                    : (value) => setState(
                        () => _replacementAcknowledged = value ?? false,
                      ),
              ),
            FilledButton(
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                minimumSize: const Size(0, 52),
              ),
              onPressed:
                  _busy ||
                      (plan.mode == ImportMode.full &&
                          !_replacementAcknowledged)
                  ? null
                  : _apply,
              child: Text(
                plan.mode == ImportMode.full
                    ? l.t15_applyRestore
                    : l.t15_applyImport,
              ),
            ),
          ],
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: CalmNotice(text: _message!, live: true),
            ),
        ],
      ),
    );
    // Beside the list Back belongs to the Settings screen (see _syncPane).
    if (pane != null) return scaffold;
    return PopScope(
      canPop: _page == _BackupPage.overview && !isOnlyPage(context),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _busy) return;
        if (_page == _BackupPage.overview) {
          leaveToToday(context);
        } else {
          _stepBack();
        }
      },
      child: scaffold,
    );
  }

  String _outcome(ImportPersonOutcome outcome, AppLocalizations l) =>
      switch (outcome) {
        ImportPersonOutcome.added => l.t15_outcomeAdded,
        ImportPersonOutcome.merged => l.t15_outcomeMerged,
        ImportPersonOutcome.unchanged => l.t15_outcomeUnchanged,
        ImportPersonOutcome.needsReview => l.t15_outcomeReview,
        ImportPersonOutcome.locked => l.t15_outcomeLocked,
        ImportPersonOutcome.replaced => l.t15_outcomeReplaced,
      };
}
