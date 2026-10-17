import 'stable_component_adapter.dart';

class PillsSyncAdapter extends StableComponentAdapter {
  const PillsSyncAdapter(super.db);

  @override
  String get entityType => 'pill';
}
