import 'stable_component_adapter.dart';

class AccountSyncAdapter extends StableComponentAdapter {
  const AccountSyncAdapter(super.db);

  @override
  String get entityType => 'account';

  @override
  String get operationComponent => 'account';
}
