import 'stable_component_adapter.dart';

class ProfilesSyncAdapter extends StableComponentAdapter {
  const ProfilesSyncAdapter(super.db);

  @override
  String get entityType => 'profile';
}
