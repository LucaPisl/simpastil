import '../../../core/storage/layout_family_preference.dart';
import 'action_inbox_layout.dart';
import 'daily_journal_layout.dart';
import 'day_planner_layout.dart';
import 'people_lanes_layout.dart';
import 'today_layout.dart';
import 'timeline_layout.dart';

/// Today layouts other than Focus deck, one line per family. A family that
/// is not listed here is "not available yet": Today keeps showing Focus deck
/// and the chooser says so instead of applying it.
final Map<LayoutFamily, TodayLayoutBuilder> todayLayouts = {
  LayoutFamily.timeline: (context, data) => TimelineLayout(data: data),
  LayoutFamily.dayPlanner: (context, data) => DayPlannerLayout(data: data),
  LayoutFamily.peopleLanes: (context, data) => PeopleLanesLayout(data: data),
  LayoutFamily.actionInbox: (context, data) => ActionInboxLayout(data: data),
  LayoutFamily.dailyJournal: (context, data) => DailyJournalLayout(data: data),
};

bool layoutFamilyAvailable(LayoutFamily family) =>
    family == LayoutFamily.focusDeck || todayLayouts.containsKey(family);

/// The family Today actually shows for a stored choice.
LayoutFamily effectiveLayoutFamily(LayoutFamily stored) =>
    layoutFamilyAvailable(stored) ? stored : LayoutFamily.focusDeck;
