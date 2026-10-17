import 'package:drift/drift.dart';

/// Opens like Drift's [LazyDatabase], but a failed opening is not final.
///
/// [LazyDatabase] keeps the first opener failure for its whole life, so a care
/// store refused once (for example while another engine was still preparing
/// it) stayed unavailable until the process restarted, and "Try again" could
/// never succeed. Here the next query after a failed opening runs the opener
/// again. A failed opener has returned no connection, so there is nothing to
/// close; an opened connection is never replaced.
class ReopenableLazyDatabase extends QueryExecutor {
  ReopenableLazyDatabase(this._opener, {this.onReopened}) {
    _current = _Attempt(_opener);
  }

  final DatabaseOpener _opener;

  /// Called once when an opening succeeds after an earlier one failed, so
  /// state that recorded the refusal can be checked again.
  final void Function()? onReopened;
  late _Attempt _current;

  @override
  SqlDialect get dialect => SqlDialect.sqlite;

  @override
  Future<bool> ensureOpen(QueryExecutorUser user) async {
    final attempt = _current;
    final bool opened;
    try {
      opened = await attempt.database.ensureOpen(user);
    } on Object {
      if (attempt.openerFailed && identical(attempt, _current)) {
        _current = _Attempt(_opener, afterRefusal: true);
      }
      rethrow;
    }
    if (attempt.afterRefusal && !attempt.announced) {
      attempt.announced = true;
      onReopened?.call();
    }
    return opened;
  }

  @override
  QueryExecutor beginExclusive() => _current.database.beginExclusive();

  @override
  TransactionExecutor beginTransaction() =>
      _current.database.beginTransaction();

  @override
  Future<void> runBatched(BatchedStatements statements) =>
      _current.database.runBatched(statements);

  @override
  Future<void> runCustom(String statement, [List<Object?>? args]) =>
      _current.database.runCustom(statement, args);

  @override
  Future<int> runDelete(String statement, List<Object?> args) =>
      _current.database.runDelete(statement, args);

  @override
  Future<int> runInsert(String statement, List<Object?> args) =>
      _current.database.runInsert(statement, args);

  @override
  Future<List<Map<String, Object?>>> runSelect(
    String statement,
    List<Object?> args,
  ) => _current.database.runSelect(statement, args);

  @override
  Future<int> runUpdate(String statement, List<Object?> args) =>
      _current.database.runUpdate(statement, args);

  @override
  Future<void> close() async {
    final attempt = _current;
    try {
      await attempt.database.close();
    } on Object {
      // Drift otherwise rethrows the rejected opener during disposal, although
      // no delegate was returned and no normal connection exists to close.
      if (!attempt.openerFailed) rethrow;
    }
  }
}

class _Attempt {
  _Attempt(DatabaseOpener opener, {this.afterRefusal = false}) {
    database = LazyDatabase(() async {
      try {
        return await opener();
      } on Object {
        openerFailed = true;
        rethrow;
      }
    });
  }

  late final LazyDatabase database;
  final bool afterRefusal;
  bool openerFailed = false;
  bool announced = false;
}
