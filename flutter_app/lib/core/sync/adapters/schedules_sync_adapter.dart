import 'stable_component_adapter.dart';

class SchedulesSyncAdapter extends StableComponentAdapter {
  const SchedulesSyncAdapter(super.db);

  @override
  String get entityType => 'schedule';
}
