// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Simpastil';

  @override
  String get appSubtitle => 'Your medication companion';

  @override
  String get shared_cancel => 'Cancel';

  @override
  String get shared_save => 'Save';

  @override
  String get shared_retry => 'Retry';

  @override
  String get shared_delete => 'Delete';

  @override
  String get shared_close => 'Close';

  @override
  String get shared_change => 'Change';

  @override
  String get shared_continue => 'Continue';

  @override
  String get shared_skip => 'Skip';

  @override
  String get shared_done => 'Done';

  @override
  String get shared_all => 'All';

  @override
  String get shared_none => 'None';

  @override
  String get shared_add => 'Add';

  @override
  String get shared_grant => 'Grant';

  @override
  String get shared_loading => 'Loading…';

  @override
  String get shared_unknown => 'Unknown';

  @override
  String get shared_enabled => 'Enabled';

  @override
  String get shared_disabled => 'Disabled';

  @override
  String get shared_cancelDeletion => 'Cancel deletion';

  @override
  String shared_confirmAction(String action) {
    return 'Confirm $action';
  }

  @override
  String get shared_somethingWentWrong =>
      'Something went wrong. Please try again.';

  @override
  String get shared_syncFailed => 'Sync failed — check connection';

  @override
  String get shared_unlock => 'Unlock';

  @override
  String get shared_unlockSimpastil => 'Unlock Simpastil';

  @override
  String get auth_tagline => 'Your medication companion';

  @override
  String get auth_stepServer => 'STEP 1 OF 3 — SERVER';

  @override
  String get auth_stepApiKey => 'STEP 2 OF 3 — API KEY';

  @override
  String get auth_stepAccount => 'STEP 3 OF 3 — ACCOUNT';

  @override
  String get auth_connectToServer => 'Connect to your server';

  @override
  String get auth_enterServerAddress =>
      'Enter the address of your Simpastil server';

  @override
  String get auth_serverAddressLabel => 'SERVER ADDRESS';

  @override
  String get auth_serverAddress => 'Server address';

  @override
  String get auth_serverMustUseHttps => 'Server address must use HTTPS.';

  @override
  String get auth_couldNotReachServer =>
      'Could not reach server — check the address and try again.';

  @override
  String get auth_connect => 'Connect';

  @override
  String auth_connectedTo(String hostname) {
    return '✓ Connected — $hostname';
  }

  @override
  String get auth_enterApiKey => 'Enter your API key';

  @override
  String get auth_apiKeyHint =>
      'Your server admin will have provided this key.';

  @override
  String get auth_apiKeyLabel => 'API Key';

  @override
  String get auth_verifyKey => 'Verify key';

  @override
  String get auth_pleaseEnterApiKey => 'Please enter your API key';

  @override
  String get auth_keyRevoked =>
      'This API key has been revoked. Contact your admin.';

  @override
  String get auth_unexpectedServerResponse => 'Unexpected server response.';

  @override
  String get auth_invalidApiKey => 'Invalid API key.';

  @override
  String get auth_couldNotReachServerShort => 'Could not reach server.';

  @override
  String get auth_unexpectedError => 'Unexpected error.';

  @override
  String get auth_createAccount => 'Create account';

  @override
  String get auth_signIn => 'Sign in';

  @override
  String get auth_choosePassword => 'Choose a password for your new account';

  @override
  String get auth_useCredentials => 'Use your account credentials';

  @override
  String get auth_emailAddress => 'Email address';

  @override
  String get auth_password => 'Password';

  @override
  String get auth_hidePassword => 'Hide password';

  @override
  String get auth_showPassword => 'Show password';

  @override
  String get auth_enterValidEmail => 'Enter a valid email address';

  @override
  String get auth_passwordRequired => 'Password is required';

  @override
  String get auth_incorrectCredentials => 'Incorrect email or password';

  @override
  String get auth_tooManyAttempts =>
      'Too many attempts. Please try again later.';

  @override
  String get auth_noConnection => 'No connection. Check your network.';

  @override
  String get auth_emailAlreadyRegistered =>
      'Email already registered — or this API key is already linked to an account. Try signing in.';

  @override
  String get auth_keyBelongsToDifferentAccount =>
      'This API key belongs to a different account.';

  @override
  String get auth_forgotPassword => 'Forgot password?';

  @override
  String get auth_createAccountButton => 'CREATE ACCOUNT';

  @override
  String get auth_logInButton => 'LOG IN';

  @override
  String get auth_useDifferentKey => 'Use a different API key';

  @override
  String get auth_checkEmail => 'Check your email';

  @override
  String get auth_resetLinkSent =>
      'If that email is registered, a reset link has been sent.';

  @override
  String get auth_backToLogin => 'Back to login';

  @override
  String get auth_resetPassword => 'Reset password';

  @override
  String get auth_enterEmailForReset =>
      'Enter your email to receive a reset link';

  @override
  String get auth_sendResetLink => 'Send reset link';

  @override
  String get auth_nameThisDevice => 'Name this device';

  @override
  String get auth_whatShouldDeviceBeCalled =>
      'What should this device be called?';

  @override
  String get auth_deviceNameHelp =>
      'This helps you identify it in the admin panel.';

  @override
  String get auth_deviceNameLabel => 'Device name';

  @override
  String get core_notifChannelName => 'Dose Reminders';

  @override
  String get core_notifChannelDesc => 'Gentle nudges when a dose is due';

  @override
  String get core_notifActionTaken => 'Taken';

  @override
  String get core_notifActionSnooze => 'Snooze';

  @override
  String get core_notifActionSkip => 'Skip';

  @override
  String core_notifTitle(String pillName) {
    return 'Time for $pillName';
  }

  @override
  String get core_notifSnoozed => 'Back again, as you asked';

  @override
  String get dashboard_goodMorning => 'Good morning';

  @override
  String get dashboard_goodAfternoon => 'Good afternoon';

  @override
  String get dashboard_goodEvening => 'Good evening';

  @override
  String get dashboard_today => 'Today';

  @override
  String get dashboard_yesterday => 'Yesterday';

  @override
  String dashboard_pillsTaken(int taken, int total) {
    return '$taken of $total pills taken';
  }

  @override
  String get dashboard_somethingWentWrong => 'Something went wrong';

  @override
  String get dashboard_selectProfile => 'Select a profile to see your schedule';

  @override
  String get dashboard_nothingScheduledToday => 'Nothing scheduled for today';

  @override
  String get dashboard_nothingScheduledThisDay =>
      'Nothing scheduled on this day';

  @override
  String get dashboard_asNeeded => 'AS NEEDED';

  @override
  String get dashboard_notTakenToday => 'Not taken today';

  @override
  String dashboard_takenTimesToday(int count) {
    return 'Taken $count× today';
  }

  @override
  String get dashboard_logDose => 'Log dose';

  @override
  String get dashboard_syncFailingTooltip => 'Sync failing — tap for details';

  @override
  String get dashboard_backToToday => 'Back to today';

  @override
  String get dashboard_previousDay => 'Previous day';

  @override
  String get dashboard_nextDay => 'Next day';

  @override
  String dashboard_scheduledTime(String time) {
    return 'Scheduled: $time';
  }

  @override
  String get dashboard_noteLabel => 'Note';

  @override
  String get dashboard_noteHint => 'Add a note for this dose…';

  @override
  String get dashboard_statusTaken => 'Taken';

  @override
  String get dashboard_statusMissed => 'Missed';

  @override
  String get dashboard_statusSkipped => 'Skipped';

  @override
  String get dashboard_statusPending => 'Pending';

  @override
  String get dashboard_statusTakenBadge => '✓ Taken';

  @override
  String get dashboard_statusMissedBadge => '✗ Missed';

  @override
  String get dashboard_statusSkippedBadge => 'Skipped';

  @override
  String get dashboard_statusPendingBadge => 'Pending';

  @override
  String get history_calendar => 'Calendar';

  @override
  String get history_list => 'List';

  @override
  String get history_exportTooltip => 'Export dose history';

  @override
  String get history_couldNotLoad => 'Could not load history';

  @override
  String people_dayProgress(Object planned, Object taken) {
    return '$taken of $planned taken today';
  }

  @override
  String history_quietDay(Object date) {
    return 'Nothing recorded on $date';
  }

  @override
  String get history_quietDayBody =>
      'No dose was planned or recorded for this day on this phone. That does not mean care was missed.';

  @override
  String history_earlierRecords(Object date) {
    return 'Earlier: $date';
  }

  @override
  String history_laterRecords(Object date) {
    return 'Later: $date';
  }

  @override
  String get history_noHistory => 'No history yet';

  @override
  String history_takenAt(String time) {
    return 'taken at $time';
  }

  @override
  String history_scheduledAt(String time) {
    return 'Scheduled $time';
  }

  @override
  String get history_noDoses => 'no doses';

  @override
  String history_adherence(String percent) {
    return '$percent adherence';
  }

  @override
  String history_ribbonDay(String date, int taken, int total) {
    return '$date, $taken of $total planned doses taken';
  }

  @override
  String history_ribbonDayEmpty(String date) {
    return '$date, no planned doses';
  }

  @override
  String history_unseenTitle(String name) {
    return 'Before $name was on this phone';
  }

  @override
  String get history_unseenTitleAll => 'Before care began on this phone';

  @override
  String history_unseenBody(String name, String date) {
    return '$name has been on this phone since $date. Days before that have no records here.';
  }

  @override
  String history_unseenBodyAll(String date) {
    return 'Care on this phone began on $date. Days before that have no records here.';
  }

  @override
  String history_ribbonDayUnseen(String date, String name) {
    return '$date, before $name was on this phone';
  }

  @override
  String history_ribbonDayUnseenAll(String date) {
    return '$date, before care began on this phone';
  }

  @override
  String history_lineDose(
    String time,
    String medication,
    String person,
    String outcome,
  ) {
    return '$time · $medication for $person · $outcome';
  }

  @override
  String people_lineDose(String time, String medication, String outcome) {
    return '$time · $medication · $outcome';
  }

  @override
  String history_lineCluster(int count, String time) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count doses around $time',
      one: '1 dose around $time',
    );
    return '$_temp0';
  }

  @override
  String get pills_title => 'Pills';

  @override
  String get pills_edit => 'Edit';

  @override
  String pills_deleteCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Delete $count pills?',
      one: 'Delete 1 pill?',
    );
    return '$_temp0';
  }

  @override
  String pills_deleteConfirmMessage(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'This will also remove all schedules and reminders for these pills. This cannot be undone.',
      one:
          'This will also remove all schedules and reminders for this pill. This cannot be undone.',
    );
    return '$_temp0';
  }

  @override
  String pills_deletedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count pills deleted',
      one: '1 pill deleted',
    );
    return '$_temp0';
  }

  @override
  String get pills_couldNotLoad => 'Could not load pills.';

  @override
  String get pills_noPillsYet => 'No pills yet';

  @override
  String get pills_addFirstSubtitle => 'Add your first pill to get started.';

  @override
  String get pills_addFirstCta => 'Add your first pill';

  @override
  String get pills_noEnabledProfiles => 'No enabled profiles';

  @override
  String get pills_enableProfileHint =>
      'Enable at least one profile in Profiles.';

  @override
  String pills_todayAt(String time) {
    return 'Today at $time';
  }

  @override
  String pills_tomorrowAt(String time) {
    return 'Tomorrow at $time';
  }

  @override
  String pills_weekdayAt(String weekday, String time) {
    return '$weekday at $time';
  }

  @override
  String get pills_noActiveSchedules => 'No active schedules';

  @override
  String get pills_daily => 'Daily';

  @override
  String get pills_custom => 'Custom';

  @override
  String pills_stockLeft(int stock) {
    return '$stock left';
  }

  @override
  String get pills_noSchedulesYet => 'No schedules yet';

  @override
  String get pills_addSchedule => 'Add schedule';

  @override
  String get pills_deletePill => 'Delete pill?';

  @override
  String pills_deletePillMessage(String name) {
    return 'Deleting \"$name\" will also remove all its schedules and cancel its reminders. This cannot be undone.';
  }

  @override
  String get pills_couldNotDelete => 'Could not delete pill';

  @override
  String get pills_deleteSelectedTooltip => 'Delete selected pills';

  @override
  String get pills_addPillTooltip => 'Add pill';

  @override
  String get pills_editPillTooltip => 'Edit pill';

  @override
  String get pills_deletePillTooltip => 'Delete pill';

  @override
  String get pills_editScheduleTooltip => 'Edit schedule';

  @override
  String get pills_deleteScheduleTooltip => 'Delete schedule';

  @override
  String get pills_deleteScheduleTitle => 'Delete schedule?';

  @override
  String pills_deleteScheduleMessage(String frequency, String time) {
    return 'Remove the $frequency reminder at $time? This cannot be undone.';
  }

  @override
  String get pills_couldNotDeleteSchedule => 'Could not delete schedule';

  @override
  String get pills_editPillTitle => 'Edit Pill';

  @override
  String get pills_newPillTitle => 'New Pill';

  @override
  String get pills_nameRequired => 'Name is required';

  @override
  String get pills_nameLabel => 'Name *';

  @override
  String get pills_dosageLabel => 'Dosage (e.g. 10 mg)';

  @override
  String get pills_notesLabel => 'Notes';

  @override
  String get pills_colorLabel => 'Color';

  @override
  String get pills_inventoryLabel => 'Inventory';

  @override
  String get pills_trackStock => 'Track stock';

  @override
  String get pills_trackStockSubtitle => 'Get notified when running low';

  @override
  String get pills_currentStock => 'Current stock';

  @override
  String get pills_alertWhenBelow => 'Alert when below';

  @override
  String get pills_required => 'Required';

  @override
  String get pills_enterANumber => 'Enter a number';

  @override
  String get pills_scheduleType => 'Schedule type';

  @override
  String get pills_asNeededPrn => 'As-needed (PRN)';

  @override
  String get pills_asNeededSubtitle => 'No fixed schedule — log doses manually';

  @override
  String get pills_updateProfiles => 'Update profiles';

  @override
  String get pills_assignToProfiles => 'Assign to profiles';

  @override
  String get pills_selectAtLeastOneProfile => 'Select at least one profile';

  @override
  String pills_addedToProfiles(int count) {
    return 'Added to $count profile(s); some failed to sync.';
  }

  @override
  String pills_alsoUpdateSiblings(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Also update $count other profiles',
      one: 'Also update 1 other profile',
    );
    return '$_temp0';
  }

  @override
  String get pills_applyChangesTo => 'Apply changes to:';

  @override
  String get pills_fieldName => 'Name';

  @override
  String get pills_fieldDosage => 'Dosage';

  @override
  String get pills_fieldNotes => 'Notes';

  @override
  String get pills_fieldColor => 'Color';

  @override
  String get pills_noProfilesAvailable =>
      'No profiles available yet. Create a profile first.';

  @override
  String pills_savedCouldNotUpdateSiblings(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Saved. Could not update $count siblings.',
      one: 'Saved. Could not update 1 sibling.',
    );
    return '$_temp0';
  }

  @override
  String get schedules_screenTitle => 'Schedules';

  @override
  String get schedules_couldNotLoad => 'Could not load schedules.';

  @override
  String get schedules_emptyTitle => 'No schedules yet';

  @override
  String get schedules_emptySubtitle =>
      'Enable a profile and add pills to create schedules.';

  @override
  String get schedules_noSchedulesYet => 'No schedules yet';

  @override
  String get schedules_addSchedule => 'Add schedule';

  @override
  String get schedules_editScheduleTooltip => 'Edit schedule';

  @override
  String get schedules_deleteScheduleTooltip => 'Delete schedule';

  @override
  String get schedules_deleteScheduleTitle => 'Delete schedule?';

  @override
  String schedules_deleteScheduleMessage(String frequency, String time) {
    return 'Remove the $frequency reminder at $time? This cannot be undone.';
  }

  @override
  String get schedules_custom => 'Custom';

  @override
  String get schedules_editTitle => 'Edit Schedule';

  @override
  String get schedules_newTitle => 'New Schedule';

  @override
  String get schedules_timeLabel => 'Time';

  @override
  String schedules_timeSemantic(String time) {
    return 'Schedule time, $time. Tap to change';
  }

  @override
  String get schedules_frequencyLabel => 'Frequency';

  @override
  String get schedules_daily => 'Daily';

  @override
  String get schedules_specificDays => 'Specific days';

  @override
  String schedules_frequencySemantic(String frequency) {
    return 'Frequency: $frequency';
  }

  @override
  String get schedules_active => 'Active';

  @override
  String get schedules_paused => 'paused';

  @override
  String get schedules_activeSubtitle => 'Turn off to pause without deleting';

  @override
  String get schedules_selectAtLeastOneDay => 'Please select at least one day';

  @override
  String get schedules_dayMon => 'Mon';

  @override
  String get schedules_dayTue => 'Tue';

  @override
  String get schedules_dayWed => 'Wed';

  @override
  String get schedules_dayThu => 'Thu';

  @override
  String get schedules_dayFri => 'Fri';

  @override
  String get schedules_daySat => 'Sat';

  @override
  String get schedules_daySun => 'Sun';

  @override
  String get profiles_title => 'Profiles';

  @override
  String get profiles_addTooltip => 'Add profile';

  @override
  String get profiles_couldNotLoad => 'Could not load profiles.';

  @override
  String get profiles_noProfYet => 'No profiles yet';

  @override
  String get profiles_createToGetStarted => 'Create a profile to get started.';

  @override
  String get profiles_createFirstCta => 'Create your first profile';

  @override
  String profiles_pillCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count pills',
      one: '1 pill',
    );
    return '$_temp0';
  }

  @override
  String get profiles_active => 'Active';

  @override
  String get profiles_inactive => 'Inactive';

  @override
  String get profiles_primary => 'Primary';

  @override
  String profiles_deleteTitle(String name) {
    return 'Delete $name?';
  }

  @override
  String profiles_deleteMessage(String name) {
    return 'This will permanently delete all pills, schedules and dose history assigned to $name.';
  }

  @override
  String profiles_pillsOverviewTitle(String name) {
    return '$name — Pills';
  }

  @override
  String get profiles_couldNotLoadPills => 'Could not load pills.';

  @override
  String get profiles_noPillsAssigned => 'No pills assigned to this profile';

  @override
  String get profiles_noSchedule => 'No schedule';

  @override
  String get profiles_editTitle => 'Edit Profile';

  @override
  String get profiles_newTitle => 'New Profile';

  @override
  String get profiles_nameLabel => 'Name';

  @override
  String get profiles_nameRequired => 'Name is required';

  @override
  String get profiles_avatarLabel => 'Avatar';

  @override
  String profiles_avatarSelected(String emoji) {
    return 'Avatar $emoji, selected';
  }

  @override
  String profiles_avatarUnselected(String emoji) {
    return 'Avatar $emoji';
  }

  @override
  String get profiles_primaryProfile => 'Primary profile';

  @override
  String get profiles_setAsPrimary => 'Set as primary profile';

  @override
  String get profiles_deleteProfile => 'Delete profile';

  @override
  String get profiles_deleted => 'Profile deleted';

  @override
  String get profiles_failedToDelete => 'Failed to delete profile';

  @override
  String get settings_title => 'Settings';

  @override
  String get settings_appearance => 'Appearance';

  @override
  String get settings_primaryProfile => 'Primary Profile';

  @override
  String get settings_pillEditing => 'Pill Editing';

  @override
  String get settings_account => 'Account';

  @override
  String get settings_server => 'Server';

  @override
  String get settings_session => 'Session';

  @override
  String get settings_notifications => 'Notifications';

  @override
  String get settings_asNeededMeds => 'As-needed medications';

  @override
  String get settings_data => 'Sync';

  @override
  String get settings_about => 'About';

  @override
  String get settings_theme => 'Theme';

  @override
  String get settings_themeAuto => 'Auto';

  @override
  String get settings_themeLight => 'Light';

  @override
  String get settings_themeDark => 'Dark';

  @override
  String get settings_dynamicColor => 'Dynamic Color';

  @override
  String get settings_dynamicColorSubtitle => 'Uses your wallpaper colors';

  @override
  String get settings_fontSize => 'Font Size';

  @override
  String get settings_fontDefault => 'Default';

  @override
  String get settings_fontLarge => 'Large';

  @override
  String get settings_fontXL => 'XL';

  @override
  String get settings_highContrast => 'High Contrast';

  @override
  String get settings_highContrastSubtitle => 'Bolder text, thicker borders';

  @override
  String get settings_reduceMotion => 'Reduce motion';

  @override
  String get settings_reduceMotionHint =>
      'Things appear in place instead of moving. Words and vibrations stay the same.';

  @override
  String get settings_reduceMotionByPhone =>
      'On because of your phone\'s accessibility settings.';

  @override
  String get settings_language => 'Language';

  @override
  String get settings_languageSystem => 'System default';

  @override
  String get settings_languageEnglish => 'English';

  @override
  String get settings_languageRomanian => 'Română';

  @override
  String get recordedBy_title => 'Recorded by';

  @override
  String get recordedBy_primary => 'The primary profile';

  @override
  String get recordedBy_custom => 'A name I type';

  @override
  String get recordedBy_person => 'The person taking it';

  @override
  String get recordedBy_nameLabel => 'Name';

  @override
  String get recordedBy_save => 'Save name';

  @override
  String get recordedBy_saved => 'Saved';

  @override
  String get recordedBy_saveFailed => 'Could not save the name';

  @override
  String get recordedBy_explainer =>
      'Applies to doses recorded from now on. Earlier records keep their name.';

  @override
  String get recordedBy_personNote =>
      'This names the person the dose belongs to, even if someone else recorded it.';

  @override
  String get settings_couldNotLoadPrimary => 'Could not load primary profile';

  @override
  String get settings_couldNotLoadProfiles => 'Could not load profiles';

  @override
  String get settings_noProfilesAvailable => 'No profiles available';

  @override
  String get settings_createProfileFirst => 'Create a profile first.';

  @override
  String get settings_siblingDetection => 'Sibling detection';

  @override
  String get settings_siblingDetectionSubtitle =>
      'When editing a pill, detect copies in other profiles';

  @override
  String get settings_siblingName => 'Name';

  @override
  String get settings_siblingNameDosage => 'Name + dosage';

  @override
  String get settings_siblingAlwaysAsk => 'Always ask';

  @override
  String get settings_changePassword => 'Change password';

  @override
  String get settings_connectedServer => 'Connected server';

  @override
  String get settings_deviceName => 'Device name';

  @override
  String get settings_notSet => 'Not set';

  @override
  String get settings_deviceNameHint => 'e.g. My Phone';

  @override
  String get settings_logOut => 'Log out';

  @override
  String get settings_logOutSubtitle =>
      'Clear local tokens and end this session';

  @override
  String get settings_snoozeDuration => 'Snooze duration';

  @override
  String get settings_snoozeSubtitle => 'How long reminders stay snoozed';

  @override
  String get settings_notificationSound => 'Notification sound';

  @override
  String get settings_notificationPermission => 'Notification permission';

  @override
  String get settings_permGranted => 'Granted';

  @override
  String get settings_permDenied => 'Denied';

  @override
  String get settings_permNotDetermined => 'Not determined';

  @override
  String get settings_openSettings => 'Open Settings';

  @override
  String get settings_exactAlarmPermission => 'Exact alarm permission';

  @override
  String get settings_exactAlarmDenied =>
      'Not granted — dose reminders will not fire';

  @override
  String get settings_batteryRestriction => 'Background battery restriction';

  @override
  String get settings_batteryRestrictionSubtitle =>
      'Samsung / Xiaomi / Huawei: go to Settings → Battery → Background usage limits and add this app to Never sleeping apps. Without this, the OS may silently erase scheduled reminders.';

  @override
  String get settings_appSettings => 'App settings';

  @override
  String get settings_includeInStats => 'Include in adherence stats';

  @override
  String get settings_includeInStatsSubtitle =>
      'Count as-needed (PRN) doses in adherence calculations and the home widget';

  @override
  String get settings_showPrnInWidget => 'Show in home widget';

  @override
  String get settings_showPrnInWidgetSubtitle =>
      'Display as-needed medications at the bottom of the widget dose list';

  @override
  String get settings_syncNow => 'Sync now';

  @override
  String get settings_syncNowSubtitle => 'Pull latest data from server';

  @override
  String get settings_syncFailing => 'Sync failing';

  @override
  String get settings_syncing => 'Syncing…';

  @override
  String get settings_synced => 'Synced';

  @override
  String get settings_syncAlreadyInProgress => 'Sync already in progress';

  @override
  String settings_syncFailedError(String error) {
    return 'Sync failed — $error';
  }

  @override
  String get settings_syncComplete => 'Sync complete';

  @override
  String settings_changesWaiting(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count changes waiting to sync',
      one: '1 change waiting to sync',
    );
    return '$_temp0';
  }

  @override
  String settings_changesNeedAttention(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count changes need your attention',
      one: '1 change needs your attention',
    );
    return '$_temp0';
  }

  @override
  String get sync_stockStaysOnPhone =>
      'Stock counts stay on this phone until your server turns on stock sync.';

  @override
  String settings_changesRetrying(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count changes will be retried automatically',
      one: '1 change will be retried automatically',
    );
    return '$_temp0';
  }

  @override
  String get settings_justNow => 'Just now';

  @override
  String settings_minutesAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count minutes ago',
      one: '1 minute ago',
    );
    return '$_temp0';
  }

  @override
  String settings_hoursAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count hours ago',
      one: '1 hour ago',
    );
    return '$_temp0';
  }

  @override
  String get settings_never => 'Never';

  @override
  String settings_failingSince(String time, String error) {
    return 'Failing since $time — $error';
  }

  @override
  String settings_retrying(String error) {
    return 'Retrying — $error';
  }

  @override
  String get settings_syncInProgress => 'Sync in progress';

  @override
  String get settings_deleteAProfile => 'Delete a profile';

  @override
  String get settings_deleteAProfileSubtitle =>
      'Permanently remove a profile and all its data';

  @override
  String get settings_noProfilesToDelete => 'No profiles to delete';

  @override
  String settings_deleteProfileCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Delete $count profiles?',
      one: 'Delete 1 profile?',
    );
    return '$_temp0';
  }

  @override
  String settings_deleteProfileConfirm(String names) {
    return 'This will permanently delete $names and all their pills, schedules, and dose history.';
  }

  @override
  String get settings_profilesDeleted => 'Profiles deleted';

  @override
  String get settings_deleteSelected => 'Delete selected';

  @override
  String get settings_appVersion => 'App version';

  @override
  String get settings_changePasswordTitle => 'Change password';

  @override
  String get settings_currentPassword => 'Current password';

  @override
  String get settings_newPassword => 'New password';

  @override
  String get settings_confirmNewPassword => 'Confirm new password';

  @override
  String get settings_currentPasswordRequired => 'Current password is required';

  @override
  String get settings_newPasswordRequired => 'New password is required';

  @override
  String get settings_passwordMinLength =>
      'Password must be at least 10 characters';

  @override
  String get settings_passwordMustDiffer =>
      'New password must differ from current password';

  @override
  String get settings_confirmPasswordRequired =>
      'Please confirm your new password';

  @override
  String get settings_passwordsDoNotMatch => 'Passwords do not match';

  @override
  String get settings_updatePassword => 'Update password';

  @override
  String get settings_passwordUpdated => 'Password updated';

  @override
  String get settings_currentPasswordIncorrect =>
      'Current password is incorrect';

  @override
  String get settings_minutesLabel => 'Minutes';

  @override
  String settings_minutesRange(int min, int max) {
    return 'Enter a value between $min and $max';
  }

  @override
  String settings_valueMin(int value) {
    return '$value min';
  }

  @override
  String settings_rangeMin(int min, int max) {
    return '$min..$max min';
  }

  @override
  String settings_decreaseTooltip(String title) {
    return 'Decrease $title';
  }

  @override
  String settings_increaseTooltip(String title) {
    return 'Increase $title';
  }

  @override
  String get analytics_last7Days => 'Last 7 days';

  @override
  String get analytics_last30Days => 'Last 30 days';

  @override
  String get analytics_weeklyTrend => 'Weekly trend';

  @override
  String get analytics_byPill30Days => 'By medication (30 days)';

  @override
  String get analytics_noDosesLast30 => 'No doses in the last 30 days';

  @override
  String get analytics_thisWeek => 'This week';

  @override
  String get analytics_noData => 'no data';

  @override
  String get analytics_couldNotLoadStats => 'Could not load stats';

  @override
  String get analytics_previousMonth => 'Previous month';

  @override
  String get analytics_nextMonth => 'Next month';

  @override
  String get export_title => 'Export Dose History';

  @override
  String export_profile(String name) {
    return 'Profile: $name';
  }

  @override
  String get export_dateRange => 'Date Range';

  @override
  String get export_last7Days => 'Last 7 days';

  @override
  String get export_last30Days => 'Last 30 days';

  @override
  String get export_last3Months => 'Last 3 months';

  @override
  String get export_custom => 'Custom…';

  @override
  String get export_format => 'Format';

  @override
  String get export_both => 'Both';

  @override
  String get export_generating => 'Generating…';

  @override
  String get export_exportAndShare => 'Export & Share';

  @override
  String export_failed(String error) {
    return 'Export failed: $error';
  }

  @override
  String get colors_coral => 'Coral';

  @override
  String get colors_amber => 'Amber';

  @override
  String get colors_yellow => 'Yellow';

  @override
  String get colors_green => 'Green';

  @override
  String get colors_teal => 'Teal';

  @override
  String get colors_blue => 'Blue';

  @override
  String get colors_lavender => 'Lavender';

  @override
  String get colors_grey => 'Grey';

  @override
  String get colors_rose => 'Rose';

  @override
  String get colors_peach => 'Peach';

  @override
  String get colors_mint => 'Mint';

  @override
  String get colors_indigo => 'Indigo';

  @override
  String get nav_home => 'Home';

  @override
  String get nav_profiles => 'Profiles';

  @override
  String get nav_pills => 'Pills';

  @override
  String get nav_schedules => 'Schedules';

  @override
  String get nav_logs => 'Logs';

  @override
  String get nav_settings => 'Settings';

  @override
  String get nav_pressBackAgain => 'Press Back again to exit';

  @override
  String get onboarding_welcome => 'Welcome to Simpastil!';

  @override
  String get onboarding_subtitle =>
      'Let\'s set up your first medication so you never miss a dose.';

  @override
  String get onboarding_addPill => 'Add a pill';

  @override
  String get onboarding_exploreLater => 'Explore first';

  @override
  String get dashboard_emptyNoPillsSubtitle =>
      'Add your first pill and schedule to see your daily doses here.';

  @override
  String get dashboard_emptyNoPillsCta => 'Add a pill';

  @override
  String get dashboard_emptyNoProfileSubtitle =>
      'Select or create a profile to get started.';

  @override
  String get dashboard_emptyNoProfileCta => 'Go to Profiles';

  @override
  String get history_emptySubtitle =>
      'Your dose history will appear here once you start logging.';

  @override
  String get schedules_emptyCta => 'Add a pill first';

  @override
  String get semantics_loading => 'Loading';

  @override
  String get semantics_selected => 'selected';

  @override
  String get semantics_notSelected => 'not selected';

  @override
  String semantics_doseMarked(String pill, String status) {
    return '$pill marked as $status';
  }

  @override
  String get settings_2faTitle => 'Two-factor authentication';

  @override
  String get settings_2faSubtitle => 'Add extra security to your account';

  @override
  String get settings_2faFlowTitle => 'Two-factor authentication';

  @override
  String get settings_2faDescription =>
      'Add an extra layer of security to your account by requiring a verification code from an authenticator app when you sign in.';

  @override
  String get settings_2faSetupButton => 'Set up 2FA';

  @override
  String get settings_2faStep1Label =>
      '1. Add this account to your authenticator app (Google Authenticator, Authy, etc.)';

  @override
  String get settings_2faManualKeyLabel => 'Manual entry key:';

  @override
  String get settings_2faStep2Label =>
      '2. Enter the 6-digit code from your authenticator app to verify';

  @override
  String get settings_2faCodeLabel => 'Code';

  @override
  String get settings_2faVerifyButton => 'Verify and enable';

  @override
  String get settings_2faSuccess => 'Two-factor authentication is now enabled!';

  @override
  String get settings_2faBackupCodesDescription =>
      'Save these backup codes in a safe place. You can use them to sign in if you lose access to your authenticator app. Each code can only be used once.';

  @override
  String get settings_2faBackupCodesCopied => 'Backup codes copied';

  @override
  String get settings_2faBackupCodesCopyButton => 'Copy';

  @override
  String get settings_2faBackupCodesDoneButton => 'Done';

  @override
  String get settings_2faDisabled => 'Two-factor authentication disabled';

  @override
  String get settings_2faDisableDescription =>
      'Enter your authenticator code or a backup code to disable two-factor authentication.';

  @override
  String get settings_2faDisableCodeLabel => 'Code';

  @override
  String get settings_2faDisableButton => 'Disable 2FA';

  @override
  String get settings_2faCodeRequired =>
      'Enter the code from your authenticator app';

  @override
  String get settings_2faCodeRequiredDisable =>
      'Enter your authenticator code to disable 2FA';

  @override
  String get shared_copiedToClipboard => 'Copied to clipboard';

  @override
  String get auth_2faStepLabel => 'Two-factor authentication';

  @override
  String get auth_2faEnterCodeTitle => 'Enter verification code';

  @override
  String get auth_2faCodeDescription =>
      'Open your authenticator app and enter the 6-digit code, or use a backup code.';

  @override
  String get auth_2faCodeLabel => 'Code';

  @override
  String get auth_2faCodeRequired => 'Enter your verification code';

  @override
  String get auth_2faVerifyButton => 'Verify';

  @override
  String get export_headerDate => 'Date';

  @override
  String get export_headerScheduledTime => 'Scheduled Time';

  @override
  String get export_headerPillName => 'Pill Name';

  @override
  String get export_headerDosage => 'Dosage';

  @override
  String get export_headerStatus => 'Status';

  @override
  String get export_headerTimeTaken => 'Time Taken';

  @override
  String get export_headerNotes => 'Notes';

  @override
  String get export_headerProfile => 'Profile';

  @override
  String get export_headerPill => 'Pill';

  @override
  String get export_headerTakenExpected => 'Taken / Expected';

  @override
  String get export_headerMissed => 'Missed';

  @override
  String get export_headerAdherence => 'Adherence';

  @override
  String get export_pdfTitle => 'Simpastil - Medication Report';

  @override
  String export_pdfProfile(String name) {
    return 'Profile: $name';
  }

  @override
  String export_pdfDateRange(String range) {
    return 'Date range: $range';
  }

  @override
  String export_pdfGenerated(String date) {
    return 'Generated: $date';
  }

  @override
  String get export_pdfDoseLog => 'Dose Log';

  @override
  String get export_pdfAdherenceSummary => 'Adherence Summary';

  @override
  String export_pdfOverallAdherence(String percent) {
    return 'Overall adherence: $percent';
  }

  @override
  String get export_pdfNoEntries => 'No dose entries for this date range.';

  @override
  String export_pdfPageNumber(int current, int total) {
    return 'Page $current of $total';
  }

  @override
  String get export_statusTaken => 'Taken';

  @override
  String get export_statusMissed => 'Missed';

  @override
  String get export_statusSkipped => 'Skipped';

  @override
  String get export_statusPending => 'Pending';

  @override
  String get export_prnLabel => 'PRN';

  @override
  String get widget_notAuthenticated => 'Open Simpastil to get started';

  @override
  String get widget_nothingScheduled => 'Nothing scheduled today';

  @override
  String widget_summary(int taken, int total) {
    return '$taken of $total taken';
  }

  @override
  String widget_moreDoses(int count) {
    return '+$count more';
  }

  @override
  String get widget_take => 'Take';

  @override
  String get error_noConnection =>
      'No internet connection. Changes saved locally.';

  @override
  String get error_sessionExpired => 'Session expired. Please log in again.';

  @override
  String get error_pillNotFound => 'Pill not found.';

  @override
  String get error_profileNotFound => 'Profile not found.';

  @override
  String error_serverError(int statusCode) {
    return 'Server error ($statusCode).';
  }

  @override
  String get t08_today => 'Today';

  @override
  String get t08_medications => 'Medications';

  @override
  String get t08_history => 'History';

  @override
  String get t08_people => 'People';

  @override
  String get t08_startTitle => 'A little care,\none day at a time.';

  @override
  String get t08_startBody =>
      'Keep medication and daily care together, privately on this device.';

  @override
  String get t08_start => 'Get started';

  @override
  String get t08_connect => 'Connect to shared care';

  @override
  String get t08_local => 'On this device';

  @override
  String get t08_personTitle => 'Who are we caring for?';

  @override
  String get t08_personBody =>
      'You can add more people later. Your name as the person recording care stays separate.';

  @override
  String get t08_personName => 'Person’s name';

  @override
  String get t08_personSave => 'Save person';

  @override
  String get t08_back => 'Back';

  @override
  String get t08_medicationTitle => 'Add a medication';

  @override
  String get t08_medicationBody =>
      'Start with its name. You can add a routine after saving.';

  @override
  String get t08_medicationName => 'Medication name';

  @override
  String get t08_strength => 'Package strength (optional)';

  @override
  String get t08_strengthHint => 'For example, 500 mg';

  @override
  String get t08_amount => 'Amount per use';

  @override
  String get t08_unknown => 'Not specified';

  @override
  String get t08_quantity => 'Quantity';

  @override
  String get t08_quantityHint => 'For example, 1 or 1/2';

  @override
  String get t08_unit => 'Unit';

  @override
  String get t08_unitHint => 'For example, tablet or mL';

  @override
  String get t08_amountHelp =>
      'Separate from package strength. Leave it unspecified if you are unsure.';

  @override
  String get t08_saveMedication => 'Save medication';

  @override
  String get t08_medicationSaved => 'Medication saved';

  @override
  String get t08_routineTitle => 'Make room for a routine';

  @override
  String get t08_routineBody =>
      'Your medication is already saved. Choose when it belongs in your day.';

  @override
  String get t08_addRoutine => 'Add a routine';

  @override
  String get t08_notNow => 'Not now';

  @override
  String get t08_daily => 'Every day';

  @override
  String get t08_time => 'Time';

  @override
  String get t08_addTime => 'Add another time';

  @override
  String get t08_removeTime => 'Remove time';

  @override
  String get t08_zone => 'Routine time zone';

  @override
  String get t08_zoneHelp =>
      'Review this place. Routine times stay in this time zone when you travel.';

  @override
  String get t08_preview => 'Review next dose';

  @override
  String get t08_reviewRoutine => 'Next dose';

  @override
  String get t08_phoneTimeUnavailable =>
      'Your phone’s time zone couldn’t be read. Try again to review the next dose.';

  @override
  String get t08_bucharest => 'Bucharest, Romania';

  @override
  String t08_savedPlaceTime(String time, String place) {
    return '$time $place time';
  }

  @override
  String t08_hereTime(String time) {
    return '$time here';
  }

  @override
  String get t08_effective => 'Starts from this review';

  @override
  String get t08_saveRoutine => 'Save routine';

  @override
  String get t08_routineSaved => 'Routine saved';

  @override
  String get t08_edit => 'Edit';

  @override
  String get t08_reminderTitle => 'Care comes first.';

  @override
  String get t08_reminderBody =>
      'Your care is saved. Reminders are optional and can be set up separately.';

  @override
  String get t08_readyTitle => 'Ready for your day.';

  @override
  String get t08_readyBody =>
      'Your person and medication are saved on this device. You can return to them anytime.';

  @override
  String get t08_openToday => 'Go to Today';

  @override
  String get t08_saving => 'Saving…';

  @override
  String get t08_saved => 'Saved on this device';

  @override
  String get t08_pendingShare => 'Saved here · waiting to share';

  @override
  String get t08_shared => 'Accepted by shared care';

  @override
  String get t08_reviewShare => 'Saved here · sharing needs review';

  @override
  String get t08_unavailable => 'Care is temporarily unavailable';

  @override
  String get t08_unavailableBody =>
      'Your saved care has not been replaced. Try again to open it.';

  @override
  String get t08_saveError =>
      'This could not be saved. Your existing care is safe. Try again.';

  @override
  String get t08_required => 'Enter a name to continue';

  @override
  String get t08_invalidAmount =>
      'Enter a positive quantity and an explicit unit';

  @override
  String get t08_invalidRoutine => 'Check the times and try the review again';

  @override
  String get t08_everyone => 'Everyone';

  @override
  String get t08_viewPerson => 'Viewing care for';

  @override
  String get t08_overview => 'Day overview';

  @override
  String get t08_previous => 'Previous';

  @override
  String get t08_next => 'Next';

  @override
  String get t08_takenNow => 'Taken now';

  @override
  String get t08_taken => 'Taken';

  @override
  String get t08_skipped => 'Skipped';

  @override
  String get t08_unrecorded => 'Not recorded';

  @override
  String get t08_undo => 'Undo';

  @override
  String get t08_unknownTime => 'Actual time unknown';

  @override
  String get t08_noPeople => 'Care starts with a person';

  @override
  String get t08_noMedications => 'A place for your medications';

  @override
  String get t08_noRoutine => 'Saved, without a routine';

  @override
  String get t08_noRoutineBody =>
      'Your medication is here. Add a routine when you are ready.';

  @override
  String get t08_dayOff => 'Nothing planned for this day';

  @override
  String get t08_dayOffBody =>
      'There are no planned doses on this routine’s calendar today.';

  @override
  String get t08_later => 'Coming up later';

  @override
  String get t08_recorded => 'Today, recorded';

  @override
  String get t08_recordError =>
      'This entry changed or could not be saved. Review it before trying again.';

  @override
  String get t08_undoStockUnchanged =>
      'Undone. The stock count was not changed, because this dose was counted before stock tracking started. Correct the stock by hand if needed.';

  @override
  String get t08_asNeeded => 'As needed';

  @override
  String get t08_asNeededBody =>
      'Your as-needed medication is saved. It has no planned dose quota.';

  @override
  String get t08_date => 'Choose day';

  @override
  String get t08_returnToday => 'Back to today';

  @override
  String get t08_finishLater => 'Save and finish later';

  @override
  String get t08_draftSaved => 'Progress saved';

  @override
  String get t08_scheduleTool => 'Schedules and connected tools';

  @override
  String t08_position(int current, int total) {
    return 'Item $current of $total';
  }

  @override
  String t08_remaining(int count) {
    return '$count still to record';
  }

  @override
  String t08_forPerson(String name) {
    return 'For $name';
  }

  @override
  String get core_notifPrivateTitle => 'A gentle reminder';

  @override
  String get core_notifPrivateBody => 'Open Simpastil when you have a moment.';

  @override
  String get core_notifTestTitle => 'This is how a reminder looks';

  @override
  String get core_notifTestBody =>
      'If you can see this, reminders reach you. Confirm it in Simpastil.';

  @override
  String get core_notifActionOpen => 'Open';

  @override
  String get t09_routine => 'Routine';

  @override
  String get t09_routineDetails => 'Routine details';

  @override
  String get t09_editRoutine => 'Edit routine';

  @override
  String get t09_pattern => 'When do you use it?';

  @override
  String get t09_weekdays => 'Selected weekdays';

  @override
  String get t09_interval => 'Every few days';

  @override
  String get t09_prn => 'As needed';

  @override
  String get t09_prnHelp =>
      'No expected daily doses. Record each use when it happens.';

  @override
  String get t09_everyDays => 'Number of calendar days';

  @override
  String get t09_anchor => 'Count from';

  @override
  String get t09_dates => 'Optional dates';

  @override
  String get t09_startDate => 'First day';

  @override
  String get t09_endDate => 'Last day (included)';

  @override
  String get t09_notSet => 'Not set';

  @override
  String get t09_clearDate => 'Remove date';

  @override
  String get t09_changesFrom => 'Changes from';

  @override
  String get t09_preserveRecords =>
      'Recorded doses keep their original details.';

  @override
  String get t09_before => 'Current routine';

  @override
  String get t09_after => 'Reviewed routine';

  @override
  String get t09_nextEntries => 'Next planned doses';

  @override
  String get t09_noPreview =>
      'No doses in the next 31 days. Review the pattern and dates before saving.';

  @override
  String get t09_reviewChanges => 'Review changes';

  @override
  String get t09_changeZone => 'Change time zone';

  @override
  String get t09_chooseZone => 'Choose a place';

  @override
  String get t09_unknownZone => 'Time zone needs review';

  @override
  String get sync_scheduleTimezoneReviewRequired =>
      'A routine time zone needs review. Choose a city or region.';

  @override
  String get t09_searchPlace => 'Search places';

  @override
  String get t09_zoneHelp =>
      'Times stay tied to this place when you travel. Changing it requires a new review.';

  @override
  String get t09_utc => 'Coordinated Universal Time';

  @override
  String get t09_noRoutine => 'Medication saved · No routine yet';

  @override
  String get t09_savedRoutine => 'Routine saved';

  @override
  String get t09_reviewConflict =>
      'Care changed during this review. Review again before saving. Your choices are still here.';

  @override
  String get t09_futureBoundary =>
      'Choose a future time under “Changes from”, then review again.';

  @override
  String get t09_legacyDosage => 'Original dosage text · Not reviewed';

  @override
  String get t09_reviewDetails => 'Review medication details';

  @override
  String get t09_editMedication => 'Edit medication';

  @override
  String get t09_form => 'Form (optional)';

  @override
  String get t09_notes => 'Notes (optional)';

  @override
  String get t09_connectedDetails =>
      'Reviewed amount, strength and form stay on this device. Shared medication changes are shown separately.';

  @override
  String get t09_savedPending => 'Saved here · Waiting to share';

  @override
  String get t09_viewCare => 'View care';

  @override
  String get t09_addMedication => 'Add medication for this person';

  @override
  String get t09_personSaved => 'Person saved';

  @override
  String get t09_remindersLater => 'Set up later';

  @override
  String get t09_allowReminders => 'Allow reminders';

  @override
  String get t09_checkReminders => 'Send a reminder check';

  @override
  String get t09_remindersAllowed =>
      'This phone allows reminders. Delivery has not been confirmed.';

  @override
  String get t09_remindersUnavailable =>
      'Reminders are not ready on this phone. Your saved care is available.';

  @override
  String get t09_checkScheduled =>
      'Check scheduled. Confirm only if you saw it on this phone.';

  @override
  String get t09_sawReminder => 'I saw the reminder';

  @override
  String get t09_deliveryConfirmed =>
      'You confirmed seeing the reminder on this phone.';

  @override
  String get t09_privacy => 'Show medication details in reminders';

  @override
  String get t09_reminderSummary =>
      'When off, reminders only ask you to open Simpastil.';

  @override
  String get t09_savedSummary => 'Saved on this device';

  @override
  String get t09_continueSetup => 'Continue setup';

  @override
  String t09_everyN(int days) {
    return 'Every $days calendar days';
  }

  @override
  String get t09_medicationAmountHelp =>
      'This is the medication’s default amount. Review the amount in each routine separately.';

  @override
  String get t10_details => 'Dose details';

  @override
  String get t10_recordDose => 'Record a dose';

  @override
  String get t10_recordedAmount => 'Recorded amount';

  @override
  String get t10_planned => 'Planned';

  @override
  String get t10_actual => 'Actual time';

  @override
  String get t10_entered => 'Recorded in Simpastil';

  @override
  String get t10_author => 'Recorded by';

  @override
  String get t10_unknownAuthor => 'Author unknown';

  @override
  String get t10_unnamedAuthor => 'Author name not recorded';

  @override
  String get t10_unknownDate => 'Date unknown';

  @override
  String get t10_unknownMedication => 'Medication details unavailable';

  @override
  String get t10_unknownPerson => 'Person unknown';

  @override
  String get t10_recordHistory => 'Record and corrections';

  @override
  String get t10_correct => 'Correct this record';

  @override
  String get t10_corrected => 'Correction';

  @override
  String get t10_withdrawn => 'Undo recorded';

  @override
  String get t10_skip => 'Record as skipped';

  @override
  String get t10_outcome => 'Outcome';

  @override
  String get t10_chooseTime => 'Choose a time';

  @override
  String get t10_timeHere => 'Time on this device';

  @override
  String get t10_reviewRecord => 'Review this record';

  @override
  String get t10_saveRecord => 'Save record';

  @override
  String get t10_recordAnother => 'Record another dose';

  @override
  String get t10_notes => 'Note (optional)';

  @override
  String get t10_noRecords => 'No records yet';

  @override
  String get t10_noRecordsBody =>
      'Recorded doses and corrections will appear here. This does not mean that care was missed.';

  @override
  String get t10_historyHint =>
      'Planned, actual and recorded times remain separate.';

  @override
  String get t10_legacy => 'Older record · some details are unknown';

  @override
  String get t10_readOnly =>
      'This retained record can be read, but cannot be changed here.';

  @override
  String get t10_select => 'Select doses';

  @override
  String get t10_selection => 'Review selected doses';

  @override
  String get t10_choosePerson => 'Choose one person before selecting doses.';

  @override
  String get t10_selectionHint =>
      'Only these exact doses will be recorded. New arrivals are not added.';

  @override
  String get t10_reviewSelection => 'Review selection';

  @override
  String get t10_recordSelected => 'Record selected doses';

  @override
  String get t10_savedItem => 'Saved';

  @override
  String get t10_retryItem => 'Not saved · retry available';

  @override
  String get t10_retryRemaining => 'Retry unsaved doses';

  @override
  String get t10_partial => 'Some doses were saved. Review each result below.';

  @override
  String get t10_allSaved => 'Every selected dose was saved.';

  @override
  String get t10_done => 'Done';

  @override
  String get t10_cancel => 'Cancel';

  @override
  String get t10_edit => 'Edit review';

  @override
  String get t10_timeInvalid => 'Check the chosen date and time.';

  @override
  String get t10_unrecordedHint =>
      'Unrecorded means no outcome has been recorded here. It does not mean missed.';

  @override
  String get t10_knownOutcomes =>
      'All planned entries have a recorded outcome.';

  @override
  String get t10_savedLocal => 'Saved on this device';

  @override
  String get t10_sharingPending => 'Saved here · waiting to share';

  @override
  String get t10_sharingAccepted => 'Shared record accepted';

  @override
  String get t10_sharingReview => 'Saved here · shared record needs review';

  @override
  String get t10_sharingUncertain => 'Saved here · sharing outcome unknown';

  @override
  String get t10_freshnessUnknown =>
      'Server update status is unknown. You can record care on this device.';

  @override
  String t10_sharedUpdated(String time) {
    return 'Last server update received: $time';
  }

  @override
  String t10_sharingCounts(int pending, int review, int uncertain) {
    return '$pending waiting · $review to review · $uncertain uncertain';
  }

  @override
  String get t10_syncing => 'Receiving server updates…';

  @override
  String get t10_asNeededUndone => 'This as-needed dose was undone.';

  @override
  String get t10_recordError =>
      'This record was not confirmed. Retry keeps the same action and time.';

  @override
  String t10_selectedCount(int count) {
    return '$count selected';
  }

  @override
  String get t10_prnHint =>
      'No daily quota. Record each administration when it happens.';

  @override
  String get t10_loadMore => 'Show earlier records';

  @override
  String get t10_noPeopleBody => 'Add a person to begin their care.';

  @override
  String get t10_noMedicationBody => 'Add a medication for this person.';

  @override
  String get t10_chooseDate => 'Choose a date';

  @override
  String get t11_entry => 'Appearance and colors';

  @override
  String get t11_scope =>
      'Personal appearance on this device. Care, connections and setup stay unchanged.';

  @override
  String get t11_preview => 'Preview · Focus deck';

  @override
  String get t11_exampleOnly => 'Example only. Preview cannot record care.';

  @override
  String get t11_examplePerson => 'Example person';

  @override
  String get t11_exampleMedication => 'Example medication';

  @override
  String get t11_exampleAmount => '1 tablet · 09:00';

  @override
  String get t11_exampleField => 'Example note';

  @override
  String get t11_exampleError => 'Example message needing attention';

  @override
  String get t11_colors => 'Theme colors';

  @override
  String get t11_actions => 'Actions and accents';

  @override
  String get t11_surfaces => 'Surfaces and text';

  @override
  String get t11_states => 'Care states and people';

  @override
  String get t11_reset => 'Restore appearance defaults';

  @override
  String get t11_resetQuestion => 'Restore appearance defaults?';

  @override
  String get t11_resetExplanation =>
      'This saves the default colors and display options. It does not remove care, connections, reminders or unfinished setup.';

  @override
  String get t11_apply => 'Apply appearance';

  @override
  String get t11_applied => 'Appearance saved on this device';

  @override
  String get t11_resetSaved => 'Default appearance restored';

  @override
  String get t11_saveError =>
      'Appearance not saved. Your previous appearance is still applied. Try again.';

  @override
  String get t11_loadError =>
      'Saved appearance could not be read. Retry, or restore appearance defaults. Your care remains unchanged.';

  @override
  String get t11_dynamicHint =>
      'Uses device colors when available. Your individual color choices take priority.';

  @override
  String get t11_dynamicUnavailable =>
      'Device colors are unavailable here. The Simpastil palette is used as the starting point.';

  @override
  String get t11_contrastHint =>
      'Strengthens text, state colors and borders. Your chosen colors stay saved; the preview shows the readable result.';

  @override
  String get t11_contrastWarning =>
      'Some text or actions may be hard to read. Adjust the colors or enable high contrast. Editor controls always use a readable palette.';

  @override
  String get t11_defaultColor => 'Theme default';

  @override
  String get t11_customColor => 'Custom color';

  @override
  String get t11_hex => 'Color code (6 hex digits)';

  @override
  String get t11_hexError => 'Enter six digits or letters from 0–9 and A–F.';

  @override
  String get t11_hue => 'Hue';

  @override
  String get t11_saturation => 'Saturation';

  @override
  String get t11_value => 'Brightness';

  @override
  String get t11_useColor => 'Use this color';

  @override
  String get t11_useDefault => 'Use theme default';

  @override
  String get t11_primary => 'Main action';

  @override
  String get t11_onPrimary => 'Text on main action';

  @override
  String get t11_primaryContainer => 'Selected background';

  @override
  String get t11_onPrimaryContainer => 'Text on selected background';

  @override
  String get t11_background => 'Page background';

  @override
  String get t11_text => 'Main text';

  @override
  String get t11_surface => 'Panels and dialogs';

  @override
  String get t11_surfaceVariant => 'Cards and fields';

  @override
  String get t11_mutedText => 'Supporting text';

  @override
  String get t11_border => 'Borders';

  @override
  String get t11_secondary => 'Secondary accent';

  @override
  String get t11_onSecondary => 'Text on secondary accent';

  @override
  String get t11_tertiary => 'Additional accent';

  @override
  String get t11_onTertiary => 'Text on additional accent';

  @override
  String get t11_error => 'Error background';

  @override
  String get t11_onError => 'Text on error';

  @override
  String get t11_taken => 'Taken';

  @override
  String get t11_skipped => 'Skipped';

  @override
  String get t11_unrecorded => 'Not recorded';

  @override
  String get t11_activePerson => 'Selected person';

  @override
  String get t11_inactivePerson => 'Other people';

  @override
  String get r07_setupTitle => 'Set up Simpastil';

  @override
  String get r07_firstMedication => 'Add your first medication';

  @override
  String r07_stepCount(int current, int total) {
    return '$current of $total';
  }

  @override
  String get r07_strength => 'Strength (optional)';

  @override
  String get r07_tablet => 'Tablet';

  @override
  String get r07_capsule => 'Capsule';

  @override
  String get r07_liquid => 'Liquid';

  @override
  String get r07_morning => 'Morning';

  @override
  String get r07_afternoon => 'Afternoon';

  @override
  String get r07_evening => 'Evening';

  @override
  String get r07_night => 'Night';

  @override
  String get r07_upNext => 'Up next';

  @override
  String r07_laterDose(String name, String time) {
    return 'Later: $name at $time';
  }

  @override
  String r07_otherDose(String name, String time) {
    return '$name at $time';
  }

  @override
  String get r08_startTitle => 'Start your routine';

  @override
  String get r08_startBody =>
      'Keep your routine on this device.\nConnect a server whenever you’re ready.';

  @override
  String get r08_noAccount => 'No account or server needed';

  @override
  String get r08_startHere => 'Start on this device';

  @override
  String get r08_connect => 'Connect to a server';

  @override
  String get r08_restore => 'Restore a backup';

  @override
  String get r08_choiceLater => 'Your choice can change later.';

  @override
  String get r08_personTitle => 'Who will you help?';

  @override
  String get r08_personHint =>
      'Start with one person. You can add more people later.';

  @override
  String get r08_personIdentity =>
      'Your name as the person recording care stays separate.';

  @override
  String get r08_routineTitle => 'Set your routine';

  @override
  String get r08_repeat => 'Repeat';

  @override
  String get r08_scheduledTime => 'Scheduled time';

  @override
  String get r08_remindersTitle => 'Gentle reminders, if you want them';

  @override
  String get r08_checkTitle => 'Check that reminders reach you';

  @override
  String get r08_reminderPreview => 'What a reminder looks like';

  @override
  String get r08_notificationsAllowed => 'Notifications allowed';

  @override
  String get r08_notificationsNotAllowed => 'Notifications not enabled yet';

  @override
  String get r08_testConfirmed => 'Test reminder confirmed';

  @override
  String get r08_testNotConfirmed => 'Test reminder not confirmed';

  @override
  String get r08_checkHelp =>
      'This harmless check does not record a dose. Confirm only after you see it on this phone.';

  @override
  String get r09_medicationsBody => 'Manage and view all medications';

  @override
  String get r09_searchMedications => 'Search medications';

  @override
  String get r09_noMatchingMedications => 'No matching medications';

  @override
  String get r09_addMedication => 'Add medication';

  @override
  String get r09_noRoutine => 'No routine yet';

  @override
  String get r09_medicationActions => 'Medication actions';

  @override
  String get r09_viewDetails => 'View details';

  @override
  String get r09_selectMedication => 'Select medication';

  @override
  String get r09_clearSearch => 'Clear search';

  @override
  String get r09_peopleToday => 'People today';

  @override
  String get r09_peopleBody => 'Care at a glance for the people you support';

  @override
  String r09_medicationCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count medications',
      one: '1 medication',
    );
    return '$_temp0';
  }

  @override
  String get r09_viewEveryone => 'View everyone';

  @override
  String get r09_managePeople => 'Manage people';

  @override
  String get r09_viewRoutine => 'View routine';

  @override
  String get r09_allRecords => 'All records';

  @override
  String r09_recordCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count records',
      one: '1 record',
    );
    return '$_temp0';
  }

  @override
  String get r09_latestEntry => 'Latest entry';

  @override
  String get r09_earlierDay => 'Earlier this day';

  @override
  String get r09_searchHistory => 'Search history';

  @override
  String get r09_noMatchingRecords => 'No matching records';

  @override
  String get r09_previousDay => 'Previous day';

  @override
  String get r09_nextDay => 'Next day';

  @override
  String get r09_recentDays => 'Recent days';

  @override
  String get r14_reviewDoses => 'Review doses';

  @override
  String get r14_chooseDoses => 'Choose doses to review';

  @override
  String r14_personDay(String person, String day) {
    return '$person · $day';
  }

  @override
  String r14_selectedDoses(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count doses selected',
      one: '1 dose selected',
    );
    return '$_temp0';
  }

  @override
  String r14_selectionCount(int count) {
    return '$count selected · Not saved yet';
  }

  @override
  String r14_unrecordedCount(int count) {
    return 'Not recorded · $count';
  }

  @override
  String r14_reviewCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Review $count doses',
      one: 'Review 1 dose',
    );
    return '$_temp0';
  }

  @override
  String r14_recordCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Record $count as taken',
      one: 'Record 1 as taken',
    );
    return '$_temp0';
  }

  @override
  String get r14_clearSelection => 'Clear selection';

  @override
  String get r14_remove => 'Remove';

  @override
  String get r14_later => 'Later';

  @override
  String r14_plannedFor(String day) {
    return 'Planned for $day';
  }

  @override
  String r14_recordFor(String person) {
    return 'This records the selected doses for $person.';
  }

  @override
  String get r14_sameTime => 'This time choice applies to every selected dose.';

  @override
  String r14_savedCount(int saved, int total) {
    return '$saved of $total saved';
  }

  @override
  String get r15_noMedications => 'No medications yet';

  @override
  String r15_addForPerson(String person) {
    return 'Add a medication for $person when you’re ready.';
  }

  @override
  String get r15_choosePerson => 'Add medication for…';

  @override
  String get r15_chooseFirstPerson =>
      'Choose a person to add their first medication.';

  @override
  String get r15_optionalSetup => 'Routine and stock setup are optional.';

  @override
  String get r15_nothingToday => 'Nothing scheduled today';

  @override
  String get r15_nothingDay => 'Nothing scheduled for this day';

  @override
  String get r15_nextBody => 'Your next scheduled dose is shown below.';

  @override
  String get r15_noNext =>
      'No upcoming dose is available from the saved routine.';

  @override
  String r15_nextDate(String date) {
    return 'Next · $date';
  }

  @override
  String get r16_editTheme => 'Edit theme';

  @override
  String get r16_scope => 'Personal appearance on this device';

  @override
  String get r16_accent => 'Accent';

  @override
  String get r16_background => 'Background';

  @override
  String get r16_text => 'Text';

  @override
  String get r16_allColors => 'All color controls';

  @override
  String get r16_formsPreview => 'Preview forms and states';

  @override
  String get r16_displayOptions => 'Display options';

  @override
  String get r16_example => 'Example';

  @override
  String get r16_examplePerson => 'Alex · 09:00';

  @override
  String get r16_exampleMedication => 'Example tablet 20 mg';

  @override
  String get r16_exampleAmount => '1 tablet';

  @override
  String get t14_lockUseDeviceLock => 'Use device lock';

  @override
  String get t14_lockTitle => 'Your care is locked';

  @override
  String get t14_lockBody =>
      'Unlock with your device to continue. Scheduled reminders can still arrive.';

  @override
  String get t14_lockChecking => 'Checking device authentication…';

  @override
  String get t14_lockCancelled =>
      'Unlock was cancelled. Your care remains hidden.';

  @override
  String get t14_lockUnavailable =>
      'Device authentication is unavailable. Your care remains hidden.';

  @override
  String get t14_lockWriteFailed =>
      'The lock setting could not be confirmed. Unlock again to continue.';

  @override
  String get t14_lockStale => 'Unlock again to continue.';

  @override
  String get t14_settingsLockTitle => 'App lock';

  @override
  String get t14_settingsLockBody =>
      'Require device authentication when opening or returning to Simpastil on this device. Reminder and widget privacy settings stay separate.';

  @override
  String get t14_settingsLockEnableReason => 'Turn on app lock';

  @override
  String get t14_settingsLockDisableReason => 'Turn off app lock';

  @override
  String get t14_settingsLockCancelled => 'App lock was not changed.';

  @override
  String get t14_settingsLockFailed =>
      'The app-lock setting could not be confirmed. Try again.';

  @override
  String get t14_personReminders => 'Reminders on this device';

  @override
  String get t14_personRemindersEnabled => 'Include this person';

  @override
  String get t14_personRemindersBody =>
      'Include this person in scheduled reminders and the home-screen widget on this device. Android notification permission is still required.';

  @override
  String get t15_intro => 'Make Simpastil work for you';

  @override
  String get t15_everyday => 'Everyday preferences';

  @override
  String get t15_yourData => 'Your data';

  @override
  String get t15_privacyAccess => 'Privacy and access';

  @override
  String get t15_layout => 'App layout';

  @override
  String get t15_focusDeck => 'Focus deck';

  @override
  String get t15_colors => 'Colors and theme';

  @override
  String get t15_defaultPalette => 'Default palette';

  @override
  String get t15_customPalette => 'Personal palette';

  @override
  String get t15_reminders => 'Reminders';

  @override
  String get t15_remindersSubtitle => 'Delivery and lock-screen details';

  @override
  String get t15_accessibility => 'Accessibility';

  @override
  String get t15_accessibilitySubtitle => 'Display and interaction';

  @override
  String get t15_backups => 'Backups';

  @override
  String get t15_backupsSubtitle => 'Export or restore a file';

  @override
  String get t15_storageRecovery => 'Storage and recovery';

  @override
  String get t15_storageSubtitle => 'Local files and recovery copies';

  @override
  String get t15_serverConnection => 'Server connection';

  @override
  String get t15_notConnected => 'Not connected';

  @override
  String get t15_protection => 'App protection';

  @override
  String get t15_protectionSubtitle => 'Encryption and optional app lock';

  @override
  String get t15_peopleSubtitle => 'Primary person and care preferences';

  @override
  String get t15_medicationSubtitle => 'Editing and as-needed preferences';

  @override
  String get t15_dataSubtitle =>
      'Connection status and records that need attention';

  @override
  String get t15_protectedCare => 'Encrypted care storage';

  @override
  String get t15_encryptionBody =>
      'Care is encrypted on this device even when app lock is off. App lock adds an optional device-authentication step before access.';

  @override
  String get t15_transferTitle => 'Moving to another phone';

  @override
  String get t15_transferBody =>
      'Protected care is excluded from automatic system backups and device transfer. Save a portable backup or use an authorized server copy before changing phones. A local recovery copy does not protect against losing this phone.';

  @override
  String get t15_serverPrivacy =>
      'A trusted server operator can technically read care stored on that server. Local care does not require a server.';

  @override
  String get t15_careFiles => 'Care, drafts and pending changes';

  @override
  String get t15_recoveryCopies => 'Recovery copies';

  @override
  String get t15_unfinishedFiles => 'Unfinished startup files';

  @override
  String get t15_legacyFiles => 'Retained original files';

  @override
  String get t15_otherFiles => 'Other private files';

  @override
  String get t15_availableSpace => 'Available on this device';

  @override
  String get t15_unknownSize => 'Not available';

  @override
  String get t15_inventoryScope =>
      'Sizes cover files controlled by Simpastil. Drafts and pending changes are included with care. Shared system files are not counted.';

  @override
  String get t15_checkedRecovery => 'Checked recovery copy';

  @override
  String get t15_noRecovery => 'No recovery copy yet';

  @override
  String get t15_recoveryUnavailable =>
      'Recovery copy could not be checked. Original files are preserved.';

  @override
  String get t15_savedAt => 'Saved';

  @override
  String get t15_checkedAt => 'Checked';

  @override
  String get t15_cleanup => 'Clean safe temporary files';

  @override
  String get t15_cleanupBody =>
      'Only abandoned startup files that were never used as care can be removed. Care, drafts, pending changes and recovery copies are kept.';

  @override
  String get t15_cleanupConfirm => 'Remove these safe temporary files?';

  @override
  String get t15_cleanupNone => 'No safe temporary files to remove.';

  @override
  String get t15_cleanupDone =>
      'Safe cleanup completed. Your care and recovery copies are unchanged.';

  @override
  String get t15_cleanupRefused =>
      'Cleanup could not be completed safely. All remaining files are kept.';

  @override
  String get t15_accessExpired =>
      'Access changed. Unlock again and start a new operation. Original files are unchanged.';

  @override
  String get t15_loadFailed =>
      'These details are temporarily unavailable. Your data is preserved.';

  @override
  String get t15_createBackup => 'Create backup';

  @override
  String get t15_checkBackup => 'Check backup';

  @override
  String get t15_backupPurpose =>
      'A portable file for restoring your care. Reports such as PDF or CSV are not restorable backups.';

  @override
  String get t15_createSubtitle =>
      'Save all available care and app preferences';

  @override
  String get t15_checkSubtitle =>
      'Open a file without changing your current care';

  @override
  String get t15_onDevice => 'On this device';

  @override
  String get t15_contents => 'View contents';

  @override
  String get t15_backupContents =>
      'Routines, dose history, stock, drafts, pending changes and supported app preferences. Account credentials and device access are not included.';

  @override
  String get t15_passwordProtected => 'Password protected';

  @override
  String get t15_unencrypted => 'Unencrypted';

  @override
  String get t15_unencryptedBody => 'Anyone with the file can read it.';

  @override
  String get t15_backupPassword => 'Backup password';

  @override
  String get t15_confirmPassword => 'Confirm password';

  @override
  String get t15_passwordNeeded =>
      'You will need this password to restore the file. Simpastil cannot recover it.';

  @override
  String get t15_passwordMismatch =>
      'Enter a password and matching confirmation.';

  @override
  String get t15_noFileSaved => 'No file saved yet.';

  @override
  String get t15_chooseSave => 'Choose save location';

  @override
  String get t15_chooseBackup => 'Choose backup file';

  @override
  String get t15_saveChosen => 'Save to chosen location';

  @override
  String get t15_openChosen => 'Open chosen file';

  @override
  String get t15_savedChecked => 'Saved and checked on this phone';

  @override
  String get t15_savedUnchecked => 'Saved, but not checked on this phone';

  @override
  String get t15_saveFailed =>
      'Saving failed. The chosen file may be incomplete; your original care is unchanged.';

  @override
  String get t15_checkFailed =>
      'The file could not be checked. Check the password and try again; original care is unchanged.';

  @override
  String get t15_checksPassed => 'File checks passed';

  @override
  String get t15_supportedBackup =>
      'This backup can be opened by this version of Simpastil.';

  @override
  String get t15_currentUnchanged => 'Your current data is unchanged.';

  @override
  String get t15_reviewRestore => 'Review restore options';

  @override
  String get t15_restoreSelection => 'Restore or import';

  @override
  String get t15_fullRestore => 'Replace current care';

  @override
  String get t15_fullRestoreBody =>
      'Restore the complete file. Current care is retained in a checked local recovery copy before replacement. Review all affected people and preferences first.';

  @override
  String get t15_selectedImport => 'Import selected people';

  @override
  String get t15_selectedImportBody =>
      'Keep current care and preferences. Conflicting history is retained for review; connected originals remain account-scoped evidence.';

  @override
  String get t15_reviewImport => 'Review import';

  @override
  String get t15_applyImport => 'Apply reviewed import';

  @override
  String get t15_applyRestore => 'Restore reviewed backup';

  @override
  String get t15_confirmReplace =>
      'I reviewed the replacement and checked recovery requirement.';

  @override
  String get t15_confirmApply => 'Apply this reviewed plan?';

  @override
  String get t15_importDone => 'Import completed';

  @override
  String get t15_restoreDone => 'Restore completed';

  @override
  String get t15_importFailed =>
      'The reviewed change could not be completed. Original care is preserved; start a fresh review.';

  @override
  String get t15_additions => 'Additions';

  @override
  String get t15_identical => 'Already identical';

  @override
  String get t15_conflicts => 'Retained conflicts';

  @override
  String get t15_retained => 'Retained work';

  @override
  String get t15_preferencesChanged => 'Preferences to change';

  @override
  String get t15_alreadyApplied => 'This import has already been applied.';

  @override
  String get t15_projectionPending =>
      'Care is saved. Reminder or widget refresh still needs a retry.';

  @override
  String get t15_afterChooser =>
      'After returning from the file chooser, unlock if asked and start this new operation.';

  @override
  String get t15_people => 'People';

  @override
  String get t15_passwordVisibility => 'Show or hide password';

  @override
  String get t15_dataCaptured => 'Data captured';

  @override
  String get t15_affectedPeople => 'Current care affected';

  @override
  String get t15_connectedCare => 'Connected care';

  @override
  String get t15_localCare => 'Local care';

  @override
  String get t15_outcomeAdded => 'Added';

  @override
  String get t15_outcomeMerged => 'Merged';

  @override
  String get t15_outcomeUnchanged => 'Unchanged';

  @override
  String get t15_outcomeReview => 'Needs review';

  @override
  String get t15_outcomeLocked => 'Unavailable account';

  @override
  String get t15_outcomeReplaced => 'Replaced';

  @override
  String get t15_medications => 'Medications';

  @override
  String get t15_routines => 'Routines';

  @override
  String get t15_history => 'Dose history';

  @override
  String get t15_preferences => 'App preferences';

  @override
  String get t15_fullDetails => 'Full details';

  @override
  String get t15_fullDetailsBody =>
      'Show care details and review actions in notifications and widgets. This is independent of app lock.';

  @override
  String get t15_privateReminders => 'Private reminders';

  @override
  String get t15_privateBody =>
      'Use generic Open-only notifications and widgets without medication names, dose counts or recording actions.';

  @override
  String get t15_reminderCoverage => 'Reminder coverage';

  @override
  String get t15_coverageShortened =>
      'The nearest reminders are scheduled. Open Simpastil regularly to schedule later reminders.';

  @override
  String get t15_coverageDegraded =>
      'Some reminders could not be scheduled. Check notification permissions, then reopen Simpastil to try again.';

  @override
  String get t15_coverageNone =>
      'No upcoming reminders are currently scheduled for this workspace. Open Simpastil regularly to refresh coverage.';

  @override
  String get t15_reminderPeople => 'People included on this device';

  @override
  String get t15_reminderPeopleBody =>
      'Choose device reminders in each person’s settings in People. People you add on this device start on; people from your account start off. The person you are viewing does not change who receives reminders.';

  @override
  String get t15_openPeople => 'Open People';

  @override
  String get t15_reminderTest => 'Check reminder delivery';

  @override
  String get t15_reminderTestBody =>
      'A scheduled test is not proof of delivery. Confirm only if you actually see the test notification.';

  @override
  String get t15_sendTest => 'Send test notification';

  @override
  String get t15_testScheduled => 'Test scheduled · delivery not confirmed';

  @override
  String get t15_testObserved => 'You confirmed seeing this test';

  @override
  String get t15_testFailed =>
      'Test could not be scheduled. Check notification and alarm permissions below.';

  @override
  String get t15_confirmObserved => 'I saw the test notification';

  @override
  String get t15_backupContentsShort =>
      'Routines, dose history, stock and app preferences';

  @override
  String t15_retainedPeopleCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count retained people',
      one: '1 retained person',
    );
    return '$_temp0';
  }

  @override
  String get t15_backupProtection => 'Protection';

  @override
  String get t15_differentDoseRecords => 'Different records for one dose';

  @override
  String get t15_onThisDevice => 'On this device';

  @override
  String get t15_inBackup => 'In the backup';

  @override
  String get t15_reviewDifference => 'Review difference';

  @override
  String get t15_differenceBody =>
      'These facts are retained separately for review. Opening this detail does not record a dose, choose a winning fact or apply the import.';

  @override
  String get t15_timeUnknown => 'Time unknown';

  @override
  String get t15_notRecorded => 'Not recorded';

  @override
  String get t15_taken => 'Taken';

  @override
  String get t15_skipped => 'Skipped';

  @override
  String get t15_fileIntegrity => 'File integrity';

  @override
  String get t15_backupFormat => 'Backup format';

  @override
  String get t15_passed => 'Passed';

  @override
  String get t15_supported => 'Supported';

  @override
  String get t15_howRestore => 'How to restore';

  @override
  String t15_selectedPeopleCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count people selected',
      one: '1 person selected',
    );
    return '$_temp0';
  }

  @override
  String get t15_notImported => 'Nothing imported yet.';

  @override
  String get t15_applying => 'Applying your reviewed backup…';

  @override
  String get t15_noChangeBeforeApply =>
      'Nothing changes until you review and apply.';

  @override
  String get legacyReview_title => 'Review older routine times';

  @override
  String get legacyReview_entry => 'Review routine times together';

  @override
  String get legacyReview_entryHint =>
      'Confirm a time zone while keeping saved hours and days.';

  @override
  String get legacyReview_intro =>
      'Choose the time zone those saved hours belong to. Review each routine below, then confirm once.';

  @override
  String get legacyReview_zone => 'Time zone for saved hours';

  @override
  String get legacyReview_bucharest => 'Bucharest, Romania';

  @override
  String legacyReview_device(String zone) {
    return 'Device time ($zone)';
  }

  @override
  String get legacyReview_from => 'Apply from';

  @override
  String legacyReview_boundary(String date, String zone) {
    return 'Applies from midnight on $date, in $zone. Saved hours, days, and past records are preserved.';
  }

  @override
  String legacyReview_ready(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count routines ready to review',
      one: '1 routine ready to review',
    );
    return '$_temp0';
  }

  @override
  String legacyReview_next(String date) {
    return 'Next planned dose: $date';
  }

  @override
  String get legacyReview_inactive => 'Paused · stays paused';

  @override
  String legacyReview_invalid(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count skipped: their saved days need an individual review.',
      one: '1 skipped: its saved days need an individual review.',
    );
    return '$_temp0';
  }

  @override
  String legacyReview_unavailable(int count) {
    return '$count skipped: pending changes, an earlier edit, or incomplete review details. Sync and review them individually.';
  }

  @override
  String get legacyReview_noChanges =>
      'No routines are ready for this batch. Existing review items remain available in Data.';

  @override
  String legacyReview_confirm(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Confirm $count routine times',
      one: 'Confirm 1 routine time',
    );
    return '$_temp0';
  }

  @override
  String get legacyReview_retry => 'Retry this review';

  @override
  String legacyReview_saved(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count routines accepted by the server. They will appear after the next successful sync.',
      one:
          '1 routine accepted by the server. It will appear after the next successful sync.',
    );
    return '$_temp0';
  }

  @override
  String legacyReview_partial(int accepted, int total) {
    return '$accepted of $total routines accepted. Keep this review to retry the remaining routines with the same choices.';
  }

  @override
  String get legacyReview_loadError =>
      'This review could not be loaded. Sync your data, then try again.';

  @override
  String get legacyReview_applyError =>
      'The server could not confirm all changes. Retry this review or return to Data to sync.';

  @override
  String get legacyReview_scope =>
      'This review only sets routine time zones. Other unresolved changes still need review.';

  @override
  String get review_openRecovery =>
      'This is waiting in Fix sync problems, where you can resolve it. Its details are retained.';

  @override
  String get sync_connectionAccessUnavailable =>
      'The saved connection needs attention. Review it and sign in to the same account if asked.';

  @override
  String get sync_reviewConnection => 'Review connection';

  @override
  String get review_incompleteDetails =>
      'Review is unavailable for this item. Its saved details are retained below.';

  @override
  String get review_errorChanged =>
      'This review changed or is no longer ready. Sync, then open it again.';

  @override
  String get review_errorSignIn =>
      'Sign in again before submitting this review.';

  @override
  String get review_errorMissing =>
      'These review details are no longer available. Sync, then check the remaining review items.';

  @override
  String get review_errorValidation =>
      'Check the review choices and time zone, then try again.';

  @override
  String get review_errorRateLimit =>
      'Too many requests. Wait a moment before submitting this review again.';

  @override
  String get review_errorServer =>
      'The server could not confirm this review. Sync to check its status before retrying.';

  @override
  String get review_errorConnection =>
      'Could not reach the server. Check your connection, then sync to check this review before retrying.';

  @override
  String get review_errorUnknown =>
      'This review could not be confirmed. Its details are retained; sync before reviewing again.';

  @override
  String get prn_reviewAmbiguous =>
      'More than one as-needed routine is active. Review them before recording.';

  @override
  String get prn_reviewRoutine =>
      'This as-needed routine is paused or needs review. Check its saved details before recording.';

  @override
  String get prn_reviewZone =>
      'Confirm this routine’s time zone before recording.';

  @override
  String get prn_openReview => 'Open Data to review';

  @override
  String get t10_sharingReconciled =>
      'Reviewed · original delivery unconfirmed';

  @override
  String get schedules_restorePrnTitle => 'Restore as-needed routine';

  @override
  String get schedules_restorePrnExplanation =>
      'Enable this saved as-needed routine in the time zone below. Past records are kept.';

  @override
  String get schedules_restorePrnZone => 'Time zone for as-needed recording';

  @override
  String get sync_todayAttention =>
      'Some records need your attention · Open Sync';

  @override
  String get sync_todayUnverified =>
      'Server records have not been verified · Open Sync';

  @override
  String get sync_todayPending =>
      'Changes saved on this phone · Waiting to sync';

  @override
  String sync_retainedRemovedRecords(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count records refer to removed medications or routines. The original information is preserved; there is no change here to review.',
      one:
          '1 record refers to a removed medication or routine. The original information is preserved; there is no change here to review.',
    );
    return '$_temp0';
  }

  @override
  String sync_retainedHistory(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count older history entries are preserved as information. Their original timing or stock effect may be uncertain; they do not require a new dose decision.',
      one:
          '1 older history entry is preserved as information. Its original timing or stock effect may be uncertain; it does not require a new dose decision.',
    );
    return '$_temp0';
  }

  @override
  String get backup_unattributed =>
      'A full backup also preserves older records whose original person can no longer be established. Restoring keeps these as inactive evidence, without assigning them to someone or sending them to a server.';

  @override
  String get review_choiceAccepted =>
      'Your choice was accepted by the server. This review clears when its acknowledgement has synced to this phone.';

  @override
  String get sc_allRecorded => 'All recorded for today';

  @override
  String sc_skyLabel(int recorded, int total, String next) {
    return 'Day sky: $recorded of $total recorded, next $next';
  }

  @override
  String sc_skyNoNext(int recorded, int total) {
    return 'Day sky: $recorded of $total recorded';
  }

  @override
  String sc_sunNext(String time, String person, String medication) {
    return 'Next: $time · $person · $medication';
  }

  @override
  String get sc_sunNone => 'Nothing more due today';

  @override
  String get sc_showNextDose => 'Show next dose';

  @override
  String get sc_readNextDose => 'Read what is next';

  @override
  String get sc_pullToShare => 'Pull to share now';

  @override
  String get sc_sharedJustNow => 'Shared just now';

  @override
  String get sc_savedOnDevice => 'Saved on this device';

  @override
  String get sc_saving => 'Saving…';

  @override
  String sc_stockLeft(int n) {
    return '$n left';
  }

  @override
  String get lay_timeline => 'Timeline';

  @override
  String get lay_peopleLanes => 'People lanes';

  @override
  String get lay_dayPlanner => 'Day planner';

  @override
  String get lay_actionInbox => 'Action inbox';

  @override
  String get lay_dailyJournal => 'Daily journal';

  @override
  String get lay_focusDeckBody =>
      'One dose at a time, with previous, next and a day overview.';

  @override
  String get lay_timelineBody =>
      'The whole day in time order, with the sun marking now.';

  @override
  String get lay_peopleLanesBody => 'Each person\'s care in a lane of its own.';

  @override
  String get lay_dayPlannerBody => 'The day as an agenda, hour by hour.';

  @override
  String get lay_actionInboxBody =>
      'What still needs recording first, recorded doses apart.';

  @override
  String get lay_dailyJournalBody =>
      'The day as a readable record of care and notes.';

  @override
  String get lay_intro =>
      'Choose how Today is arranged. Colours, the selected person and the date stay as they are. This choice is kept on this device only.';

  @override
  String get lay_inUse => 'In use';

  @override
  String get lay_notReady => 'Not available yet';

  @override
  String get lay_notReadyBody =>
      'This layout is still being built. Today keeps using Focus deck until it is ready.';

  @override
  String get lay_preview => 'Preview';

  @override
  String lay_previewOf(String name) {
    return 'Preview of $name';
  }

  @override
  String get lay_previewNotice =>
      'Example day with fictional medications. Nothing you tap here is recorded.';

  @override
  String lay_use(String name) {
    return 'Use $name';
  }

  @override
  String lay_applied(String name) {
    return 'Today now uses $name.';
  }

  @override
  String get lay_saveError =>
      'The layout could not be saved, so nothing changed. Try again.';

  @override
  String get lay_exampleMorning => 'Morning tablet';

  @override
  String get lay_exampleNoon => 'Vitamin D';

  @override
  String get lay_exampleEvening => 'Evening tablet';

  @override
  String lay_now(String time) {
    return 'Now, $time';
  }

  @override
  String lay_quietHours(String from, String to) {
    return 'Nothing planned · $from – $to';
  }

  @override
  String get lay_showDetails => 'Show details';

  @override
  String get lay_hideDetails => 'Hide details';

  @override
  String lay_itemLabel(String time, String medication, String state) {
    return '$time, $medication, $state';
  }

  @override
  String get ibx_needsYou => 'Needs you';

  @override
  String get ibx_recordedToday => 'Recorded today';

  @override
  String get ibx_needsNone => 'Nothing needs you right now.';

  @override
  String get ibx_recordedNone => 'Nothing recorded yet.';

  @override
  String ibx_movedRecorded(String medication) {
    return '$medication moved to Recorded today.';
  }

  @override
  String ibx_movedNeeds(String medication) {
    return '$medication moved back to Needs you.';
  }

  @override
  String get jrn_morning => 'Morning';

  @override
  String get jrn_afternoon => 'Afternoon';

  @override
  String get jrn_evening => 'Evening';

  @override
  String get jrn_night => 'Night';

  @override
  String get supply_title => 'Supply';

  @override
  String supply_until(String date) {
    return 'Enough until $date';
  }

  @override
  String supply_cardUntil(String date) {
    return 'Until $date';
  }

  @override
  String supply_refillBy(String date) {
    return 'Refill by $date to stay above your low-stock level';
  }

  @override
  String get supply_pastHorizon => 'Enough for more than two months';

  @override
  String get supply_shortToday => 'Not enough for today\'s remaining doses';

  @override
  String supply_shortOn(String date) {
    return 'Runs short on $date';
  }

  @override
  String get supply_none => 'No doses left';

  @override
  String get supply_estimateNote =>
      'Estimated from the routine, one dose per planned time. Doses taken outside it change this.';

  @override
  String jrn_periodSummary(String period, int recorded, int total) {
    return '$period, $recorded of $total recorded';
  }

  @override
  String jrn_took(String time, String person, String medication) {
    return '$time · $person took $medication';
  }

  @override
  String jrn_tookUnknown(String person, String medication) {
    return '$person took $medication · time not known';
  }

  @override
  String jrn_skipped(String time, String person, String medication) {
    return '$time · $person skipped $medication';
  }

  @override
  String jrn_skippedUnknown(String person, String medication) {
    return '$person skipped $medication · time not known';
  }

  @override
  String jrn_planned(String time, String person, String medication) {
    return 'Planned $time · $person to take $medication';
  }

  @override
  String get mf_previewPlaceholder => 'Your medication';

  @override
  String get mf_sectionWhat => 'What it is';

  @override
  String get mf_sectionWhatHint =>
      'A name you will recognise, and how it comes.';

  @override
  String get mf_sectionDose => 'Each dose';

  @override
  String get mf_sectionLook => 'How it looks';

  @override
  String get mf_sectionLookHint =>
      'This colour follows it to Today and Medications.';

  @override
  String get mf_sectionSupply => 'Supply';

  @override
  String get mf_sectionNotes => 'Anything to remember';

  @override
  String get mf_sectionWho => 'Who takes it';

  @override
  String get mf_sectionWhen => 'When';

  @override
  String get mf_sectionRepeat => 'Repeat';

  @override
  String mf_colorSwatch(String color) {
    return '$color colour';
  }

  @override
  String get mf_nameNeeded => 'Add a name so you can find it later.';

  @override
  String get mf_numberNeeded => 'Use a whole number, like 30.';

  @override
  String get mf_fewer => 'One fewer';

  @override
  String get mf_more => 'One more';

  @override
  String get mf_colourAfterSave => 'It gets its own colour once it is saved.';

  @override
  String mf_skyTime(String time, String part) {
    return '$time, $part';
  }

  @override
  String schedules_dialLabel(String times) {
    return 'Dose times on the day dial: $times';
  }

  @override
  String get blister_label => 'Medication stock';

  @override
  String blister_cellFull(String name, int stock) {
    return '$name, $stock left';
  }

  @override
  String blister_cellRefill(String name, int stock) {
    return '$name, time to refill, $stock left';
  }

  @override
  String blister_cellEmpty(String name) {
    return '$name, none left';
  }

  @override
  String blister_cellUntracked(String name) {
    return '$name, stock not tracked';
  }

  @override
  String get blister_show => 'show in the list';

  @override
  String get blister_fine => 'Stock is fine';

  @override
  String blister_refill(String names) {
    return 'Refill soon: $names';
  }

  @override
  String blister_empty(String names) {
    return 'None left: $names';
  }

  @override
  String get mf_tapToChange => 'Tap to change';

  @override
  String get mf_daysNeeded => 'Pick at least one day.';

  @override
  String get mf_personHint => 'The name you use for them is enough.';

  @override
  String get mf_personFace => 'A face for their medications';

  @override
  String get r4_recoveryChecked => 'Checked';

  @override
  String get r4_recoveryNone => 'None yet';

  @override
  String get r4_recoveryUnchecked => 'Not checked';

  @override
  String get r4_spaceUsed => 'Space used';

  @override
  String get r4_cleanupGroup => 'Tidy up';

  @override
  String get r4_syncReviewGroup => 'To review';

  @override
  String get r4_syncDetails => 'Shows sync details';

  @override
  String r6_notifDoseBody(String dosage) {
    return '$dosage, when you’re ready';
  }

  @override
  String get r6_notifNoDoseBody => 'When you’re ready.';

  @override
  String r6_notifStillTitle(String pillName) {
    return '$pillName is still waiting';
  }

  @override
  String r6_notifStillBody(String dosage) {
    return '$dosage, only if you haven’t yet';
  }

  @override
  String get r6_notifStillNoDoseBody => 'Only if you haven’t yet.';

  @override
  String get r6_notifSubText => 'Dose reminder';

  @override
  String get r6_permBody =>
      'Simpastil can give you a quiet nudge when a dose is due. Your care is saved either way.';

  @override
  String get r6_whyNudge => 'One calm nudge at each scheduled time';

  @override
  String get r6_whyActions =>
      'Mark it taken or snooze it from the notification';

  @override
  String get r6_whyPrivacy =>
      'You choose whether names show on the lock screen';

  @override
  String get r6_whyNothingRecorded => 'Nothing is recorded until you say so';

  @override
  String get r6_sampleMedicine => 'your medicine';

  @override
  String get r6_sampleDose => '1 tablet';

  @override
  String get r6_previewNow => 'now';

  @override
  String r6_previewSemantics(String title, String body) {
    return 'Sample reminder: $title. $body';
  }

  @override
  String get r6_statusTitle => 'This device';

  @override
  String get r6_statusChecking => 'Checking this device';

  @override
  String get r6_statusOn => 'Reminders on';

  @override
  String get r6_statusOnBody =>
      'This device can show reminders at their scheduled time.';

  @override
  String get r6_statusNeedsPermission => 'Needs permission';

  @override
  String get r6_statusNeedsPermissionBody =>
      'Notifications are off for Simpastil, so reminders will not appear. Your care is still saved.';

  @override
  String get r6_statusMayBeLate => 'May arrive late';

  @override
  String get r6_statusMayBeLateBody =>
      'Exact alarms are off, so Android may delay reminders.';

  @override
  String get r6_statusSomeMissing => 'Some not scheduled';

  @override
  String get r6_statusUnavailable => 'Not available here';

  @override
  String get r6_statusUnavailableBody =>
      'This device cannot show reminders. Your care is still saved.';

  @override
  String get r6_privacyNames => 'Names shown';

  @override
  String get r6_privacyPrivate => 'Private';

  @override
  String get r6_dayTitle => 'Your reminder day';

  @override
  String get r6_dayBody => 'Reminders follow your routine times.';

  @override
  String get r6_dayEmpty =>
      'No scheduled times yet. Add a routine to get reminders.';

  @override
  String get r6_dayEdit => 'Change times in Routine';

  @override
  String get r8_syncNotConnected => 'Not connected to a server';

  @override
  String get r8_peopleManageGroup => 'Add and manage';

  @override
  String get r8_peopleRemoveGroup => 'Remove';

  @override
  String r8_lowStockTitle(String pillName) {
    return '$pillName is running low';
  }

  @override
  String r8_lowStockBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count doses left',
      one: '1 dose left',
    );
    return '$_temp0';
  }

  @override
  String get r8_editingPalette => 'Editing palette for:';

  @override
  String get r8_paletteNote =>
      'This only chooses which colours you are editing. It does not switch the app between light and dark.';

  @override
  String get r10_statusNobodyOn => 'No one switched on';

  @override
  String get r10_statusNobodyOnBody =>
      'This device allows reminders, but no person is switched on here, so no reminders are scheduled and the home-screen widget stays empty.';

  @override
  String get r10_peopleHintNone => 'Switch a person on for this device';

  @override
  String r10_peopleHintSome(int on, int total) {
    return 'On for $on of $total people on this device';
  }

  @override
  String get r10_peopleHintBody =>
      'In People, open a person\'s menu and choose Reminders on this device.';

  @override
  String get lay_nothingDueYet => 'Nothing due yet';

  @override
  String get rv_launchTitle => 'Care from your previous version is waiting';

  @override
  String get rv_launchBody =>
      'Your medications, schedules and history are safe on this device. Sign in to the server you used before to continue where you left off.';

  @override
  String get rv_launchSignIn => 'Sign in to your original server';

  @override
  String get rv_launchReview => 'Review your original server';

  @override
  String get rv_launchLocal => 'Set up new care on this device instead';

  @override
  String get rv_reviewTitle => 'Confirm your original server';

  @override
  String get rv_reviewBody =>
      'The care saved by your previous version belongs to an account on one server. Confirm this is the server you used before. If it is not, sign out and nothing is changed.';

  @override
  String get rv_reviewAddress => 'Server address';

  @override
  String get rv_reviewConfirm => 'Yes, this is my original server';

  @override
  String get rv_reviewReject => 'No, sign out';

  @override
  String get rv_reviewError => 'The review could not be completed. Try again.';

  @override
  String get r08_connectedTitle => 'You’re connected';

  @override
  String get r08_connectedBody =>
      'Add the first person you help. Their routine will sync with your server.';

  @override
  String get r08_connectedCard => 'Synced with your server';

  @override
  String get r08_connectedStart => 'Add the first person';

  @override
  String r09_checkWaiting(int seconds) {
    return 'Waiting for the reminder… $seconds s';
  }

  @override
  String get r09_checkWaitingHint =>
      'It can take up to 15 seconds to arrive. Keep this screen open.';

  @override
  String get r09_checkQuestion => 'Did you see the reminder on this phone?';

  @override
  String get r09_checkYes => 'Yes, I saw it';

  @override
  String get r09_checkNo => 'No, I didn’t';

  @override
  String get r09_checkNoHelp =>
      'Check that Simpastil notifications are on and that Do Not Disturb or battery saver is not blocking them, then send another check.';

  @override
  String get thread_sending => 'Sending changes to your server…';

  @override
  String get thread_settled => 'Up to date with your server';

  @override
  String get thread_falteredSaved =>
      'The last sync didn’t finish · Changes stay on this phone';

  @override
  String get thread_faltered => 'The last sync didn’t finish · Open Sync';

  @override
  String get auth_stepVerification => 'STEP 4 — VERIFICATION';

  @override
  String story_plannedFor(Object time) {
    return 'Planned for $time';
  }

  @override
  String story_takenAt(Object time) {
    return 'Taken at $time';
  }

  @override
  String story_skippedAt(Object time) {
    return 'Skipped at $time';
  }

  @override
  String get story_recordedNoTime => 'Recorded, time not known';

  @override
  String get story_notYet => 'Not recorded yet';

  @override
  String get story_onTime => 'At the planned time';

  @override
  String story_after(Object duration) {
    return '$duration after the plan';
  }

  @override
  String story_before(Object duration) {
    return '$duration before the plan';
  }

  @override
  String story_minutes(Object minutes) {
    return '$minutes min';
  }

  @override
  String story_hoursMinutes(Object hours, Object minutes) {
    return '$hours h $minutes min';
  }

  @override
  String get recovery_title => 'Fix sync problems';

  @override
  String get recovery_entryHintNone => 'Nothing needs fixing right now';

  @override
  String recovery_entryHint(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count changes need you',
      one: '1 change needs you',
    );
    return '$_temp0';
  }

  @override
  String recovery_entryNotes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count kept notes to review',
      one: '1 kept note to review',
    );
    return '$_temp0';
  }

  @override
  String get recovery_entryChecking => 'Check for sync problems';

  @override
  String get recovery_intro =>
      'These changes were made on this phone and have not reached the server yet. None of them is lost: each one stays here until it is sent or you decide otherwise.';

  @override
  String get recovery_nothingTitle => 'Nothing to fix';

  @override
  String get recovery_nothingBody =>
      'All your changes have been sent to the server.';

  @override
  String get recovery_waitingOnly =>
      'These will be sent by themselves. You don\'t need to do anything.';

  @override
  String get recovery_loadFailed =>
      'Couldn\'t load the list of unsent changes.';

  @override
  String get recovery_groupChanges => 'Unsent changes';

  @override
  String get recovery_groupTools => 'More options';

  @override
  String get recovery_kindPerson => 'Person';

  @override
  String get recovery_kindMedication => 'Medication';

  @override
  String get recovery_kindSchedule => 'Schedule';

  @override
  String get recovery_kindDose => 'Dose';

  @override
  String get recovery_kindOther => 'Change';

  @override
  String get recovery_unnamed => 'Not on this phone anymore';

  @override
  String get recovery_changeAdded => 'Added on this phone';

  @override
  String get recovery_changeEdited => 'Edited on this phone';

  @override
  String get recovery_changeRemoved => 'Removed on this phone';

  @override
  String get recovery_changeDose => 'Dose recorded';

  @override
  String get recovery_changeStock => 'Stock changed';

  @override
  String get recovery_changeOther => 'Changed on this phone';

  @override
  String get recovery_reasonQueued => 'Waiting to be sent';

  @override
  String recovery_reasonRetrying(String time) {
    return 'Couldn\'t reach the server. Trying again at $time.';
  }

  @override
  String get recovery_reasonRetryingSoon =>
      'Couldn\'t reach the server. Trying again soon.';

  @override
  String get recovery_reasonBlocked => 'Can\'t be sent as it is.';

  @override
  String get recovery_reasonConflict => 'Someone changed it on the server too.';

  @override
  String get recovery_reasonConflictSettled =>
      'Someone changed it on the server too. The server\'s version is already showing here.';

  @override
  String get recovery_reasonStranded =>
      'Waiting for another change that is stuck.';

  @override
  String get recovery_reasonWaitingForStart =>
      'Waiting for this medication\'s stock count to be sent first.';

  @override
  String get recovery_reasonStartStuck =>
      'Held behind this medication\'s stock start, which needs a decision first. Open the stock start to settle it.';

  @override
  String get recovery_reasonReview =>
      'Needs a decision. Try again, or discard it.';

  @override
  String get recovery_blockedBodyChanged =>
      'It was edited after the first attempt, so it can\'t be repeated safely.';

  @override
  String get recovery_blockedExhausted =>
      'The server couldn\'t be reached after several tries.';

  @override
  String get recovery_blockedUndo => 'This server can\'t take this back yet.';

  @override
  String get recovery_blockedGeneric =>
      'The server or this phone couldn\'t accept it as it is.';

  @override
  String get reminders_resetGroup => 'Repair';

  @override
  String get reminders_resetTitle => 'Reset reminders';

  @override
  String get reminders_resetHint =>
      'Clear every reminder this device has set and set them again from your schedules. Medicines and history are not touched.';

  @override
  String get reminders_resetConfirmBody =>
      'This clears all reminders on this device and sets them again. Use it if a reminder rings twice or not at all.';

  @override
  String get reminders_resetAction => 'Reset';

  @override
  String reminders_resetDone(int count) {
    return 'Reminders reset. $count set again.';
  }

  @override
  String get reminders_resetNeedsPermission =>
      'Allow notifications and exact alarms first, then reset reminders.';

  @override
  String get reminders_resetFailed =>
      'Reminders could not be reset. Try again in a moment.';

  @override
  String get reminders_resetRegistryUnreadable =>
      'The reminder records on this device could not be read, so nothing was changed. Your medicines and history are safe.';

  @override
  String get reminders_resetRestoring =>
      'Reminders are being set up again. This can take a moment.';

  @override
  String reminders_auditStatus(String when, int count) {
    return 'Last check: $when. Stray reminders removed: $count.';
  }

  @override
  String reminders_auditDeferred(String when) {
    return 'Last check: $when. It could not finish and will try again.';
  }

  @override
  String get reminders_auditPartial =>
      ' Some shared care was left out this time.';

  @override
  String get recovery_retryAll => 'Retry all';

  @override
  String get recovery_retryAllHint =>
      'Try every stuck change again, then check the server.';

  @override
  String get recovery_useServer => 'Use server version';

  @override
  String get recovery_keepMine => 'Keep my change';

  @override
  String get recovery_dismiss => 'Dismiss';

  @override
  String get recovery_tryAgain => 'Try again';

  @override
  String get recovery_discard => 'Discard this change';

  @override
  String get recovery_discardTitle => 'Discard this change?';

  @override
  String recovery_discardDoseBody(String name) {
    return 'The dose you recorded on this phone for $name was never accepted by the server. It will be dropped and the dose will show as the server has it. Changes that don\'t depend on it will then be sent. This can\'t be undone.';
  }

  @override
  String recovery_discardStockBody(String name) {
    return 'The stock change you made on this phone for $name never reached the server. It will be dropped and the stock will show as the server has it. Changes that don\'t depend on it will then be sent. This can\'t be undone.';
  }

  @override
  String recovery_discardOtherBody(String name) {
    return 'This change to $name never reached the server. It will be dropped and whatever doesn\'t depend on it will be sent. This can\'t be undone.';
  }

  @override
  String get recovery_doneTryAgain =>
      'Tried again. Anything still stuck stays on this list.';

  @override
  String get recovery_doneDiscard =>
      'Discarded. Whatever was waiting behind it is being sent.';

  @override
  String get recovery_groupNotes => 'Kept notes';

  @override
  String get recovery_noteTitle => 'Note from an earlier sync';

  @override
  String get recovery_noteBody =>
      'Something was kept for review. It blocks nothing and its details are kept.';

  @override
  String recovery_discardCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count changes in all will be dropped, including the ones that depend on it.',
    );
    return '$_temp0';
  }

  @override
  String get recovery_discardHistory =>
      'This was added on this phone and already has dose history, so it can\'t be discarded. Retry it instead.';

  @override
  String get recovery_useServerTitle => 'Use the server\'s version?';

  @override
  String recovery_useServerBody(String name) {
    return 'Your unsent change to $name will be dropped and the server\'s version will replace it. This can\'t be undone.';
  }

  @override
  String recovery_useServerCreateBody(String name) {
    return '$name was only ever added on this phone. It will be removed from this phone together with the changes waiting for it. This can\'t be undone.';
  }

  @override
  String get recovery_keepMineTitle => 'Keep your change?';

  @override
  String recovery_keepMineBody(String name) {
    return 'Your change to $name will be sent again on top of the server\'s latest version. Whatever was changed on the server in the meantime will be overwritten.';
  }

  @override
  String get recovery_redownload => 'Re-download from server';

  @override
  String get recovery_redownloadHint =>
      'Fetch everything from the server again. Your unsent changes stay.';

  @override
  String get recovery_redownloadTitle => 'Re-download everything?';

  @override
  String get recovery_redownloadBody =>
      'Waiting changes are sent first, then everything is downloaded again. Changes still waiting on this phone are kept and never overwritten. This can use more data.';

  @override
  String get recovery_copyDiagnostics => 'Copy diagnostics';

  @override
  String get recovery_copyDiagnosticsHint =>
      'Counts and codes only: no names, notes or addresses.';

  @override
  String get recovery_copied => 'Diagnostics copied';

  @override
  String get recovery_doneRetry =>
      'Tried again. Anything still stuck stays on this list.';

  @override
  String get recovery_doneServer =>
      'Done. The server\'s version is being used.';

  @override
  String get recovery_doneKeep => 'Your change will be sent again.';

  @override
  String get recovery_doneDismiss => 'Dismissed.';

  @override
  String get recovery_doneRedownload => 'Downloaded again from the server.';

  @override
  String get recovery_busy =>
      'A sync is already running. Try again in a moment.';

  @override
  String get recovery_failed => 'That didn\'t work. Nothing was lost.';

  @override
  String get recovery_refusedSending =>
      'A change is being sent right now. Try again in a moment.';

  @override
  String get recovery_refusedGone => 'Already taken care of.';

  @override
  String get recovery_refusedNotDiscardable =>
      'There is nothing here that can be discarded.';

  @override
  String get recovery_refusedOffline =>
      'The server can\'t be reached right now, so your change was kept. Try again when you are online.';

  @override
  String get recovery_serverCopyPending =>
      'Your change was dropped. The server\'s version is waiting to download and will replace it at the next sync.';

  @override
  String get recovery_reasonConflictDeleted =>
      'It was deleted on the server, so your change can\'t be applied. Use the server\'s version to accept the deletion.';

  @override
  String get asn_hintTitle => 'Hold a card to record a dose';

  @override
  String get asn_hintBody =>
      'Keep your finger on it until the ring fills. Tap a card for details.';

  @override
  String get asn_hintGotIt => 'Got it';

  @override
  String get asn_holdToRecord => 'Hold to record';

  @override
  String get asn_keepHolding => 'Keep holding';

  @override
  String asn_todayCount(int count) {
    return '$count today';
  }

  @override
  String get asn_notTakenYet => 'Not taken yet';

  @override
  String asn_amountAgo(String amount, String ago) {
    return '$amount · $ago';
  }

  @override
  String asn_takenAtToday(String time, int count) {
    return 'Taken $time · $count today';
  }

  @override
  String get asn_takenToday => 'Taken today';

  @override
  String asn_takenTime(String time) {
    return 'Taken $time';
  }

  @override
  String get asn_needsReview => 'Needs review';

  @override
  String asn_logLine(int count, String time) {
    return '$count today · last $time';
  }

  @override
  String asn_logLineNoTime(int count) {
    return '$count today';
  }

  @override
  String get asn_logNone => 'None today';

  @override
  String get asn_noDosesToday => 'No doses yet today';

  @override
  String get asn_logToggle => 'Doses taken today';

  @override
  String get asn_statToday => 'Today';

  @override
  String get asn_stat7Days => 'Last 7 days';

  @override
  String get asn_statLastDose => 'Last dose';

  @override
  String get asn_onlyWhenNeeded => 'Only when needed';

  @override
  String get asn_recentDoses => 'Recent doses';

  @override
  String get asn_yesterday => 'Yesterday';

  @override
  String asn_doseCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count doses',
      one: '1 dose',
    );
    return '$_temp0';
  }

  @override
  String asn_groupHeader(String day, String doses) {
    return '$day · $doses';
  }

  @override
  String get asn_noRecentDoses => 'No doses in the last 7 days';

  @override
  String get asn_recordNow => 'Record now';

  @override
  String get asn_openEditor => 'Open dose editor';

  @override
  String asn_usualDose(String amount) {
    return 'Usual dose $amount';
  }

  @override
  String asn_stockLeft(String amount) {
    return '$amount left';
  }

  @override
  String get asn_stockLow => 'Running low';

  @override
  String get asn_stockLabel => 'Stock';

  @override
  String get asn_editorTitle => 'Record a dose';

  @override
  String get asn_amountLabel => 'Amount';

  @override
  String get asn_amountDecrease => 'Decrease amount';

  @override
  String get asn_amountIncrease => 'Increase amount';

  @override
  String get asn_whenLabel => 'When';

  @override
  String get asn_whenNow => 'Now';

  @override
  String get asn_when15 => '15 min ago';

  @override
  String get asn_when1h => '1 h ago';

  @override
  String get asn_when3h => '3 h ago';

  @override
  String get asn_whenPick => 'Pick time';

  @override
  String get asn_whenUnknown => 'Not sure';

  @override
  String get asn_amountNotSure => 'Not sure';

  @override
  String asn_save(String amount, String time) {
    return 'Save $amount at $time';
  }

  @override
  String asn_saveNoTime(String amount) {
    return 'Save $amount, time not known';
  }

  @override
  String asn_cardLabel(String name, String person, String info) {
    return '$name, for $person. $info';
  }

  @override
  String get asn_recordAction => 'Record dose';

  @override
  String get asn_agoJustNow => 'Just now';

  @override
  String asn_agoMinutes(int count) {
    return '$count min ago';
  }

  @override
  String asn_agoHours(int count) {
    return '$count h ago';
  }

  @override
  String asn_agoDays(int count) {
    return '$count d ago';
  }

  @override
  String get asn_unitPlaceholder => 'Unit';

  @override
  String asn_detailsFor(String name) {
    return 'Details for $name';
  }

  @override
  String get asn_jumpLabel => 'Jump to As needed';

  @override
  String get asn_shortcutTitle => 'As needed shortcut';

  @override
  String get asn_shortcutSubtitle =>
      'Show a button that jumps to your as-needed medicines';

  @override
  String get asn_editorSwitch => 'Only when I need it';

  @override
  String get asn_editorSwitchHint =>
      'No routine and no reminders. Record a dose whenever you take it.';

  @override
  String get asn_detailIntro =>
      'Taken only when needed, so there is no routine to set up.';

  @override
  String get asn_recordDose => 'Record a dose';

  @override
  String asn_prnStat(int count) {
    return 'As-needed doses (last 30 days, separate): $count';
  }

  @override
  String lay_asNeededCount(int count) {
    return '$count as needed';
  }

  @override
  String jrn_tookAsNeeded(String time, String person, String medication) {
    return '$time · $person took $medication, as needed';
  }

  @override
  String jrn_tookAsNeededUnknown(String person, String medication) {
    return '$person took $medication, as needed · time not known';
  }

  @override
  String get lay_exampleAsNeeded => 'Ibuprofen';

  @override
  String get tm_stockFine => 'Stock is fine';

  @override
  String get tm_stockFineBody => 'Nothing runs out in the next 14 days';

  @override
  String get tm_stockSoon => 'Runs out soon';

  @override
  String get tm_stockOut => 'Out of stock';

  @override
  String get tm_stockUntracked => 'No stock counts yet';

  @override
  String get tm_stockUntrackedBody =>
      'Add a count to a medication to see when it runs out';

  @override
  String get tm_scheduledLabel => 'Scheduled';

  @override
  String get tm_asNeededBody => 'Recorded from Today';

  @override
  String tm_stockNegativeSpoken(String label) {
    return 'Warning: negative stock. $label';
  }

  @override
  String get tm_noCount => 'No count';

  @override
  String get tm_stockTitle => 'Stock';

  @override
  String get tm_addStock => 'Add stock';

  @override
  String get tm_stockNone =>
      'No stock count yet. Add one to see when it runs out.';

  @override
  String tm_runsOutAround(String date) {
    return 'Runs out around $date';
  }

  @override
  String tm_refillAt(int count) {
    return 'Refill reminder at $count left';
  }

  @override
  String get tm_last14Title => 'Last 14 days';

  @override
  String tm_daysTaken(int taken, int due) {
    return '$taken of $due days';
  }

  @override
  String tm_daysTakenSpoken(int taken, int due) {
    return 'Every dose taken on $taken of $due days';
  }

  @override
  String get tm_last14Empty =>
      'No doses recorded yet. Doses you record on Today fill these in.';

  @override
  String tm_asNeededTotal(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count doses',
      one: '1 dose',
      zero: 'No doses',
    );
    return '$_temp0';
  }

  @override
  String get tm_last14AsNeededNote => 'As-needed doses taken each day.';

  @override
  String get tm_dayPartial => 'Some doses taken';

  @override
  String get tm_dayNone => 'No dose planned';

  @override
  String get tm_dayUpcoming => 'Not due yet';

  @override
  String tm_dayCell(String date, String state) {
    return '$date: $state';
  }

  @override
  String tm_dayCellAsNeeded(String date, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count doses',
      one: '1 dose',
      zero: 'no doses',
    );
    return '$date: $_temp0';
  }

  @override
  String get tm_recentTitle => 'Recent';

  @override
  String get tm_seeAllHistory => 'See all in History';

  @override
  String get tm_recentEmpty => 'Nothing recorded in the last 30 days.';

  @override
  String get tm_kindScheduled => 'Scheduled';

  @override
  String get tm_statSchedule => 'Schedule';

  @override
  String get tm_perUse => 'Per use';

  @override
  String get tm_edit => 'Edit';

  @override
  String get tm_previewTitle => 'Preview';

  @override
  String get tm_previewNote =>
      'This is how the dose shows on Today and in reminders.';

  @override
  String get tm_stockAfterSaving => 'Stock after saving';

  @override
  String tm_stockWas(int count) {
    return 'Was $count';
  }

  @override
  String get th_viewCalendar => 'Calendar';

  @override
  String get th_viewTrends => 'Trends';

  @override
  String get th_viewLabel => 'History view';

  @override
  String th_monthSoFar(String month) {
    return '$month so far';
  }

  @override
  String get th_tilePlannedRecorded => 'Planned recorded';

  @override
  String th_tileOfTotal(int recorded, int total) {
    return '$recorded of $total';
  }

  @override
  String get th_tileAsNeededDoses => 'As-needed doses';

  @override
  String get th_dayPlannedRecorded => 'Planned doses recorded';

  @override
  String th_dayAsNeededDoses(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'As-needed doses',
      one: 'As-needed dose',
    );
    return '$_temp0';
  }

  @override
  String get th_dayStreak => 'Day streak';

  @override
  String th_streakBest(int days) {
    return 'Best in 12 weeks: $days';
  }

  @override
  String get th_byMedication => 'By medication';

  @override
  String get th_scheduledLast30 => 'Scheduled, last 30 days';

  @override
  String get th_asNeededByMedication => 'As needed by medication';

  @override
  String get th_asNeededNone => 'No as-needed doses in the last 30 days';

  @override
  String th_asNeededCountSemantics(String medication, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count doses',
      one: '1 dose',
    );
    return '$medication: $_temp0';
  }

  @override
  String get th_unknownMedication => 'Unknown medication';

  @override
  String get th_timeOfDay => 'Time of day';

  @override
  String get th_timeOfDayNote => 'When doses were taken, last 30 days';

  @override
  String get th_timeOfDayNone =>
      'No doses with a known time in the last 30 days';

  @override
  String th_timeOfDaySemantics(String hour, int count) {
    return 'Doses by hour of the day, last 30 days. Most at $hour: $count.';
  }

  @override
  String th_weekOfSemantics(String date, String value) {
    return 'Week of $date: $value';
  }

  @override
  String th_pillAdherenceSemantics(
    String name,
    int taken,
    int expected,
    String percent,
  ) {
    return '$name: $taken of $expected taken, $percent adherence';
  }

  @override
  String th_calendarDayFuture(String date) {
    return '$date, in the future';
  }

  @override
  String get th_stockChanges => 'Stock changes';

  @override
  String th_stockChangeRow(String medication, int before, int after) {
    return '$medication, $before to $after';
  }

  @override
  String get th_stockKindRefill => 'Refill';

  @override
  String get th_stockKindCorrection => 'Corrected';

  @override
  String get th_stockKindUndone => 'Dose undone';

  @override
  String th_stockChangeSemantics(
    String medication,
    int before,
    int after,
    String time,
  ) {
    return '$medication: stock from $before to $after at $time';
  }

  @override
  String get ts_nextTitle => 'Next reminders on this device';

  @override
  String get ts_nextEmpty => 'No reminders are planned for the next 30 days.';

  @override
  String get ts_nextEmptyNobody =>
      'No one is switched on for reminders on this device, so none are planned.';

  @override
  String get ts_nextLoadFailed => 'The planned reminders could not be read.';

  @override
  String ts_whenToday(String time) {
    return 'Today $time';
  }

  @override
  String ts_whenTonight(String time) {
    return 'Tonight $time';
  }

  @override
  String ts_whenTomorrow(String time) {
    return 'Tomorrow $time';
  }

  @override
  String ts_whenDay(String day, String time) {
    return '$day $time';
  }

  @override
  String get ts_previewTitle => 'Preview';

  @override
  String get ts_previewNext => 'Your next reminder, as it will appear.';

  @override
  String get ts_previewSample => 'An example. No reminder is planned yet.';

  @override
  String get ts_previewOnDevice => 'Preview on this device';

  @override
  String get tt_stockTitle => 'Stock';

  @override
  String get tt_stockEmpty =>
      'Stock counts you keep for your medicines show up here.';

  @override
  String tt_stockLeft(String count) {
    return '$count left';
  }

  @override
  String get tt_stockAsNeeded => 'Used as needed';

  @override
  String get tt_stockLong => 'More than two months';

  @override
  String tt_stockAboutDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count days',
      one: '1 day',
    );
    return 'About $_temp0';
  }

  @override
  String tt_stockAboutWeeks(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count weeks',
      one: '1 week',
    );
    return 'About $_temp0';
  }

  @override
  String get tt_stockOut => 'Out of stock';

  @override
  String tt_stockRow(String name, String left) {
    return '$name, $left';
  }

  @override
  String get tt_week => 'This week';

  @override
  String tt_weekRecorded(int count) {
    return '$count recorded';
  }

  @override
  String get tt_weekHint =>
      'Doses you record fill these in. Taken late still counts.';

  @override
  String tt_weekDay(String date, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count doses recorded',
      one: '1 dose recorded',
      zero: 'nothing recorded',
    );
    return '$date: $_temp0';
  }

  @override
  String get tt_comingUp => 'Coming up';

  @override
  String get tt_comingUpPlanned => 'Planned';

  @override
  String get tt_comingUpNone => 'Nothing is planned after today.';

  @override
  String get tt_tomorrow => 'Tomorrow';

  @override
  String get tt_detailsClose => 'Close dose details';

  @override
  String get tt_otherTime => 'Other time';

  @override
  String get tt_takenOtherTime => 'Taken at another time';

  @override
  String get tt_skippedAction => 'Skipped';

  @override
  String get tt_afterTaking => 'After taking';

  @override
  String get tt_previousNights => 'Previous nights';

  @override
  String get tt_previousMornings => 'Previous mornings';

  @override
  String get tt_previousAfternoons => 'Previous afternoons';

  @override
  String get tt_previousEvenings => 'Previous evenings';

  @override
  String tt_previousCount(int taken, int total) {
    return '$taken of $total';
  }

  @override
  String tt_previousTakenAt(String time) {
    return 'Taken $time';
  }

  @override
  String tt_previousRow(String when, String state) {
    return '$when, $state';
  }

  @override
  String tt_lowRunsIn(String name, int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days days',
      one: '1 day',
    );
    return '$name runs low in about $_temp0';
  }

  @override
  String tt_lowNow(String name, String left) {
    return '$name is running low: $left left';
  }

  @override
  String tt_lowOut(String name) {
    return '$name is out of stock';
  }

  @override
  String tt_lowDetailRunsIn(int days, String left) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days days',
      one: '1 day',
    );
    return 'Runs low in about $_temp0 · $left left';
  }

  @override
  String tt_lowDetailNow(String left) {
    return 'Running low · $left left';
  }

  @override
  String get tt_lowDetailOut => 'Out of stock';

  @override
  String get tt_addStock => 'Add stock';

  @override
  String get tt_later => 'Later';

  @override
  String get tt_lowStockNotice => 'Low stock';

  @override
  String get tt_status => 'Status';

  @override
  String get tt_allDay => 'All day';

  @override
  String get tt_previousDay => 'Previous day';

  @override
  String get tt_nextDay => 'Next day';

  @override
  String get tt_stockAll => 'All';

  @override
  String get tt_stockAllLabel => 'All medications';

  @override
  String get tf_adherence => 'Adherence';

  @override
  String get tr_trendsCouldNotLoad => 'Could not load the streak and charts';

  @override
  String get settings_autoMissRecordTitle => 'Record missed doses';

  @override
  String get settings_autoMissRecordSubtitle =>
      'A dose nobody recorded in time is written to the history as missed, on every device. Turning this off does not undo misses already recorded.';

  @override
  String get settings_autoMissRecordAfter => 'Record as missed after';

  @override
  String get settings_autoMissRecordDelaySubtitle =>
      'How long after its planned time a dose waits before it is recorded as missed';

  @override
  String get settings_autoMissServerUnsupported =>
      'This server cannot store missed doses yet. Nothing is recorded as missed for this connected workspace until the server is updated.';

  @override
  String get dose_takenLate => 'Taken (late)';

  @override
  String get dose_takeLateNow => 'Taken now (late)';

  @override
  String get dose_markedMissedAuto => 'Marked missed automatically';

  @override
  String get dose_missedHint =>
      'Nobody recorded this dose in time, so it was marked missed. You can still record it as taken late, record it as skipped, or undo the miss.';

  @override
  String dose_missedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count doses missed',
      one: '1 dose missed',
    );
    return '$_temp0';
  }

  @override
  String get export_statusNotRecorded => 'Not recorded';

  @override
  String jrn_missed(String time, String person, String medication) {
    return '$time · $person missed $medication';
  }

  @override
  String jrn_tookLate(String time, String person, String medication) {
    return '$time · $person took $medication, late';
  }

  @override
  String get amountReview_entry => 'Review medication amounts';

  @override
  String amountReview_entryHint(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count medicines still show their original dosage text',
      one: '1 medicine still shows its original dosage text',
    );
    return '$_temp0';
  }

  @override
  String get amountReview_title => 'Medication amounts';

  @override
  String get amountReview_intro =>
      'These medicines were saved with their dosage as plain text. Set an amount per use so Today and the dose editor can show it.';

  @override
  String get amountReview_readable => 'Ready to use';

  @override
  String get amountReview_readableHint =>
      'The original text reads as one amount. Check it, then accept all at once.';

  @override
  String get amountReview_manual => 'Set these yourself';

  @override
  String get amountReview_manualHint =>
      'The original text does not read as a single amount, so nothing is guessed. Open each one and set it.';

  @override
  String amountReview_original(String text) {
    return 'Original text: $text';
  }

  @override
  String amountReview_willSet(String amount) {
    return 'Sets $amount per use';
  }

  @override
  String amountReview_willKeep(String amount) {
    return 'Keeps $amount per use';
  }

  @override
  String amountReview_accept(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Use these $count amounts',
      one: 'Use this amount',
    );
    return '$_temp0';
  }

  @override
  String amountReview_saved(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count amounts saved',
      one: '1 amount saved',
    );
    return '$_temp0';
  }

  @override
  String amountReview_partial(int saved, int total) {
    return '$saved of $total saved. Open the rest and set them yourself.';
  }

  @override
  String get amountReview_error => 'The amounts could not be saved. Try again.';

  @override
  String get amountReview_empty => 'Every medicine has an amount per use.';

  @override
  String get amountReview_selectedPerson =>
      'Only the person you are viewing is listed. Switch to Everyone in People to review the rest.';

  @override
  String get amountReview_markReviewed =>
      'I have reviewed the original dosage text';

  @override
  String get amountReview_markReviewedHint =>
      'The original wording is always kept. This only stops the reminder to review it.';

  @override
  String get t09_legacyDosageReviewed => 'Original dosage text · Reviewed';

  @override
  String get updateAvailableTitle => 'Update available';

  @override
  String updateAvailableBody(String version) {
    return 'Version $version of Simpastil is out.';
  }

  @override
  String get updateAvailableBodyGeneric =>
      'A newer version of Simpastil is out.';

  @override
  String get updateAvailableAction => 'View release';

  @override
  String get updateCheckSwitchTitle => 'Check for updates';

  @override
  String get updateCheckSwitchBody =>
      'Once a day, ask GitHub whether a newer version is out.';

  @override
  String get supportRowTitle => 'Support Simpastil';

  @override
  String get supportRowSubtitle => 'Donate on Ko-fi. Entirely optional.';

  @override
  String onb_personRemindersTitle(String name) {
    return 'Remind me about $name';
  }

  @override
  String get onb_personRemindersBody =>
      'On this device. You can change it any time in People.';

  @override
  String get onb_detailsTitle => 'Show medication names';

  @override
  String get onb_detailsBody =>
      'On the lock screen. Turn off to keep them private; reminders then only say a dose is due.';

  @override
  String get onb_choicesTitle => 'Your choices';

  @override
  String get onb_choiceFailed =>
      'That choice could not be saved. You can change it later in Settings.';

  @override
  String get onb_batteryTitle => 'Keep reminders on time';

  @override
  String get onb_batteryBody =>
      'Battery savers can delay or block reminders when Simpastil is closed. Letting it run in the background keeps them on time.';

  @override
  String get onb_batteryAllow => 'Let Simpastil run in the background';

  @override
  String get onb_batteryNotNow => 'Not now';

  @override
  String get onb_batterySamsungTip =>
      'On Samsung phones: Settings → Battery → Background usage limits, and keep Simpastil out of the sleeping apps.';

  @override
  String get onb_batteryNoLimits => 'Battery: no limits';

  @override
  String get onb_batteryLimited => 'Battery saver may delay reminders';

  @override
  String get onb_batteryUnlimited => 'No battery limits for Simpastil';

  @override
  String get onb_projectTitle => 'A small project';

  @override
  String get onb_projectBody =>
      'Simpastil is a small, independent app, so now and then something may not work as it should.';

  @override
  String get onb_projectReport => 'Report on GitHub';

  @override
  String get onb_projectProblemTitle => 'Found a problem?';

  @override
  String get onb_projectProblemBody =>
      'Tell us on GitHub, or use Report a problem in Settings → About.';

  @override
  String get onb_projectHelpTitle => 'Want to help build it?';

  @override
  String get onb_projectHelpBody =>
      'The code is open, and contributions are welcome.';

  @override
  String get onb_projectSupportTitle => 'Support the project';

  @override
  String get onb_projectSupportBody => 'Donations help keep Simpastil going.';

  @override
  String get onb_projectCode => 'See the code';

  @override
  String get onb_projectSponsors => 'GitHub Sponsors';

  @override
  String get onb_projectKofi => 'Ko-fi';

  @override
  String get onb_summaryTitle => 'Your reminders';

  @override
  String onb_summaryRemindersOn(String name) {
    return '$name gets reminders on this device';
  }

  @override
  String onb_summaryRemindersOff(String name) {
    return '$name does not get reminders on this device';
  }

  @override
  String get onb_summaryChangePeople => 'Change it in Settings → People.';

  @override
  String get onb_summaryNotificationsOn => 'Notifications are allowed';

  @override
  String get onb_summaryNotificationsOff => 'Notifications are not allowed yet';

  @override
  String get onb_summaryChangeReminders => 'Change it in Settings → Reminders.';

  @override
  String get onb_summaryNamesShown =>
      'Medication names show on the lock screen';

  @override
  String get onb_summaryNamesHidden =>
      'Medication names are hidden on the lock screen';

  @override
  String get onb_summaryBackups =>
      'Backups are not automatic. Make one in Settings → Backups.';

  @override
  String get onb_remindersOffTitle => 'Reminders are off on this device';

  @override
  String get onb_remindersOffBody => 'No one gets dose reminders here yet.';

  @override
  String get onb_remindersOffAction => 'Turn on';

  @override
  String get onb_remindersOffDismiss => 'Hide on this device';

  @override
  String get onb_remindersOffFailed =>
      'Reminders could not be turned on. You can try again in Settings → Reminders.';

  @override
  String get report_title => 'Report a problem';

  @override
  String get report_settingsRowSubtitle =>
      'Send the details needed to fix it. Nothing is sent until you choose.';

  @override
  String get report_intro =>
      'Something not working? Send a report so it can be found and fixed. The report holds technical details only.';

  @override
  String get report_includesTitle => 'What is in the report';

  @override
  String get report_includesBody =>
      'App version, phone model and Android version, whether reminders are allowed, rough sizes such as \"2-5 medicines\", the last sync steps and recent errors.';

  @override
  String get report_neverBody =>
      'Never included: names, medicines, doses, notes, your server address, email or account, or sign-in details.';

  @override
  String get report_previewTitle => 'See exactly what will be shared';

  @override
  String get report_preparing => 'Preparing the report…';

  @override
  String get report_githubAction => 'Submit issue on GitHub';

  @override
  String get report_githubHint =>
      'Public, free and the quickest way to get help.';

  @override
  String get report_shareAction => 'Share another way';

  @override
  String get report_shareHint =>
      'Save the file, email it to the maintainer, or send it with another app.';

  @override
  String get report_publicNote =>
      'Issues on GitHub are public. This report is safe to post, and you choose what else to write. For a security problem, do not post publicly: see the security policy on GitHub.';

  @override
  String get report_githubSheetTitle => 'How reporting on GitHub works';

  @override
  String report_githubStep1(String fileName) {
    return 'The report is saved to your Downloads folder as $fileName.';
  }

  @override
  String get report_githubStep2 =>
      'GitHub opens with the form already started.';

  @override
  String get report_githubStep3 =>
      'Describe what happened, attach the saved file to the issue, then submit it.';

  @override
  String get report_githubContinue => 'Save and open GitHub';

  @override
  String get report_githubOpenFailed =>
      'GitHub could not be opened. Open github.com/LucaPisl/simpastil/issues/new in a browser and attach the saved file.';

  @override
  String get report_saveAction => 'Save to Downloads';

  @override
  String get report_saveHint =>
      'Keep the file, or attach it to a message yourself.';

  @override
  String get report_emailAction => 'Email the maintainer';

  @override
  String get report_emailHint =>
      'Opens your email app with the message and the file ready to send.';

  @override
  String get report_otherShareAction => 'Share with another app';

  @override
  String get report_otherShareHint => 'Send the file with any app you choose.';

  @override
  String report_savedTo(String fileName) {
    return 'Saved to Downloads as $fileName';
  }

  @override
  String get report_saveUnsupported =>
      'This Android version cannot save straight to Downloads. Use Share with another app to put the file where you like.';

  @override
  String get report_saveFailed =>
      'The file could not be saved. Try Share with another app instead.';

  @override
  String get report_noEmailApp =>
      'No email app was found. Save the file or share it another way.';

  @override
  String get report_emailFailed =>
      'The email could not be prepared. Try saving the file instead.';

  @override
  String get report_shareFailed =>
      'The file could not be shared. Try saving it to Downloads instead.';

  @override
  String get report_crashTitle => 'Simpastil closed unexpectedly last time';

  @override
  String get report_crashBody => 'A short report can help get it fixed.';

  @override
  String get report_crashAction => 'Report';

  @override
  String get report_crashDismiss => 'Dismiss';

  @override
  String get report_syncAction => 'Report this problem';

  @override
  String get report_startupAction => 'Report this problem';

  @override
  String get pin_trustTitle => 'Trust this server\'s certificate?';

  @override
  String pin_trustBody(String host) {
    return '$host uses a certificate that this device cannot check on its own. If you run this server, compare the fingerprint below with the one your server shows: in the setup output, or with the command in DEPLOYMENT.md. Continue only if they match exactly.';
  }

  @override
  String get pin_trustWarning =>
      'If you do not run this server, or the fingerprints differ, cancel. Someone may be intercepting the connection.';

  @override
  String get pin_fingerprintLabel => 'Fingerprint (SHA-256)';

  @override
  String get pin_trustAction => 'Trust this key';

  @override
  String get pin_unreadable =>
      'The saved key for this server can\'t be read, so Simpastil will not connect. Try again, or restart the app.';

  @override
  String get pin_changedTitle => 'Server key changed';

  @override
  String pin_changedLead(String host) {
    return '$host now presents a different key than the one this device trusts. Simpastil has stopped all traffic to it, so nothing was sent.';
  }

  @override
  String get pin_changedWhy =>
      'This can mean someone is intercepting your connection, or that the server\'s certificate was regenerated. Ask whoever runs the server, and compare the fingerprint below with theirs.';

  @override
  String get pin_pinnedLabel => 'Trusted on this device';

  @override
  String get pin_presentedLabel => 'Presented now';

  @override
  String get pin_presentedNone => 'No certificate could be read';

  @override
  String pin_noticedAt(String when) {
    return 'Noticed $when';
  }

  @override
  String get pin_checking => 'Checking the server…';

  @override
  String get pin_checkAgain => 'Check again';

  @override
  String get pin_probeFailed =>
      'The server could not be reached, so its current key cannot be shown. Traffic stays blocked.';

  @override
  String get pin_keepBlocked => 'Keep blocked';

  @override
  String get pin_trustNewKey => 'Trust the new key';

  @override
  String get pin_useNormal => 'Use normal certificate checking';

  @override
  String get pin_normalAvailable =>
      'This server now has a certificate that passes normal checking. You can stop pinning its key.';

  @override
  String get pin_confirmTrustTitle => 'Trust the new key?';

  @override
  String get pin_confirmTrustBody =>
      'Do this only if the server\'s admin confirmed the new fingerprint. Whoever holds a key you trust can read everything this device sends to the server, including your sign-in and your medication data.';

  @override
  String get pin_confirmTrustAction => 'Trust new key';

  @override
  String get pin_confirmNormalTitle => 'Stop pinning this server?';

  @override
  String get pin_confirmNormalBody =>
      'Simpastil will rely on the server\'s regular certificate, checked by the authorities this device trusts, instead of this exact key. A server whose certificate is not valid will be refused.';

  @override
  String get pin_confirmNormalAction => 'Use normal checking';

  @override
  String pin_resolvedLead(String host) {
    return '$host presents the trusted key again. An earlier connection saw a different one and was blocked. Nothing was sent then.';
  }

  @override
  String get pin_dismiss => 'Dismiss notice';

  @override
  String get pin_reviewAction => 'Review server key';

  @override
  String get sync_errorKeyChanged =>
      'The server\'s key changed, so nothing was sent.';

  @override
  String get sync_errorOffline => 'You appear to be offline';

  @override
  String get sync_errorTimeout => 'Connection timed out';

  @override
  String get sync_errorServer => 'Server error';

  @override
  String get sync_errorFailed => 'Sync failed';

  @override
  String get sync_errorUnreachable => 'Couldn\'t reach the server';

  @override
  String get sync_headlineNotYet => 'Not synced yet';

  @override
  String get sync_headlineReview => 'Review needed';

  @override
  String get sync_headlinePartial => 'Partially synced';

  @override
  String get sync_headlineCouldNot => 'Couldn\'t sync';

  @override
  String get sync_headlineOffline => 'Offline';

  @override
  String get sync_headlineUpdate => 'Update required';

  @override
  String get sync_detailsTitle => 'Sync details';

  @override
  String get sync_lastConnection => 'Last successful sync connection';

  @override
  String get sync_noStageDetails => 'Component details are not available yet.';

  @override
  String get sync_retry => 'Retry sync';

  @override
  String get sync_detailCause => 'Cause';

  @override
  String get sync_detailHttp => 'HTTP status';

  @override
  String get sync_detailCompleted => 'Completed';

  @override
  String get sync_detailDuration => 'Duration';

  @override
  String get sync_detailRetries => 'Retries';

  @override
  String get sync_detailNotReported => 'Not reported';

  @override
  String get sync_detailCorrelation => 'Correlation ID';

  @override
  String get auth_resetUnavailableTitle => 'Reset through your admin';

  @override
  String get auth_resetUnavailableBody =>
      'This server does not send reset emails. Ask the person who runs it to create a password reset link for you, then follow that link to choose a new password.';

  @override
  String get auth_resetUnknownHint =>
      'If no email arrives, your server admin can create a reset link for you.';

  @override
  String settings_logOutUnsynced(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count unsynced changes',
      one: '1 unsynced change',
    );
    return 'You have $_temp0. Logging out will attempt to sync them first, but any remaining changes will be lost.';
  }

  @override
  String get error_conflict => 'That item already exists.';

  @override
  String error_rateLimitedMinutes(int minutes) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: '$minutes minutes',
      one: '1 minute',
    );
    return 'Too many requests. Try again in $_temp0.';
  }

  @override
  String get error_rateLimited => 'Too many requests. Please wait a moment.';

  @override
  String get error_itemNotFound => 'The item could not be found.';

  @override
  String get error_serverTrouble =>
      'Something went wrong on our end. Please try again later.';

  @override
  String get error_unexpected => 'An unexpected error occurred.';

  @override
  String get error_validation => 'Invalid input. Please check your data.';

  @override
  String get error_staleUpdate =>
      'This item was modified on another device. Pull to refresh.';

  @override
  String get error_passwordWeak =>
      'Password is too weak. Use at least 10 characters.';

  @override
  String get error_passwordLong => 'Password is too long.';

  @override
  String get error_emailTaken => 'An account with that email already exists.';

  @override
  String get error_keyRevoked =>
      'Your API key has been revoked. Contact the administrator.';

  @override
  String get error_keyInvalid =>
      'Invalid API key. Check your key and try again.';

  @override
  String get error_keyClaimed => 'This API key is already in use.';

  @override
  String get error_resetInvalid => 'This reset link is invalid or has expired.';

  @override
  String get error_totpInvalidCode =>
      'Invalid verification code. Please try again.';

  @override
  String get error_totpAlreadyEnabled =>
      'Two-factor authentication is already enabled.';

  @override
  String get error_totpNotEnabled =>
      'Two-factor authentication is not enabled.';

  @override
  String get error_totpChallengeInvalid =>
      'Invalid or expired challenge. Please log in again.';

  @override
  String get settings_logOutConfirm =>
      'You will be signed out and need to sign in again to sync on this device.';

  @override
  String get auth_signedOutNotice =>
      'You were signed out. Sign in again to continue.';

  @override
  String get auth_connectionRefreshed =>
      'The connection was refreshed. Verify the key again.';

  @override
  String get auth_certificateNotTrusted =>
      'This server\'s certificate can\'t be verified, so Simpastil didn\'t connect.';

  @override
  String get auth_resetKeyChangedNotice =>
      'The server\'s key changed, so nothing was sent. Review the key to continue.';

  @override
  String get auth_resetCertificateNotice =>
      'This server\'s certificate can\'t be verified, so nothing was sent. Review its key to continue.';

  @override
  String get pin_certRejectedTitle => 'Server certificate not trusted';

  @override
  String pin_certRejectedBody(String host) {
    return '$host presents a certificate this device can\'t verify, so Simpastil didn\'t connect. If you run this server, review its key and trust it only if the fingerprint matches.';
  }
}
