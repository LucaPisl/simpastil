import 'backup_service.dart';
import 'import_service.dart';

/// Binds preview and activation to one provider-selected document. Passwords
/// remain in this foreground session and are released when its caller closes it.
class BackupImportSession {
  BackupImportSession._(
    this._backup,
    this._source,
    this._password,
    this.checked,
  );
  final BackupService _backup;
  final SelectedBackupSource _source;
  final CheckedBackup checked;
  String? _password;
  bool _closed = false;
  late final ImportService _import;

  static Future<BackupImportSession> open({
    required BackupService backup,
    required SelectedBackupSource source,
    String? password,
    required Future<ImportService> Function(
      CheckedBackup checked,
      Future<CheckedBackup> Function(CheckedBackup) recheck,
    )
    buildImport,
  }) async {
    final checked = await backup.checkSource(source, password: password);
    final session = BackupImportSession._(backup, source, password, checked);
    try {
      session._import = await buildImport(checked, session._recheck);
      return session;
    } catch (_) {
      session.close();
      rethrow;
    }
  }

  void _requireOpen() {
    if (_closed) throw const ImportFailure(ImportFailureCode.invalidSelection);
  }

  Future<CheckedBackup> _recheck(CheckedBackup _) {
    _requireOpen();
    return _backup.checkSource(_source, password: _password);
  }

  Future<ImportPlan> preview(ImportSelection selection) {
    _requireOpen();
    return _import.preview(checked, selection);
  }

  Future<ImportResult> apply(ImportPlan plan) {
    _requireOpen();
    return _import.apply(plan);
  }

  void close() {
    _closed = true;
    _password = null;
  }
}
