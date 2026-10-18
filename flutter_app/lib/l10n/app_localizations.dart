import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ro.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ro'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Simpastil'**
  String get appTitle;

  /// No description provided for @appSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Your medication companion'**
  String get appSubtitle;

  /// No description provided for @shared_cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get shared_cancel;

  /// No description provided for @shared_save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get shared_save;

  /// No description provided for @shared_retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get shared_retry;

  /// No description provided for @shared_delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get shared_delete;

  /// No description provided for @shared_close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get shared_close;

  /// No description provided for @shared_change.
  ///
  /// In en, this message translates to:
  /// **'Change'**
  String get shared_change;

  /// No description provided for @shared_continue.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get shared_continue;

  /// No description provided for @shared_skip.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get shared_skip;

  /// No description provided for @shared_done.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get shared_done;

  /// No description provided for @shared_all.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get shared_all;

  /// No description provided for @shared_none.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get shared_none;

  /// No description provided for @shared_add.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get shared_add;

  /// No description provided for @shared_grant.
  ///
  /// In en, this message translates to:
  /// **'Grant'**
  String get shared_grant;

  /// No description provided for @shared_loading.
  ///
  /// In en, this message translates to:
  /// **'Loading…'**
  String get shared_loading;

  /// No description provided for @shared_unknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get shared_unknown;

  /// No description provided for @shared_enabled.
  ///
  /// In en, this message translates to:
  /// **'Enabled'**
  String get shared_enabled;

  /// No description provided for @shared_disabled.
  ///
  /// In en, this message translates to:
  /// **'Disabled'**
  String get shared_disabled;

  /// No description provided for @shared_cancelDeletion.
  ///
  /// In en, this message translates to:
  /// **'Cancel deletion'**
  String get shared_cancelDeletion;

  /// No description provided for @shared_confirmAction.
  ///
  /// In en, this message translates to:
  /// **'Confirm {action}'**
  String shared_confirmAction(String action);

  /// No description provided for @shared_somethingWentWrong.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong. Please try again.'**
  String get shared_somethingWentWrong;

  /// No description provided for @shared_syncFailed.
  ///
  /// In en, this message translates to:
  /// **'Sync failed — check connection'**
  String get shared_syncFailed;

  /// No description provided for @shared_unlock.
  ///
  /// In en, this message translates to:
  /// **'Unlock'**
  String get shared_unlock;

  /// No description provided for @shared_unlockSimpastil.
  ///
  /// In en, this message translates to:
  /// **'Unlock Simpastil'**
  String get shared_unlockSimpastil;

  /// No description provided for @auth_tagline.
  ///
  /// In en, this message translates to:
  /// **'Your medication companion'**
  String get auth_tagline;

  /// No description provided for @auth_stepServer.
  ///
  /// In en, this message translates to:
  /// **'STEP 1 OF 3 — SERVER'**
  String get auth_stepServer;

  /// No description provided for @auth_stepApiKey.
  ///
  /// In en, this message translates to:
  /// **'STEP 2 OF 3 — API KEY'**
  String get auth_stepApiKey;

  /// No description provided for @auth_stepAccount.
  ///
  /// In en, this message translates to:
  /// **'STEP 3 OF 3 — ACCOUNT'**
  String get auth_stepAccount;

  /// No description provided for @auth_connectToServer.
  ///
  /// In en, this message translates to:
  /// **'Connect to your server'**
  String get auth_connectToServer;

  /// No description provided for @auth_enterServerAddress.
  ///
  /// In en, this message translates to:
  /// **'Enter the address of your Simpastil server'**
  String get auth_enterServerAddress;

  /// No description provided for @auth_serverAddressLabel.
  ///
  /// In en, this message translates to:
  /// **'SERVER ADDRESS'**
  String get auth_serverAddressLabel;

  /// No description provided for @auth_serverAddress.
  ///
  /// In en, this message translates to:
  /// **'Server address'**
  String get auth_serverAddress;

  /// No description provided for @auth_serverMustUseHttps.
  ///
  /// In en, this message translates to:
  /// **'Server address must use HTTPS.'**
  String get auth_serverMustUseHttps;

  /// No description provided for @auth_couldNotReachServer.
  ///
  /// In en, this message translates to:
  /// **'Could not reach server — check the address and try again.'**
  String get auth_couldNotReachServer;

  /// No description provided for @auth_connect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get auth_connect;

  /// No description provided for @auth_connectedTo.
  ///
  /// In en, this message translates to:
  /// **'✓ Connected — {hostname}'**
  String auth_connectedTo(String hostname);

  /// No description provided for @auth_enterApiKey.
  ///
  /// In en, this message translates to:
  /// **'Enter your API key'**
  String get auth_enterApiKey;

  /// No description provided for @auth_apiKeyHint.
  ///
  /// In en, this message translates to:
  /// **'Your server admin will have provided this key.'**
  String get auth_apiKeyHint;

  /// No description provided for @auth_apiKeyLabel.
  ///
  /// In en, this message translates to:
  /// **'API Key'**
  String get auth_apiKeyLabel;

  /// No description provided for @auth_verifyKey.
  ///
  /// In en, this message translates to:
  /// **'Verify key'**
  String get auth_verifyKey;

  /// No description provided for @auth_pleaseEnterApiKey.
  ///
  /// In en, this message translates to:
  /// **'Please enter your API key'**
  String get auth_pleaseEnterApiKey;

  /// No description provided for @auth_keyRevoked.
  ///
  /// In en, this message translates to:
  /// **'This API key has been revoked. Contact your admin.'**
  String get auth_keyRevoked;

  /// No description provided for @auth_unexpectedServerResponse.
  ///
  /// In en, this message translates to:
  /// **'Unexpected server response.'**
  String get auth_unexpectedServerResponse;

  /// No description provided for @auth_invalidApiKey.
  ///
  /// In en, this message translates to:
  /// **'Invalid API key.'**
  String get auth_invalidApiKey;

  /// No description provided for @auth_couldNotReachServerShort.
  ///
  /// In en, this message translates to:
  /// **'Could not reach server.'**
  String get auth_couldNotReachServerShort;

  /// No description provided for @auth_unexpectedError.
  ///
  /// In en, this message translates to:
  /// **'Unexpected error.'**
  String get auth_unexpectedError;

  /// No description provided for @auth_createAccount.
  ///
  /// In en, this message translates to:
  /// **'Create account'**
  String get auth_createAccount;

  /// No description provided for @auth_signIn.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get auth_signIn;

  /// No description provided for @auth_choosePassword.
  ///
  /// In en, this message translates to:
  /// **'Choose a password for your new account'**
  String get auth_choosePassword;

  /// No description provided for @auth_useCredentials.
  ///
  /// In en, this message translates to:
  /// **'Use your account credentials'**
  String get auth_useCredentials;

  /// No description provided for @auth_emailAddress.
  ///
  /// In en, this message translates to:
  /// **'Email address'**
  String get auth_emailAddress;

  /// No description provided for @auth_password.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get auth_password;

  /// No description provided for @auth_hidePassword.
  ///
  /// In en, this message translates to:
  /// **'Hide password'**
  String get auth_hidePassword;

  /// No description provided for @auth_showPassword.
  ///
  /// In en, this message translates to:
  /// **'Show password'**
  String get auth_showPassword;

  /// No description provided for @auth_enterValidEmail.
  ///
  /// In en, this message translates to:
  /// **'Enter a valid email address'**
  String get auth_enterValidEmail;

  /// No description provided for @auth_passwordRequired.
  ///
  /// In en, this message translates to:
  /// **'Password is required'**
  String get auth_passwordRequired;

  /// No description provided for @auth_incorrectCredentials.
  ///
  /// In en, this message translates to:
  /// **'Incorrect email or password'**
  String get auth_incorrectCredentials;

  /// No description provided for @auth_tooManyAttempts.
  ///
  /// In en, this message translates to:
  /// **'Too many attempts. Please try again later.'**
  String get auth_tooManyAttempts;

  /// No description provided for @auth_noConnection.
  ///
  /// In en, this message translates to:
  /// **'No connection. Check your network.'**
  String get auth_noConnection;

  /// No description provided for @auth_emailAlreadyRegistered.
  ///
  /// In en, this message translates to:
  /// **'Email already registered — or this API key is already linked to an account. Try signing in.'**
  String get auth_emailAlreadyRegistered;

  /// No description provided for @auth_keyBelongsToDifferentAccount.
  ///
  /// In en, this message translates to:
  /// **'This API key belongs to a different account.'**
  String get auth_keyBelongsToDifferentAccount;

  /// No description provided for @auth_forgotPassword.
  ///
  /// In en, this message translates to:
  /// **'Forgot password?'**
  String get auth_forgotPassword;

  /// No description provided for @auth_createAccountButton.
  ///
  /// In en, this message translates to:
  /// **'CREATE ACCOUNT'**
  String get auth_createAccountButton;

  /// No description provided for @auth_logInButton.
  ///
  /// In en, this message translates to:
  /// **'LOG IN'**
  String get auth_logInButton;

  /// No description provided for @auth_useDifferentKey.
  ///
  /// In en, this message translates to:
  /// **'Use a different API key'**
  String get auth_useDifferentKey;

  /// No description provided for @auth_checkEmail.
  ///
  /// In en, this message translates to:
  /// **'Check your email'**
  String get auth_checkEmail;

  /// No description provided for @auth_resetLinkSent.
  ///
  /// In en, this message translates to:
  /// **'If that email is registered, a reset link has been sent.'**
  String get auth_resetLinkSent;

  /// No description provided for @auth_backToLogin.
  ///
  /// In en, this message translates to:
  /// **'Back to login'**
  String get auth_backToLogin;

  /// No description provided for @auth_resetPassword.
  ///
  /// In en, this message translates to:
  /// **'Reset password'**
  String get auth_resetPassword;

  /// No description provided for @auth_enterEmailForReset.
  ///
  /// In en, this message translates to:
  /// **'Enter your email to receive a reset link'**
  String get auth_enterEmailForReset;

  /// No description provided for @auth_sendResetLink.
  ///
  /// In en, this message translates to:
  /// **'Send reset link'**
  String get auth_sendResetLink;

  /// No description provided for @auth_nameThisDevice.
  ///
  /// In en, this message translates to:
  /// **'Name this device'**
  String get auth_nameThisDevice;

  /// No description provided for @auth_whatShouldDeviceBeCalled.
  ///
  /// In en, this message translates to:
  /// **'What should this device be called?'**
  String get auth_whatShouldDeviceBeCalled;

  /// No description provided for @auth_deviceNameHelp.
  ///
  /// In en, this message translates to:
  /// **'This helps you identify it in the admin panel.'**
  String get auth_deviceNameHelp;

  /// No description provided for @auth_deviceNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Device name'**
  String get auth_deviceNameLabel;

  /// No description provided for @core_sessionExpired.
  ///
  /// In en, this message translates to:
  /// **'Session expired. Please log in again.'**
  String get core_sessionExpired;

  /// No description provided for @core_notifChannelName.
  ///
  /// In en, this message translates to:
  /// **'Dose Reminders'**
  String get core_notifChannelName;

  /// No description provided for @core_notifChannelDesc.
  ///
  /// In en, this message translates to:
  /// **'Gentle nudges when a dose is due'**
  String get core_notifChannelDesc;

  /// No description provided for @core_notifActionTaken.
  ///
  /// In en, this message translates to:
  /// **'Taken'**
  String get core_notifActionTaken;

  /// No description provided for @core_notifActionSnooze.
  ///
  /// In en, this message translates to:
  /// **'Snooze'**
  String get core_notifActionSnooze;

  /// No description provided for @core_notifActionSkip.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get core_notifActionSkip;

  /// No description provided for @core_notifTitle.
  ///
  /// In en, this message translates to:
  /// **'Time for {pillName}'**
  String core_notifTitle(String pillName);

  /// No description provided for @core_notifSnoozed.
  ///
  /// In en, this message translates to:
  /// **'Back again, as you asked'**
  String get core_notifSnoozed;

  /// No description provided for @dashboard_goodMorning.
  ///
  /// In en, this message translates to:
  /// **'Good morning'**
  String get dashboard_goodMorning;

  /// No description provided for @dashboard_goodAfternoon.
  ///
  /// In en, this message translates to:
  /// **'Good afternoon'**
  String get dashboard_goodAfternoon;

  /// No description provided for @dashboard_goodEvening.
  ///
  /// In en, this message translates to:
  /// **'Good evening'**
  String get dashboard_goodEvening;

  /// No description provided for @dashboard_today.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get dashboard_today;

  /// No description provided for @dashboard_yesterday.
  ///
  /// In en, this message translates to:
  /// **'Yesterday'**
  String get dashboard_yesterday;

  /// No description provided for @dashboard_pillsTaken.
  ///
  /// In en, this message translates to:
  /// **'{taken} of {total} pills taken'**
  String dashboard_pillsTaken(int taken, int total);

  /// No description provided for @dashboard_somethingWentWrong.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong'**
  String get dashboard_somethingWentWrong;

  /// No description provided for @dashboard_selectProfile.
  ///
  /// In en, this message translates to:
  /// **'Select a profile to see your schedule'**
  String get dashboard_selectProfile;

  /// No description provided for @dashboard_nothingScheduledToday.
  ///
  /// In en, this message translates to:
  /// **'Nothing scheduled for today'**
  String get dashboard_nothingScheduledToday;

  /// No description provided for @dashboard_nothingScheduledThisDay.
  ///
  /// In en, this message translates to:
  /// **'Nothing scheduled on this day'**
  String get dashboard_nothingScheduledThisDay;

  /// No description provided for @dashboard_asNeeded.
  ///
  /// In en, this message translates to:
  /// **'AS NEEDED'**
  String get dashboard_asNeeded;

  /// No description provided for @dashboard_notTakenToday.
  ///
  /// In en, this message translates to:
  /// **'Not taken today'**
  String get dashboard_notTakenToday;

  /// No description provided for @dashboard_takenTimesToday.
  ///
  /// In en, this message translates to:
  /// **'Taken {count}× today'**
  String dashboard_takenTimesToday(int count);

  /// No description provided for @dashboard_logDose.
  ///
  /// In en, this message translates to:
  /// **'Log dose'**
  String get dashboard_logDose;

  /// No description provided for @dashboard_syncFailingTooltip.
  ///
  /// In en, this message translates to:
  /// **'Sync failing — tap for details'**
  String get dashboard_syncFailingTooltip;

  /// No description provided for @dashboard_backToToday.
  ///
  /// In en, this message translates to:
  /// **'Back to today'**
  String get dashboard_backToToday;

  /// No description provided for @dashboard_previousDay.
  ///
  /// In en, this message translates to:
  /// **'Previous day'**
  String get dashboard_previousDay;

  /// No description provided for @dashboard_nextDay.
  ///
  /// In en, this message translates to:
  /// **'Next day'**
  String get dashboard_nextDay;

  /// No description provided for @dashboard_scheduledTime.
  ///
  /// In en, this message translates to:
  /// **'Scheduled: {time}'**
  String dashboard_scheduledTime(String time);

  /// No description provided for @dashboard_noteLabel.
  ///
  /// In en, this message translates to:
  /// **'Note'**
  String get dashboard_noteLabel;

  /// No description provided for @dashboard_noteHint.
  ///
  /// In en, this message translates to:
  /// **'Add a note for this dose…'**
  String get dashboard_noteHint;

  /// No description provided for @dashboard_statusTaken.
  ///
  /// In en, this message translates to:
  /// **'Taken'**
  String get dashboard_statusTaken;

  /// No description provided for @dashboard_statusMissed.
  ///
  /// In en, this message translates to:
  /// **'Missed'**
  String get dashboard_statusMissed;

  /// No description provided for @dashboard_statusSkipped.
  ///
  /// In en, this message translates to:
  /// **'Skipped'**
  String get dashboard_statusSkipped;

  /// No description provided for @dashboard_statusPending.
  ///
  /// In en, this message translates to:
  /// **'Pending'**
  String get dashboard_statusPending;

  /// No description provided for @dashboard_statusTakenBadge.
  ///
  /// In en, this message translates to:
  /// **'✓ Taken'**
  String get dashboard_statusTakenBadge;

  /// No description provided for @dashboard_statusMissedBadge.
  ///
  /// In en, this message translates to:
  /// **'✗ Missed'**
  String get dashboard_statusMissedBadge;

  /// No description provided for @dashboard_statusSkippedBadge.
  ///
  /// In en, this message translates to:
  /// **'Skipped'**
  String get dashboard_statusSkippedBadge;

  /// No description provided for @dashboard_statusPendingBadge.
  ///
  /// In en, this message translates to:
  /// **'Pending'**
  String get dashboard_statusPendingBadge;

  /// No description provided for @history_calendar.
  ///
  /// In en, this message translates to:
  /// **'Calendar'**
  String get history_calendar;

  /// No description provided for @history_list.
  ///
  /// In en, this message translates to:
  /// **'List'**
  String get history_list;

  /// No description provided for @history_exportTooltip.
  ///
  /// In en, this message translates to:
  /// **'Export dose history'**
  String get history_exportTooltip;

  /// No description provided for @history_couldNotLoad.
  ///
  /// In en, this message translates to:
  /// **'Could not load history'**
  String get history_couldNotLoad;

  /// No description provided for @people_dayProgress.
  ///
  /// In en, this message translates to:
  /// **'{taken} of {planned} taken today'**
  String people_dayProgress(Object planned, Object taken);

  /// No description provided for @history_quietDay.
  ///
  /// In en, this message translates to:
  /// **'Nothing recorded on {date}'**
  String history_quietDay(Object date);

  /// No description provided for @history_quietDayBody.
  ///
  /// In en, this message translates to:
  /// **'No dose was planned or recorded for this day on this phone. That does not mean care was missed.'**
  String get history_quietDayBody;

  /// No description provided for @history_earlierRecords.
  ///
  /// In en, this message translates to:
  /// **'Earlier: {date}'**
  String history_earlierRecords(Object date);

  /// No description provided for @history_laterRecords.
  ///
  /// In en, this message translates to:
  /// **'Later: {date}'**
  String history_laterRecords(Object date);

  /// No description provided for @history_noHistory.
  ///
  /// In en, this message translates to:
  /// **'No history yet'**
  String get history_noHistory;

  /// No description provided for @history_takenAt.
  ///
  /// In en, this message translates to:
  /// **'taken at {time}'**
  String history_takenAt(String time);

  /// No description provided for @history_scheduledAt.
  ///
  /// In en, this message translates to:
  /// **'Scheduled {time}'**
  String history_scheduledAt(String time);

  /// No description provided for @history_noDoses.
  ///
  /// In en, this message translates to:
  /// **'no doses'**
  String get history_noDoses;

  /// No description provided for @history_adherence.
  ///
  /// In en, this message translates to:
  /// **'{percent} adherence'**
  String history_adherence(String percent);

  /// No description provided for @history_ribbonDay.
  ///
  /// In en, this message translates to:
  /// **'{date}, {taken} of {total} planned doses taken'**
  String history_ribbonDay(String date, int taken, int total);

  /// No description provided for @history_ribbonDayEmpty.
  ///
  /// In en, this message translates to:
  /// **'{date}, no planned doses'**
  String history_ribbonDayEmpty(String date);

  /// No description provided for @history_unseenTitle.
  ///
  /// In en, this message translates to:
  /// **'Before {name} was on this phone'**
  String history_unseenTitle(String name);

  /// No description provided for @history_unseenTitleAll.
  ///
  /// In en, this message translates to:
  /// **'Before care began on this phone'**
  String get history_unseenTitleAll;

  /// No description provided for @history_unseenBody.
  ///
  /// In en, this message translates to:
  /// **'{name} has been on this phone since {date}. Days before that have no records here.'**
  String history_unseenBody(String name, String date);

  /// No description provided for @history_unseenBodyAll.
  ///
  /// In en, this message translates to:
  /// **'Care on this phone began on {date}. Days before that have no records here.'**
  String history_unseenBodyAll(String date);

  /// No description provided for @history_ribbonDayUnseen.
  ///
  /// In en, this message translates to:
  /// **'{date}, before {name} was on this phone'**
  String history_ribbonDayUnseen(String date, String name);

  /// No description provided for @history_ribbonDayUnseenAll.
  ///
  /// In en, this message translates to:
  /// **'{date}, before care began on this phone'**
  String history_ribbonDayUnseenAll(String date);

  /// One dose on History's day line, shown when its dot is tapped and read by screen readers. outcome is Taken, Skipped, Planned, Not recorded or As needed.
  ///
  /// In en, this message translates to:
  /// **'{time} · {medication} for {person} · {outcome}'**
  String history_lineDose(
    String time,
    String medication,
    String person,
    String outcome,
  );

  /// One dose on a person's day line on People, shown when its dot is tapped. outcome is Taken, Skipped, Planned, Not recorded or As needed.
  ///
  /// In en, this message translates to:
  /// **'{time} · {medication} · {outcome}'**
  String people_lineDose(String time, String medication, String outcome);

  /// Doses close together on History's day line share one dot.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 dose around {time}} other{{count} doses around {time}}}'**
  String history_lineCluster(int count, String time);

  /// No description provided for @pills_title.
  ///
  /// In en, this message translates to:
  /// **'Pills'**
  String get pills_title;

  /// No description provided for @pills_edit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get pills_edit;

  /// No description provided for @pills_deleteCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Delete 1 pill?} other{Delete {count} pills?}}'**
  String pills_deleteCount(int count);

  /// No description provided for @pills_deleteConfirmMessage.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{This will also remove all schedules and reminders for this pill. This cannot be undone.} other{This will also remove all schedules and reminders for these pills. This cannot be undone.}}'**
  String pills_deleteConfirmMessage(int count);

  /// No description provided for @pills_deletedCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 pill deleted} other{{count} pills deleted}}'**
  String pills_deletedCount(int count);

  /// No description provided for @pills_couldNotLoad.
  ///
  /// In en, this message translates to:
  /// **'Could not load pills.'**
  String get pills_couldNotLoad;

  /// No description provided for @pills_noPillsYet.
  ///
  /// In en, this message translates to:
  /// **'No pills yet'**
  String get pills_noPillsYet;

  /// No description provided for @pills_addFirstSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Add your first pill to get started.'**
  String get pills_addFirstSubtitle;

  /// No description provided for @pills_addFirstCta.
  ///
  /// In en, this message translates to:
  /// **'Add your first pill'**
  String get pills_addFirstCta;

  /// No description provided for @pills_noEnabledProfiles.
  ///
  /// In en, this message translates to:
  /// **'No enabled profiles'**
  String get pills_noEnabledProfiles;

  /// No description provided for @pills_enableProfileHint.
  ///
  /// In en, this message translates to:
  /// **'Enable at least one profile in Profiles.'**
  String get pills_enableProfileHint;

  /// No description provided for @pills_todayAt.
  ///
  /// In en, this message translates to:
  /// **'Today at {time}'**
  String pills_todayAt(String time);

  /// No description provided for @pills_tomorrowAt.
  ///
  /// In en, this message translates to:
  /// **'Tomorrow at {time}'**
  String pills_tomorrowAt(String time);

  /// No description provided for @pills_weekdayAt.
  ///
  /// In en, this message translates to:
  /// **'{weekday} at {time}'**
  String pills_weekdayAt(String weekday, String time);

  /// No description provided for @pills_noActiveSchedules.
  ///
  /// In en, this message translates to:
  /// **'No active schedules'**
  String get pills_noActiveSchedules;

  /// No description provided for @pills_daily.
  ///
  /// In en, this message translates to:
  /// **'Daily'**
  String get pills_daily;

  /// No description provided for @pills_custom.
  ///
  /// In en, this message translates to:
  /// **'Custom'**
  String get pills_custom;

  /// No description provided for @pills_stockLeft.
  ///
  /// In en, this message translates to:
  /// **'{stock} left'**
  String pills_stockLeft(int stock);

  /// No description provided for @pills_noSchedulesYet.
  ///
  /// In en, this message translates to:
  /// **'No schedules yet'**
  String get pills_noSchedulesYet;

  /// No description provided for @pills_addSchedule.
  ///
  /// In en, this message translates to:
  /// **'Add schedule'**
  String get pills_addSchedule;

  /// No description provided for @pills_deletePill.
  ///
  /// In en, this message translates to:
  /// **'Delete pill?'**
  String get pills_deletePill;

  /// No description provided for @pills_deletePillMessage.
  ///
  /// In en, this message translates to:
  /// **'Deleting \"{name}\" will also remove all its schedules and cancel its reminders. This cannot be undone.'**
  String pills_deletePillMessage(String name);

  /// No description provided for @pills_couldNotDelete.
  ///
  /// In en, this message translates to:
  /// **'Could not delete pill'**
  String get pills_couldNotDelete;

  /// No description provided for @pills_deleteSelectedTooltip.
  ///
  /// In en, this message translates to:
  /// **'Delete selected pills'**
  String get pills_deleteSelectedTooltip;

  /// No description provided for @pills_addPillTooltip.
  ///
  /// In en, this message translates to:
  /// **'Add pill'**
  String get pills_addPillTooltip;

  /// No description provided for @pills_editPillTooltip.
  ///
  /// In en, this message translates to:
  /// **'Edit pill'**
  String get pills_editPillTooltip;

  /// No description provided for @pills_deletePillTooltip.
  ///
  /// In en, this message translates to:
  /// **'Delete pill'**
  String get pills_deletePillTooltip;

  /// No description provided for @pills_editScheduleTooltip.
  ///
  /// In en, this message translates to:
  /// **'Edit schedule'**
  String get pills_editScheduleTooltip;

  /// No description provided for @pills_deleteScheduleTooltip.
  ///
  /// In en, this message translates to:
  /// **'Delete schedule'**
  String get pills_deleteScheduleTooltip;

  /// No description provided for @pills_deleteScheduleTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete schedule?'**
  String get pills_deleteScheduleTitle;

  /// No description provided for @pills_deleteScheduleMessage.
  ///
  /// In en, this message translates to:
  /// **'Remove the {frequency} reminder at {time}? This cannot be undone.'**
  String pills_deleteScheduleMessage(String frequency, String time);

  /// No description provided for @pills_couldNotDeleteSchedule.
  ///
  /// In en, this message translates to:
  /// **'Could not delete schedule'**
  String get pills_couldNotDeleteSchedule;

  /// No description provided for @pills_editPillTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit Pill'**
  String get pills_editPillTitle;

  /// No description provided for @pills_newPillTitle.
  ///
  /// In en, this message translates to:
  /// **'New Pill'**
  String get pills_newPillTitle;

  /// No description provided for @pills_nameRequired.
  ///
  /// In en, this message translates to:
  /// **'Name is required'**
  String get pills_nameRequired;

  /// No description provided for @pills_nameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name *'**
  String get pills_nameLabel;

  /// No description provided for @pills_dosageLabel.
  ///
  /// In en, this message translates to:
  /// **'Dosage (e.g. 10 mg)'**
  String get pills_dosageLabel;

  /// No description provided for @pills_notesLabel.
  ///
  /// In en, this message translates to:
  /// **'Notes'**
  String get pills_notesLabel;

  /// No description provided for @pills_colorLabel.
  ///
  /// In en, this message translates to:
  /// **'Color'**
  String get pills_colorLabel;

  /// No description provided for @pills_inventoryLabel.
  ///
  /// In en, this message translates to:
  /// **'Inventory'**
  String get pills_inventoryLabel;

  /// No description provided for @pills_trackStock.
  ///
  /// In en, this message translates to:
  /// **'Track stock'**
  String get pills_trackStock;

  /// No description provided for @pills_trackStockSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Get notified when running low'**
  String get pills_trackStockSubtitle;

  /// No description provided for @pills_currentStock.
  ///
  /// In en, this message translates to:
  /// **'Current stock'**
  String get pills_currentStock;

  /// No description provided for @pills_alertWhenBelow.
  ///
  /// In en, this message translates to:
  /// **'Alert when below'**
  String get pills_alertWhenBelow;

  /// No description provided for @pills_required.
  ///
  /// In en, this message translates to:
  /// **'Required'**
  String get pills_required;

  /// No description provided for @pills_enterANumber.
  ///
  /// In en, this message translates to:
  /// **'Enter a number'**
  String get pills_enterANumber;

  /// No description provided for @pills_scheduleType.
  ///
  /// In en, this message translates to:
  /// **'Schedule type'**
  String get pills_scheduleType;

  /// No description provided for @pills_asNeededPrn.
  ///
  /// In en, this message translates to:
  /// **'As-needed (PRN)'**
  String get pills_asNeededPrn;

  /// No description provided for @pills_asNeededSubtitle.
  ///
  /// In en, this message translates to:
  /// **'No fixed schedule — log doses manually'**
  String get pills_asNeededSubtitle;

  /// No description provided for @pills_updateProfiles.
  ///
  /// In en, this message translates to:
  /// **'Update profiles'**
  String get pills_updateProfiles;

  /// No description provided for @pills_assignToProfiles.
  ///
  /// In en, this message translates to:
  /// **'Assign to profiles'**
  String get pills_assignToProfiles;

  /// No description provided for @pills_selectAtLeastOneProfile.
  ///
  /// In en, this message translates to:
  /// **'Select at least one profile'**
  String get pills_selectAtLeastOneProfile;

  /// No description provided for @pills_addedToProfiles.
  ///
  /// In en, this message translates to:
  /// **'Added to {count} profile(s); some failed to sync.'**
  String pills_addedToProfiles(int count);

  /// No description provided for @pills_alsoUpdateSiblings.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Also update 1 other profile} other{Also update {count} other profiles}}'**
  String pills_alsoUpdateSiblings(int count);

  /// No description provided for @pills_applyChangesTo.
  ///
  /// In en, this message translates to:
  /// **'Apply changes to:'**
  String get pills_applyChangesTo;

  /// No description provided for @pills_fieldName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get pills_fieldName;

  /// No description provided for @pills_fieldDosage.
  ///
  /// In en, this message translates to:
  /// **'Dosage'**
  String get pills_fieldDosage;

  /// No description provided for @pills_fieldNotes.
  ///
  /// In en, this message translates to:
  /// **'Notes'**
  String get pills_fieldNotes;

  /// No description provided for @pills_fieldColor.
  ///
  /// In en, this message translates to:
  /// **'Color'**
  String get pills_fieldColor;

  /// No description provided for @pills_noProfilesAvailable.
  ///
  /// In en, this message translates to:
  /// **'No profiles available yet. Create a profile first.'**
  String get pills_noProfilesAvailable;

  /// No description provided for @pills_savedCouldNotUpdateSiblings.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Saved. Could not update 1 sibling.} other{Saved. Could not update {count} siblings.}}'**
  String pills_savedCouldNotUpdateSiblings(int count);

  /// No description provided for @schedules_screenTitle.
  ///
  /// In en, this message translates to:
  /// **'Schedules'**
  String get schedules_screenTitle;

  /// No description provided for @schedules_couldNotLoad.
  ///
  /// In en, this message translates to:
  /// **'Could not load schedules.'**
  String get schedules_couldNotLoad;

  /// No description provided for @schedules_emptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No schedules yet'**
  String get schedules_emptyTitle;

  /// No description provided for @schedules_emptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Enable a profile and add pills to create schedules.'**
  String get schedules_emptySubtitle;

  /// No description provided for @schedules_noSchedulesYet.
  ///
  /// In en, this message translates to:
  /// **'No schedules yet'**
  String get schedules_noSchedulesYet;

  /// No description provided for @schedules_addSchedule.
  ///
  /// In en, this message translates to:
  /// **'Add schedule'**
  String get schedules_addSchedule;

  /// No description provided for @schedules_editScheduleTooltip.
  ///
  /// In en, this message translates to:
  /// **'Edit schedule'**
  String get schedules_editScheduleTooltip;

  /// No description provided for @schedules_deleteScheduleTooltip.
  ///
  /// In en, this message translates to:
  /// **'Delete schedule'**
  String get schedules_deleteScheduleTooltip;

  /// No description provided for @schedules_deleteScheduleTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete schedule?'**
  String get schedules_deleteScheduleTitle;

  /// No description provided for @schedules_deleteScheduleMessage.
  ///
  /// In en, this message translates to:
  /// **'Remove the {frequency} reminder at {time}? This cannot be undone.'**
  String schedules_deleteScheduleMessage(String frequency, String time);

  /// No description provided for @schedules_custom.
  ///
  /// In en, this message translates to:
  /// **'Custom'**
  String get schedules_custom;

  /// No description provided for @schedules_editTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit Schedule'**
  String get schedules_editTitle;

  /// No description provided for @schedules_newTitle.
  ///
  /// In en, this message translates to:
  /// **'New Schedule'**
  String get schedules_newTitle;

  /// No description provided for @schedules_timeLabel.
  ///
  /// In en, this message translates to:
  /// **'Time'**
  String get schedules_timeLabel;

  /// No description provided for @schedules_timeSemantic.
  ///
  /// In en, this message translates to:
  /// **'Schedule time, {time}. Tap to change'**
  String schedules_timeSemantic(String time);

  /// No description provided for @schedules_frequencyLabel.
  ///
  /// In en, this message translates to:
  /// **'Frequency'**
  String get schedules_frequencyLabel;

  /// No description provided for @schedules_daily.
  ///
  /// In en, this message translates to:
  /// **'Daily'**
  String get schedules_daily;

  /// No description provided for @schedules_specificDays.
  ///
  /// In en, this message translates to:
  /// **'Specific days'**
  String get schedules_specificDays;

  /// No description provided for @schedules_frequencySemantic.
  ///
  /// In en, this message translates to:
  /// **'Frequency: {frequency}'**
  String schedules_frequencySemantic(String frequency);

  /// No description provided for @schedules_active.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get schedules_active;

  /// No description provided for @schedules_paused.
  ///
  /// In en, this message translates to:
  /// **'paused'**
  String get schedules_paused;

  /// No description provided for @schedules_activeSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Turn off to pause without deleting'**
  String get schedules_activeSubtitle;

  /// No description provided for @schedules_selectAtLeastOneDay.
  ///
  /// In en, this message translates to:
  /// **'Please select at least one day'**
  String get schedules_selectAtLeastOneDay;

  /// No description provided for @schedules_dayMon.
  ///
  /// In en, this message translates to:
  /// **'Mon'**
  String get schedules_dayMon;

  /// No description provided for @schedules_dayTue.
  ///
  /// In en, this message translates to:
  /// **'Tue'**
  String get schedules_dayTue;

  /// No description provided for @schedules_dayWed.
  ///
  /// In en, this message translates to:
  /// **'Wed'**
  String get schedules_dayWed;

  /// No description provided for @schedules_dayThu.
  ///
  /// In en, this message translates to:
  /// **'Thu'**
  String get schedules_dayThu;

  /// No description provided for @schedules_dayFri.
  ///
  /// In en, this message translates to:
  /// **'Fri'**
  String get schedules_dayFri;

  /// No description provided for @schedules_daySat.
  ///
  /// In en, this message translates to:
  /// **'Sat'**
  String get schedules_daySat;

  /// No description provided for @schedules_daySun.
  ///
  /// In en, this message translates to:
  /// **'Sun'**
  String get schedules_daySun;

  /// No description provided for @profiles_title.
  ///
  /// In en, this message translates to:
  /// **'Profiles'**
  String get profiles_title;

  /// No description provided for @profiles_addTooltip.
  ///
  /// In en, this message translates to:
  /// **'Add profile'**
  String get profiles_addTooltip;

  /// No description provided for @profiles_couldNotLoad.
  ///
  /// In en, this message translates to:
  /// **'Could not load profiles.'**
  String get profiles_couldNotLoad;

  /// No description provided for @profiles_noProfYet.
  ///
  /// In en, this message translates to:
  /// **'No profiles yet'**
  String get profiles_noProfYet;

  /// No description provided for @profiles_createToGetStarted.
  ///
  /// In en, this message translates to:
  /// **'Create a profile to get started.'**
  String get profiles_createToGetStarted;

  /// No description provided for @profiles_createFirstCta.
  ///
  /// In en, this message translates to:
  /// **'Create your first profile'**
  String get profiles_createFirstCta;

  /// No description provided for @profiles_pillCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 pill} other{{count} pills}}'**
  String profiles_pillCount(int count);

  /// No description provided for @profiles_active.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get profiles_active;

  /// No description provided for @profiles_inactive.
  ///
  /// In en, this message translates to:
  /// **'Inactive'**
  String get profiles_inactive;

  /// No description provided for @profiles_primary.
  ///
  /// In en, this message translates to:
  /// **'Primary'**
  String get profiles_primary;

  /// No description provided for @profiles_deleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete {name}?'**
  String profiles_deleteTitle(String name);

  /// No description provided for @profiles_deleteMessage.
  ///
  /// In en, this message translates to:
  /// **'This will permanently delete all pills, schedules and dose history assigned to {name}.'**
  String profiles_deleteMessage(String name);

  /// No description provided for @profiles_pillsOverviewTitle.
  ///
  /// In en, this message translates to:
  /// **'{name} — Pills'**
  String profiles_pillsOverviewTitle(String name);

  /// No description provided for @profiles_couldNotLoadPills.
  ///
  /// In en, this message translates to:
  /// **'Could not load pills.'**
  String get profiles_couldNotLoadPills;

  /// No description provided for @profiles_noPillsAssigned.
  ///
  /// In en, this message translates to:
  /// **'No pills assigned to this profile'**
  String get profiles_noPillsAssigned;

  /// No description provided for @profiles_noSchedule.
  ///
  /// In en, this message translates to:
  /// **'No schedule'**
  String get profiles_noSchedule;

  /// No description provided for @profiles_editTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit Profile'**
  String get profiles_editTitle;

  /// No description provided for @profiles_newTitle.
  ///
  /// In en, this message translates to:
  /// **'New Profile'**
  String get profiles_newTitle;

  /// No description provided for @profiles_nameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get profiles_nameLabel;

  /// No description provided for @profiles_nameRequired.
  ///
  /// In en, this message translates to:
  /// **'Name is required'**
  String get profiles_nameRequired;

  /// No description provided for @profiles_avatarLabel.
  ///
  /// In en, this message translates to:
  /// **'Avatar'**
  String get profiles_avatarLabel;

  /// No description provided for @profiles_avatarSelected.
  ///
  /// In en, this message translates to:
  /// **'Avatar {emoji}, selected'**
  String profiles_avatarSelected(String emoji);

  /// No description provided for @profiles_avatarUnselected.
  ///
  /// In en, this message translates to:
  /// **'Avatar {emoji}'**
  String profiles_avatarUnselected(String emoji);

  /// No description provided for @profiles_primaryProfile.
  ///
  /// In en, this message translates to:
  /// **'Primary profile'**
  String get profiles_primaryProfile;

  /// No description provided for @profiles_setAsPrimary.
  ///
  /// In en, this message translates to:
  /// **'Set as primary profile'**
  String get profiles_setAsPrimary;

  /// No description provided for @profiles_deleteProfile.
  ///
  /// In en, this message translates to:
  /// **'Delete profile'**
  String get profiles_deleteProfile;

  /// No description provided for @profiles_deleted.
  ///
  /// In en, this message translates to:
  /// **'Profile deleted'**
  String get profiles_deleted;

  /// No description provided for @profiles_failedToDelete.
  ///
  /// In en, this message translates to:
  /// **'Failed to delete profile'**
  String get profiles_failedToDelete;

  /// No description provided for @settings_title.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings_title;

  /// No description provided for @settings_appearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get settings_appearance;

  /// No description provided for @settings_primaryProfile.
  ///
  /// In en, this message translates to:
  /// **'Primary Profile'**
  String get settings_primaryProfile;

  /// No description provided for @settings_pillEditing.
  ///
  /// In en, this message translates to:
  /// **'Pill Editing'**
  String get settings_pillEditing;

  /// No description provided for @settings_account.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get settings_account;

  /// No description provided for @settings_server.
  ///
  /// In en, this message translates to:
  /// **'Server'**
  String get settings_server;

  /// No description provided for @settings_session.
  ///
  /// In en, this message translates to:
  /// **'Session'**
  String get settings_session;

  /// No description provided for @settings_notifications.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get settings_notifications;

  /// No description provided for @settings_asNeededMeds.
  ///
  /// In en, this message translates to:
  /// **'As-needed medications'**
  String get settings_asNeededMeds;

  /// No description provided for @settings_data.
  ///
  /// In en, this message translates to:
  /// **'Sync'**
  String get settings_data;

  /// No description provided for @settings_about.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get settings_about;

  /// No description provided for @settings_theme.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get settings_theme;

  /// No description provided for @settings_themeAuto.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get settings_themeAuto;

  /// No description provided for @settings_themeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get settings_themeLight;

  /// No description provided for @settings_themeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get settings_themeDark;

  /// No description provided for @settings_dynamicColor.
  ///
  /// In en, this message translates to:
  /// **'Dynamic Color'**
  String get settings_dynamicColor;

  /// No description provided for @settings_dynamicColorSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Uses your wallpaper colors'**
  String get settings_dynamicColorSubtitle;

  /// No description provided for @settings_fontSize.
  ///
  /// In en, this message translates to:
  /// **'Font Size'**
  String get settings_fontSize;

  /// No description provided for @settings_fontDefault.
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get settings_fontDefault;

  /// No description provided for @settings_fontLarge.
  ///
  /// In en, this message translates to:
  /// **'Large'**
  String get settings_fontLarge;

  /// No description provided for @settings_fontXL.
  ///
  /// In en, this message translates to:
  /// **'XL'**
  String get settings_fontXL;

  /// No description provided for @settings_highContrast.
  ///
  /// In en, this message translates to:
  /// **'High Contrast'**
  String get settings_highContrast;

  /// No description provided for @settings_highContrastSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Bolder text, thicker borders'**
  String get settings_highContrastSubtitle;

  /// No description provided for @settings_reduceMotion.
  ///
  /// In en, this message translates to:
  /// **'Reduce motion'**
  String get settings_reduceMotion;

  /// No description provided for @settings_reduceMotionHint.
  ///
  /// In en, this message translates to:
  /// **'Things appear in place instead of moving. Words and vibrations stay the same.'**
  String get settings_reduceMotionHint;

  /// No description provided for @settings_reduceMotionByPhone.
  ///
  /// In en, this message translates to:
  /// **'On because of your phone\'s accessibility settings.'**
  String get settings_reduceMotionByPhone;

  /// No description provided for @settings_language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get settings_language;

  /// No description provided for @settings_languageSystem.
  ///
  /// In en, this message translates to:
  /// **'System default'**
  String get settings_languageSystem;

  /// No description provided for @settings_languageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get settings_languageEnglish;

  /// No description provided for @settings_languageRomanian.
  ///
  /// In en, this message translates to:
  /// **'Română'**
  String get settings_languageRomanian;

  /// No description provided for @recordedBy_title.
  ///
  /// In en, this message translates to:
  /// **'Recorded by'**
  String get recordedBy_title;

  /// No description provided for @recordedBy_primary.
  ///
  /// In en, this message translates to:
  /// **'The primary profile'**
  String get recordedBy_primary;

  /// No description provided for @recordedBy_custom.
  ///
  /// In en, this message translates to:
  /// **'A name I type'**
  String get recordedBy_custom;

  /// No description provided for @recordedBy_person.
  ///
  /// In en, this message translates to:
  /// **'The person taking it'**
  String get recordedBy_person;

  /// No description provided for @recordedBy_nameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get recordedBy_nameLabel;

  /// No description provided for @recordedBy_save.
  ///
  /// In en, this message translates to:
  /// **'Save name'**
  String get recordedBy_save;

  /// No description provided for @recordedBy_saved.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get recordedBy_saved;

  /// No description provided for @recordedBy_saveFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not save the name'**
  String get recordedBy_saveFailed;

  /// No description provided for @recordedBy_explainer.
  ///
  /// In en, this message translates to:
  /// **'Applies to doses recorded from now on. Earlier records keep their name.'**
  String get recordedBy_explainer;

  /// No description provided for @recordedBy_personNote.
  ///
  /// In en, this message translates to:
  /// **'This names the person the dose belongs to, even if someone else recorded it.'**
  String get recordedBy_personNote;

  /// No description provided for @settings_couldNotLoadPrimary.
  ///
  /// In en, this message translates to:
  /// **'Could not load primary profile'**
  String get settings_couldNotLoadPrimary;

  /// No description provided for @settings_couldNotLoadProfiles.
  ///
  /// In en, this message translates to:
  /// **'Could not load profiles'**
  String get settings_couldNotLoadProfiles;

  /// No description provided for @settings_noProfilesAvailable.
  ///
  /// In en, this message translates to:
  /// **'No profiles available'**
  String get settings_noProfilesAvailable;

  /// No description provided for @settings_createProfileFirst.
  ///
  /// In en, this message translates to:
  /// **'Create a profile first.'**
  String get settings_createProfileFirst;

  /// No description provided for @settings_siblingDetection.
  ///
  /// In en, this message translates to:
  /// **'Sibling detection'**
  String get settings_siblingDetection;

  /// No description provided for @settings_siblingDetectionSubtitle.
  ///
  /// In en, this message translates to:
  /// **'When editing a pill, detect copies in other profiles'**
  String get settings_siblingDetectionSubtitle;

  /// No description provided for @settings_siblingName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get settings_siblingName;

  /// No description provided for @settings_siblingNameDosage.
  ///
  /// In en, this message translates to:
  /// **'Name + dosage'**
  String get settings_siblingNameDosage;

  /// No description provided for @settings_siblingAlwaysAsk.
  ///
  /// In en, this message translates to:
  /// **'Always ask'**
  String get settings_siblingAlwaysAsk;

  /// No description provided for @settings_changePassword.
  ///
  /// In en, this message translates to:
  /// **'Change password'**
  String get settings_changePassword;

  /// No description provided for @settings_connectedServer.
  ///
  /// In en, this message translates to:
  /// **'Connected server'**
  String get settings_connectedServer;

  /// No description provided for @settings_deviceName.
  ///
  /// In en, this message translates to:
  /// **'Device name'**
  String get settings_deviceName;

  /// No description provided for @settings_notSet.
  ///
  /// In en, this message translates to:
  /// **'Not set'**
  String get settings_notSet;

  /// No description provided for @settings_deviceNameHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. My Phone'**
  String get settings_deviceNameHint;

  /// No description provided for @settings_logOut.
  ///
  /// In en, this message translates to:
  /// **'Log out'**
  String get settings_logOut;

  /// No description provided for @settings_logOutSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Clear local tokens and end this session'**
  String get settings_logOutSubtitle;

  /// No description provided for @settings_snoozeDuration.
  ///
  /// In en, this message translates to:
  /// **'Snooze duration'**
  String get settings_snoozeDuration;

  /// No description provided for @settings_snoozeSubtitle.
  ///
  /// In en, this message translates to:
  /// **'How long reminders stay snoozed'**
  String get settings_snoozeSubtitle;

  /// No description provided for @settings_notificationSound.
  ///
  /// In en, this message translates to:
  /// **'Notification sound'**
  String get settings_notificationSound;

  /// No description provided for @settings_notificationPermission.
  ///
  /// In en, this message translates to:
  /// **'Notification permission'**
  String get settings_notificationPermission;

  /// No description provided for @settings_permGranted.
  ///
  /// In en, this message translates to:
  /// **'Granted'**
  String get settings_permGranted;

  /// No description provided for @settings_permDenied.
  ///
  /// In en, this message translates to:
  /// **'Denied'**
  String get settings_permDenied;

  /// No description provided for @settings_permNotDetermined.
  ///
  /// In en, this message translates to:
  /// **'Not determined'**
  String get settings_permNotDetermined;

  /// No description provided for @settings_openSettings.
  ///
  /// In en, this message translates to:
  /// **'Open Settings'**
  String get settings_openSettings;

  /// No description provided for @settings_exactAlarmPermission.
  ///
  /// In en, this message translates to:
  /// **'Exact alarm permission'**
  String get settings_exactAlarmPermission;

  /// No description provided for @settings_exactAlarmDenied.
  ///
  /// In en, this message translates to:
  /// **'Not granted — dose reminders will not fire'**
  String get settings_exactAlarmDenied;

  /// No description provided for @settings_batteryRestriction.
  ///
  /// In en, this message translates to:
  /// **'Background battery restriction'**
  String get settings_batteryRestriction;

  /// No description provided for @settings_batteryRestrictionSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Samsung / Xiaomi / Huawei: go to Settings → Battery → Background usage limits and add this app to Never sleeping apps. Without this, the OS may silently erase scheduled reminders.'**
  String get settings_batteryRestrictionSubtitle;

  /// No description provided for @settings_appSettings.
  ///
  /// In en, this message translates to:
  /// **'App settings'**
  String get settings_appSettings;

  /// No description provided for @settings_includeInStats.
  ///
  /// In en, this message translates to:
  /// **'Include in adherence stats'**
  String get settings_includeInStats;

  /// No description provided for @settings_includeInStatsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Count as-needed (PRN) doses in adherence calculations and the home widget'**
  String get settings_includeInStatsSubtitle;

  /// No description provided for @settings_showPrnInWidget.
  ///
  /// In en, this message translates to:
  /// **'Show in home widget'**
  String get settings_showPrnInWidget;

  /// No description provided for @settings_showPrnInWidgetSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Display as-needed medications at the bottom of the widget dose list'**
  String get settings_showPrnInWidgetSubtitle;

  /// No description provided for @settings_syncNow.
  ///
  /// In en, this message translates to:
  /// **'Sync now'**
  String get settings_syncNow;

  /// No description provided for @settings_syncNowSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Pull latest data from server'**
  String get settings_syncNowSubtitle;

  /// No description provided for @settings_syncFailing.
  ///
  /// In en, this message translates to:
  /// **'Sync failing'**
  String get settings_syncFailing;

  /// No description provided for @settings_syncing.
  ///
  /// In en, this message translates to:
  /// **'Syncing…'**
  String get settings_syncing;

  /// No description provided for @settings_synced.
  ///
  /// In en, this message translates to:
  /// **'Synced'**
  String get settings_synced;

  /// No description provided for @settings_syncAlreadyInProgress.
  ///
  /// In en, this message translates to:
  /// **'Sync already in progress'**
  String get settings_syncAlreadyInProgress;

  /// No description provided for @settings_syncFailedError.
  ///
  /// In en, this message translates to:
  /// **'Sync failed — {error}'**
  String settings_syncFailedError(String error);

  /// No description provided for @settings_syncComplete.
  ///
  /// In en, this message translates to:
  /// **'Sync complete'**
  String get settings_syncComplete;

  /// No description provided for @settings_changesWaiting.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 change waiting to sync} other{{count} changes waiting to sync}}'**
  String settings_changesWaiting(int count);

  /// No description provided for @settings_changesNeedAttention.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 change needs your attention} other{{count} changes need your attention}}'**
  String settings_changesNeedAttention(int count);

  /// No description provided for @sync_stockStaysOnPhone.
  ///
  /// In en, this message translates to:
  /// **'Stock counts stay on this phone until your server turns on stock sync.'**
  String get sync_stockStaysOnPhone;

  /// No description provided for @settings_changesRetrying.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 change will be retried automatically} other{{count} changes will be retried automatically}}'**
  String settings_changesRetrying(int count);

  /// No description provided for @settings_justNow.
  ///
  /// In en, this message translates to:
  /// **'Just now'**
  String get settings_justNow;

  /// No description provided for @settings_minutesAgo.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 minute ago} other{{count} minutes ago}}'**
  String settings_minutesAgo(int count);

  /// No description provided for @settings_hoursAgo.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 hour ago} other{{count} hours ago}}'**
  String settings_hoursAgo(int count);

  /// No description provided for @settings_never.
  ///
  /// In en, this message translates to:
  /// **'Never'**
  String get settings_never;

  /// No description provided for @settings_failingSince.
  ///
  /// In en, this message translates to:
  /// **'Failing since {time} — {error}'**
  String settings_failingSince(String time, String error);

  /// No description provided for @settings_retrying.
  ///
  /// In en, this message translates to:
  /// **'Retrying — {error}'**
  String settings_retrying(String error);

  /// No description provided for @settings_syncInProgress.
  ///
  /// In en, this message translates to:
  /// **'Sync in progress'**
  String get settings_syncInProgress;

  /// No description provided for @settings_deleteAProfile.
  ///
  /// In en, this message translates to:
  /// **'Delete a profile'**
  String get settings_deleteAProfile;

  /// No description provided for @settings_deleteAProfileSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Permanently remove a profile and all its data'**
  String get settings_deleteAProfileSubtitle;

  /// No description provided for @settings_noProfilesToDelete.
  ///
  /// In en, this message translates to:
  /// **'No profiles to delete'**
  String get settings_noProfilesToDelete;

  /// No description provided for @settings_deleteProfileCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Delete 1 profile?} other{Delete {count} profiles?}}'**
  String settings_deleteProfileCount(int count);

  /// No description provided for @settings_deleteProfileConfirm.
  ///
  /// In en, this message translates to:
  /// **'This will permanently delete {names} and all their pills, schedules, and dose history.'**
  String settings_deleteProfileConfirm(String names);

  /// No description provided for @settings_profilesDeleted.
  ///
  /// In en, this message translates to:
  /// **'Profiles deleted'**
  String get settings_profilesDeleted;

  /// No description provided for @settings_deleteSelected.
  ///
  /// In en, this message translates to:
  /// **'Delete selected'**
  String get settings_deleteSelected;

  /// No description provided for @settings_appVersion.
  ///
  /// In en, this message translates to:
  /// **'App version'**
  String get settings_appVersion;

  /// No description provided for @settings_changePasswordTitle.
  ///
  /// In en, this message translates to:
  /// **'Change password'**
  String get settings_changePasswordTitle;

  /// No description provided for @settings_currentPassword.
  ///
  /// In en, this message translates to:
  /// **'Current password'**
  String get settings_currentPassword;

  /// No description provided for @settings_newPassword.
  ///
  /// In en, this message translates to:
  /// **'New password'**
  String get settings_newPassword;

  /// No description provided for @settings_confirmNewPassword.
  ///
  /// In en, this message translates to:
  /// **'Confirm new password'**
  String get settings_confirmNewPassword;

  /// No description provided for @settings_currentPasswordRequired.
  ///
  /// In en, this message translates to:
  /// **'Current password is required'**
  String get settings_currentPasswordRequired;

  /// No description provided for @settings_newPasswordRequired.
  ///
  /// In en, this message translates to:
  /// **'New password is required'**
  String get settings_newPasswordRequired;

  /// No description provided for @settings_passwordMinLength.
  ///
  /// In en, this message translates to:
  /// **'Password must be at least 10 characters'**
  String get settings_passwordMinLength;

  /// No description provided for @settings_passwordMustDiffer.
  ///
  /// In en, this message translates to:
  /// **'New password must differ from current password'**
  String get settings_passwordMustDiffer;

  /// No description provided for @settings_confirmPasswordRequired.
  ///
  /// In en, this message translates to:
  /// **'Please confirm your new password'**
  String get settings_confirmPasswordRequired;

  /// No description provided for @settings_passwordsDoNotMatch.
  ///
  /// In en, this message translates to:
  /// **'Passwords do not match'**
  String get settings_passwordsDoNotMatch;

  /// No description provided for @settings_updatePassword.
  ///
  /// In en, this message translates to:
  /// **'Update password'**
  String get settings_updatePassword;

  /// No description provided for @settings_passwordUpdated.
  ///
  /// In en, this message translates to:
  /// **'Password updated'**
  String get settings_passwordUpdated;

  /// No description provided for @settings_currentPasswordIncorrect.
  ///
  /// In en, this message translates to:
  /// **'Current password is incorrect'**
  String get settings_currentPasswordIncorrect;

  /// No description provided for @settings_minutesLabel.
  ///
  /// In en, this message translates to:
  /// **'Minutes'**
  String get settings_minutesLabel;

  /// No description provided for @settings_minutesRange.
  ///
  /// In en, this message translates to:
  /// **'Enter a value between {min} and {max}'**
  String settings_minutesRange(int min, int max);

  /// No description provided for @settings_valueMin.
  ///
  /// In en, this message translates to:
  /// **'{value} min'**
  String settings_valueMin(int value);

  /// No description provided for @settings_rangeMin.
  ///
  /// In en, this message translates to:
  /// **'{min}..{max} min'**
  String settings_rangeMin(int min, int max);

  /// No description provided for @settings_decreaseTooltip.
  ///
  /// In en, this message translates to:
  /// **'Decrease {title}'**
  String settings_decreaseTooltip(String title);

  /// No description provided for @settings_increaseTooltip.
  ///
  /// In en, this message translates to:
  /// **'Increase {title}'**
  String settings_increaseTooltip(String title);

  /// No description provided for @analytics_last7Days.
  ///
  /// In en, this message translates to:
  /// **'Last 7 days'**
  String get analytics_last7Days;

  /// No description provided for @analytics_last30Days.
  ///
  /// In en, this message translates to:
  /// **'Last 30 days'**
  String get analytics_last30Days;

  /// No description provided for @analytics_weeklyTrend.
  ///
  /// In en, this message translates to:
  /// **'Weekly trend'**
  String get analytics_weeklyTrend;

  /// No description provided for @analytics_byPill30Days.
  ///
  /// In en, this message translates to:
  /// **'By medication (30 days)'**
  String get analytics_byPill30Days;

  /// No description provided for @analytics_noDosesLast30.
  ///
  /// In en, this message translates to:
  /// **'No doses in the last 30 days'**
  String get analytics_noDosesLast30;

  /// No description provided for @analytics_thisWeek.
  ///
  /// In en, this message translates to:
  /// **'This week'**
  String get analytics_thisWeek;

  /// No description provided for @analytics_noData.
  ///
  /// In en, this message translates to:
  /// **'no data'**
  String get analytics_noData;

  /// No description provided for @analytics_couldNotLoadStats.
  ///
  /// In en, this message translates to:
  /// **'Could not load stats'**
  String get analytics_couldNotLoadStats;

  /// No description provided for @analytics_previousMonth.
  ///
  /// In en, this message translates to:
  /// **'Previous month'**
  String get analytics_previousMonth;

  /// No description provided for @analytics_nextMonth.
  ///
  /// In en, this message translates to:
  /// **'Next month'**
  String get analytics_nextMonth;

  /// No description provided for @export_title.
  ///
  /// In en, this message translates to:
  /// **'Export Dose History'**
  String get export_title;

  /// No description provided for @export_profile.
  ///
  /// In en, this message translates to:
  /// **'Profile: {name}'**
  String export_profile(String name);

  /// No description provided for @export_dateRange.
  ///
  /// In en, this message translates to:
  /// **'Date Range'**
  String get export_dateRange;

  /// No description provided for @export_last7Days.
  ///
  /// In en, this message translates to:
  /// **'Last 7 days'**
  String get export_last7Days;

  /// No description provided for @export_last30Days.
  ///
  /// In en, this message translates to:
  /// **'Last 30 days'**
  String get export_last30Days;

  /// No description provided for @export_last3Months.
  ///
  /// In en, this message translates to:
  /// **'Last 3 months'**
  String get export_last3Months;

  /// No description provided for @export_custom.
  ///
  /// In en, this message translates to:
  /// **'Custom…'**
  String get export_custom;

  /// No description provided for @export_format.
  ///
  /// In en, this message translates to:
  /// **'Format'**
  String get export_format;

  /// No description provided for @export_both.
  ///
  /// In en, this message translates to:
  /// **'Both'**
  String get export_both;

  /// No description provided for @export_generating.
  ///
  /// In en, this message translates to:
  /// **'Generating…'**
  String get export_generating;

  /// No description provided for @export_exportAndShare.
  ///
  /// In en, this message translates to:
  /// **'Export & Share'**
  String get export_exportAndShare;

  /// No description provided for @export_failed.
  ///
  /// In en, this message translates to:
  /// **'Export failed: {error}'**
  String export_failed(String error);

  /// No description provided for @colors_coral.
  ///
  /// In en, this message translates to:
  /// **'Coral'**
  String get colors_coral;

  /// No description provided for @colors_amber.
  ///
  /// In en, this message translates to:
  /// **'Amber'**
  String get colors_amber;

  /// No description provided for @colors_yellow.
  ///
  /// In en, this message translates to:
  /// **'Yellow'**
  String get colors_yellow;

  /// No description provided for @colors_green.
  ///
  /// In en, this message translates to:
  /// **'Green'**
  String get colors_green;

  /// No description provided for @colors_teal.
  ///
  /// In en, this message translates to:
  /// **'Teal'**
  String get colors_teal;

  /// No description provided for @colors_blue.
  ///
  /// In en, this message translates to:
  /// **'Blue'**
  String get colors_blue;

  /// No description provided for @colors_lavender.
  ///
  /// In en, this message translates to:
  /// **'Lavender'**
  String get colors_lavender;

  /// No description provided for @colors_grey.
  ///
  /// In en, this message translates to:
  /// **'Grey'**
  String get colors_grey;

  /// No description provided for @colors_rose.
  ///
  /// In en, this message translates to:
  /// **'Rose'**
  String get colors_rose;

  /// No description provided for @colors_peach.
  ///
  /// In en, this message translates to:
  /// **'Peach'**
  String get colors_peach;

  /// No description provided for @colors_mint.
  ///
  /// In en, this message translates to:
  /// **'Mint'**
  String get colors_mint;

  /// No description provided for @colors_indigo.
  ///
  /// In en, this message translates to:
  /// **'Indigo'**
  String get colors_indigo;

  /// No description provided for @nav_home.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get nav_home;

  /// No description provided for @nav_profiles.
  ///
  /// In en, this message translates to:
  /// **'Profiles'**
  String get nav_profiles;

  /// No description provided for @nav_pills.
  ///
  /// In en, this message translates to:
  /// **'Pills'**
  String get nav_pills;

  /// No description provided for @nav_schedules.
  ///
  /// In en, this message translates to:
  /// **'Schedules'**
  String get nav_schedules;

  /// No description provided for @nav_logs.
  ///
  /// In en, this message translates to:
  /// **'Logs'**
  String get nav_logs;

  /// No description provided for @nav_settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get nav_settings;

  /// No description provided for @nav_pressBackAgain.
  ///
  /// In en, this message translates to:
  /// **'Press Back again to exit'**
  String get nav_pressBackAgain;

  /// No description provided for @onboarding_welcome.
  ///
  /// In en, this message translates to:
  /// **'Welcome to Simpastil!'**
  String get onboarding_welcome;

  /// No description provided for @onboarding_subtitle.
  ///
  /// In en, this message translates to:
  /// **'Let\'s set up your first medication so you never miss a dose.'**
  String get onboarding_subtitle;

  /// No description provided for @onboarding_addPill.
  ///
  /// In en, this message translates to:
  /// **'Add a pill'**
  String get onboarding_addPill;

  /// No description provided for @onboarding_exploreLater.
  ///
  /// In en, this message translates to:
  /// **'Explore first'**
  String get onboarding_exploreLater;

  /// No description provided for @dashboard_emptyNoPillsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Add your first pill and schedule to see your daily doses here.'**
  String get dashboard_emptyNoPillsSubtitle;

  /// No description provided for @dashboard_emptyNoPillsCta.
  ///
  /// In en, this message translates to:
  /// **'Add a pill'**
  String get dashboard_emptyNoPillsCta;

  /// No description provided for @dashboard_emptyNoProfileSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Select or create a profile to get started.'**
  String get dashboard_emptyNoProfileSubtitle;

  /// No description provided for @dashboard_emptyNoProfileCta.
  ///
  /// In en, this message translates to:
  /// **'Go to Profiles'**
  String get dashboard_emptyNoProfileCta;

  /// No description provided for @history_emptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Your dose history will appear here once you start logging.'**
  String get history_emptySubtitle;

  /// No description provided for @schedules_emptyCta.
  ///
  /// In en, this message translates to:
  /// **'Add a pill first'**
  String get schedules_emptyCta;

  /// No description provided for @semantics_loading.
  ///
  /// In en, this message translates to:
  /// **'Loading'**
  String get semantics_loading;

  /// No description provided for @semantics_selected.
  ///
  /// In en, this message translates to:
  /// **'selected'**
  String get semantics_selected;

  /// No description provided for @semantics_notSelected.
  ///
  /// In en, this message translates to:
  /// **'not selected'**
  String get semantics_notSelected;

  /// No description provided for @semantics_doseMarked.
  ///
  /// In en, this message translates to:
  /// **'{pill} marked as {status}'**
  String semantics_doseMarked(String pill, String status);

  /// No description provided for @settings_2faTitle.
  ///
  /// In en, this message translates to:
  /// **'Two-factor authentication'**
  String get settings_2faTitle;

  /// No description provided for @settings_2faSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Add extra security to your account'**
  String get settings_2faSubtitle;

  /// No description provided for @settings_2faFlowTitle.
  ///
  /// In en, this message translates to:
  /// **'Two-factor authentication'**
  String get settings_2faFlowTitle;

  /// No description provided for @settings_2faDescription.
  ///
  /// In en, this message translates to:
  /// **'Add an extra layer of security to your account by requiring a verification code from an authenticator app when you sign in.'**
  String get settings_2faDescription;

  /// No description provided for @settings_2faSetupButton.
  ///
  /// In en, this message translates to:
  /// **'Set up 2FA'**
  String get settings_2faSetupButton;

  /// No description provided for @settings_2faStep1Label.
  ///
  /// In en, this message translates to:
  /// **'1. Add this account to your authenticator app (Google Authenticator, Authy, etc.)'**
  String get settings_2faStep1Label;

  /// No description provided for @settings_2faManualKeyLabel.
  ///
  /// In en, this message translates to:
  /// **'Manual entry key:'**
  String get settings_2faManualKeyLabel;

  /// No description provided for @settings_2faStep2Label.
  ///
  /// In en, this message translates to:
  /// **'2. Enter the 6-digit code from your authenticator app to verify'**
  String get settings_2faStep2Label;

  /// No description provided for @settings_2faCodeLabel.
  ///
  /// In en, this message translates to:
  /// **'Code'**
  String get settings_2faCodeLabel;

  /// No description provided for @settings_2faVerifyButton.
  ///
  /// In en, this message translates to:
  /// **'Verify and enable'**
  String get settings_2faVerifyButton;

  /// No description provided for @settings_2faSuccess.
  ///
  /// In en, this message translates to:
  /// **'Two-factor authentication is now enabled!'**
  String get settings_2faSuccess;

  /// No description provided for @settings_2faBackupCodesDescription.
  ///
  /// In en, this message translates to:
  /// **'Save these backup codes in a safe place. You can use them to sign in if you lose access to your authenticator app. Each code can only be used once.'**
  String get settings_2faBackupCodesDescription;

  /// No description provided for @settings_2faBackupCodesCopied.
  ///
  /// In en, this message translates to:
  /// **'Backup codes copied'**
  String get settings_2faBackupCodesCopied;

  /// No description provided for @settings_2faBackupCodesCopyButton.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get settings_2faBackupCodesCopyButton;

  /// No description provided for @settings_2faBackupCodesDoneButton.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get settings_2faBackupCodesDoneButton;

  /// No description provided for @settings_2faDisabled.
  ///
  /// In en, this message translates to:
  /// **'Two-factor authentication disabled'**
  String get settings_2faDisabled;

  /// No description provided for @settings_2faDisableDescription.
  ///
  /// In en, this message translates to:
  /// **'Enter your authenticator code or a backup code to disable two-factor authentication.'**
  String get settings_2faDisableDescription;

  /// No description provided for @settings_2faDisableCodeLabel.
  ///
  /// In en, this message translates to:
  /// **'Code'**
  String get settings_2faDisableCodeLabel;

  /// No description provided for @settings_2faDisableButton.
  ///
  /// In en, this message translates to:
  /// **'Disable 2FA'**
  String get settings_2faDisableButton;

  /// No description provided for @settings_2faCodeRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter the code from your authenticator app'**
  String get settings_2faCodeRequired;

  /// No description provided for @settings_2faCodeRequiredDisable.
  ///
  /// In en, this message translates to:
  /// **'Enter your authenticator code to disable 2FA'**
  String get settings_2faCodeRequiredDisable;

  /// No description provided for @shared_copiedToClipboard.
  ///
  /// In en, this message translates to:
  /// **'Copied to clipboard'**
  String get shared_copiedToClipboard;

  /// No description provided for @auth_2faStepLabel.
  ///
  /// In en, this message translates to:
  /// **'Two-factor authentication'**
  String get auth_2faStepLabel;

  /// No description provided for @auth_2faEnterCodeTitle.
  ///
  /// In en, this message translates to:
  /// **'Enter verification code'**
  String get auth_2faEnterCodeTitle;

  /// No description provided for @auth_2faCodeDescription.
  ///
  /// In en, this message translates to:
  /// **'Open your authenticator app and enter the 6-digit code, or use a backup code.'**
  String get auth_2faCodeDescription;

  /// No description provided for @auth_2faCodeLabel.
  ///
  /// In en, this message translates to:
  /// **'Code'**
  String get auth_2faCodeLabel;

  /// No description provided for @auth_2faCodeRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter your verification code'**
  String get auth_2faCodeRequired;

  /// No description provided for @auth_2faVerifyButton.
  ///
  /// In en, this message translates to:
  /// **'Verify'**
  String get auth_2faVerifyButton;

  /// No description provided for @export_headerDate.
  ///
  /// In en, this message translates to:
  /// **'Date'**
  String get export_headerDate;

  /// No description provided for @export_headerScheduledTime.
  ///
  /// In en, this message translates to:
  /// **'Scheduled Time'**
  String get export_headerScheduledTime;

  /// No description provided for @export_headerPillName.
  ///
  /// In en, this message translates to:
  /// **'Pill Name'**
  String get export_headerPillName;

  /// No description provided for @export_headerDosage.
  ///
  /// In en, this message translates to:
  /// **'Dosage'**
  String get export_headerDosage;

  /// No description provided for @export_headerStatus.
  ///
  /// In en, this message translates to:
  /// **'Status'**
  String get export_headerStatus;

  /// No description provided for @export_headerTimeTaken.
  ///
  /// In en, this message translates to:
  /// **'Time Taken'**
  String get export_headerTimeTaken;

  /// No description provided for @export_headerNotes.
  ///
  /// In en, this message translates to:
  /// **'Notes'**
  String get export_headerNotes;

  /// No description provided for @export_headerProfile.
  ///
  /// In en, this message translates to:
  /// **'Profile'**
  String get export_headerProfile;

  /// No description provided for @export_headerPill.
  ///
  /// In en, this message translates to:
  /// **'Pill'**
  String get export_headerPill;

  /// No description provided for @export_headerTakenExpected.
  ///
  /// In en, this message translates to:
  /// **'Taken / Expected'**
  String get export_headerTakenExpected;

  /// No description provided for @export_headerMissed.
  ///
  /// In en, this message translates to:
  /// **'Missed'**
  String get export_headerMissed;

  /// No description provided for @export_headerAdherence.
  ///
  /// In en, this message translates to:
  /// **'Adherence'**
  String get export_headerAdherence;

  /// No description provided for @export_pdfTitle.
  ///
  /// In en, this message translates to:
  /// **'Simpastil - Medication Report'**
  String get export_pdfTitle;

  /// No description provided for @export_pdfProfile.
  ///
  /// In en, this message translates to:
  /// **'Profile: {name}'**
  String export_pdfProfile(String name);

  /// No description provided for @export_pdfDateRange.
  ///
  /// In en, this message translates to:
  /// **'Date range: {range}'**
  String export_pdfDateRange(String range);

  /// No description provided for @export_pdfGenerated.
  ///
  /// In en, this message translates to:
  /// **'Generated: {date}'**
  String export_pdfGenerated(String date);

  /// No description provided for @export_pdfDoseLog.
  ///
  /// In en, this message translates to:
  /// **'Dose Log'**
  String get export_pdfDoseLog;

  /// No description provided for @export_pdfAdherenceSummary.
  ///
  /// In en, this message translates to:
  /// **'Adherence Summary'**
  String get export_pdfAdherenceSummary;

  /// No description provided for @export_pdfOverallAdherence.
  ///
  /// In en, this message translates to:
  /// **'Overall adherence: {percent}'**
  String export_pdfOverallAdherence(String percent);

  /// No description provided for @export_pdfNoEntries.
  ///
  /// In en, this message translates to:
  /// **'No dose entries for this date range.'**
  String get export_pdfNoEntries;

  /// No description provided for @export_pdfPageNumber.
  ///
  /// In en, this message translates to:
  /// **'Page {current} of {total}'**
  String export_pdfPageNumber(int current, int total);

  /// No description provided for @export_statusTaken.
  ///
  /// In en, this message translates to:
  /// **'Taken'**
  String get export_statusTaken;

  /// No description provided for @export_statusMissed.
  ///
  /// In en, this message translates to:
  /// **'Missed'**
  String get export_statusMissed;

  /// No description provided for @export_statusSkipped.
  ///
  /// In en, this message translates to:
  /// **'Skipped'**
  String get export_statusSkipped;

  /// No description provided for @export_statusPending.
  ///
  /// In en, this message translates to:
  /// **'Pending'**
  String get export_statusPending;

  /// No description provided for @export_prnLabel.
  ///
  /// In en, this message translates to:
  /// **'PRN'**
  String get export_prnLabel;

  /// No description provided for @widget_notAuthenticated.
  ///
  /// In en, this message translates to:
  /// **'Open Simpastil to get started'**
  String get widget_notAuthenticated;

  /// No description provided for @widget_nothingScheduled.
  ///
  /// In en, this message translates to:
  /// **'Nothing scheduled today'**
  String get widget_nothingScheduled;

  /// No description provided for @widget_summary.
  ///
  /// In en, this message translates to:
  /// **'{taken} of {total} taken'**
  String widget_summary(int taken, int total);

  /// No description provided for @widget_moreDoses.
  ///
  /// In en, this message translates to:
  /// **'+{count} more'**
  String widget_moreDoses(int count);

  /// No description provided for @widget_take.
  ///
  /// In en, this message translates to:
  /// **'Take'**
  String get widget_take;

  /// No description provided for @widget_log.
  ///
  /// In en, this message translates to:
  /// **'Log'**
  String get widget_log;

  /// No description provided for @error_noConnection.
  ///
  /// In en, this message translates to:
  /// **'No internet connection. Changes saved locally.'**
  String get error_noConnection;

  /// No description provided for @error_sessionExpired.
  ///
  /// In en, this message translates to:
  /// **'Session expired. Please log in again.'**
  String get error_sessionExpired;

  /// No description provided for @error_pillNotFound.
  ///
  /// In en, this message translates to:
  /// **'Pill not found.'**
  String get error_pillNotFound;

  /// No description provided for @error_profileNotFound.
  ///
  /// In en, this message translates to:
  /// **'Profile not found.'**
  String get error_profileNotFound;

  /// No description provided for @error_serverError.
  ///
  /// In en, this message translates to:
  /// **'Server error ({statusCode}).'**
  String error_serverError(int statusCode);

  /// No description provided for @t08_today.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get t08_today;

  /// No description provided for @t08_medications.
  ///
  /// In en, this message translates to:
  /// **'Medications'**
  String get t08_medications;

  /// No description provided for @t08_history.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get t08_history;

  /// No description provided for @t08_people.
  ///
  /// In en, this message translates to:
  /// **'People'**
  String get t08_people;

  /// No description provided for @t08_startTitle.
  ///
  /// In en, this message translates to:
  /// **'A little care,\none day at a time.'**
  String get t08_startTitle;

  /// No description provided for @t08_startBody.
  ///
  /// In en, this message translates to:
  /// **'Keep medication and daily care together, privately on this device.'**
  String get t08_startBody;

  /// No description provided for @t08_start.
  ///
  /// In en, this message translates to:
  /// **'Get started'**
  String get t08_start;

  /// No description provided for @t08_connect.
  ///
  /// In en, this message translates to:
  /// **'Connect to shared care'**
  String get t08_connect;

  /// No description provided for @t08_local.
  ///
  /// In en, this message translates to:
  /// **'On this device'**
  String get t08_local;

  /// No description provided for @t08_personTitle.
  ///
  /// In en, this message translates to:
  /// **'Who are we caring for?'**
  String get t08_personTitle;

  /// No description provided for @t08_personBody.
  ///
  /// In en, this message translates to:
  /// **'You can add more people later. Your name as the person recording care stays separate.'**
  String get t08_personBody;

  /// No description provided for @t08_personName.
  ///
  /// In en, this message translates to:
  /// **'Person’s name'**
  String get t08_personName;

  /// No description provided for @t08_personSave.
  ///
  /// In en, this message translates to:
  /// **'Save person'**
  String get t08_personSave;

  /// No description provided for @t08_back.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get t08_back;

  /// No description provided for @t08_medicationTitle.
  ///
  /// In en, this message translates to:
  /// **'Add a medication'**
  String get t08_medicationTitle;

  /// No description provided for @t08_medicationBody.
  ///
  /// In en, this message translates to:
  /// **'Start with its name. You can add a routine after saving.'**
  String get t08_medicationBody;

  /// No description provided for @t08_medicationName.
  ///
  /// In en, this message translates to:
  /// **'Medication name'**
  String get t08_medicationName;

  /// No description provided for @t08_strength.
  ///
  /// In en, this message translates to:
  /// **'Package strength (optional)'**
  String get t08_strength;

  /// No description provided for @t08_strengthHint.
  ///
  /// In en, this message translates to:
  /// **'For example, 500 mg'**
  String get t08_strengthHint;

  /// No description provided for @t08_amount.
  ///
  /// In en, this message translates to:
  /// **'Amount per use'**
  String get t08_amount;

  /// No description provided for @t08_unknown.
  ///
  /// In en, this message translates to:
  /// **'Not specified'**
  String get t08_unknown;

  /// No description provided for @t08_quantity.
  ///
  /// In en, this message translates to:
  /// **'Quantity'**
  String get t08_quantity;

  /// No description provided for @t08_quantityHint.
  ///
  /// In en, this message translates to:
  /// **'For example, 1 or 1/2'**
  String get t08_quantityHint;

  /// No description provided for @t08_unit.
  ///
  /// In en, this message translates to:
  /// **'Unit'**
  String get t08_unit;

  /// No description provided for @t08_unitHint.
  ///
  /// In en, this message translates to:
  /// **'For example, tablet or mL'**
  String get t08_unitHint;

  /// No description provided for @t08_amountHelp.
  ///
  /// In en, this message translates to:
  /// **'Separate from package strength. Leave it unspecified if you are unsure.'**
  String get t08_amountHelp;

  /// No description provided for @t08_saveMedication.
  ///
  /// In en, this message translates to:
  /// **'Save medication'**
  String get t08_saveMedication;

  /// No description provided for @t08_medicationSaved.
  ///
  /// In en, this message translates to:
  /// **'Medication saved'**
  String get t08_medicationSaved;

  /// No description provided for @t08_routineTitle.
  ///
  /// In en, this message translates to:
  /// **'Make room for a routine'**
  String get t08_routineTitle;

  /// No description provided for @t08_routineBody.
  ///
  /// In en, this message translates to:
  /// **'Your medication is already saved. Choose when it belongs in your day.'**
  String get t08_routineBody;

  /// No description provided for @t08_addRoutine.
  ///
  /// In en, this message translates to:
  /// **'Add a routine'**
  String get t08_addRoutine;

  /// No description provided for @t08_notNow.
  ///
  /// In en, this message translates to:
  /// **'Not now'**
  String get t08_notNow;

  /// No description provided for @t08_daily.
  ///
  /// In en, this message translates to:
  /// **'Every day'**
  String get t08_daily;

  /// No description provided for @t08_time.
  ///
  /// In en, this message translates to:
  /// **'Time'**
  String get t08_time;

  /// No description provided for @t08_addTime.
  ///
  /// In en, this message translates to:
  /// **'Add another time'**
  String get t08_addTime;

  /// No description provided for @t08_removeTime.
  ///
  /// In en, this message translates to:
  /// **'Remove time'**
  String get t08_removeTime;

  /// No description provided for @t08_zone.
  ///
  /// In en, this message translates to:
  /// **'Routine time zone'**
  String get t08_zone;

  /// No description provided for @t08_zoneHelp.
  ///
  /// In en, this message translates to:
  /// **'Review this place. Routine times stay in this time zone when you travel.'**
  String get t08_zoneHelp;

  /// No description provided for @t08_preview.
  ///
  /// In en, this message translates to:
  /// **'Review next dose'**
  String get t08_preview;

  /// No description provided for @t08_reviewRoutine.
  ///
  /// In en, this message translates to:
  /// **'Next dose'**
  String get t08_reviewRoutine;

  /// No description provided for @t08_phoneTimeUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Your phone’s time zone couldn’t be read. Try again to review the next dose.'**
  String get t08_phoneTimeUnavailable;

  /// No description provided for @t08_bucharest.
  ///
  /// In en, this message translates to:
  /// **'Bucharest, Romania'**
  String get t08_bucharest;

  /// No description provided for @t08_savedPlaceTime.
  ///
  /// In en, this message translates to:
  /// **'{time} {place} time'**
  String t08_savedPlaceTime(String time, String place);

  /// No description provided for @t08_hereTime.
  ///
  /// In en, this message translates to:
  /// **'{time} here'**
  String t08_hereTime(String time);

  /// No description provided for @t08_effective.
  ///
  /// In en, this message translates to:
  /// **'Starts from this review'**
  String get t08_effective;

  /// No description provided for @t08_saveRoutine.
  ///
  /// In en, this message translates to:
  /// **'Save routine'**
  String get t08_saveRoutine;

  /// No description provided for @t08_routineSaved.
  ///
  /// In en, this message translates to:
  /// **'Routine saved'**
  String get t08_routineSaved;

  /// No description provided for @t08_edit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get t08_edit;

  /// No description provided for @t08_reminderTitle.
  ///
  /// In en, this message translates to:
  /// **'Care comes first.'**
  String get t08_reminderTitle;

  /// No description provided for @t08_reminderBody.
  ///
  /// In en, this message translates to:
  /// **'Your care is saved. Reminders are optional and can be set up separately.'**
  String get t08_reminderBody;

  /// No description provided for @t08_readyTitle.
  ///
  /// In en, this message translates to:
  /// **'Ready for your day.'**
  String get t08_readyTitle;

  /// No description provided for @t08_readyBody.
  ///
  /// In en, this message translates to:
  /// **'Your person and medication are saved on this device. You can return to them anytime.'**
  String get t08_readyBody;

  /// No description provided for @t08_openToday.
  ///
  /// In en, this message translates to:
  /// **'Go to Today'**
  String get t08_openToday;

  /// No description provided for @t08_saving.
  ///
  /// In en, this message translates to:
  /// **'Saving…'**
  String get t08_saving;

  /// No description provided for @t08_saved.
  ///
  /// In en, this message translates to:
  /// **'Saved on this device'**
  String get t08_saved;

  /// No description provided for @t08_pendingShare.
  ///
  /// In en, this message translates to:
  /// **'Saved here · waiting to share'**
  String get t08_pendingShare;

  /// No description provided for @t08_shared.
  ///
  /// In en, this message translates to:
  /// **'Accepted by shared care'**
  String get t08_shared;

  /// No description provided for @t08_reviewShare.
  ///
  /// In en, this message translates to:
  /// **'Saved here · sharing needs review'**
  String get t08_reviewShare;

  /// No description provided for @t08_unavailable.
  ///
  /// In en, this message translates to:
  /// **'Care is temporarily unavailable'**
  String get t08_unavailable;

  /// No description provided for @t08_unavailableBody.
  ///
  /// In en, this message translates to:
  /// **'Your saved care has not been replaced. Try again to open it.'**
  String get t08_unavailableBody;

  /// No description provided for @t08_saveError.
  ///
  /// In en, this message translates to:
  /// **'This could not be saved. Your existing care is safe. Try again.'**
  String get t08_saveError;

  /// No description provided for @t08_required.
  ///
  /// In en, this message translates to:
  /// **'Enter a name to continue'**
  String get t08_required;

  /// No description provided for @t08_invalidAmount.
  ///
  /// In en, this message translates to:
  /// **'Enter a positive quantity and an explicit unit'**
  String get t08_invalidAmount;

  /// No description provided for @t08_invalidRoutine.
  ///
  /// In en, this message translates to:
  /// **'Check the times and try the review again'**
  String get t08_invalidRoutine;

  /// No description provided for @t08_everyone.
  ///
  /// In en, this message translates to:
  /// **'Everyone'**
  String get t08_everyone;

  /// No description provided for @t08_viewPerson.
  ///
  /// In en, this message translates to:
  /// **'Viewing care for'**
  String get t08_viewPerson;

  /// No description provided for @t08_overview.
  ///
  /// In en, this message translates to:
  /// **'Day overview'**
  String get t08_overview;

  /// No description provided for @t08_previous.
  ///
  /// In en, this message translates to:
  /// **'Previous'**
  String get t08_previous;

  /// No description provided for @t08_next.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get t08_next;

  /// No description provided for @t08_takenNow.
  ///
  /// In en, this message translates to:
  /// **'Taken now'**
  String get t08_takenNow;

  /// No description provided for @t08_taken.
  ///
  /// In en, this message translates to:
  /// **'Taken'**
  String get t08_taken;

  /// No description provided for @t08_skipped.
  ///
  /// In en, this message translates to:
  /// **'Skipped'**
  String get t08_skipped;

  /// No description provided for @t08_unrecorded.
  ///
  /// In en, this message translates to:
  /// **'Not recorded'**
  String get t08_unrecorded;

  /// No description provided for @t08_undo.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get t08_undo;

  /// No description provided for @t08_unknownTime.
  ///
  /// In en, this message translates to:
  /// **'Actual time unknown'**
  String get t08_unknownTime;

  /// No description provided for @t08_noPeople.
  ///
  /// In en, this message translates to:
  /// **'Care starts with a person'**
  String get t08_noPeople;

  /// No description provided for @t08_noMedications.
  ///
  /// In en, this message translates to:
  /// **'A place for your medications'**
  String get t08_noMedications;

  /// No description provided for @t08_noRoutine.
  ///
  /// In en, this message translates to:
  /// **'Saved, without a routine'**
  String get t08_noRoutine;

  /// No description provided for @t08_noRoutineBody.
  ///
  /// In en, this message translates to:
  /// **'Your medication is here. Add a routine when you are ready.'**
  String get t08_noRoutineBody;

  /// No description provided for @t08_dayOff.
  ///
  /// In en, this message translates to:
  /// **'Nothing planned for this day'**
  String get t08_dayOff;

  /// No description provided for @t08_dayOffBody.
  ///
  /// In en, this message translates to:
  /// **'There are no planned doses on this routine’s calendar today.'**
  String get t08_dayOffBody;

  /// No description provided for @t08_later.
  ///
  /// In en, this message translates to:
  /// **'Coming up later'**
  String get t08_later;

  /// No description provided for @t08_recorded.
  ///
  /// In en, this message translates to:
  /// **'Today, recorded'**
  String get t08_recorded;

  /// No description provided for @t08_recordError.
  ///
  /// In en, this message translates to:
  /// **'This entry changed or could not be saved. Review it before trying again.'**
  String get t08_recordError;

  /// No description provided for @t08_undoStockUnchanged.
  ///
  /// In en, this message translates to:
  /// **'Undone. The stock count was not changed, because this dose was counted before stock tracking started. Correct the stock by hand if needed.'**
  String get t08_undoStockUnchanged;

  /// No description provided for @t08_asNeeded.
  ///
  /// In en, this message translates to:
  /// **'As needed'**
  String get t08_asNeeded;

  /// No description provided for @t08_asNeededBody.
  ///
  /// In en, this message translates to:
  /// **'Your as-needed medication is saved. It has no planned dose quota.'**
  String get t08_asNeededBody;

  /// No description provided for @t08_date.
  ///
  /// In en, this message translates to:
  /// **'Choose day'**
  String get t08_date;

  /// No description provided for @t08_returnToday.
  ///
  /// In en, this message translates to:
  /// **'Back to today'**
  String get t08_returnToday;

  /// No description provided for @t08_finishLater.
  ///
  /// In en, this message translates to:
  /// **'Save and finish later'**
  String get t08_finishLater;

  /// No description provided for @t08_draftSaved.
  ///
  /// In en, this message translates to:
  /// **'Progress saved'**
  String get t08_draftSaved;

  /// No description provided for @t08_scheduleTool.
  ///
  /// In en, this message translates to:
  /// **'Schedules and connected tools'**
  String get t08_scheduleTool;

  /// No description provided for @t08_position.
  ///
  /// In en, this message translates to:
  /// **'Item {current} of {total}'**
  String t08_position(int current, int total);

  /// No description provided for @t08_remaining.
  ///
  /// In en, this message translates to:
  /// **'{count} still to record'**
  String t08_remaining(int count);

  /// No description provided for @t08_forPerson.
  ///
  /// In en, this message translates to:
  /// **'For {name}'**
  String t08_forPerson(String name);

  /// No description provided for @core_notifPrivateTitle.
  ///
  /// In en, this message translates to:
  /// **'A gentle reminder'**
  String get core_notifPrivateTitle;

  /// No description provided for @core_notifPrivateBody.
  ///
  /// In en, this message translates to:
  /// **'Open Simpastil when you have a moment.'**
  String get core_notifPrivateBody;

  /// No description provided for @core_notifTestTitle.
  ///
  /// In en, this message translates to:
  /// **'This is how a reminder looks'**
  String get core_notifTestTitle;

  /// No description provided for @core_notifTestBody.
  ///
  /// In en, this message translates to:
  /// **'If you can see this, reminders reach you. Confirm it in Simpastil.'**
  String get core_notifTestBody;

  /// No description provided for @core_notifActionOpen.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get core_notifActionOpen;

  /// No description provided for @t09_routine.
  ///
  /// In en, this message translates to:
  /// **'Routine'**
  String get t09_routine;

  /// No description provided for @t09_routineDetails.
  ///
  /// In en, this message translates to:
  /// **'Routine details'**
  String get t09_routineDetails;

  /// No description provided for @t09_editRoutine.
  ///
  /// In en, this message translates to:
  /// **'Edit routine'**
  String get t09_editRoutine;

  /// No description provided for @t09_pattern.
  ///
  /// In en, this message translates to:
  /// **'When do you use it?'**
  String get t09_pattern;

  /// No description provided for @t09_weekdays.
  ///
  /// In en, this message translates to:
  /// **'Selected weekdays'**
  String get t09_weekdays;

  /// No description provided for @t09_interval.
  ///
  /// In en, this message translates to:
  /// **'Every few days'**
  String get t09_interval;

  /// No description provided for @t09_prn.
  ///
  /// In en, this message translates to:
  /// **'As needed'**
  String get t09_prn;

  /// No description provided for @t09_prnHelp.
  ///
  /// In en, this message translates to:
  /// **'No expected daily doses. Record each use when it happens.'**
  String get t09_prnHelp;

  /// No description provided for @t09_everyDays.
  ///
  /// In en, this message translates to:
  /// **'Number of calendar days'**
  String get t09_everyDays;

  /// No description provided for @t09_anchor.
  ///
  /// In en, this message translates to:
  /// **'Count from'**
  String get t09_anchor;

  /// No description provided for @t09_dates.
  ///
  /// In en, this message translates to:
  /// **'Optional dates'**
  String get t09_dates;

  /// No description provided for @t09_startDate.
  ///
  /// In en, this message translates to:
  /// **'First day'**
  String get t09_startDate;

  /// No description provided for @t09_endDate.
  ///
  /// In en, this message translates to:
  /// **'Last day (included)'**
  String get t09_endDate;

  /// No description provided for @t09_notSet.
  ///
  /// In en, this message translates to:
  /// **'Not set'**
  String get t09_notSet;

  /// No description provided for @t09_clearDate.
  ///
  /// In en, this message translates to:
  /// **'Remove date'**
  String get t09_clearDate;

  /// No description provided for @t09_changesFrom.
  ///
  /// In en, this message translates to:
  /// **'Changes from'**
  String get t09_changesFrom;

  /// No description provided for @t09_preserveRecords.
  ///
  /// In en, this message translates to:
  /// **'Recorded doses keep their original details.'**
  String get t09_preserveRecords;

  /// No description provided for @t09_before.
  ///
  /// In en, this message translates to:
  /// **'Current routine'**
  String get t09_before;

  /// No description provided for @t09_after.
  ///
  /// In en, this message translates to:
  /// **'Reviewed routine'**
  String get t09_after;

  /// No description provided for @t09_nextEntries.
  ///
  /// In en, this message translates to:
  /// **'Next planned doses'**
  String get t09_nextEntries;

  /// No description provided for @t09_noPreview.
  ///
  /// In en, this message translates to:
  /// **'No doses in the next 31 days. Review the pattern and dates before saving.'**
  String get t09_noPreview;

  /// No description provided for @t09_reviewChanges.
  ///
  /// In en, this message translates to:
  /// **'Review changes'**
  String get t09_reviewChanges;

  /// No description provided for @t09_changeZone.
  ///
  /// In en, this message translates to:
  /// **'Change time zone'**
  String get t09_changeZone;

  /// No description provided for @t09_chooseZone.
  ///
  /// In en, this message translates to:
  /// **'Choose a place'**
  String get t09_chooseZone;

  /// No description provided for @t09_unknownZone.
  ///
  /// In en, this message translates to:
  /// **'Time zone needs review'**
  String get t09_unknownZone;

  /// No description provided for @sync_scheduleTimezoneReviewRequired.
  ///
  /// In en, this message translates to:
  /// **'A routine time zone needs review. Choose a city or region.'**
  String get sync_scheduleTimezoneReviewRequired;

  /// No description provided for @t09_searchPlace.
  ///
  /// In en, this message translates to:
  /// **'Search places'**
  String get t09_searchPlace;

  /// No description provided for @t09_zoneHelp.
  ///
  /// In en, this message translates to:
  /// **'Times stay tied to this place when you travel. Changing it requires a new review.'**
  String get t09_zoneHelp;

  /// No description provided for @t09_utc.
  ///
  /// In en, this message translates to:
  /// **'Coordinated Universal Time'**
  String get t09_utc;

  /// No description provided for @t09_noRoutine.
  ///
  /// In en, this message translates to:
  /// **'Medication saved · No routine yet'**
  String get t09_noRoutine;

  /// No description provided for @t09_savedRoutine.
  ///
  /// In en, this message translates to:
  /// **'Routine saved'**
  String get t09_savedRoutine;

  /// No description provided for @t09_reviewConflict.
  ///
  /// In en, this message translates to:
  /// **'Care changed during this review. Review again before saving. Your choices are still here.'**
  String get t09_reviewConflict;

  /// No description provided for @t09_futureBoundary.
  ///
  /// In en, this message translates to:
  /// **'Choose a future time under “Changes from”, then review again.'**
  String get t09_futureBoundary;

  /// No description provided for @t09_legacyDosage.
  ///
  /// In en, this message translates to:
  /// **'Original dosage text · Not reviewed'**
  String get t09_legacyDosage;

  /// No description provided for @t09_reviewDetails.
  ///
  /// In en, this message translates to:
  /// **'Review medication details'**
  String get t09_reviewDetails;

  /// No description provided for @t09_editMedication.
  ///
  /// In en, this message translates to:
  /// **'Edit medication'**
  String get t09_editMedication;

  /// No description provided for @t09_form.
  ///
  /// In en, this message translates to:
  /// **'Form (optional)'**
  String get t09_form;

  /// No description provided for @t09_notes.
  ///
  /// In en, this message translates to:
  /// **'Notes (optional)'**
  String get t09_notes;

  /// No description provided for @t09_connectedDetails.
  ///
  /// In en, this message translates to:
  /// **'Reviewed amount, strength and form stay on this device. Shared medication changes are shown separately.'**
  String get t09_connectedDetails;

  /// No description provided for @t09_savedPending.
  ///
  /// In en, this message translates to:
  /// **'Saved here · Waiting to share'**
  String get t09_savedPending;

  /// No description provided for @t09_viewCare.
  ///
  /// In en, this message translates to:
  /// **'View care'**
  String get t09_viewCare;

  /// No description provided for @t09_addMedication.
  ///
  /// In en, this message translates to:
  /// **'Add medication for this person'**
  String get t09_addMedication;

  /// No description provided for @t09_personSaved.
  ///
  /// In en, this message translates to:
  /// **'Person saved'**
  String get t09_personSaved;

  /// No description provided for @t09_remindersLater.
  ///
  /// In en, this message translates to:
  /// **'Set up later'**
  String get t09_remindersLater;

  /// No description provided for @t09_allowReminders.
  ///
  /// In en, this message translates to:
  /// **'Allow reminders'**
  String get t09_allowReminders;

  /// No description provided for @t09_checkReminders.
  ///
  /// In en, this message translates to:
  /// **'Send a reminder check'**
  String get t09_checkReminders;

  /// No description provided for @t09_remindersAllowed.
  ///
  /// In en, this message translates to:
  /// **'This phone allows reminders. Delivery has not been confirmed.'**
  String get t09_remindersAllowed;

  /// No description provided for @t09_remindersUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Reminders are not ready on this phone. Your saved care is available.'**
  String get t09_remindersUnavailable;

  /// No description provided for @t09_checkScheduled.
  ///
  /// In en, this message translates to:
  /// **'Check scheduled. Confirm only if you saw it on this phone.'**
  String get t09_checkScheduled;

  /// No description provided for @t09_sawReminder.
  ///
  /// In en, this message translates to:
  /// **'I saw the reminder'**
  String get t09_sawReminder;

  /// No description provided for @t09_deliveryConfirmed.
  ///
  /// In en, this message translates to:
  /// **'You confirmed seeing the reminder on this phone.'**
  String get t09_deliveryConfirmed;

  /// No description provided for @t09_privacy.
  ///
  /// In en, this message translates to:
  /// **'Show medication details in reminders'**
  String get t09_privacy;

  /// No description provided for @t09_reminderSummary.
  ///
  /// In en, this message translates to:
  /// **'When off, reminders only ask you to open Simpastil.'**
  String get t09_reminderSummary;

  /// No description provided for @t09_savedSummary.
  ///
  /// In en, this message translates to:
  /// **'Saved on this device'**
  String get t09_savedSummary;

  /// No description provided for @t09_continueSetup.
  ///
  /// In en, this message translates to:
  /// **'Continue setup'**
  String get t09_continueSetup;

  /// No description provided for @t09_everyN.
  ///
  /// In en, this message translates to:
  /// **'Every {days} calendar days'**
  String t09_everyN(int days);

  /// No description provided for @t09_medicationAmountHelp.
  ///
  /// In en, this message translates to:
  /// **'This is the medication’s default amount. Review the amount in each routine separately.'**
  String get t09_medicationAmountHelp;

  /// No description provided for @t10_details.
  ///
  /// In en, this message translates to:
  /// **'Dose details'**
  String get t10_details;

  /// No description provided for @t10_recordDose.
  ///
  /// In en, this message translates to:
  /// **'Record a dose'**
  String get t10_recordDose;

  /// No description provided for @t10_recordedAmount.
  ///
  /// In en, this message translates to:
  /// **'Recorded amount'**
  String get t10_recordedAmount;

  /// No description provided for @t10_planned.
  ///
  /// In en, this message translates to:
  /// **'Planned'**
  String get t10_planned;

  /// No description provided for @t10_actual.
  ///
  /// In en, this message translates to:
  /// **'Actual time'**
  String get t10_actual;

  /// No description provided for @t10_entered.
  ///
  /// In en, this message translates to:
  /// **'Recorded in Simpastil'**
  String get t10_entered;

  /// No description provided for @t10_author.
  ///
  /// In en, this message translates to:
  /// **'Recorded by'**
  String get t10_author;

  /// No description provided for @t10_unknownAuthor.
  ///
  /// In en, this message translates to:
  /// **'Author unknown'**
  String get t10_unknownAuthor;

  /// No description provided for @t10_unnamedAuthor.
  ///
  /// In en, this message translates to:
  /// **'Author name not recorded'**
  String get t10_unnamedAuthor;

  /// No description provided for @t10_unknownDate.
  ///
  /// In en, this message translates to:
  /// **'Date unknown'**
  String get t10_unknownDate;

  /// No description provided for @t10_unknownMedication.
  ///
  /// In en, this message translates to:
  /// **'Medication details unavailable'**
  String get t10_unknownMedication;

  /// No description provided for @t10_unknownPerson.
  ///
  /// In en, this message translates to:
  /// **'Person unknown'**
  String get t10_unknownPerson;

  /// No description provided for @t10_recordHistory.
  ///
  /// In en, this message translates to:
  /// **'Record and corrections'**
  String get t10_recordHistory;

  /// No description provided for @t10_correct.
  ///
  /// In en, this message translates to:
  /// **'Correct this record'**
  String get t10_correct;

  /// No description provided for @t10_corrected.
  ///
  /// In en, this message translates to:
  /// **'Correction'**
  String get t10_corrected;

  /// No description provided for @t10_withdrawn.
  ///
  /// In en, this message translates to:
  /// **'Undo recorded'**
  String get t10_withdrawn;

  /// No description provided for @t10_skip.
  ///
  /// In en, this message translates to:
  /// **'Record as skipped'**
  String get t10_skip;

  /// No description provided for @t10_outcome.
  ///
  /// In en, this message translates to:
  /// **'Outcome'**
  String get t10_outcome;

  /// No description provided for @t10_chooseTime.
  ///
  /// In en, this message translates to:
  /// **'Choose a time'**
  String get t10_chooseTime;

  /// No description provided for @t10_timeHere.
  ///
  /// In en, this message translates to:
  /// **'Time on this device'**
  String get t10_timeHere;

  /// No description provided for @t10_reviewRecord.
  ///
  /// In en, this message translates to:
  /// **'Review this record'**
  String get t10_reviewRecord;

  /// No description provided for @t10_saveRecord.
  ///
  /// In en, this message translates to:
  /// **'Save record'**
  String get t10_saveRecord;

  /// No description provided for @t10_recordAnother.
  ///
  /// In en, this message translates to:
  /// **'Record another dose'**
  String get t10_recordAnother;

  /// No description provided for @t10_notes.
  ///
  /// In en, this message translates to:
  /// **'Note (optional)'**
  String get t10_notes;

  /// No description provided for @t10_noRecords.
  ///
  /// In en, this message translates to:
  /// **'No records yet'**
  String get t10_noRecords;

  /// No description provided for @t10_noRecordsBody.
  ///
  /// In en, this message translates to:
  /// **'Recorded doses and corrections will appear here. This does not mean that care was missed.'**
  String get t10_noRecordsBody;

  /// No description provided for @t10_historyHint.
  ///
  /// In en, this message translates to:
  /// **'Planned, actual and recorded times remain separate.'**
  String get t10_historyHint;

  /// No description provided for @t10_legacy.
  ///
  /// In en, this message translates to:
  /// **'Older record · some details are unknown'**
  String get t10_legacy;

  /// No description provided for @t10_readOnly.
  ///
  /// In en, this message translates to:
  /// **'This retained record can be read, but cannot be changed here.'**
  String get t10_readOnly;

  /// No description provided for @t10_select.
  ///
  /// In en, this message translates to:
  /// **'Select doses'**
  String get t10_select;

  /// No description provided for @t10_selection.
  ///
  /// In en, this message translates to:
  /// **'Review selected doses'**
  String get t10_selection;

  /// No description provided for @t10_choosePerson.
  ///
  /// In en, this message translates to:
  /// **'Choose one person before selecting doses.'**
  String get t10_choosePerson;

  /// No description provided for @t10_selectionHint.
  ///
  /// In en, this message translates to:
  /// **'Only these exact doses will be recorded. New arrivals are not added.'**
  String get t10_selectionHint;

  /// No description provided for @t10_reviewSelection.
  ///
  /// In en, this message translates to:
  /// **'Review selection'**
  String get t10_reviewSelection;

  /// No description provided for @t10_recordSelected.
  ///
  /// In en, this message translates to:
  /// **'Record selected doses'**
  String get t10_recordSelected;

  /// No description provided for @t10_savedItem.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get t10_savedItem;

  /// No description provided for @t10_retryItem.
  ///
  /// In en, this message translates to:
  /// **'Not saved · retry available'**
  String get t10_retryItem;

  /// No description provided for @t10_retryRemaining.
  ///
  /// In en, this message translates to:
  /// **'Retry unsaved doses'**
  String get t10_retryRemaining;

  /// No description provided for @t10_partial.
  ///
  /// In en, this message translates to:
  /// **'Some doses were saved. Review each result below.'**
  String get t10_partial;

  /// No description provided for @t10_allSaved.
  ///
  /// In en, this message translates to:
  /// **'Every selected dose was saved.'**
  String get t10_allSaved;

  /// No description provided for @t10_done.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get t10_done;

  /// No description provided for @t10_cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get t10_cancel;

  /// No description provided for @t10_edit.
  ///
  /// In en, this message translates to:
  /// **'Edit review'**
  String get t10_edit;

  /// No description provided for @t10_timeInvalid.
  ///
  /// In en, this message translates to:
  /// **'Check the chosen date and time.'**
  String get t10_timeInvalid;

  /// No description provided for @t10_unrecordedHint.
  ///
  /// In en, this message translates to:
  /// **'Unrecorded means no outcome has been recorded here. It does not mean missed.'**
  String get t10_unrecordedHint;

  /// No description provided for @t10_knownOutcomes.
  ///
  /// In en, this message translates to:
  /// **'All planned entries have a recorded outcome.'**
  String get t10_knownOutcomes;

  /// No description provided for @t10_savedLocal.
  ///
  /// In en, this message translates to:
  /// **'Saved on this device'**
  String get t10_savedLocal;

  /// No description provided for @t10_sharingPending.
  ///
  /// In en, this message translates to:
  /// **'Saved here · waiting to share'**
  String get t10_sharingPending;

  /// No description provided for @t10_sharingAccepted.
  ///
  /// In en, this message translates to:
  /// **'Shared record accepted'**
  String get t10_sharingAccepted;

  /// No description provided for @t10_sharingReview.
  ///
  /// In en, this message translates to:
  /// **'Saved here · shared record needs review'**
  String get t10_sharingReview;

  /// No description provided for @t10_sharingUncertain.
  ///
  /// In en, this message translates to:
  /// **'Saved here · sharing outcome unknown'**
  String get t10_sharingUncertain;

  /// No description provided for @t10_freshnessUnknown.
  ///
  /// In en, this message translates to:
  /// **'Server update status is unknown. You can record care on this device.'**
  String get t10_freshnessUnknown;

  /// No description provided for @t10_sharedUpdated.
  ///
  /// In en, this message translates to:
  /// **'Last server update received: {time}'**
  String t10_sharedUpdated(String time);

  /// No description provided for @t10_sharingCounts.
  ///
  /// In en, this message translates to:
  /// **'{pending} waiting · {review} to review · {uncertain} uncertain'**
  String t10_sharingCounts(int pending, int review, int uncertain);

  /// No description provided for @t10_syncing.
  ///
  /// In en, this message translates to:
  /// **'Receiving server updates…'**
  String get t10_syncing;

  /// No description provided for @t10_asNeededUndone.
  ///
  /// In en, this message translates to:
  /// **'This as-needed dose was undone.'**
  String get t10_asNeededUndone;

  /// No description provided for @t10_recordError.
  ///
  /// In en, this message translates to:
  /// **'This record was not confirmed. Retry keeps the same action and time.'**
  String get t10_recordError;

  /// No description provided for @t10_selectedCount.
  ///
  /// In en, this message translates to:
  /// **'{count} selected'**
  String t10_selectedCount(int count);

  /// No description provided for @t10_prnHint.
  ///
  /// In en, this message translates to:
  /// **'No daily quota. Record each administration when it happens.'**
  String get t10_prnHint;

  /// No description provided for @t10_loadMore.
  ///
  /// In en, this message translates to:
  /// **'Show earlier records'**
  String get t10_loadMore;

  /// No description provided for @t10_noPeopleBody.
  ///
  /// In en, this message translates to:
  /// **'Add a person to begin their care.'**
  String get t10_noPeopleBody;

  /// No description provided for @t10_noMedicationBody.
  ///
  /// In en, this message translates to:
  /// **'Add a medication for this person.'**
  String get t10_noMedicationBody;

  /// No description provided for @t10_chooseDate.
  ///
  /// In en, this message translates to:
  /// **'Choose a date'**
  String get t10_chooseDate;

  /// No description provided for @t11_entry.
  ///
  /// In en, this message translates to:
  /// **'Appearance and colors'**
  String get t11_entry;

  /// No description provided for @t11_scope.
  ///
  /// In en, this message translates to:
  /// **'Personal appearance on this device. Care, connections and setup stay unchanged.'**
  String get t11_scope;

  /// No description provided for @t11_preview.
  ///
  /// In en, this message translates to:
  /// **'Preview · Focus deck'**
  String get t11_preview;

  /// No description provided for @t11_exampleOnly.
  ///
  /// In en, this message translates to:
  /// **'Example only. Preview cannot record care.'**
  String get t11_exampleOnly;

  /// No description provided for @t11_examplePerson.
  ///
  /// In en, this message translates to:
  /// **'Example person'**
  String get t11_examplePerson;

  /// No description provided for @t11_exampleMedication.
  ///
  /// In en, this message translates to:
  /// **'Example medication'**
  String get t11_exampleMedication;

  /// No description provided for @t11_exampleAmount.
  ///
  /// In en, this message translates to:
  /// **'1 tablet · 09:00'**
  String get t11_exampleAmount;

  /// No description provided for @t11_exampleField.
  ///
  /// In en, this message translates to:
  /// **'Example note'**
  String get t11_exampleField;

  /// No description provided for @t11_exampleError.
  ///
  /// In en, this message translates to:
  /// **'Example message needing attention'**
  String get t11_exampleError;

  /// No description provided for @t11_colors.
  ///
  /// In en, this message translates to:
  /// **'Theme colors'**
  String get t11_colors;

  /// No description provided for @t11_actions.
  ///
  /// In en, this message translates to:
  /// **'Actions and accents'**
  String get t11_actions;

  /// No description provided for @t11_surfaces.
  ///
  /// In en, this message translates to:
  /// **'Surfaces and text'**
  String get t11_surfaces;

  /// No description provided for @t11_states.
  ///
  /// In en, this message translates to:
  /// **'Care states and people'**
  String get t11_states;

  /// No description provided for @t11_reset.
  ///
  /// In en, this message translates to:
  /// **'Restore appearance defaults'**
  String get t11_reset;

  /// No description provided for @t11_resetQuestion.
  ///
  /// In en, this message translates to:
  /// **'Restore appearance defaults?'**
  String get t11_resetQuestion;

  /// No description provided for @t11_resetExplanation.
  ///
  /// In en, this message translates to:
  /// **'This saves the default colors and display options. It does not remove care, connections, reminders or unfinished setup.'**
  String get t11_resetExplanation;

  /// No description provided for @t11_apply.
  ///
  /// In en, this message translates to:
  /// **'Apply appearance'**
  String get t11_apply;

  /// No description provided for @t11_applied.
  ///
  /// In en, this message translates to:
  /// **'Appearance saved on this device'**
  String get t11_applied;

  /// No description provided for @t11_resetSaved.
  ///
  /// In en, this message translates to:
  /// **'Default appearance restored'**
  String get t11_resetSaved;

  /// No description provided for @t11_saveError.
  ///
  /// In en, this message translates to:
  /// **'Appearance not saved. Your previous appearance is still applied. Try again.'**
  String get t11_saveError;

  /// No description provided for @t11_loadError.
  ///
  /// In en, this message translates to:
  /// **'Saved appearance could not be read. Retry, or restore appearance defaults. Your care remains unchanged.'**
  String get t11_loadError;

  /// No description provided for @t11_dynamicHint.
  ///
  /// In en, this message translates to:
  /// **'Uses device colors when available. Your individual color choices take priority.'**
  String get t11_dynamicHint;

  /// No description provided for @t11_dynamicUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Device colors are unavailable here. The Simpastil palette is used as the starting point.'**
  String get t11_dynamicUnavailable;

  /// No description provided for @t11_contrastHint.
  ///
  /// In en, this message translates to:
  /// **'Strengthens text, state colors and borders. Your chosen colors stay saved; the preview shows the readable result.'**
  String get t11_contrastHint;

  /// No description provided for @t11_contrastWarning.
  ///
  /// In en, this message translates to:
  /// **'Some text or actions may be hard to read. Adjust the colors or enable high contrast. Editor controls always use a readable palette.'**
  String get t11_contrastWarning;

  /// No description provided for @t11_defaultColor.
  ///
  /// In en, this message translates to:
  /// **'Theme default'**
  String get t11_defaultColor;

  /// No description provided for @t11_customColor.
  ///
  /// In en, this message translates to:
  /// **'Custom color'**
  String get t11_customColor;

  /// No description provided for @t11_hex.
  ///
  /// In en, this message translates to:
  /// **'Color code (6 hex digits)'**
  String get t11_hex;

  /// No description provided for @t11_hexError.
  ///
  /// In en, this message translates to:
  /// **'Enter six digits or letters from 0–9 and A–F.'**
  String get t11_hexError;

  /// No description provided for @t11_hue.
  ///
  /// In en, this message translates to:
  /// **'Hue'**
  String get t11_hue;

  /// No description provided for @t11_saturation.
  ///
  /// In en, this message translates to:
  /// **'Saturation'**
  String get t11_saturation;

  /// No description provided for @t11_value.
  ///
  /// In en, this message translates to:
  /// **'Brightness'**
  String get t11_value;

  /// No description provided for @t11_useColor.
  ///
  /// In en, this message translates to:
  /// **'Use this color'**
  String get t11_useColor;

  /// No description provided for @t11_useDefault.
  ///
  /// In en, this message translates to:
  /// **'Use theme default'**
  String get t11_useDefault;

  /// No description provided for @t11_primary.
  ///
  /// In en, this message translates to:
  /// **'Main action'**
  String get t11_primary;

  /// No description provided for @t11_onPrimary.
  ///
  /// In en, this message translates to:
  /// **'Text on main action'**
  String get t11_onPrimary;

  /// No description provided for @t11_primaryContainer.
  ///
  /// In en, this message translates to:
  /// **'Selected background'**
  String get t11_primaryContainer;

  /// No description provided for @t11_onPrimaryContainer.
  ///
  /// In en, this message translates to:
  /// **'Text on selected background'**
  String get t11_onPrimaryContainer;

  /// No description provided for @t11_background.
  ///
  /// In en, this message translates to:
  /// **'Page background'**
  String get t11_background;

  /// No description provided for @t11_text.
  ///
  /// In en, this message translates to:
  /// **'Main text'**
  String get t11_text;

  /// No description provided for @t11_surface.
  ///
  /// In en, this message translates to:
  /// **'Panels and dialogs'**
  String get t11_surface;

  /// No description provided for @t11_surfaceVariant.
  ///
  /// In en, this message translates to:
  /// **'Cards and fields'**
  String get t11_surfaceVariant;

  /// No description provided for @t11_mutedText.
  ///
  /// In en, this message translates to:
  /// **'Supporting text'**
  String get t11_mutedText;

  /// No description provided for @t11_border.
  ///
  /// In en, this message translates to:
  /// **'Borders'**
  String get t11_border;

  /// No description provided for @t11_secondary.
  ///
  /// In en, this message translates to:
  /// **'Secondary accent'**
  String get t11_secondary;

  /// No description provided for @t11_onSecondary.
  ///
  /// In en, this message translates to:
  /// **'Text on secondary accent'**
  String get t11_onSecondary;

  /// No description provided for @t11_tertiary.
  ///
  /// In en, this message translates to:
  /// **'Additional accent'**
  String get t11_tertiary;

  /// No description provided for @t11_onTertiary.
  ///
  /// In en, this message translates to:
  /// **'Text on additional accent'**
  String get t11_onTertiary;

  /// No description provided for @t11_error.
  ///
  /// In en, this message translates to:
  /// **'Error background'**
  String get t11_error;

  /// No description provided for @t11_onError.
  ///
  /// In en, this message translates to:
  /// **'Text on error'**
  String get t11_onError;

  /// No description provided for @t11_taken.
  ///
  /// In en, this message translates to:
  /// **'Taken'**
  String get t11_taken;

  /// No description provided for @t11_skipped.
  ///
  /// In en, this message translates to:
  /// **'Skipped'**
  String get t11_skipped;

  /// No description provided for @t11_unrecorded.
  ///
  /// In en, this message translates to:
  /// **'Not recorded'**
  String get t11_unrecorded;

  /// No description provided for @t11_activePerson.
  ///
  /// In en, this message translates to:
  /// **'Selected person'**
  String get t11_activePerson;

  /// No description provided for @t11_inactivePerson.
  ///
  /// In en, this message translates to:
  /// **'Other people'**
  String get t11_inactivePerson;

  /// No description provided for @r07_setupTitle.
  ///
  /// In en, this message translates to:
  /// **'Set up Simpastil'**
  String get r07_setupTitle;

  /// No description provided for @r07_firstMedication.
  ///
  /// In en, this message translates to:
  /// **'Add your first medication'**
  String get r07_firstMedication;

  /// No description provided for @r07_stepCount.
  ///
  /// In en, this message translates to:
  /// **'{current} of {total}'**
  String r07_stepCount(int current, int total);

  /// No description provided for @r07_strength.
  ///
  /// In en, this message translates to:
  /// **'Strength (optional)'**
  String get r07_strength;

  /// No description provided for @r07_tablet.
  ///
  /// In en, this message translates to:
  /// **'Tablet'**
  String get r07_tablet;

  /// No description provided for @r07_capsule.
  ///
  /// In en, this message translates to:
  /// **'Capsule'**
  String get r07_capsule;

  /// No description provided for @r07_liquid.
  ///
  /// In en, this message translates to:
  /// **'Liquid'**
  String get r07_liquid;

  /// No description provided for @r07_morning.
  ///
  /// In en, this message translates to:
  /// **'Morning'**
  String get r07_morning;

  /// No description provided for @r07_afternoon.
  ///
  /// In en, this message translates to:
  /// **'Afternoon'**
  String get r07_afternoon;

  /// No description provided for @r07_evening.
  ///
  /// In en, this message translates to:
  /// **'Evening'**
  String get r07_evening;

  /// No description provided for @r07_night.
  ///
  /// In en, this message translates to:
  /// **'Night'**
  String get r07_night;

  /// No description provided for @r07_upNext.
  ///
  /// In en, this message translates to:
  /// **'Up next'**
  String get r07_upNext;

  /// No description provided for @r07_laterDose.
  ///
  /// In en, this message translates to:
  /// **'Later: {name} at {time}'**
  String r07_laterDose(String name, String time);

  /// No description provided for @r07_otherDose.
  ///
  /// In en, this message translates to:
  /// **'{name} at {time}'**
  String r07_otherDose(String name, String time);

  /// No description provided for @r08_startTitle.
  ///
  /// In en, this message translates to:
  /// **'Start your routine'**
  String get r08_startTitle;

  /// No description provided for @r08_startBody.
  ///
  /// In en, this message translates to:
  /// **'Keep your routine on this device.\nConnect a server whenever you’re ready.'**
  String get r08_startBody;

  /// No description provided for @r08_noAccount.
  ///
  /// In en, this message translates to:
  /// **'No account or server needed'**
  String get r08_noAccount;

  /// No description provided for @r08_startHere.
  ///
  /// In en, this message translates to:
  /// **'Start on this device'**
  String get r08_startHere;

  /// No description provided for @r08_connect.
  ///
  /// In en, this message translates to:
  /// **'Connect to a server'**
  String get r08_connect;

  /// No description provided for @r08_restore.
  ///
  /// In en, this message translates to:
  /// **'Restore a backup'**
  String get r08_restore;

  /// No description provided for @r08_choiceLater.
  ///
  /// In en, this message translates to:
  /// **'Your choice can change later.'**
  String get r08_choiceLater;

  /// No description provided for @r08_personTitle.
  ///
  /// In en, this message translates to:
  /// **'Who will you help?'**
  String get r08_personTitle;

  /// No description provided for @r08_personHint.
  ///
  /// In en, this message translates to:
  /// **'Start with one person. You can add more people later.'**
  String get r08_personHint;

  /// No description provided for @r08_personIdentity.
  ///
  /// In en, this message translates to:
  /// **'Your name as the person recording care stays separate.'**
  String get r08_personIdentity;

  /// No description provided for @r08_routineTitle.
  ///
  /// In en, this message translates to:
  /// **'Set your routine'**
  String get r08_routineTitle;

  /// No description provided for @r08_repeat.
  ///
  /// In en, this message translates to:
  /// **'Repeat'**
  String get r08_repeat;

  /// No description provided for @r08_scheduledTime.
  ///
  /// In en, this message translates to:
  /// **'Scheduled time'**
  String get r08_scheduledTime;

  /// No description provided for @r08_remindersTitle.
  ///
  /// In en, this message translates to:
  /// **'Gentle reminders, if you want them'**
  String get r08_remindersTitle;

  /// No description provided for @r08_checkTitle.
  ///
  /// In en, this message translates to:
  /// **'Check that reminders reach you'**
  String get r08_checkTitle;

  /// No description provided for @r08_reminderPreview.
  ///
  /// In en, this message translates to:
  /// **'What a reminder looks like'**
  String get r08_reminderPreview;

  /// No description provided for @r08_notificationsAllowed.
  ///
  /// In en, this message translates to:
  /// **'Notifications allowed'**
  String get r08_notificationsAllowed;

  /// No description provided for @r08_notificationsNotAllowed.
  ///
  /// In en, this message translates to:
  /// **'Notifications not enabled yet'**
  String get r08_notificationsNotAllowed;

  /// No description provided for @r08_testConfirmed.
  ///
  /// In en, this message translates to:
  /// **'Test reminder confirmed'**
  String get r08_testConfirmed;

  /// No description provided for @r08_testNotConfirmed.
  ///
  /// In en, this message translates to:
  /// **'Test reminder not confirmed'**
  String get r08_testNotConfirmed;

  /// No description provided for @r08_checkHelp.
  ///
  /// In en, this message translates to:
  /// **'This harmless check does not record a dose. Confirm only after you see it on this phone.'**
  String get r08_checkHelp;

  /// No description provided for @r09_medicationsBody.
  ///
  /// In en, this message translates to:
  /// **'Manage and view all medications'**
  String get r09_medicationsBody;

  /// No description provided for @r09_searchMedications.
  ///
  /// In en, this message translates to:
  /// **'Search medications'**
  String get r09_searchMedications;

  /// No description provided for @r09_noMatchingMedications.
  ///
  /// In en, this message translates to:
  /// **'No matching medications'**
  String get r09_noMatchingMedications;

  /// No description provided for @r09_addMedication.
  ///
  /// In en, this message translates to:
  /// **'Add medication'**
  String get r09_addMedication;

  /// No description provided for @r09_noRoutine.
  ///
  /// In en, this message translates to:
  /// **'No routine yet'**
  String get r09_noRoutine;

  /// No description provided for @r09_medicationActions.
  ///
  /// In en, this message translates to:
  /// **'Medication actions'**
  String get r09_medicationActions;

  /// No description provided for @r09_viewDetails.
  ///
  /// In en, this message translates to:
  /// **'View details'**
  String get r09_viewDetails;

  /// No description provided for @r09_selectMedication.
  ///
  /// In en, this message translates to:
  /// **'Select medication'**
  String get r09_selectMedication;

  /// No description provided for @r09_clearSearch.
  ///
  /// In en, this message translates to:
  /// **'Clear search'**
  String get r09_clearSearch;

  /// No description provided for @r09_peopleToday.
  ///
  /// In en, this message translates to:
  /// **'People today'**
  String get r09_peopleToday;

  /// No description provided for @r09_peopleBody.
  ///
  /// In en, this message translates to:
  /// **'Care at a glance for the people you support'**
  String get r09_peopleBody;

  /// No description provided for @r09_medicationCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 medication} other{{count} medications}}'**
  String r09_medicationCount(int count);

  /// No description provided for @r09_viewEveryone.
  ///
  /// In en, this message translates to:
  /// **'View everyone'**
  String get r09_viewEveryone;

  /// No description provided for @r09_managePeople.
  ///
  /// In en, this message translates to:
  /// **'Manage people'**
  String get r09_managePeople;

  /// No description provided for @r09_viewRoutine.
  ///
  /// In en, this message translates to:
  /// **'View routine'**
  String get r09_viewRoutine;

  /// No description provided for @r09_allRecords.
  ///
  /// In en, this message translates to:
  /// **'All records'**
  String get r09_allRecords;

  /// No description provided for @r09_recordCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 record} other{{count} records}}'**
  String r09_recordCount(int count);

  /// No description provided for @r09_latestEntry.
  ///
  /// In en, this message translates to:
  /// **'Latest entry'**
  String get r09_latestEntry;

  /// No description provided for @r09_earlierDay.
  ///
  /// In en, this message translates to:
  /// **'Earlier this day'**
  String get r09_earlierDay;

  /// No description provided for @r09_searchHistory.
  ///
  /// In en, this message translates to:
  /// **'Search history'**
  String get r09_searchHistory;

  /// No description provided for @r09_noMatchingRecords.
  ///
  /// In en, this message translates to:
  /// **'No matching records'**
  String get r09_noMatchingRecords;

  /// No description provided for @r09_previousDay.
  ///
  /// In en, this message translates to:
  /// **'Previous day'**
  String get r09_previousDay;

  /// No description provided for @r09_nextDay.
  ///
  /// In en, this message translates to:
  /// **'Next day'**
  String get r09_nextDay;

  /// No description provided for @r09_recentDays.
  ///
  /// In en, this message translates to:
  /// **'Recent days'**
  String get r09_recentDays;

  /// No description provided for @r14_reviewDoses.
  ///
  /// In en, this message translates to:
  /// **'Review doses'**
  String get r14_reviewDoses;

  /// No description provided for @r14_chooseDoses.
  ///
  /// In en, this message translates to:
  /// **'Choose doses to review'**
  String get r14_chooseDoses;

  /// No description provided for @r14_personDay.
  ///
  /// In en, this message translates to:
  /// **'{person} · {day}'**
  String r14_personDay(String person, String day);

  /// No description provided for @r14_selectedDoses.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 dose selected} other{{count} doses selected}}'**
  String r14_selectedDoses(int count);

  /// No description provided for @r14_selectionCount.
  ///
  /// In en, this message translates to:
  /// **'{count} selected · Not saved yet'**
  String r14_selectionCount(int count);

  /// No description provided for @r14_unrecordedCount.
  ///
  /// In en, this message translates to:
  /// **'Not recorded · {count}'**
  String r14_unrecordedCount(int count);

  /// No description provided for @r14_reviewCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Review 1 dose} other{Review {count} doses}}'**
  String r14_reviewCount(int count);

  /// No description provided for @r14_recordCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Record 1 as taken} other{Record {count} as taken}}'**
  String r14_recordCount(int count);

  /// No description provided for @r14_clearSelection.
  ///
  /// In en, this message translates to:
  /// **'Clear selection'**
  String get r14_clearSelection;

  /// No description provided for @r14_remove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get r14_remove;

  /// No description provided for @r14_later.
  ///
  /// In en, this message translates to:
  /// **'Later'**
  String get r14_later;

  /// No description provided for @r14_plannedFor.
  ///
  /// In en, this message translates to:
  /// **'Planned for {day}'**
  String r14_plannedFor(String day);

  /// No description provided for @r14_recordFor.
  ///
  /// In en, this message translates to:
  /// **'This records the selected doses for {person}.'**
  String r14_recordFor(String person);

  /// No description provided for @r14_sameTime.
  ///
  /// In en, this message translates to:
  /// **'This time choice applies to every selected dose.'**
  String get r14_sameTime;

  /// No description provided for @r14_savedCount.
  ///
  /// In en, this message translates to:
  /// **'{saved} of {total} saved'**
  String r14_savedCount(int saved, int total);

  /// No description provided for @r15_noMedications.
  ///
  /// In en, this message translates to:
  /// **'No medications yet'**
  String get r15_noMedications;

  /// No description provided for @r15_addForPerson.
  ///
  /// In en, this message translates to:
  /// **'Add a medication for {person} when you’re ready.'**
  String r15_addForPerson(String person);

  /// No description provided for @r15_choosePerson.
  ///
  /// In en, this message translates to:
  /// **'Add medication for…'**
  String get r15_choosePerson;

  /// No description provided for @r15_chooseFirstPerson.
  ///
  /// In en, this message translates to:
  /// **'Choose a person to add their first medication.'**
  String get r15_chooseFirstPerson;

  /// No description provided for @r15_optionalSetup.
  ///
  /// In en, this message translates to:
  /// **'Routine and stock setup are optional.'**
  String get r15_optionalSetup;

  /// No description provided for @r15_nothingToday.
  ///
  /// In en, this message translates to:
  /// **'Nothing scheduled today'**
  String get r15_nothingToday;

  /// No description provided for @r15_nothingDay.
  ///
  /// In en, this message translates to:
  /// **'Nothing scheduled for this day'**
  String get r15_nothingDay;

  /// No description provided for @r15_nextBody.
  ///
  /// In en, this message translates to:
  /// **'Your next scheduled dose is shown below.'**
  String get r15_nextBody;

  /// No description provided for @r15_noNext.
  ///
  /// In en, this message translates to:
  /// **'No upcoming dose is available from the saved routine.'**
  String get r15_noNext;

  /// No description provided for @r15_nextDate.
  ///
  /// In en, this message translates to:
  /// **'Next · {date}'**
  String r15_nextDate(String date);

  /// No description provided for @r16_editTheme.
  ///
  /// In en, this message translates to:
  /// **'Edit theme'**
  String get r16_editTheme;

  /// No description provided for @r16_scope.
  ///
  /// In en, this message translates to:
  /// **'Personal appearance on this device'**
  String get r16_scope;

  /// No description provided for @r16_accent.
  ///
  /// In en, this message translates to:
  /// **'Accent'**
  String get r16_accent;

  /// No description provided for @r16_background.
  ///
  /// In en, this message translates to:
  /// **'Background'**
  String get r16_background;

  /// No description provided for @r16_text.
  ///
  /// In en, this message translates to:
  /// **'Text'**
  String get r16_text;

  /// No description provided for @r16_allColors.
  ///
  /// In en, this message translates to:
  /// **'All color controls'**
  String get r16_allColors;

  /// No description provided for @r16_formsPreview.
  ///
  /// In en, this message translates to:
  /// **'Preview forms and states'**
  String get r16_formsPreview;

  /// No description provided for @r16_displayOptions.
  ///
  /// In en, this message translates to:
  /// **'Display options'**
  String get r16_displayOptions;

  /// No description provided for @r16_example.
  ///
  /// In en, this message translates to:
  /// **'Example'**
  String get r16_example;

  /// No description provided for @r16_examplePerson.
  ///
  /// In en, this message translates to:
  /// **'Alex · 09:00'**
  String get r16_examplePerson;

  /// No description provided for @r16_exampleMedication.
  ///
  /// In en, this message translates to:
  /// **'Example tablet 20 mg'**
  String get r16_exampleMedication;

  /// No description provided for @r16_exampleAmount.
  ///
  /// In en, this message translates to:
  /// **'1 tablet'**
  String get r16_exampleAmount;

  /// No description provided for @t14_lockUseDeviceLock.
  ///
  /// In en, this message translates to:
  /// **'Use device lock'**
  String get t14_lockUseDeviceLock;

  /// No description provided for @t14_lockTitle.
  ///
  /// In en, this message translates to:
  /// **'Your care is locked'**
  String get t14_lockTitle;

  /// No description provided for @t14_lockBody.
  ///
  /// In en, this message translates to:
  /// **'Unlock with your device to continue. Scheduled reminders can still arrive.'**
  String get t14_lockBody;

  /// No description provided for @t14_lockChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking device authentication…'**
  String get t14_lockChecking;

  /// No description provided for @t14_lockCancelled.
  ///
  /// In en, this message translates to:
  /// **'Unlock was cancelled. Your care remains hidden.'**
  String get t14_lockCancelled;

  /// No description provided for @t14_lockUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Device authentication is unavailable. Your care remains hidden.'**
  String get t14_lockUnavailable;

  /// No description provided for @t14_lockWriteFailed.
  ///
  /// In en, this message translates to:
  /// **'The lock setting could not be confirmed. Unlock again to continue.'**
  String get t14_lockWriteFailed;

  /// No description provided for @t14_lockStale.
  ///
  /// In en, this message translates to:
  /// **'Unlock again to continue.'**
  String get t14_lockStale;

  /// No description provided for @t14_settingsLockTitle.
  ///
  /// In en, this message translates to:
  /// **'App lock'**
  String get t14_settingsLockTitle;

  /// No description provided for @t14_settingsLockBody.
  ///
  /// In en, this message translates to:
  /// **'Require device authentication when opening or returning to Simpastil on this device. Reminder and widget privacy settings stay separate.'**
  String get t14_settingsLockBody;

  /// No description provided for @t14_settingsLockEnableReason.
  ///
  /// In en, this message translates to:
  /// **'Turn on app lock'**
  String get t14_settingsLockEnableReason;

  /// No description provided for @t14_settingsLockDisableReason.
  ///
  /// In en, this message translates to:
  /// **'Turn off app lock'**
  String get t14_settingsLockDisableReason;

  /// No description provided for @t14_settingsLockCancelled.
  ///
  /// In en, this message translates to:
  /// **'App lock was not changed.'**
  String get t14_settingsLockCancelled;

  /// No description provided for @t14_settingsLockFailed.
  ///
  /// In en, this message translates to:
  /// **'The app-lock setting could not be confirmed. Try again.'**
  String get t14_settingsLockFailed;

  /// No description provided for @t14_personReminders.
  ///
  /// In en, this message translates to:
  /// **'Reminders on this device'**
  String get t14_personReminders;

  /// No description provided for @t14_personRemindersEnabled.
  ///
  /// In en, this message translates to:
  /// **'Include this person'**
  String get t14_personRemindersEnabled;

  /// No description provided for @t14_personRemindersBody.
  ///
  /// In en, this message translates to:
  /// **'Include this person in scheduled reminders and the home-screen widget on this device. Android notification permission is still required.'**
  String get t14_personRemindersBody;

  /// No description provided for @t15_intro.
  ///
  /// In en, this message translates to:
  /// **'Make Simpastil work for you'**
  String get t15_intro;

  /// No description provided for @t15_everyday.
  ///
  /// In en, this message translates to:
  /// **'Everyday preferences'**
  String get t15_everyday;

  /// No description provided for @t15_yourData.
  ///
  /// In en, this message translates to:
  /// **'Your data'**
  String get t15_yourData;

  /// No description provided for @t15_privacyAccess.
  ///
  /// In en, this message translates to:
  /// **'Privacy and access'**
  String get t15_privacyAccess;

  /// No description provided for @t15_layout.
  ///
  /// In en, this message translates to:
  /// **'App layout'**
  String get t15_layout;

  /// No description provided for @t15_focusDeck.
  ///
  /// In en, this message translates to:
  /// **'Focus deck'**
  String get t15_focusDeck;

  /// No description provided for @t15_colors.
  ///
  /// In en, this message translates to:
  /// **'Colors and theme'**
  String get t15_colors;

  /// No description provided for @t15_defaultPalette.
  ///
  /// In en, this message translates to:
  /// **'Default palette'**
  String get t15_defaultPalette;

  /// No description provided for @t15_customPalette.
  ///
  /// In en, this message translates to:
  /// **'Personal palette'**
  String get t15_customPalette;

  /// No description provided for @t15_reminders.
  ///
  /// In en, this message translates to:
  /// **'Reminders'**
  String get t15_reminders;

  /// No description provided for @t15_remindersSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Delivery and lock-screen details'**
  String get t15_remindersSubtitle;

  /// No description provided for @t15_accessibility.
  ///
  /// In en, this message translates to:
  /// **'Accessibility'**
  String get t15_accessibility;

  /// No description provided for @t15_accessibilitySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Display and interaction'**
  String get t15_accessibilitySubtitle;

  /// No description provided for @t15_backups.
  ///
  /// In en, this message translates to:
  /// **'Backups'**
  String get t15_backups;

  /// No description provided for @t15_backupsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Export or restore a file'**
  String get t15_backupsSubtitle;

  /// No description provided for @t15_storageRecovery.
  ///
  /// In en, this message translates to:
  /// **'Storage and recovery'**
  String get t15_storageRecovery;

  /// No description provided for @t15_storageSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Local files and recovery copies'**
  String get t15_storageSubtitle;

  /// No description provided for @t15_serverConnection.
  ///
  /// In en, this message translates to:
  /// **'Server connection'**
  String get t15_serverConnection;

  /// No description provided for @t15_notConnected.
  ///
  /// In en, this message translates to:
  /// **'Not connected'**
  String get t15_notConnected;

  /// No description provided for @t15_protection.
  ///
  /// In en, this message translates to:
  /// **'App protection'**
  String get t15_protection;

  /// No description provided for @t15_protectionSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Encryption and optional app lock'**
  String get t15_protectionSubtitle;

  /// No description provided for @t15_peopleSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Primary person and care preferences'**
  String get t15_peopleSubtitle;

  /// No description provided for @t15_medicationSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Editing and as-needed preferences'**
  String get t15_medicationSubtitle;

  /// No description provided for @t15_dataSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Connection status and records that need attention'**
  String get t15_dataSubtitle;

  /// No description provided for @t15_protectedCare.
  ///
  /// In en, this message translates to:
  /// **'Encrypted care storage'**
  String get t15_protectedCare;

  /// No description provided for @t15_encryptionBody.
  ///
  /// In en, this message translates to:
  /// **'Care is encrypted on this device even when app lock is off. App lock adds an optional device-authentication step before access.'**
  String get t15_encryptionBody;

  /// No description provided for @t15_transferTitle.
  ///
  /// In en, this message translates to:
  /// **'Moving to another phone'**
  String get t15_transferTitle;

  /// No description provided for @t15_transferBody.
  ///
  /// In en, this message translates to:
  /// **'Protected care is excluded from automatic system backups and device transfer. Save a portable backup or use an authorized server copy before changing phones. A local recovery copy does not protect against losing this phone.'**
  String get t15_transferBody;

  /// No description provided for @t15_serverPrivacy.
  ///
  /// In en, this message translates to:
  /// **'A trusted server operator can technically read care stored on that server. Local care does not require a server.'**
  String get t15_serverPrivacy;

  /// No description provided for @t15_careFiles.
  ///
  /// In en, this message translates to:
  /// **'Care, drafts and pending changes'**
  String get t15_careFiles;

  /// No description provided for @t15_recoveryCopies.
  ///
  /// In en, this message translates to:
  /// **'Recovery copies'**
  String get t15_recoveryCopies;

  /// No description provided for @t15_unfinishedFiles.
  ///
  /// In en, this message translates to:
  /// **'Unfinished startup files'**
  String get t15_unfinishedFiles;

  /// No description provided for @t15_legacyFiles.
  ///
  /// In en, this message translates to:
  /// **'Retained original files'**
  String get t15_legacyFiles;

  /// No description provided for @t15_otherFiles.
  ///
  /// In en, this message translates to:
  /// **'Other private files'**
  String get t15_otherFiles;

  /// No description provided for @t15_availableSpace.
  ///
  /// In en, this message translates to:
  /// **'Available on this device'**
  String get t15_availableSpace;

  /// No description provided for @t15_unknownSize.
  ///
  /// In en, this message translates to:
  /// **'Not available'**
  String get t15_unknownSize;

  /// No description provided for @t15_inventoryScope.
  ///
  /// In en, this message translates to:
  /// **'Sizes cover files controlled by Simpastil. Drafts and pending changes are included with care. Shared system files are not counted.'**
  String get t15_inventoryScope;

  /// No description provided for @t15_checkedRecovery.
  ///
  /// In en, this message translates to:
  /// **'Checked recovery copy'**
  String get t15_checkedRecovery;

  /// No description provided for @t15_noRecovery.
  ///
  /// In en, this message translates to:
  /// **'No recovery copy yet'**
  String get t15_noRecovery;

  /// No description provided for @t15_recoveryUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Recovery copy could not be checked. Original files are preserved.'**
  String get t15_recoveryUnavailable;

  /// No description provided for @t15_savedAt.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get t15_savedAt;

  /// No description provided for @t15_checkedAt.
  ///
  /// In en, this message translates to:
  /// **'Checked'**
  String get t15_checkedAt;

  /// No description provided for @t15_cleanup.
  ///
  /// In en, this message translates to:
  /// **'Clean safe temporary files'**
  String get t15_cleanup;

  /// No description provided for @t15_cleanupBody.
  ///
  /// In en, this message translates to:
  /// **'Only abandoned startup files that were never used as care can be removed. Care, drafts, pending changes and recovery copies are kept.'**
  String get t15_cleanupBody;

  /// No description provided for @t15_cleanupConfirm.
  ///
  /// In en, this message translates to:
  /// **'Remove these safe temporary files?'**
  String get t15_cleanupConfirm;

  /// No description provided for @t15_cleanupNone.
  ///
  /// In en, this message translates to:
  /// **'No safe temporary files to remove.'**
  String get t15_cleanupNone;

  /// No description provided for @t15_cleanupDone.
  ///
  /// In en, this message translates to:
  /// **'Safe cleanup completed. Your care and recovery copies are unchanged.'**
  String get t15_cleanupDone;

  /// No description provided for @t15_cleanupRefused.
  ///
  /// In en, this message translates to:
  /// **'Cleanup could not be completed safely. All remaining files are kept.'**
  String get t15_cleanupRefused;

  /// No description provided for @t15_accessExpired.
  ///
  /// In en, this message translates to:
  /// **'Access changed. Unlock again and start a new operation. Original files are unchanged.'**
  String get t15_accessExpired;

  /// No description provided for @t15_loadFailed.
  ///
  /// In en, this message translates to:
  /// **'These details are temporarily unavailable. Your data is preserved.'**
  String get t15_loadFailed;

  /// No description provided for @t15_createBackup.
  ///
  /// In en, this message translates to:
  /// **'Create backup'**
  String get t15_createBackup;

  /// No description provided for @t15_checkBackup.
  ///
  /// In en, this message translates to:
  /// **'Check backup'**
  String get t15_checkBackup;

  /// No description provided for @t15_backupPurpose.
  ///
  /// In en, this message translates to:
  /// **'A portable file for restoring your care. Reports such as PDF or CSV are not restorable backups.'**
  String get t15_backupPurpose;

  /// No description provided for @t15_createSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Save all available care and app preferences'**
  String get t15_createSubtitle;

  /// No description provided for @t15_checkSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Open a file without changing your current care'**
  String get t15_checkSubtitle;

  /// No description provided for @t15_onDevice.
  ///
  /// In en, this message translates to:
  /// **'On this device'**
  String get t15_onDevice;

  /// No description provided for @t15_contents.
  ///
  /// In en, this message translates to:
  /// **'View contents'**
  String get t15_contents;

  /// No description provided for @t15_backupContents.
  ///
  /// In en, this message translates to:
  /// **'Routines, dose history, stock, drafts, pending changes and supported app preferences. Account credentials and device access are not included.'**
  String get t15_backupContents;

  /// No description provided for @t15_passwordProtected.
  ///
  /// In en, this message translates to:
  /// **'Password protected'**
  String get t15_passwordProtected;

  /// No description provided for @t15_unencrypted.
  ///
  /// In en, this message translates to:
  /// **'Unencrypted'**
  String get t15_unencrypted;

  /// No description provided for @t15_unencryptedBody.
  ///
  /// In en, this message translates to:
  /// **'Anyone with the file can read it.'**
  String get t15_unencryptedBody;

  /// No description provided for @t15_backupPassword.
  ///
  /// In en, this message translates to:
  /// **'Backup password'**
  String get t15_backupPassword;

  /// No description provided for @t15_confirmPassword.
  ///
  /// In en, this message translates to:
  /// **'Confirm password'**
  String get t15_confirmPassword;

  /// No description provided for @t15_passwordNeeded.
  ///
  /// In en, this message translates to:
  /// **'You will need this password to restore the file. Simpastil cannot recover it.'**
  String get t15_passwordNeeded;

  /// No description provided for @t15_passwordMismatch.
  ///
  /// In en, this message translates to:
  /// **'Enter a password and matching confirmation.'**
  String get t15_passwordMismatch;

  /// No description provided for @t15_noFileSaved.
  ///
  /// In en, this message translates to:
  /// **'No file saved yet.'**
  String get t15_noFileSaved;

  /// No description provided for @t15_chooseSave.
  ///
  /// In en, this message translates to:
  /// **'Choose save location'**
  String get t15_chooseSave;

  /// No description provided for @t15_chooseBackup.
  ///
  /// In en, this message translates to:
  /// **'Choose backup file'**
  String get t15_chooseBackup;

  /// No description provided for @t15_saveChosen.
  ///
  /// In en, this message translates to:
  /// **'Save to chosen location'**
  String get t15_saveChosen;

  /// No description provided for @t15_openChosen.
  ///
  /// In en, this message translates to:
  /// **'Open chosen file'**
  String get t15_openChosen;

  /// No description provided for @t15_savedChecked.
  ///
  /// In en, this message translates to:
  /// **'Saved and checked on this phone'**
  String get t15_savedChecked;

  /// No description provided for @t15_savedUnchecked.
  ///
  /// In en, this message translates to:
  /// **'Saved, but not checked on this phone'**
  String get t15_savedUnchecked;

  /// No description provided for @t15_saveFailed.
  ///
  /// In en, this message translates to:
  /// **'Saving failed. The chosen file may be incomplete; your original care is unchanged.'**
  String get t15_saveFailed;

  /// No description provided for @t15_checkFailed.
  ///
  /// In en, this message translates to:
  /// **'The file could not be checked. Check the password and try again; original care is unchanged.'**
  String get t15_checkFailed;

  /// No description provided for @t15_checksPassed.
  ///
  /// In en, this message translates to:
  /// **'File checks passed'**
  String get t15_checksPassed;

  /// No description provided for @t15_supportedBackup.
  ///
  /// In en, this message translates to:
  /// **'This backup can be opened by this version of Simpastil.'**
  String get t15_supportedBackup;

  /// No description provided for @t15_currentUnchanged.
  ///
  /// In en, this message translates to:
  /// **'Your current data is unchanged.'**
  String get t15_currentUnchanged;

  /// No description provided for @t15_reviewRestore.
  ///
  /// In en, this message translates to:
  /// **'Review restore options'**
  String get t15_reviewRestore;

  /// No description provided for @t15_restoreSelection.
  ///
  /// In en, this message translates to:
  /// **'Restore or import'**
  String get t15_restoreSelection;

  /// No description provided for @t15_fullRestore.
  ///
  /// In en, this message translates to:
  /// **'Replace current care'**
  String get t15_fullRestore;

  /// No description provided for @t15_fullRestoreBody.
  ///
  /// In en, this message translates to:
  /// **'Restore the complete file. Current care is retained in a checked local recovery copy before replacement. Review all affected people and preferences first.'**
  String get t15_fullRestoreBody;

  /// No description provided for @t15_selectedImport.
  ///
  /// In en, this message translates to:
  /// **'Import selected people'**
  String get t15_selectedImport;

  /// No description provided for @t15_selectedImportBody.
  ///
  /// In en, this message translates to:
  /// **'Keep current care and preferences. Conflicting history is retained for review; connected originals remain account-scoped evidence.'**
  String get t15_selectedImportBody;

  /// No description provided for @t15_reviewImport.
  ///
  /// In en, this message translates to:
  /// **'Review import'**
  String get t15_reviewImport;

  /// No description provided for @t15_applyImport.
  ///
  /// In en, this message translates to:
  /// **'Apply reviewed import'**
  String get t15_applyImport;

  /// No description provided for @t15_applyRestore.
  ///
  /// In en, this message translates to:
  /// **'Restore reviewed backup'**
  String get t15_applyRestore;

  /// No description provided for @t15_confirmReplace.
  ///
  /// In en, this message translates to:
  /// **'I reviewed the replacement and checked recovery requirement.'**
  String get t15_confirmReplace;

  /// No description provided for @t15_confirmApply.
  ///
  /// In en, this message translates to:
  /// **'Apply this reviewed plan?'**
  String get t15_confirmApply;

  /// No description provided for @t15_importDone.
  ///
  /// In en, this message translates to:
  /// **'Import completed'**
  String get t15_importDone;

  /// No description provided for @t15_restoreDone.
  ///
  /// In en, this message translates to:
  /// **'Restore completed'**
  String get t15_restoreDone;

  /// No description provided for @t15_importFailed.
  ///
  /// In en, this message translates to:
  /// **'The reviewed change could not be completed. Original care is preserved; start a fresh review.'**
  String get t15_importFailed;

  /// No description provided for @t15_additions.
  ///
  /// In en, this message translates to:
  /// **'Additions'**
  String get t15_additions;

  /// No description provided for @t15_identical.
  ///
  /// In en, this message translates to:
  /// **'Already identical'**
  String get t15_identical;

  /// No description provided for @t15_conflicts.
  ///
  /// In en, this message translates to:
  /// **'Retained conflicts'**
  String get t15_conflicts;

  /// No description provided for @t15_retained.
  ///
  /// In en, this message translates to:
  /// **'Retained work'**
  String get t15_retained;

  /// No description provided for @t15_preferencesChanged.
  ///
  /// In en, this message translates to:
  /// **'Preferences to change'**
  String get t15_preferencesChanged;

  /// No description provided for @t15_alreadyApplied.
  ///
  /// In en, this message translates to:
  /// **'This import has already been applied.'**
  String get t15_alreadyApplied;

  /// No description provided for @t15_projectionPending.
  ///
  /// In en, this message translates to:
  /// **'Care is saved. Reminder or widget refresh still needs a retry.'**
  String get t15_projectionPending;

  /// No description provided for @t15_afterChooser.
  ///
  /// In en, this message translates to:
  /// **'After returning from the file chooser, unlock if asked and start this new operation.'**
  String get t15_afterChooser;

  /// No description provided for @t15_people.
  ///
  /// In en, this message translates to:
  /// **'People'**
  String get t15_people;

  /// No description provided for @t15_passwordVisibility.
  ///
  /// In en, this message translates to:
  /// **'Show or hide password'**
  String get t15_passwordVisibility;

  /// No description provided for @t15_dataCaptured.
  ///
  /// In en, this message translates to:
  /// **'Data captured'**
  String get t15_dataCaptured;

  /// No description provided for @t15_affectedPeople.
  ///
  /// In en, this message translates to:
  /// **'Current care affected'**
  String get t15_affectedPeople;

  /// No description provided for @t15_connectedCare.
  ///
  /// In en, this message translates to:
  /// **'Connected care'**
  String get t15_connectedCare;

  /// No description provided for @t15_localCare.
  ///
  /// In en, this message translates to:
  /// **'Local care'**
  String get t15_localCare;

  /// No description provided for @t15_outcomeAdded.
  ///
  /// In en, this message translates to:
  /// **'Added'**
  String get t15_outcomeAdded;

  /// No description provided for @t15_outcomeMerged.
  ///
  /// In en, this message translates to:
  /// **'Merged'**
  String get t15_outcomeMerged;

  /// No description provided for @t15_outcomeUnchanged.
  ///
  /// In en, this message translates to:
  /// **'Unchanged'**
  String get t15_outcomeUnchanged;

  /// No description provided for @t15_outcomeReview.
  ///
  /// In en, this message translates to:
  /// **'Needs review'**
  String get t15_outcomeReview;

  /// No description provided for @t15_outcomeLocked.
  ///
  /// In en, this message translates to:
  /// **'Unavailable account'**
  String get t15_outcomeLocked;

  /// No description provided for @t15_outcomeReplaced.
  ///
  /// In en, this message translates to:
  /// **'Replaced'**
  String get t15_outcomeReplaced;

  /// No description provided for @t15_medications.
  ///
  /// In en, this message translates to:
  /// **'Medications'**
  String get t15_medications;

  /// No description provided for @t15_routines.
  ///
  /// In en, this message translates to:
  /// **'Routines'**
  String get t15_routines;

  /// No description provided for @t15_history.
  ///
  /// In en, this message translates to:
  /// **'Dose history'**
  String get t15_history;

  /// No description provided for @t15_preferences.
  ///
  /// In en, this message translates to:
  /// **'App preferences'**
  String get t15_preferences;

  /// No description provided for @t15_fullDetails.
  ///
  /// In en, this message translates to:
  /// **'Full details'**
  String get t15_fullDetails;

  /// No description provided for @t15_fullDetailsBody.
  ///
  /// In en, this message translates to:
  /// **'Show care details and review actions in notifications and widgets. This is independent of app lock.'**
  String get t15_fullDetailsBody;

  /// No description provided for @t15_privateReminders.
  ///
  /// In en, this message translates to:
  /// **'Private reminders'**
  String get t15_privateReminders;

  /// No description provided for @t15_privateBody.
  ///
  /// In en, this message translates to:
  /// **'Use generic Open-only notifications and widgets without medication names, dose counts or recording actions.'**
  String get t15_privateBody;

  /// No description provided for @t15_reminderCoverage.
  ///
  /// In en, this message translates to:
  /// **'Reminder coverage'**
  String get t15_reminderCoverage;

  /// No description provided for @t15_coverageShortened.
  ///
  /// In en, this message translates to:
  /// **'The nearest reminders are scheduled. Open Simpastil regularly to schedule later reminders.'**
  String get t15_coverageShortened;

  /// No description provided for @t15_coverageDegraded.
  ///
  /// In en, this message translates to:
  /// **'Some reminders could not be scheduled. Check notification permissions, then reopen Simpastil to try again.'**
  String get t15_coverageDegraded;

  /// No description provided for @t15_coverageNone.
  ///
  /// In en, this message translates to:
  /// **'No upcoming reminders are currently scheduled for this workspace. Open Simpastil regularly to refresh coverage.'**
  String get t15_coverageNone;

  /// No description provided for @t15_reminderPeople.
  ///
  /// In en, this message translates to:
  /// **'People included on this device'**
  String get t15_reminderPeople;

  /// No description provided for @t15_reminderPeopleBody.
  ///
  /// In en, this message translates to:
  /// **'Choose device reminders in each person’s settings in People. People you add on this device start on; people from your account start off. The person you are viewing does not change who receives reminders.'**
  String get t15_reminderPeopleBody;

  /// No description provided for @t15_openPeople.
  ///
  /// In en, this message translates to:
  /// **'Open People'**
  String get t15_openPeople;

  /// No description provided for @t15_reminderTest.
  ///
  /// In en, this message translates to:
  /// **'Check reminder delivery'**
  String get t15_reminderTest;

  /// No description provided for @t15_reminderTestBody.
  ///
  /// In en, this message translates to:
  /// **'A scheduled test is not proof of delivery. Confirm only if you actually see the test notification.'**
  String get t15_reminderTestBody;

  /// No description provided for @t15_sendTest.
  ///
  /// In en, this message translates to:
  /// **'Send test notification'**
  String get t15_sendTest;

  /// No description provided for @t15_testScheduled.
  ///
  /// In en, this message translates to:
  /// **'Test scheduled · delivery not confirmed'**
  String get t15_testScheduled;

  /// No description provided for @t15_testObserved.
  ///
  /// In en, this message translates to:
  /// **'You confirmed seeing this test'**
  String get t15_testObserved;

  /// No description provided for @t15_testFailed.
  ///
  /// In en, this message translates to:
  /// **'Test could not be scheduled. Check notification and alarm permissions below.'**
  String get t15_testFailed;

  /// No description provided for @t15_confirmObserved.
  ///
  /// In en, this message translates to:
  /// **'I saw the test notification'**
  String get t15_confirmObserved;

  /// No description provided for @t15_backupContentsShort.
  ///
  /// In en, this message translates to:
  /// **'Routines, dose history, stock and app preferences'**
  String get t15_backupContentsShort;

  /// No description provided for @t15_retainedPeopleCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 retained person} other{{count} retained people}}'**
  String t15_retainedPeopleCount(int count);

  /// No description provided for @t15_backupProtection.
  ///
  /// In en, this message translates to:
  /// **'Protection'**
  String get t15_backupProtection;

  /// No description provided for @t15_differentDoseRecords.
  ///
  /// In en, this message translates to:
  /// **'Different records for one dose'**
  String get t15_differentDoseRecords;

  /// No description provided for @t15_onThisDevice.
  ///
  /// In en, this message translates to:
  /// **'On this device'**
  String get t15_onThisDevice;

  /// No description provided for @t15_inBackup.
  ///
  /// In en, this message translates to:
  /// **'In the backup'**
  String get t15_inBackup;

  /// No description provided for @t15_reviewDifference.
  ///
  /// In en, this message translates to:
  /// **'Review difference'**
  String get t15_reviewDifference;

  /// No description provided for @t15_differenceBody.
  ///
  /// In en, this message translates to:
  /// **'These facts are retained separately for review. Opening this detail does not record a dose, choose a winning fact or apply the import.'**
  String get t15_differenceBody;

  /// No description provided for @t15_timeUnknown.
  ///
  /// In en, this message translates to:
  /// **'Time unknown'**
  String get t15_timeUnknown;

  /// No description provided for @t15_notRecorded.
  ///
  /// In en, this message translates to:
  /// **'Not recorded'**
  String get t15_notRecorded;

  /// No description provided for @t15_taken.
  ///
  /// In en, this message translates to:
  /// **'Taken'**
  String get t15_taken;

  /// No description provided for @t15_skipped.
  ///
  /// In en, this message translates to:
  /// **'Skipped'**
  String get t15_skipped;

  /// No description provided for @t15_fileIntegrity.
  ///
  /// In en, this message translates to:
  /// **'File integrity'**
  String get t15_fileIntegrity;

  /// No description provided for @t15_backupFormat.
  ///
  /// In en, this message translates to:
  /// **'Backup format'**
  String get t15_backupFormat;

  /// No description provided for @t15_passed.
  ///
  /// In en, this message translates to:
  /// **'Passed'**
  String get t15_passed;

  /// No description provided for @t15_supported.
  ///
  /// In en, this message translates to:
  /// **'Supported'**
  String get t15_supported;

  /// No description provided for @t15_howRestore.
  ///
  /// In en, this message translates to:
  /// **'How to restore'**
  String get t15_howRestore;

  /// No description provided for @t15_selectedPeopleCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 person selected} other{{count} people selected}}'**
  String t15_selectedPeopleCount(int count);

  /// No description provided for @t15_notImported.
  ///
  /// In en, this message translates to:
  /// **'Nothing imported yet.'**
  String get t15_notImported;

  /// No description provided for @t15_applying.
  ///
  /// In en, this message translates to:
  /// **'Applying your reviewed backup…'**
  String get t15_applying;

  /// No description provided for @t15_noChangeBeforeApply.
  ///
  /// In en, this message translates to:
  /// **'Nothing changes until you review and apply.'**
  String get t15_noChangeBeforeApply;

  /// No description provided for @legacyReview_title.
  ///
  /// In en, this message translates to:
  /// **'Review older routine times'**
  String get legacyReview_title;

  /// No description provided for @legacyReview_entry.
  ///
  /// In en, this message translates to:
  /// **'Review routine times together'**
  String get legacyReview_entry;

  /// No description provided for @legacyReview_entryHint.
  ///
  /// In en, this message translates to:
  /// **'Confirm a time zone while keeping saved hours and days.'**
  String get legacyReview_entryHint;

  /// No description provided for @legacyReview_intro.
  ///
  /// In en, this message translates to:
  /// **'Choose the time zone those saved hours belong to. Review each routine below, then confirm once.'**
  String get legacyReview_intro;

  /// No description provided for @legacyReview_zone.
  ///
  /// In en, this message translates to:
  /// **'Time zone for saved hours'**
  String get legacyReview_zone;

  /// No description provided for @legacyReview_bucharest.
  ///
  /// In en, this message translates to:
  /// **'Bucharest, Romania'**
  String get legacyReview_bucharest;

  /// No description provided for @legacyReview_device.
  ///
  /// In en, this message translates to:
  /// **'Device time ({zone})'**
  String legacyReview_device(String zone);

  /// No description provided for @legacyReview_from.
  ///
  /// In en, this message translates to:
  /// **'Apply from'**
  String get legacyReview_from;

  /// No description provided for @legacyReview_boundary.
  ///
  /// In en, this message translates to:
  /// **'Applies from midnight on {date}, in {zone}. Saved hours, days, and past records are preserved.'**
  String legacyReview_boundary(String date, String zone);

  /// No description provided for @legacyReview_ready.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1 {1 routine ready to review} other {{count} routines ready to review}}'**
  String legacyReview_ready(int count);

  /// No description provided for @legacyReview_next.
  ///
  /// In en, this message translates to:
  /// **'Next planned dose: {date}'**
  String legacyReview_next(String date);

  /// No description provided for @legacyReview_inactive.
  ///
  /// In en, this message translates to:
  /// **'Paused · stays paused'**
  String get legacyReview_inactive;

  /// No description provided for @legacyReview_invalid.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1 {1 skipped: its saved days need an individual review.} other {{count} skipped: their saved days need an individual review.}}'**
  String legacyReview_invalid(int count);

  /// No description provided for @legacyReview_unavailable.
  ///
  /// In en, this message translates to:
  /// **'{count} skipped: pending changes, an earlier edit, or incomplete review details. Sync and review them individually.'**
  String legacyReview_unavailable(int count);

  /// No description provided for @legacyReview_noChanges.
  ///
  /// In en, this message translates to:
  /// **'No routines are ready for this batch. Existing review items remain available in Data.'**
  String get legacyReview_noChanges;

  /// No description provided for @legacyReview_confirm.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1 {Confirm 1 routine time} other {Confirm {count} routine times}}'**
  String legacyReview_confirm(int count);

  /// No description provided for @legacyReview_retry.
  ///
  /// In en, this message translates to:
  /// **'Retry this review'**
  String get legacyReview_retry;

  /// No description provided for @legacyReview_saved.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1 {1 routine accepted by the server. It will appear after the next successful sync.} other {{count} routines accepted by the server. They will appear after the next successful sync.}}'**
  String legacyReview_saved(int count);

  /// No description provided for @legacyReview_partial.
  ///
  /// In en, this message translates to:
  /// **'{accepted} of {total} routines accepted. Keep this review to retry the remaining routines with the same choices.'**
  String legacyReview_partial(int accepted, int total);

  /// No description provided for @legacyReview_loadError.
  ///
  /// In en, this message translates to:
  /// **'This review could not be loaded. Sync your data, then try again.'**
  String get legacyReview_loadError;

  /// No description provided for @legacyReview_applyError.
  ///
  /// In en, this message translates to:
  /// **'The server could not confirm all changes. Retry this review or return to Data to sync.'**
  String get legacyReview_applyError;

  /// No description provided for @legacyReview_scope.
  ///
  /// In en, this message translates to:
  /// **'This review only sets routine time zones. Other unresolved changes still need review.'**
  String get legacyReview_scope;

  /// No description provided for @review_openRecovery.
  ///
  /// In en, this message translates to:
  /// **'This is waiting in Fix sync problems, where you can resolve it. Its details are retained.'**
  String get review_openRecovery;

  /// No description provided for @sync_connectionAccessUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The saved connection needs attention. Review it and sign in to the same account if asked.'**
  String get sync_connectionAccessUnavailable;

  /// No description provided for @sync_reviewConnection.
  ///
  /// In en, this message translates to:
  /// **'Review connection'**
  String get sync_reviewConnection;

  /// No description provided for @review_incompleteDetails.
  ///
  /// In en, this message translates to:
  /// **'Review is unavailable for this item. Its saved details are retained below.'**
  String get review_incompleteDetails;

  /// No description provided for @review_errorChanged.
  ///
  /// In en, this message translates to:
  /// **'This review changed or is no longer ready. Sync, then open it again.'**
  String get review_errorChanged;

  /// No description provided for @review_errorSignIn.
  ///
  /// In en, this message translates to:
  /// **'Sign in again before submitting this review.'**
  String get review_errorSignIn;

  /// No description provided for @review_errorMissing.
  ///
  /// In en, this message translates to:
  /// **'These review details are no longer available. Sync, then check the remaining review items.'**
  String get review_errorMissing;

  /// No description provided for @review_errorValidation.
  ///
  /// In en, this message translates to:
  /// **'Check the review choices and time zone, then try again.'**
  String get review_errorValidation;

  /// No description provided for @review_errorRateLimit.
  ///
  /// In en, this message translates to:
  /// **'Too many requests. Wait a moment before submitting this review again.'**
  String get review_errorRateLimit;

  /// No description provided for @review_errorServer.
  ///
  /// In en, this message translates to:
  /// **'The server could not confirm this review. Sync to check its status before retrying.'**
  String get review_errorServer;

  /// No description provided for @review_errorConnection.
  ///
  /// In en, this message translates to:
  /// **'Could not reach the server. Check your connection, then sync to check this review before retrying.'**
  String get review_errorConnection;

  /// No description provided for @review_errorUnknown.
  ///
  /// In en, this message translates to:
  /// **'This review could not be confirmed. Its details are retained; sync before reviewing again.'**
  String get review_errorUnknown;

  /// No description provided for @prn_reviewAmbiguous.
  ///
  /// In en, this message translates to:
  /// **'More than one as-needed routine is active. Review them before recording.'**
  String get prn_reviewAmbiguous;

  /// No description provided for @prn_reviewRoutine.
  ///
  /// In en, this message translates to:
  /// **'This as-needed routine is paused or needs review. Check its saved details before recording.'**
  String get prn_reviewRoutine;

  /// No description provided for @prn_reviewZone.
  ///
  /// In en, this message translates to:
  /// **'Confirm this routine’s time zone before recording.'**
  String get prn_reviewZone;

  /// No description provided for @prn_openReview.
  ///
  /// In en, this message translates to:
  /// **'Open Data to review'**
  String get prn_openReview;

  /// No description provided for @t10_sharingReconciled.
  ///
  /// In en, this message translates to:
  /// **'Reviewed · original delivery unconfirmed'**
  String get t10_sharingReconciled;

  /// No description provided for @schedules_restorePrnTitle.
  ///
  /// In en, this message translates to:
  /// **'Restore as-needed routine'**
  String get schedules_restorePrnTitle;

  /// No description provided for @schedules_restorePrnExplanation.
  ///
  /// In en, this message translates to:
  /// **'Enable this saved as-needed routine in the time zone below. Past records are kept.'**
  String get schedules_restorePrnExplanation;

  /// No description provided for @schedules_restorePrnZone.
  ///
  /// In en, this message translates to:
  /// **'Time zone for as-needed recording'**
  String get schedules_restorePrnZone;

  /// No description provided for @sync_todayAttention.
  ///
  /// In en, this message translates to:
  /// **'Some records need your attention · Open Sync'**
  String get sync_todayAttention;

  /// No description provided for @sync_todayUnverified.
  ///
  /// In en, this message translates to:
  /// **'Server records have not been verified · Open Sync'**
  String get sync_todayUnverified;

  /// No description provided for @sync_todayPending.
  ///
  /// In en, this message translates to:
  /// **'Changes saved on this phone · Waiting to sync'**
  String get sync_todayPending;

  /// No description provided for @sync_retainedRemovedRecords.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 record refers to a removed medication or routine. The original information is preserved; there is no change here to review.} other{{count} records refer to removed medications or routines. The original information is preserved; there is no change here to review.}}'**
  String sync_retainedRemovedRecords(int count);

  /// No description provided for @sync_retainedHistory.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 older history entry is preserved as information. Its original timing or stock effect may be uncertain; it does not require a new dose decision.} other{{count} older history entries are preserved as information. Their original timing or stock effect may be uncertain; they do not require a new dose decision.}}'**
  String sync_retainedHistory(int count);

  /// No description provided for @backup_unattributed.
  ///
  /// In en, this message translates to:
  /// **'A full backup also preserves older records whose original person can no longer be established. Restoring keeps these as inactive evidence, without assigning them to someone or sending them to a server.'**
  String get backup_unattributed;

  /// No description provided for @review_choiceAccepted.
  ///
  /// In en, this message translates to:
  /// **'Your choice was accepted by the server. This review clears when its acknowledgement has synced to this phone.'**
  String get review_choiceAccepted;

  /// No description provided for @sc_allRecorded.
  ///
  /// In en, this message translates to:
  /// **'All recorded for today'**
  String get sc_allRecorded;

  /// No description provided for @sc_skyLabel.
  ///
  /// In en, this message translates to:
  /// **'Day sky: {recorded} of {total} recorded, next {next}'**
  String sc_skyLabel(int recorded, int total, String next);

  /// No description provided for @sc_skyNoNext.
  ///
  /// In en, this message translates to:
  /// **'Day sky: {recorded} of {total} recorded'**
  String sc_skyNoNext(int recorded, int total);

  /// No description provided for @sc_sunNext.
  ///
  /// In en, this message translates to:
  /// **'Next: {time} · {person} · {medication}'**
  String sc_sunNext(String time, String person, String medication);

  /// No description provided for @sc_sunNone.
  ///
  /// In en, this message translates to:
  /// **'Nothing more due today'**
  String get sc_sunNone;

  /// No description provided for @sc_showNextDose.
  ///
  /// In en, this message translates to:
  /// **'Show next dose'**
  String get sc_showNextDose;

  /// No description provided for @sc_readNextDose.
  ///
  /// In en, this message translates to:
  /// **'Read what is next'**
  String get sc_readNextDose;

  /// No description provided for @sc_pullToShare.
  ///
  /// In en, this message translates to:
  /// **'Pull to share now'**
  String get sc_pullToShare;

  /// No description provided for @sc_sharedJustNow.
  ///
  /// In en, this message translates to:
  /// **'Shared just now'**
  String get sc_sharedJustNow;

  /// No description provided for @sc_savedOnDevice.
  ///
  /// In en, this message translates to:
  /// **'Saved on this device'**
  String get sc_savedOnDevice;

  /// No description provided for @sc_saving.
  ///
  /// In en, this message translates to:
  /// **'Saving…'**
  String get sc_saving;

  /// No description provided for @sc_stockLeft.
  ///
  /// In en, this message translates to:
  /// **'{n} left'**
  String sc_stockLeft(int n);

  /// No description provided for @lay_timeline.
  ///
  /// In en, this message translates to:
  /// **'Timeline'**
  String get lay_timeline;

  /// No description provided for @lay_peopleLanes.
  ///
  /// In en, this message translates to:
  /// **'People lanes'**
  String get lay_peopleLanes;

  /// No description provided for @lay_dayPlanner.
  ///
  /// In en, this message translates to:
  /// **'Day planner'**
  String get lay_dayPlanner;

  /// No description provided for @lay_actionInbox.
  ///
  /// In en, this message translates to:
  /// **'Action inbox'**
  String get lay_actionInbox;

  /// No description provided for @lay_dailyJournal.
  ///
  /// In en, this message translates to:
  /// **'Daily journal'**
  String get lay_dailyJournal;

  /// No description provided for @lay_focusDeckBody.
  ///
  /// In en, this message translates to:
  /// **'One dose at a time, with previous, next and a day overview.'**
  String get lay_focusDeckBody;

  /// No description provided for @lay_timelineBody.
  ///
  /// In en, this message translates to:
  /// **'The whole day in time order, with the sun marking now.'**
  String get lay_timelineBody;

  /// No description provided for @lay_peopleLanesBody.
  ///
  /// In en, this message translates to:
  /// **'Each person\'s care in a lane of its own.'**
  String get lay_peopleLanesBody;

  /// No description provided for @lay_dayPlannerBody.
  ///
  /// In en, this message translates to:
  /// **'The day as an agenda, hour by hour.'**
  String get lay_dayPlannerBody;

  /// No description provided for @lay_actionInboxBody.
  ///
  /// In en, this message translates to:
  /// **'What still needs recording first, recorded doses apart.'**
  String get lay_actionInboxBody;

  /// No description provided for @lay_dailyJournalBody.
  ///
  /// In en, this message translates to:
  /// **'The day as a readable record of care and notes.'**
  String get lay_dailyJournalBody;

  /// No description provided for @lay_intro.
  ///
  /// In en, this message translates to:
  /// **'Choose how Today is arranged. Colours, the selected person and the date stay as they are. This choice is kept on this device only.'**
  String get lay_intro;

  /// No description provided for @lay_inUse.
  ///
  /// In en, this message translates to:
  /// **'In use'**
  String get lay_inUse;

  /// No description provided for @lay_notReady.
  ///
  /// In en, this message translates to:
  /// **'Not available yet'**
  String get lay_notReady;

  /// No description provided for @lay_notReadyBody.
  ///
  /// In en, this message translates to:
  /// **'This layout is still being built. Today keeps using Focus deck until it is ready.'**
  String get lay_notReadyBody;

  /// No description provided for @lay_preview.
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get lay_preview;

  /// No description provided for @lay_previewOf.
  ///
  /// In en, this message translates to:
  /// **'Preview of {name}'**
  String lay_previewOf(String name);

  /// No description provided for @lay_previewNotice.
  ///
  /// In en, this message translates to:
  /// **'Example day with fictional medications. Nothing you tap here is recorded.'**
  String get lay_previewNotice;

  /// No description provided for @lay_use.
  ///
  /// In en, this message translates to:
  /// **'Use {name}'**
  String lay_use(String name);

  /// No description provided for @lay_applied.
  ///
  /// In en, this message translates to:
  /// **'Today now uses {name}.'**
  String lay_applied(String name);

  /// No description provided for @lay_saveError.
  ///
  /// In en, this message translates to:
  /// **'The layout could not be saved, so nothing changed. Try again.'**
  String get lay_saveError;

  /// No description provided for @lay_exampleMorning.
  ///
  /// In en, this message translates to:
  /// **'Morning tablet'**
  String get lay_exampleMorning;

  /// No description provided for @lay_exampleNoon.
  ///
  /// In en, this message translates to:
  /// **'Vitamin D'**
  String get lay_exampleNoon;

  /// No description provided for @lay_exampleEvening.
  ///
  /// In en, this message translates to:
  /// **'Evening tablet'**
  String get lay_exampleEvening;

  /// No description provided for @lay_now.
  ///
  /// In en, this message translates to:
  /// **'Now, {time}'**
  String lay_now(String time);

  /// No description provided for @lay_quietHours.
  ///
  /// In en, this message translates to:
  /// **'Nothing planned · {from} – {to}'**
  String lay_quietHours(String from, String to);

  /// No description provided for @lay_showDetails.
  ///
  /// In en, this message translates to:
  /// **'Show details'**
  String get lay_showDetails;

  /// No description provided for @lay_hideDetails.
  ///
  /// In en, this message translates to:
  /// **'Hide details'**
  String get lay_hideDetails;

  /// No description provided for @lay_itemLabel.
  ///
  /// In en, this message translates to:
  /// **'{time}, {medication}, {state}'**
  String lay_itemLabel(String time, String medication, String state);

  /// No description provided for @ibx_needsYou.
  ///
  /// In en, this message translates to:
  /// **'Needs you'**
  String get ibx_needsYou;

  /// No description provided for @ibx_recordedToday.
  ///
  /// In en, this message translates to:
  /// **'Recorded today'**
  String get ibx_recordedToday;

  /// No description provided for @ibx_needsNone.
  ///
  /// In en, this message translates to:
  /// **'Nothing needs you right now.'**
  String get ibx_needsNone;

  /// No description provided for @ibx_recordedNone.
  ///
  /// In en, this message translates to:
  /// **'Nothing recorded yet.'**
  String get ibx_recordedNone;

  /// No description provided for @ibx_movedRecorded.
  ///
  /// In en, this message translates to:
  /// **'{medication} moved to Recorded today.'**
  String ibx_movedRecorded(String medication);

  /// No description provided for @ibx_movedNeeds.
  ///
  /// In en, this message translates to:
  /// **'{medication} moved back to Needs you.'**
  String ibx_movedNeeds(String medication);

  /// No description provided for @jrn_morning.
  ///
  /// In en, this message translates to:
  /// **'Morning'**
  String get jrn_morning;

  /// No description provided for @jrn_afternoon.
  ///
  /// In en, this message translates to:
  /// **'Afternoon'**
  String get jrn_afternoon;

  /// No description provided for @jrn_evening.
  ///
  /// In en, this message translates to:
  /// **'Evening'**
  String get jrn_evening;

  /// No description provided for @jrn_night.
  ///
  /// In en, this message translates to:
  /// **'Night'**
  String get jrn_night;

  /// No description provided for @supply_title.
  ///
  /// In en, this message translates to:
  /// **'Supply'**
  String get supply_title;

  /// No description provided for @supply_until.
  ///
  /// In en, this message translates to:
  /// **'Enough until {date}'**
  String supply_until(String date);

  /// No description provided for @supply_cardUntil.
  ///
  /// In en, this message translates to:
  /// **'Until {date}'**
  String supply_cardUntil(String date);

  /// No description provided for @supply_refillBy.
  ///
  /// In en, this message translates to:
  /// **'Refill by {date} to stay above your low-stock level'**
  String supply_refillBy(String date);

  /// No description provided for @supply_pastHorizon.
  ///
  /// In en, this message translates to:
  /// **'Enough for more than two months'**
  String get supply_pastHorizon;

  /// No description provided for @supply_shortToday.
  ///
  /// In en, this message translates to:
  /// **'Not enough for today\'s remaining doses'**
  String get supply_shortToday;

  /// No description provided for @supply_shortOn.
  ///
  /// In en, this message translates to:
  /// **'Runs short on {date}'**
  String supply_shortOn(String date);

  /// No description provided for @supply_none.
  ///
  /// In en, this message translates to:
  /// **'No doses left'**
  String get supply_none;

  /// No description provided for @supply_estimateNote.
  ///
  /// In en, this message translates to:
  /// **'Estimated from the routine, one dose per planned time. Doses taken outside it change this.'**
  String get supply_estimateNote;

  /// No description provided for @jrn_periodSummary.
  ///
  /// In en, this message translates to:
  /// **'{period}, {recorded} of {total} recorded'**
  String jrn_periodSummary(String period, int recorded, int total);

  /// No description provided for @jrn_took.
  ///
  /// In en, this message translates to:
  /// **'{time} · {person} took {medication}'**
  String jrn_took(String time, String person, String medication);

  /// No description provided for @jrn_tookUnknown.
  ///
  /// In en, this message translates to:
  /// **'{person} took {medication} · time not known'**
  String jrn_tookUnknown(String person, String medication);

  /// No description provided for @jrn_skipped.
  ///
  /// In en, this message translates to:
  /// **'{time} · {person} skipped {medication}'**
  String jrn_skipped(String time, String person, String medication);

  /// No description provided for @jrn_skippedUnknown.
  ///
  /// In en, this message translates to:
  /// **'{person} skipped {medication} · time not known'**
  String jrn_skippedUnknown(String person, String medication);

  /// No description provided for @jrn_planned.
  ///
  /// In en, this message translates to:
  /// **'Planned {time} · {person} to take {medication}'**
  String jrn_planned(String time, String person, String medication);

  /// No description provided for @mf_previewPlaceholder.
  ///
  /// In en, this message translates to:
  /// **'Your medication'**
  String get mf_previewPlaceholder;

  /// No description provided for @mf_sectionWhat.
  ///
  /// In en, this message translates to:
  /// **'What it is'**
  String get mf_sectionWhat;

  /// No description provided for @mf_sectionWhatHint.
  ///
  /// In en, this message translates to:
  /// **'A name you will recognise, and how it comes.'**
  String get mf_sectionWhatHint;

  /// No description provided for @mf_sectionDose.
  ///
  /// In en, this message translates to:
  /// **'Each dose'**
  String get mf_sectionDose;

  /// No description provided for @mf_sectionLook.
  ///
  /// In en, this message translates to:
  /// **'How it looks'**
  String get mf_sectionLook;

  /// No description provided for @mf_sectionLookHint.
  ///
  /// In en, this message translates to:
  /// **'This colour follows it to Today and Medications.'**
  String get mf_sectionLookHint;

  /// No description provided for @mf_sectionSupply.
  ///
  /// In en, this message translates to:
  /// **'Supply'**
  String get mf_sectionSupply;

  /// No description provided for @mf_sectionNotes.
  ///
  /// In en, this message translates to:
  /// **'Anything to remember'**
  String get mf_sectionNotes;

  /// No description provided for @mf_sectionWho.
  ///
  /// In en, this message translates to:
  /// **'Who takes it'**
  String get mf_sectionWho;

  /// No description provided for @mf_sectionWhen.
  ///
  /// In en, this message translates to:
  /// **'When'**
  String get mf_sectionWhen;

  /// No description provided for @mf_sectionRepeat.
  ///
  /// In en, this message translates to:
  /// **'Repeat'**
  String get mf_sectionRepeat;

  /// No description provided for @mf_colorSwatch.
  ///
  /// In en, this message translates to:
  /// **'{color} colour'**
  String mf_colorSwatch(String color);

  /// No description provided for @mf_nameNeeded.
  ///
  /// In en, this message translates to:
  /// **'Add a name so you can find it later.'**
  String get mf_nameNeeded;

  /// No description provided for @mf_numberNeeded.
  ///
  /// In en, this message translates to:
  /// **'Use a whole number, like 30.'**
  String get mf_numberNeeded;

  /// No description provided for @mf_fewer.
  ///
  /// In en, this message translates to:
  /// **'One fewer'**
  String get mf_fewer;

  /// No description provided for @mf_more.
  ///
  /// In en, this message translates to:
  /// **'One more'**
  String get mf_more;

  /// No description provided for @mf_colourAfterSave.
  ///
  /// In en, this message translates to:
  /// **'It gets its own colour once it is saved.'**
  String get mf_colourAfterSave;

  /// No description provided for @mf_skyTime.
  ///
  /// In en, this message translates to:
  /// **'{time}, {part}'**
  String mf_skyTime(String time, String part);

  /// Screen-reader summary of the dose dial in schedule editors; times is a list like '08:00, Morning; 20:30, Evening'.
  ///
  /// In en, this message translates to:
  /// **'Dose times on the day dial: {times}'**
  String schedules_dialLabel(String times);

  /// Screen-reader name of the blister card at the top of Medications: one cell per medication showing its stock.
  ///
  /// In en, this message translates to:
  /// **'Medication stock'**
  String get blister_label;

  /// No description provided for @blister_cellFull.
  ///
  /// In en, this message translates to:
  /// **'{name}, {stock} left'**
  String blister_cellFull(String name, int stock);

  /// No description provided for @blister_cellRefill.
  ///
  /// In en, this message translates to:
  /// **'{name}, time to refill, {stock} left'**
  String blister_cellRefill(String name, int stock);

  /// No description provided for @blister_cellEmpty.
  ///
  /// In en, this message translates to:
  /// **'{name}, none left'**
  String blister_cellEmpty(String name);

  /// No description provided for @blister_cellUntracked.
  ///
  /// In en, this message translates to:
  /// **'{name}, stock not tracked'**
  String blister_cellUntracked(String name);

  /// Screen-reader hint for tapping a blister cell: scrolls to that medication's card.
  ///
  /// In en, this message translates to:
  /// **'show in the list'**
  String get blister_show;

  /// No description provided for @blister_fine.
  ///
  /// In en, this message translates to:
  /// **'Stock is fine'**
  String get blister_fine;

  /// No description provided for @blister_refill.
  ///
  /// In en, this message translates to:
  /// **'Refill soon: {names}'**
  String blister_refill(String names);

  /// No description provided for @blister_empty.
  ///
  /// In en, this message translates to:
  /// **'None left: {names}'**
  String blister_empty(String names);

  /// No description provided for @mf_tapToChange.
  ///
  /// In en, this message translates to:
  /// **'Tap to change'**
  String get mf_tapToChange;

  /// No description provided for @mf_daysNeeded.
  ///
  /// In en, this message translates to:
  /// **'Pick at least one day.'**
  String get mf_daysNeeded;

  /// No description provided for @mf_personHint.
  ///
  /// In en, this message translates to:
  /// **'The name you use for them is enough.'**
  String get mf_personHint;

  /// No description provided for @mf_personFace.
  ///
  /// In en, this message translates to:
  /// **'A face for their medications'**
  String get mf_personFace;

  /// No description provided for @r4_recoveryChecked.
  ///
  /// In en, this message translates to:
  /// **'Checked'**
  String get r4_recoveryChecked;

  /// No description provided for @r4_recoveryNone.
  ///
  /// In en, this message translates to:
  /// **'None yet'**
  String get r4_recoveryNone;

  /// No description provided for @r4_recoveryUnchecked.
  ///
  /// In en, this message translates to:
  /// **'Not checked'**
  String get r4_recoveryUnchecked;

  /// No description provided for @r4_spaceUsed.
  ///
  /// In en, this message translates to:
  /// **'Space used'**
  String get r4_spaceUsed;

  /// No description provided for @r4_cleanupGroup.
  ///
  /// In en, this message translates to:
  /// **'Tidy up'**
  String get r4_cleanupGroup;

  /// No description provided for @r4_syncReviewGroup.
  ///
  /// In en, this message translates to:
  /// **'To review'**
  String get r4_syncReviewGroup;

  /// No description provided for @r4_syncDetails.
  ///
  /// In en, this message translates to:
  /// **'Shows sync details'**
  String get r4_syncDetails;

  /// No description provided for @r6_notifDoseBody.
  ///
  /// In en, this message translates to:
  /// **'{dosage}, when you’re ready'**
  String r6_notifDoseBody(String dosage);

  /// No description provided for @r6_notifNoDoseBody.
  ///
  /// In en, this message translates to:
  /// **'When you’re ready.'**
  String get r6_notifNoDoseBody;

  /// No description provided for @r6_notifStillTitle.
  ///
  /// In en, this message translates to:
  /// **'{pillName} is still waiting'**
  String r6_notifStillTitle(String pillName);

  /// No description provided for @r6_notifStillBody.
  ///
  /// In en, this message translates to:
  /// **'{dosage}, only if you haven’t yet'**
  String r6_notifStillBody(String dosage);

  /// No description provided for @r6_notifStillNoDoseBody.
  ///
  /// In en, this message translates to:
  /// **'Only if you haven’t yet.'**
  String get r6_notifStillNoDoseBody;

  /// No description provided for @r6_notifSubText.
  ///
  /// In en, this message translates to:
  /// **'Dose reminder'**
  String get r6_notifSubText;

  /// No description provided for @r6_permBody.
  ///
  /// In en, this message translates to:
  /// **'Simpastil can give you a quiet nudge when a dose is due. Your care is saved either way.'**
  String get r6_permBody;

  /// No description provided for @r6_whyNudge.
  ///
  /// In en, this message translates to:
  /// **'One calm nudge at each scheduled time'**
  String get r6_whyNudge;

  /// No description provided for @r6_whyActions.
  ///
  /// In en, this message translates to:
  /// **'Mark it taken or snooze it from the notification'**
  String get r6_whyActions;

  /// No description provided for @r6_whyPrivacy.
  ///
  /// In en, this message translates to:
  /// **'You choose whether names show on the lock screen'**
  String get r6_whyPrivacy;

  /// No description provided for @r6_whyNothingRecorded.
  ///
  /// In en, this message translates to:
  /// **'Nothing is recorded until you say so'**
  String get r6_whyNothingRecorded;

  /// No description provided for @r6_sampleMedicine.
  ///
  /// In en, this message translates to:
  /// **'your medicine'**
  String get r6_sampleMedicine;

  /// No description provided for @r6_sampleDose.
  ///
  /// In en, this message translates to:
  /// **'1 tablet'**
  String get r6_sampleDose;

  /// No description provided for @r6_previewNow.
  ///
  /// In en, this message translates to:
  /// **'now'**
  String get r6_previewNow;

  /// No description provided for @r6_previewSemantics.
  ///
  /// In en, this message translates to:
  /// **'Sample reminder: {title}. {body}'**
  String r6_previewSemantics(String title, String body);

  /// No description provided for @r6_statusTitle.
  ///
  /// In en, this message translates to:
  /// **'This device'**
  String get r6_statusTitle;

  /// No description provided for @r6_statusChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking this device'**
  String get r6_statusChecking;

  /// No description provided for @r6_statusOn.
  ///
  /// In en, this message translates to:
  /// **'Reminders on'**
  String get r6_statusOn;

  /// No description provided for @r6_statusOnBody.
  ///
  /// In en, this message translates to:
  /// **'This device can show reminders at their scheduled time.'**
  String get r6_statusOnBody;

  /// No description provided for @r6_statusNeedsPermission.
  ///
  /// In en, this message translates to:
  /// **'Needs permission'**
  String get r6_statusNeedsPermission;

  /// No description provided for @r6_statusNeedsPermissionBody.
  ///
  /// In en, this message translates to:
  /// **'Notifications are off for Simpastil, so reminders will not appear. Your care is still saved.'**
  String get r6_statusNeedsPermissionBody;

  /// No description provided for @r6_statusMayBeLate.
  ///
  /// In en, this message translates to:
  /// **'May arrive late'**
  String get r6_statusMayBeLate;

  /// No description provided for @r6_statusMayBeLateBody.
  ///
  /// In en, this message translates to:
  /// **'Exact alarms are off, so Android may delay reminders.'**
  String get r6_statusMayBeLateBody;

  /// No description provided for @r6_statusSomeMissing.
  ///
  /// In en, this message translates to:
  /// **'Some not scheduled'**
  String get r6_statusSomeMissing;

  /// No description provided for @r6_statusUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Not available here'**
  String get r6_statusUnavailable;

  /// No description provided for @r6_statusUnavailableBody.
  ///
  /// In en, this message translates to:
  /// **'This device cannot show reminders. Your care is still saved.'**
  String get r6_statusUnavailableBody;

  /// No description provided for @r6_privacyNames.
  ///
  /// In en, this message translates to:
  /// **'Names shown'**
  String get r6_privacyNames;

  /// No description provided for @r6_privacyPrivate.
  ///
  /// In en, this message translates to:
  /// **'Private'**
  String get r6_privacyPrivate;

  /// No description provided for @r6_dayTitle.
  ///
  /// In en, this message translates to:
  /// **'Your reminder day'**
  String get r6_dayTitle;

  /// No description provided for @r6_dayBody.
  ///
  /// In en, this message translates to:
  /// **'Reminders follow your routine times.'**
  String get r6_dayBody;

  /// No description provided for @r6_dayEmpty.
  ///
  /// In en, this message translates to:
  /// **'No scheduled times yet. Add a routine to get reminders.'**
  String get r6_dayEmpty;

  /// No description provided for @r6_dayEdit.
  ///
  /// In en, this message translates to:
  /// **'Change times in Routine'**
  String get r6_dayEdit;

  /// No description provided for @r8_syncNotConnected.
  ///
  /// In en, this message translates to:
  /// **'Not connected to a server'**
  String get r8_syncNotConnected;

  /// No description provided for @r8_peopleManageGroup.
  ///
  /// In en, this message translates to:
  /// **'Add and manage'**
  String get r8_peopleManageGroup;

  /// No description provided for @r8_peopleRemoveGroup.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get r8_peopleRemoveGroup;

  /// No description provided for @r8_lowStockTitle.
  ///
  /// In en, this message translates to:
  /// **'{pillName} is running low'**
  String r8_lowStockTitle(String pillName);

  /// No description provided for @r8_lowStockBody.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 dose left} other{{count} doses left}}'**
  String r8_lowStockBody(int count);

  /// No description provided for @r8_editingPalette.
  ///
  /// In en, this message translates to:
  /// **'Editing palette for:'**
  String get r8_editingPalette;

  /// No description provided for @r8_paletteNote.
  ///
  /// In en, this message translates to:
  /// **'This only chooses which colours you are editing. It does not switch the app between light and dark.'**
  String get r8_paletteNote;

  /// No description provided for @r10_statusNobodyOn.
  ///
  /// In en, this message translates to:
  /// **'No one switched on'**
  String get r10_statusNobodyOn;

  /// No description provided for @r10_statusNobodyOnBody.
  ///
  /// In en, this message translates to:
  /// **'This device allows reminders, but no person is switched on here, so no reminders are scheduled and the home-screen widget stays empty.'**
  String get r10_statusNobodyOnBody;

  /// No description provided for @r10_peopleHintNone.
  ///
  /// In en, this message translates to:
  /// **'Switch a person on for this device'**
  String get r10_peopleHintNone;

  /// No description provided for @r10_peopleHintSome.
  ///
  /// In en, this message translates to:
  /// **'On for {on} of {total} people on this device'**
  String r10_peopleHintSome(int on, int total);

  /// No description provided for @r10_peopleHintBody.
  ///
  /// In en, this message translates to:
  /// **'In People, open a person\'s menu and choose Reminders on this device.'**
  String get r10_peopleHintBody;

  /// No description provided for @lay_nothingDueYet.
  ///
  /// In en, this message translates to:
  /// **'Nothing due yet'**
  String get lay_nothingDueYet;

  /// No description provided for @rv_launchTitle.
  ///
  /// In en, this message translates to:
  /// **'Care from your previous version is waiting'**
  String get rv_launchTitle;

  /// No description provided for @rv_launchBody.
  ///
  /// In en, this message translates to:
  /// **'Your medications, schedules and history are safe on this device. Sign in to the server you used before to continue where you left off.'**
  String get rv_launchBody;

  /// No description provided for @rv_launchSignIn.
  ///
  /// In en, this message translates to:
  /// **'Sign in to your original server'**
  String get rv_launchSignIn;

  /// No description provided for @rv_launchReview.
  ///
  /// In en, this message translates to:
  /// **'Review your original server'**
  String get rv_launchReview;

  /// No description provided for @rv_launchLocal.
  ///
  /// In en, this message translates to:
  /// **'Set up new care on this device instead'**
  String get rv_launchLocal;

  /// No description provided for @rv_reviewTitle.
  ///
  /// In en, this message translates to:
  /// **'Confirm your original server'**
  String get rv_reviewTitle;

  /// No description provided for @rv_reviewBody.
  ///
  /// In en, this message translates to:
  /// **'The care saved by your previous version belongs to an account on one server. Confirm this is the server you used before. If it is not, sign out and nothing is changed.'**
  String get rv_reviewBody;

  /// No description provided for @rv_reviewAddress.
  ///
  /// In en, this message translates to:
  /// **'Server address'**
  String get rv_reviewAddress;

  /// No description provided for @rv_reviewConfirm.
  ///
  /// In en, this message translates to:
  /// **'Yes, this is my original server'**
  String get rv_reviewConfirm;

  /// No description provided for @rv_reviewReject.
  ///
  /// In en, this message translates to:
  /// **'No, sign out'**
  String get rv_reviewReject;

  /// No description provided for @rv_reviewError.
  ///
  /// In en, this message translates to:
  /// **'The review could not be completed. Try again.'**
  String get rv_reviewError;

  /// No description provided for @r08_connectedTitle.
  ///
  /// In en, this message translates to:
  /// **'You’re connected'**
  String get r08_connectedTitle;

  /// No description provided for @r08_connectedBody.
  ///
  /// In en, this message translates to:
  /// **'Add the first person you help. Their routine will sync with your server.'**
  String get r08_connectedBody;

  /// No description provided for @r08_connectedCard.
  ///
  /// In en, this message translates to:
  /// **'Synced with your server'**
  String get r08_connectedCard;

  /// No description provided for @r08_connectedStart.
  ///
  /// In en, this message translates to:
  /// **'Add the first person'**
  String get r08_connectedStart;

  /// No description provided for @r09_checkWaiting.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the reminder… {seconds} s'**
  String r09_checkWaiting(int seconds);

  /// No description provided for @r09_checkWaitingHint.
  ///
  /// In en, this message translates to:
  /// **'It can take up to 15 seconds to arrive. Keep this screen open.'**
  String get r09_checkWaitingHint;

  /// No description provided for @r09_checkQuestion.
  ///
  /// In en, this message translates to:
  /// **'Did you see the reminder on this phone?'**
  String get r09_checkQuestion;

  /// No description provided for @r09_checkYes.
  ///
  /// In en, this message translates to:
  /// **'Yes, I saw it'**
  String get r09_checkYes;

  /// No description provided for @r09_checkNo.
  ///
  /// In en, this message translates to:
  /// **'No, I didn’t'**
  String get r09_checkNo;

  /// No description provided for @r09_checkNoHelp.
  ///
  /// In en, this message translates to:
  /// **'Check that Simpastil notifications are on and that Do Not Disturb or battery saver is not blocking them, then send another check.'**
  String get r09_checkNoHelp;

  /// No description provided for @thread_sending.
  ///
  /// In en, this message translates to:
  /// **'Sending changes to your server…'**
  String get thread_sending;

  /// No description provided for @thread_settled.
  ///
  /// In en, this message translates to:
  /// **'Up to date with your server'**
  String get thread_settled;

  /// No description provided for @thread_falteredSaved.
  ///
  /// In en, this message translates to:
  /// **'The last sync didn’t finish · Changes stay on this phone'**
  String get thread_falteredSaved;

  /// No description provided for @thread_faltered.
  ///
  /// In en, this message translates to:
  /// **'The last sync didn’t finish · Open Sync'**
  String get thread_faltered;

  /// No description provided for @auth_stepVerification.
  ///
  /// In en, this message translates to:
  /// **'STEP 4 — VERIFICATION'**
  String get auth_stepVerification;

  /// No description provided for @story_plannedFor.
  ///
  /// In en, this message translates to:
  /// **'Planned for {time}'**
  String story_plannedFor(Object time);

  /// No description provided for @story_takenAt.
  ///
  /// In en, this message translates to:
  /// **'Taken at {time}'**
  String story_takenAt(Object time);

  /// No description provided for @story_skippedAt.
  ///
  /// In en, this message translates to:
  /// **'Skipped at {time}'**
  String story_skippedAt(Object time);

  /// No description provided for @story_recordedNoTime.
  ///
  /// In en, this message translates to:
  /// **'Recorded, time not known'**
  String get story_recordedNoTime;

  /// No description provided for @story_notYet.
  ///
  /// In en, this message translates to:
  /// **'Not recorded yet'**
  String get story_notYet;

  /// No description provided for @story_onTime.
  ///
  /// In en, this message translates to:
  /// **'At the planned time'**
  String get story_onTime;

  /// No description provided for @story_after.
  ///
  /// In en, this message translates to:
  /// **'{duration} after the plan'**
  String story_after(Object duration);

  /// No description provided for @story_before.
  ///
  /// In en, this message translates to:
  /// **'{duration} before the plan'**
  String story_before(Object duration);

  /// No description provided for @story_minutes.
  ///
  /// In en, this message translates to:
  /// **'{minutes} min'**
  String story_minutes(Object minutes);

  /// No description provided for @story_hoursMinutes.
  ///
  /// In en, this message translates to:
  /// **'{hours} h {minutes} min'**
  String story_hoursMinutes(Object hours, Object minutes);

  /// No description provided for @recovery_title.
  ///
  /// In en, this message translates to:
  /// **'Fix sync problems'**
  String get recovery_title;

  /// No description provided for @recovery_entryHintNone.
  ///
  /// In en, this message translates to:
  /// **'Nothing needs fixing right now'**
  String get recovery_entryHintNone;

  /// No description provided for @recovery_entryHint.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 change needs you} other{{count} changes need you}}'**
  String recovery_entryHint(int count);

  /// No description provided for @recovery_entryNotes.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 kept note to review} other{{count} kept notes to review}}'**
  String recovery_entryNotes(int count);

  /// No description provided for @recovery_entryChecking.
  ///
  /// In en, this message translates to:
  /// **'Check for sync problems'**
  String get recovery_entryChecking;

  /// No description provided for @recovery_intro.
  ///
  /// In en, this message translates to:
  /// **'These changes were made on this phone and have not reached the server yet. None of them is lost: each one stays here until it is sent or you decide otherwise.'**
  String get recovery_intro;

  /// No description provided for @recovery_nothingTitle.
  ///
  /// In en, this message translates to:
  /// **'Nothing to fix'**
  String get recovery_nothingTitle;

  /// No description provided for @recovery_nothingBody.
  ///
  /// In en, this message translates to:
  /// **'All your changes have been sent to the server.'**
  String get recovery_nothingBody;

  /// No description provided for @recovery_waitingOnly.
  ///
  /// In en, this message translates to:
  /// **'These will be sent by themselves. You don\'t need to do anything.'**
  String get recovery_waitingOnly;

  /// No description provided for @recovery_loadFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load the list of unsent changes.'**
  String get recovery_loadFailed;

  /// No description provided for @recovery_groupChanges.
  ///
  /// In en, this message translates to:
  /// **'Unsent changes'**
  String get recovery_groupChanges;

  /// No description provided for @recovery_groupTools.
  ///
  /// In en, this message translates to:
  /// **'More options'**
  String get recovery_groupTools;

  /// No description provided for @recovery_kindPerson.
  ///
  /// In en, this message translates to:
  /// **'Person'**
  String get recovery_kindPerson;

  /// No description provided for @recovery_kindMedication.
  ///
  /// In en, this message translates to:
  /// **'Medication'**
  String get recovery_kindMedication;

  /// No description provided for @recovery_kindSchedule.
  ///
  /// In en, this message translates to:
  /// **'Schedule'**
  String get recovery_kindSchedule;

  /// No description provided for @recovery_kindDose.
  ///
  /// In en, this message translates to:
  /// **'Dose'**
  String get recovery_kindDose;

  /// No description provided for @recovery_kindOther.
  ///
  /// In en, this message translates to:
  /// **'Change'**
  String get recovery_kindOther;

  /// No description provided for @recovery_unnamed.
  ///
  /// In en, this message translates to:
  /// **'Not on this phone anymore'**
  String get recovery_unnamed;

  /// No description provided for @recovery_changeAdded.
  ///
  /// In en, this message translates to:
  /// **'Added on this phone'**
  String get recovery_changeAdded;

  /// No description provided for @recovery_changeEdited.
  ///
  /// In en, this message translates to:
  /// **'Edited on this phone'**
  String get recovery_changeEdited;

  /// No description provided for @recovery_changeRemoved.
  ///
  /// In en, this message translates to:
  /// **'Removed on this phone'**
  String get recovery_changeRemoved;

  /// No description provided for @recovery_changeDose.
  ///
  /// In en, this message translates to:
  /// **'Dose recorded'**
  String get recovery_changeDose;

  /// No description provided for @recovery_changeStock.
  ///
  /// In en, this message translates to:
  /// **'Stock changed'**
  String get recovery_changeStock;

  /// No description provided for @recovery_changeOther.
  ///
  /// In en, this message translates to:
  /// **'Changed on this phone'**
  String get recovery_changeOther;

  /// No description provided for @recovery_reasonQueued.
  ///
  /// In en, this message translates to:
  /// **'Waiting to be sent'**
  String get recovery_reasonQueued;

  /// No description provided for @recovery_reasonRetrying.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t reach the server. Trying again at {time}.'**
  String recovery_reasonRetrying(String time);

  /// No description provided for @recovery_reasonRetryingSoon.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t reach the server. Trying again soon.'**
  String get recovery_reasonRetryingSoon;

  /// No description provided for @recovery_reasonBlocked.
  ///
  /// In en, this message translates to:
  /// **'Can\'t be sent as it is.'**
  String get recovery_reasonBlocked;

  /// No description provided for @recovery_reasonConflict.
  ///
  /// In en, this message translates to:
  /// **'Someone changed it on the server too.'**
  String get recovery_reasonConflict;

  /// No description provided for @recovery_reasonConflictSettled.
  ///
  /// In en, this message translates to:
  /// **'Someone changed it on the server too. The server\'s version is already showing here.'**
  String get recovery_reasonConflictSettled;

  /// No description provided for @recovery_reasonStranded.
  ///
  /// In en, this message translates to:
  /// **'Waiting for another change that is stuck.'**
  String get recovery_reasonStranded;

  /// No description provided for @recovery_reasonWaitingForStart.
  ///
  /// In en, this message translates to:
  /// **'Waiting for this medication\'s stock count to be sent first.'**
  String get recovery_reasonWaitingForStart;

  /// No description provided for @recovery_reasonStartStuck.
  ///
  /// In en, this message translates to:
  /// **'Held behind this medication\'s stock start, which needs a decision first. Open the stock start to settle it.'**
  String get recovery_reasonStartStuck;

  /// No description provided for @recovery_reasonReview.
  ///
  /// In en, this message translates to:
  /// **'Needs a decision. Try again, or discard it.'**
  String get recovery_reasonReview;

  /// No description provided for @recovery_blockedBodyChanged.
  ///
  /// In en, this message translates to:
  /// **'It was edited after the first attempt, so it can\'t be repeated safely.'**
  String get recovery_blockedBodyChanged;

  /// No description provided for @recovery_blockedExhausted.
  ///
  /// In en, this message translates to:
  /// **'The server couldn\'t be reached after several tries.'**
  String get recovery_blockedExhausted;

  /// No description provided for @recovery_blockedUndo.
  ///
  /// In en, this message translates to:
  /// **'This server can\'t take this back yet.'**
  String get recovery_blockedUndo;

  /// No description provided for @recovery_blockedGeneric.
  ///
  /// In en, this message translates to:
  /// **'The server or this phone couldn\'t accept it as it is.'**
  String get recovery_blockedGeneric;

  /// No description provided for @reminders_resetGroup.
  ///
  /// In en, this message translates to:
  /// **'Repair'**
  String get reminders_resetGroup;

  /// No description provided for @reminders_resetTitle.
  ///
  /// In en, this message translates to:
  /// **'Reset reminders'**
  String get reminders_resetTitle;

  /// No description provided for @reminders_resetHint.
  ///
  /// In en, this message translates to:
  /// **'Clear every reminder this device has set and set them again from your schedules. Medicines and history are not touched.'**
  String get reminders_resetHint;

  /// No description provided for @reminders_resetConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'This clears all reminders on this device and sets them again. Use it if a reminder rings twice or not at all.'**
  String get reminders_resetConfirmBody;

  /// No description provided for @reminders_resetAction.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get reminders_resetAction;

  /// No description provided for @reminders_resetDone.
  ///
  /// In en, this message translates to:
  /// **'Reminders reset. {count} set again.'**
  String reminders_resetDone(int count);

  /// No description provided for @reminders_resetNeedsPermission.
  ///
  /// In en, this message translates to:
  /// **'Allow notifications and exact alarms first, then reset reminders.'**
  String get reminders_resetNeedsPermission;

  /// No description provided for @reminders_resetFailed.
  ///
  /// In en, this message translates to:
  /// **'Reminders could not be reset. Try again in a moment.'**
  String get reminders_resetFailed;

  /// No description provided for @reminders_resetRegistryUnreadable.
  ///
  /// In en, this message translates to:
  /// **'The reminder records on this device could not be read, so nothing was changed. Your medicines and history are safe.'**
  String get reminders_resetRegistryUnreadable;

  /// No description provided for @reminders_resetRestoring.
  ///
  /// In en, this message translates to:
  /// **'Reminders are being set up again. This can take a moment.'**
  String get reminders_resetRestoring;

  /// No description provided for @reminders_auditStatus.
  ///
  /// In en, this message translates to:
  /// **'Last check: {when}. Stray reminders removed: {count}.'**
  String reminders_auditStatus(String when, int count);

  /// No description provided for @reminders_auditDeferred.
  ///
  /// In en, this message translates to:
  /// **'Last check: {when}. It could not finish and will try again.'**
  String reminders_auditDeferred(String when);

  /// No description provided for @reminders_auditPartial.
  ///
  /// In en, this message translates to:
  /// **' Some shared care was left out this time.'**
  String get reminders_auditPartial;

  /// No description provided for @recovery_retryAll.
  ///
  /// In en, this message translates to:
  /// **'Retry all'**
  String get recovery_retryAll;

  /// No description provided for @recovery_retryAllHint.
  ///
  /// In en, this message translates to:
  /// **'Try every stuck change again, then check the server.'**
  String get recovery_retryAllHint;

  /// No description provided for @recovery_useServer.
  ///
  /// In en, this message translates to:
  /// **'Use server version'**
  String get recovery_useServer;

  /// No description provided for @recovery_keepMine.
  ///
  /// In en, this message translates to:
  /// **'Keep my change'**
  String get recovery_keepMine;

  /// No description provided for @recovery_dismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get recovery_dismiss;

  /// No description provided for @recovery_tryAgain.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get recovery_tryAgain;

  /// No description provided for @recovery_discard.
  ///
  /// In en, this message translates to:
  /// **'Discard this change'**
  String get recovery_discard;

  /// No description provided for @recovery_discardTitle.
  ///
  /// In en, this message translates to:
  /// **'Discard this change?'**
  String get recovery_discardTitle;

  /// No description provided for @recovery_discardDoseBody.
  ///
  /// In en, this message translates to:
  /// **'The dose you recorded on this phone for {name} was never accepted by the server. It will be dropped and the dose will show as the server has it. Changes that don\'t depend on it will then be sent. This can\'t be undone.'**
  String recovery_discardDoseBody(String name);

  /// No description provided for @recovery_discardStockBody.
  ///
  /// In en, this message translates to:
  /// **'The stock change you made on this phone for {name} never reached the server. It will be dropped and the stock will show as the server has it. Changes that don\'t depend on it will then be sent. This can\'t be undone.'**
  String recovery_discardStockBody(String name);

  /// No description provided for @recovery_discardOtherBody.
  ///
  /// In en, this message translates to:
  /// **'This change to {name} never reached the server. It will be dropped and whatever doesn\'t depend on it will be sent. This can\'t be undone.'**
  String recovery_discardOtherBody(String name);

  /// No description provided for @recovery_doneTryAgain.
  ///
  /// In en, this message translates to:
  /// **'Tried again. Anything still stuck stays on this list.'**
  String get recovery_doneTryAgain;

  /// No description provided for @recovery_doneDiscard.
  ///
  /// In en, this message translates to:
  /// **'Discarded. Whatever was waiting behind it is being sent.'**
  String get recovery_doneDiscard;

  /// No description provided for @recovery_groupNotes.
  ///
  /// In en, this message translates to:
  /// **'Kept notes'**
  String get recovery_groupNotes;

  /// No description provided for @recovery_noteTitle.
  ///
  /// In en, this message translates to:
  /// **'Note from an earlier sync'**
  String get recovery_noteTitle;

  /// No description provided for @recovery_noteBody.
  ///
  /// In en, this message translates to:
  /// **'Something was kept for review. It blocks nothing and its details are kept.'**
  String get recovery_noteBody;

  /// No description provided for @recovery_discardCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, other{{count} changes in all will be dropped, including the ones that depend on it.}}'**
  String recovery_discardCount(int count);

  /// No description provided for @recovery_discardHistory.
  ///
  /// In en, this message translates to:
  /// **'This was added on this phone and already has dose history, so it can\'t be discarded. Retry it instead.'**
  String get recovery_discardHistory;

  /// No description provided for @recovery_useServerTitle.
  ///
  /// In en, this message translates to:
  /// **'Use the server\'s version?'**
  String get recovery_useServerTitle;

  /// No description provided for @recovery_useServerBody.
  ///
  /// In en, this message translates to:
  /// **'Your unsent change to {name} will be dropped and the server\'s version will replace it. This can\'t be undone.'**
  String recovery_useServerBody(String name);

  /// No description provided for @recovery_useServerCreateBody.
  ///
  /// In en, this message translates to:
  /// **'{name} was only ever added on this phone. It will be removed from this phone together with the changes waiting for it. This can\'t be undone.'**
  String recovery_useServerCreateBody(String name);

  /// No description provided for @recovery_keepMineTitle.
  ///
  /// In en, this message translates to:
  /// **'Keep your change?'**
  String get recovery_keepMineTitle;

  /// No description provided for @recovery_keepMineBody.
  ///
  /// In en, this message translates to:
  /// **'Your change to {name} will be sent again on top of the server\'s latest version. Whatever was changed on the server in the meantime will be overwritten.'**
  String recovery_keepMineBody(String name);

  /// No description provided for @recovery_redownload.
  ///
  /// In en, this message translates to:
  /// **'Re-download from server'**
  String get recovery_redownload;

  /// No description provided for @recovery_redownloadHint.
  ///
  /// In en, this message translates to:
  /// **'Fetch everything from the server again. Your unsent changes stay.'**
  String get recovery_redownloadHint;

  /// No description provided for @recovery_redownloadTitle.
  ///
  /// In en, this message translates to:
  /// **'Re-download everything?'**
  String get recovery_redownloadTitle;

  /// No description provided for @recovery_redownloadBody.
  ///
  /// In en, this message translates to:
  /// **'Waiting changes are sent first, then everything is downloaded again. Changes still waiting on this phone are kept and never overwritten. This can use more data.'**
  String get recovery_redownloadBody;

  /// No description provided for @recovery_copyDiagnostics.
  ///
  /// In en, this message translates to:
  /// **'Copy diagnostics'**
  String get recovery_copyDiagnostics;

  /// No description provided for @recovery_copyDiagnosticsHint.
  ///
  /// In en, this message translates to:
  /// **'Counts and codes only: no names, notes or addresses.'**
  String get recovery_copyDiagnosticsHint;

  /// No description provided for @recovery_copied.
  ///
  /// In en, this message translates to:
  /// **'Diagnostics copied'**
  String get recovery_copied;

  /// No description provided for @recovery_doneRetry.
  ///
  /// In en, this message translates to:
  /// **'Tried again. Anything still stuck stays on this list.'**
  String get recovery_doneRetry;

  /// No description provided for @recovery_doneServer.
  ///
  /// In en, this message translates to:
  /// **'Done. The server\'s version is being used.'**
  String get recovery_doneServer;

  /// No description provided for @recovery_doneKeep.
  ///
  /// In en, this message translates to:
  /// **'Your change will be sent again.'**
  String get recovery_doneKeep;

  /// No description provided for @recovery_doneDismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismissed.'**
  String get recovery_doneDismiss;

  /// No description provided for @recovery_doneRedownload.
  ///
  /// In en, this message translates to:
  /// **'Downloaded again from the server.'**
  String get recovery_doneRedownload;

  /// No description provided for @recovery_busy.
  ///
  /// In en, this message translates to:
  /// **'A sync is already running. Try again in a moment.'**
  String get recovery_busy;

  /// No description provided for @recovery_failed.
  ///
  /// In en, this message translates to:
  /// **'That didn\'t work. Nothing was lost.'**
  String get recovery_failed;

  /// No description provided for @recovery_refusedSending.
  ///
  /// In en, this message translates to:
  /// **'A change is being sent right now. Try again in a moment.'**
  String get recovery_refusedSending;

  /// No description provided for @recovery_refusedGone.
  ///
  /// In en, this message translates to:
  /// **'Already taken care of.'**
  String get recovery_refusedGone;

  /// No description provided for @recovery_refusedNotDiscardable.
  ///
  /// In en, this message translates to:
  /// **'There is nothing here that can be discarded.'**
  String get recovery_refusedNotDiscardable;

  /// No description provided for @recovery_refusedOffline.
  ///
  /// In en, this message translates to:
  /// **'The server can\'t be reached right now, so your change was kept. Try again when you are online.'**
  String get recovery_refusedOffline;

  /// No description provided for @recovery_serverCopyPending.
  ///
  /// In en, this message translates to:
  /// **'Your change was dropped. The server\'s version is waiting to download and will replace it at the next sync.'**
  String get recovery_serverCopyPending;

  /// No description provided for @recovery_reasonConflictDeleted.
  ///
  /// In en, this message translates to:
  /// **'It was deleted on the server, so your change can\'t be applied. Use the server\'s version to accept the deletion.'**
  String get recovery_reasonConflictDeleted;

  /// No description provided for @asn_hintTitle.
  ///
  /// In en, this message translates to:
  /// **'Hold a card to record a dose'**
  String get asn_hintTitle;

  /// No description provided for @asn_hintBody.
  ///
  /// In en, this message translates to:
  /// **'Keep your finger on it until the ring fills. Tap a card for details.'**
  String get asn_hintBody;

  /// No description provided for @asn_hintGotIt.
  ///
  /// In en, this message translates to:
  /// **'Got it'**
  String get asn_hintGotIt;

  /// No description provided for @asn_holdToRecord.
  ///
  /// In en, this message translates to:
  /// **'Hold to record'**
  String get asn_holdToRecord;

  /// No description provided for @asn_keepHolding.
  ///
  /// In en, this message translates to:
  /// **'Keep holding'**
  String get asn_keepHolding;

  /// No description provided for @asn_todayCount.
  ///
  /// In en, this message translates to:
  /// **'{count} today'**
  String asn_todayCount(int count);

  /// No description provided for @asn_notTakenYet.
  ///
  /// In en, this message translates to:
  /// **'Not taken yet'**
  String get asn_notTakenYet;

  /// No description provided for @asn_amountAgo.
  ///
  /// In en, this message translates to:
  /// **'{amount} · {ago}'**
  String asn_amountAgo(String amount, String ago);

  /// No description provided for @asn_takenAtToday.
  ///
  /// In en, this message translates to:
  /// **'Taken {time} · {count} today'**
  String asn_takenAtToday(String time, int count);

  /// No description provided for @asn_takenToday.
  ///
  /// In en, this message translates to:
  /// **'Taken today'**
  String get asn_takenToday;

  /// No description provided for @asn_takenTime.
  ///
  /// In en, this message translates to:
  /// **'Taken {time}'**
  String asn_takenTime(String time);

  /// No description provided for @asn_needsReview.
  ///
  /// In en, this message translates to:
  /// **'Needs review'**
  String get asn_needsReview;

  /// No description provided for @asn_logLine.
  ///
  /// In en, this message translates to:
  /// **'{count} today · last {time}'**
  String asn_logLine(int count, String time);

  /// No description provided for @asn_logLineNoTime.
  ///
  /// In en, this message translates to:
  /// **'{count} today'**
  String asn_logLineNoTime(int count);

  /// No description provided for @asn_logNone.
  ///
  /// In en, this message translates to:
  /// **'None today'**
  String get asn_logNone;

  /// No description provided for @asn_noDosesToday.
  ///
  /// In en, this message translates to:
  /// **'No doses yet today'**
  String get asn_noDosesToday;

  /// No description provided for @asn_logToggle.
  ///
  /// In en, this message translates to:
  /// **'Doses taken today'**
  String get asn_logToggle;

  /// No description provided for @asn_statToday.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get asn_statToday;

  /// No description provided for @asn_stat7Days.
  ///
  /// In en, this message translates to:
  /// **'Last 7 days'**
  String get asn_stat7Days;

  /// No description provided for @asn_statLastDose.
  ///
  /// In en, this message translates to:
  /// **'Last dose'**
  String get asn_statLastDose;

  /// No description provided for @asn_onlyWhenNeeded.
  ///
  /// In en, this message translates to:
  /// **'Only when needed'**
  String get asn_onlyWhenNeeded;

  /// No description provided for @asn_recentDoses.
  ///
  /// In en, this message translates to:
  /// **'Recent doses'**
  String get asn_recentDoses;

  /// No description provided for @asn_yesterday.
  ///
  /// In en, this message translates to:
  /// **'Yesterday'**
  String get asn_yesterday;

  /// No description provided for @asn_doseCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 dose} other{{count} doses}}'**
  String asn_doseCount(int count);

  /// No description provided for @asn_groupHeader.
  ///
  /// In en, this message translates to:
  /// **'{day} · {doses}'**
  String asn_groupHeader(String day, String doses);

  /// No description provided for @asn_noRecentDoses.
  ///
  /// In en, this message translates to:
  /// **'No doses in the last 7 days'**
  String get asn_noRecentDoses;

  /// No description provided for @asn_recordNow.
  ///
  /// In en, this message translates to:
  /// **'Record now'**
  String get asn_recordNow;

  /// No description provided for @asn_openEditor.
  ///
  /// In en, this message translates to:
  /// **'Open dose editor'**
  String get asn_openEditor;

  /// No description provided for @asn_usualDose.
  ///
  /// In en, this message translates to:
  /// **'Usual dose {amount}'**
  String asn_usualDose(String amount);

  /// No description provided for @asn_stockLeft.
  ///
  /// In en, this message translates to:
  /// **'{amount} left'**
  String asn_stockLeft(String amount);

  /// No description provided for @asn_stockLow.
  ///
  /// In en, this message translates to:
  /// **'Running low'**
  String get asn_stockLow;

  /// No description provided for @asn_stockLabel.
  ///
  /// In en, this message translates to:
  /// **'Stock'**
  String get asn_stockLabel;

  /// No description provided for @asn_editorTitle.
  ///
  /// In en, this message translates to:
  /// **'Record a dose'**
  String get asn_editorTitle;

  /// No description provided for @asn_amountLabel.
  ///
  /// In en, this message translates to:
  /// **'Amount'**
  String get asn_amountLabel;

  /// No description provided for @asn_amountDecrease.
  ///
  /// In en, this message translates to:
  /// **'Decrease amount'**
  String get asn_amountDecrease;

  /// No description provided for @asn_amountIncrease.
  ///
  /// In en, this message translates to:
  /// **'Increase amount'**
  String get asn_amountIncrease;

  /// No description provided for @asn_whenLabel.
  ///
  /// In en, this message translates to:
  /// **'When'**
  String get asn_whenLabel;

  /// No description provided for @asn_whenNow.
  ///
  /// In en, this message translates to:
  /// **'Now'**
  String get asn_whenNow;

  /// No description provided for @asn_when15.
  ///
  /// In en, this message translates to:
  /// **'15 min ago'**
  String get asn_when15;

  /// No description provided for @asn_when1h.
  ///
  /// In en, this message translates to:
  /// **'1 h ago'**
  String get asn_when1h;

  /// No description provided for @asn_when3h.
  ///
  /// In en, this message translates to:
  /// **'3 h ago'**
  String get asn_when3h;

  /// No description provided for @asn_whenPick.
  ///
  /// In en, this message translates to:
  /// **'Pick time'**
  String get asn_whenPick;

  /// No description provided for @asn_whenUnknown.
  ///
  /// In en, this message translates to:
  /// **'Not sure'**
  String get asn_whenUnknown;

  /// No description provided for @asn_amountNotSure.
  ///
  /// In en, this message translates to:
  /// **'Not sure'**
  String get asn_amountNotSure;

  /// No description provided for @asn_save.
  ///
  /// In en, this message translates to:
  /// **'Save {amount} at {time}'**
  String asn_save(String amount, String time);

  /// No description provided for @asn_saveNoTime.
  ///
  /// In en, this message translates to:
  /// **'Save {amount}, time not known'**
  String asn_saveNoTime(String amount);

  /// No description provided for @asn_cardLabel.
  ///
  /// In en, this message translates to:
  /// **'{name}, for {person}. {info}'**
  String asn_cardLabel(String name, String person, String info);

  /// No description provided for @asn_recordAction.
  ///
  /// In en, this message translates to:
  /// **'Record dose'**
  String get asn_recordAction;

  /// No description provided for @asn_agoJustNow.
  ///
  /// In en, this message translates to:
  /// **'Just now'**
  String get asn_agoJustNow;

  /// No description provided for @asn_agoMinutes.
  ///
  /// In en, this message translates to:
  /// **'{count} min ago'**
  String asn_agoMinutes(int count);

  /// No description provided for @asn_agoHours.
  ///
  /// In en, this message translates to:
  /// **'{count} h ago'**
  String asn_agoHours(int count);

  /// No description provided for @asn_agoDays.
  ///
  /// In en, this message translates to:
  /// **'{count} d ago'**
  String asn_agoDays(int count);

  /// No description provided for @asn_unitPlaceholder.
  ///
  /// In en, this message translates to:
  /// **'Unit'**
  String get asn_unitPlaceholder;

  /// No description provided for @asn_detailsFor.
  ///
  /// In en, this message translates to:
  /// **'Details for {name}'**
  String asn_detailsFor(String name);

  /// No description provided for @asn_jumpLabel.
  ///
  /// In en, this message translates to:
  /// **'Jump to As needed'**
  String get asn_jumpLabel;

  /// No description provided for @asn_shortcutTitle.
  ///
  /// In en, this message translates to:
  /// **'As needed shortcut'**
  String get asn_shortcutTitle;

  /// No description provided for @asn_shortcutSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Show a button that jumps to your as-needed medicines'**
  String get asn_shortcutSubtitle;

  /// No description provided for @asn_editorSwitch.
  ///
  /// In en, this message translates to:
  /// **'Only when I need it'**
  String get asn_editorSwitch;

  /// No description provided for @asn_editorSwitchHint.
  ///
  /// In en, this message translates to:
  /// **'No routine and no reminders. Record a dose whenever you take it.'**
  String get asn_editorSwitchHint;

  /// No description provided for @asn_detailIntro.
  ///
  /// In en, this message translates to:
  /// **'Taken only when needed, so there is no routine to set up.'**
  String get asn_detailIntro;

  /// No description provided for @asn_recordDose.
  ///
  /// In en, this message translates to:
  /// **'Record a dose'**
  String get asn_recordDose;

  /// No description provided for @asn_prnStat.
  ///
  /// In en, this message translates to:
  /// **'As-needed doses (last 30 days, separate): {count}'**
  String asn_prnStat(int count);

  /// No description provided for @lay_asNeededCount.
  ///
  /// In en, this message translates to:
  /// **'{count} as needed'**
  String lay_asNeededCount(int count);

  /// No description provided for @jrn_tookAsNeeded.
  ///
  /// In en, this message translates to:
  /// **'{time} · {person} took {medication}, as needed'**
  String jrn_tookAsNeeded(String time, String person, String medication);

  /// No description provided for @jrn_tookAsNeededUnknown.
  ///
  /// In en, this message translates to:
  /// **'{person} took {medication}, as needed · time not known'**
  String jrn_tookAsNeededUnknown(String person, String medication);

  /// No description provided for @lay_exampleAsNeeded.
  ///
  /// In en, this message translates to:
  /// **'Ibuprofen'**
  String get lay_exampleAsNeeded;

  /// No description provided for @tm_stockFine.
  ///
  /// In en, this message translates to:
  /// **'Stock is fine'**
  String get tm_stockFine;

  /// No description provided for @tm_stockFineBody.
  ///
  /// In en, this message translates to:
  /// **'Nothing runs out in the next 14 days'**
  String get tm_stockFineBody;

  /// No description provided for @tm_stockSoon.
  ///
  /// In en, this message translates to:
  /// **'Runs out soon'**
  String get tm_stockSoon;

  /// No description provided for @tm_stockOut.
  ///
  /// In en, this message translates to:
  /// **'Out of stock'**
  String get tm_stockOut;

  /// No description provided for @tm_stockUntracked.
  ///
  /// In en, this message translates to:
  /// **'No stock counts yet'**
  String get tm_stockUntracked;

  /// No description provided for @tm_stockUntrackedBody.
  ///
  /// In en, this message translates to:
  /// **'Add a count to a medication to see when it runs out'**
  String get tm_stockUntrackedBody;

  /// No description provided for @tm_scheduledLabel.
  ///
  /// In en, this message translates to:
  /// **'Scheduled'**
  String get tm_scheduledLabel;

  /// No description provided for @tm_asNeededBody.
  ///
  /// In en, this message translates to:
  /// **'Recorded from Today'**
  String get tm_asNeededBody;

  /// No description provided for @tm_stockNegativeSpoken.
  ///
  /// In en, this message translates to:
  /// **'Warning: negative stock. {label}'**
  String tm_stockNegativeSpoken(String label);

  /// No description provided for @tm_noCount.
  ///
  /// In en, this message translates to:
  /// **'No count'**
  String get tm_noCount;

  /// No description provided for @tm_stockTitle.
  ///
  /// In en, this message translates to:
  /// **'Stock'**
  String get tm_stockTitle;

  /// No description provided for @tm_addStock.
  ///
  /// In en, this message translates to:
  /// **'Add stock'**
  String get tm_addStock;

  /// No description provided for @tm_stockNone.
  ///
  /// In en, this message translates to:
  /// **'No stock count yet. Add one to see when it runs out.'**
  String get tm_stockNone;

  /// No description provided for @tm_runsOutAround.
  ///
  /// In en, this message translates to:
  /// **'Runs out around {date}'**
  String tm_runsOutAround(String date);

  /// No description provided for @tm_refillAt.
  ///
  /// In en, this message translates to:
  /// **'Refill reminder at {count} left'**
  String tm_refillAt(int count);

  /// No description provided for @tm_last14Title.
  ///
  /// In en, this message translates to:
  /// **'Last 14 days'**
  String get tm_last14Title;

  /// No description provided for @tm_daysTaken.
  ///
  /// In en, this message translates to:
  /// **'{taken} of {due} days'**
  String tm_daysTaken(int taken, int due);

  /// No description provided for @tm_daysTakenSpoken.
  ///
  /// In en, this message translates to:
  /// **'Every dose taken on {taken} of {due} days'**
  String tm_daysTakenSpoken(int taken, int due);

  /// No description provided for @tm_last14Empty.
  ///
  /// In en, this message translates to:
  /// **'No doses recorded yet. Doses you record on Today fill these in.'**
  String get tm_last14Empty;

  /// No description provided for @tm_asNeededTotal.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No doses} =1{1 dose} other{{count} doses}}'**
  String tm_asNeededTotal(int count);

  /// No description provided for @tm_last14AsNeededNote.
  ///
  /// In en, this message translates to:
  /// **'As-needed doses taken each day.'**
  String get tm_last14AsNeededNote;

  /// No description provided for @tm_dayPartial.
  ///
  /// In en, this message translates to:
  /// **'Some doses taken'**
  String get tm_dayPartial;

  /// No description provided for @tm_dayNone.
  ///
  /// In en, this message translates to:
  /// **'No dose planned'**
  String get tm_dayNone;

  /// No description provided for @tm_dayUpcoming.
  ///
  /// In en, this message translates to:
  /// **'Not due yet'**
  String get tm_dayUpcoming;

  /// No description provided for @tm_dayCell.
  ///
  /// In en, this message translates to:
  /// **'{date}: {state}'**
  String tm_dayCell(String date, String state);

  /// No description provided for @tm_dayCellAsNeeded.
  ///
  /// In en, this message translates to:
  /// **'{date}: {count, plural, =0{no doses} =1{1 dose} other{{count} doses}}'**
  String tm_dayCellAsNeeded(String date, int count);

  /// No description provided for @tm_recentTitle.
  ///
  /// In en, this message translates to:
  /// **'Recent'**
  String get tm_recentTitle;

  /// No description provided for @tm_seeAllHistory.
  ///
  /// In en, this message translates to:
  /// **'See all in History'**
  String get tm_seeAllHistory;

  /// No description provided for @tm_recentEmpty.
  ///
  /// In en, this message translates to:
  /// **'Nothing recorded in the last 30 days.'**
  String get tm_recentEmpty;

  /// No description provided for @tm_kindScheduled.
  ///
  /// In en, this message translates to:
  /// **'Scheduled'**
  String get tm_kindScheduled;

  /// No description provided for @tm_statSchedule.
  ///
  /// In en, this message translates to:
  /// **'Schedule'**
  String get tm_statSchedule;

  /// No description provided for @tm_perUse.
  ///
  /// In en, this message translates to:
  /// **'Per use'**
  String get tm_perUse;

  /// No description provided for @tm_edit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get tm_edit;

  /// No description provided for @tm_previewTitle.
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get tm_previewTitle;

  /// No description provided for @tm_previewNote.
  ///
  /// In en, this message translates to:
  /// **'This is how the dose shows on Today and in reminders.'**
  String get tm_previewNote;

  /// No description provided for @tm_stockAfterSaving.
  ///
  /// In en, this message translates to:
  /// **'Stock after saving'**
  String get tm_stockAfterSaving;

  /// No description provided for @tm_stockWas.
  ///
  /// In en, this message translates to:
  /// **'Was {count}'**
  String tm_stockWas(int count);

  /// No description provided for @th_viewCalendar.
  ///
  /// In en, this message translates to:
  /// **'Calendar'**
  String get th_viewCalendar;

  /// No description provided for @th_viewTrends.
  ///
  /// In en, this message translates to:
  /// **'Trends'**
  String get th_viewTrends;

  /// No description provided for @th_viewLabel.
  ///
  /// In en, this message translates to:
  /// **'History view'**
  String get th_viewLabel;

  /// No description provided for @th_monthSoFar.
  ///
  /// In en, this message translates to:
  /// **'{month} so far'**
  String th_monthSoFar(String month);

  /// No description provided for @th_tilePlannedRecorded.
  ///
  /// In en, this message translates to:
  /// **'Planned recorded'**
  String get th_tilePlannedRecorded;

  /// No description provided for @th_tileOfTotal.
  ///
  /// In en, this message translates to:
  /// **'{recorded} of {total}'**
  String th_tileOfTotal(int recorded, int total);

  /// No description provided for @th_tileAsNeededDoses.
  ///
  /// In en, this message translates to:
  /// **'As-needed doses'**
  String get th_tileAsNeededDoses;

  /// No description provided for @th_dayPlannedRecorded.
  ///
  /// In en, this message translates to:
  /// **'Planned doses recorded'**
  String get th_dayPlannedRecorded;

  /// No description provided for @th_dayAsNeededDoses.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{As-needed dose} other{As-needed doses}}'**
  String th_dayAsNeededDoses(int count);

  /// No description provided for @th_dayStreak.
  ///
  /// In en, this message translates to:
  /// **'Day streak'**
  String get th_dayStreak;

  /// No description provided for @th_streakBest.
  ///
  /// In en, this message translates to:
  /// **'Best in 12 weeks: {days}'**
  String th_streakBest(int days);

  /// No description provided for @th_byMedication.
  ///
  /// In en, this message translates to:
  /// **'By medication'**
  String get th_byMedication;

  /// No description provided for @th_scheduledLast30.
  ///
  /// In en, this message translates to:
  /// **'Scheduled, last 30 days'**
  String get th_scheduledLast30;

  /// No description provided for @th_asNeededByMedication.
  ///
  /// In en, this message translates to:
  /// **'As needed by medication'**
  String get th_asNeededByMedication;

  /// No description provided for @th_asNeededNone.
  ///
  /// In en, this message translates to:
  /// **'No as-needed doses in the last 30 days'**
  String get th_asNeededNone;

  /// No description provided for @th_asNeededCountSemantics.
  ///
  /// In en, this message translates to:
  /// **'{medication}: {count, plural, =1{1 dose} other{{count} doses}}'**
  String th_asNeededCountSemantics(String medication, int count);

  /// No description provided for @th_unknownMedication.
  ///
  /// In en, this message translates to:
  /// **'Unknown medication'**
  String get th_unknownMedication;

  /// No description provided for @th_timeOfDay.
  ///
  /// In en, this message translates to:
  /// **'Time of day'**
  String get th_timeOfDay;

  /// No description provided for @th_timeOfDayNote.
  ///
  /// In en, this message translates to:
  /// **'When doses were taken, last 30 days'**
  String get th_timeOfDayNote;

  /// No description provided for @th_timeOfDayNone.
  ///
  /// In en, this message translates to:
  /// **'No doses with a known time in the last 30 days'**
  String get th_timeOfDayNone;

  /// No description provided for @th_timeOfDaySemantics.
  ///
  /// In en, this message translates to:
  /// **'Doses by hour of the day, last 30 days. Most at {hour}: {count}.'**
  String th_timeOfDaySemantics(String hour, int count);

  /// No description provided for @th_weekOfSemantics.
  ///
  /// In en, this message translates to:
  /// **'Week of {date}: {value}'**
  String th_weekOfSemantics(String date, String value);

  /// No description provided for @th_pillAdherenceSemantics.
  ///
  /// In en, this message translates to:
  /// **'{name}: {taken} of {expected} taken, {percent} adherence'**
  String th_pillAdherenceSemantics(
    String name,
    int taken,
    int expected,
    String percent,
  );

  /// No description provided for @th_calendarDayFuture.
  ///
  /// In en, this message translates to:
  /// **'{date}, in the future'**
  String th_calendarDayFuture(String date);

  /// No description provided for @th_stockChanges.
  ///
  /// In en, this message translates to:
  /// **'Stock changes'**
  String get th_stockChanges;

  /// No description provided for @th_stockChangeRow.
  ///
  /// In en, this message translates to:
  /// **'{medication}, {before} to {after}'**
  String th_stockChangeRow(String medication, int before, int after);

  /// No description provided for @th_stockKindRefill.
  ///
  /// In en, this message translates to:
  /// **'Refill'**
  String get th_stockKindRefill;

  /// No description provided for @th_stockKindCorrection.
  ///
  /// In en, this message translates to:
  /// **'Corrected'**
  String get th_stockKindCorrection;

  /// No description provided for @th_stockKindUndone.
  ///
  /// In en, this message translates to:
  /// **'Dose undone'**
  String get th_stockKindUndone;

  /// No description provided for @th_stockChangeSemantics.
  ///
  /// In en, this message translates to:
  /// **'{medication}: stock from {before} to {after} at {time}'**
  String th_stockChangeSemantics(
    String medication,
    int before,
    int after,
    String time,
  );

  /// No description provided for @ts_nextTitle.
  ///
  /// In en, this message translates to:
  /// **'Next reminders on this device'**
  String get ts_nextTitle;

  /// No description provided for @ts_nextEmpty.
  ///
  /// In en, this message translates to:
  /// **'No reminders are planned for the next 30 days.'**
  String get ts_nextEmpty;

  /// No description provided for @ts_nextEmptyNobody.
  ///
  /// In en, this message translates to:
  /// **'No one is switched on for reminders on this device, so none are planned.'**
  String get ts_nextEmptyNobody;

  /// No description provided for @ts_nextLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'The planned reminders could not be read.'**
  String get ts_nextLoadFailed;

  /// No description provided for @ts_whenToday.
  ///
  /// In en, this message translates to:
  /// **'Today {time}'**
  String ts_whenToday(String time);

  /// No description provided for @ts_whenTonight.
  ///
  /// In en, this message translates to:
  /// **'Tonight {time}'**
  String ts_whenTonight(String time);

  /// No description provided for @ts_whenTomorrow.
  ///
  /// In en, this message translates to:
  /// **'Tomorrow {time}'**
  String ts_whenTomorrow(String time);

  /// No description provided for @ts_whenDay.
  ///
  /// In en, this message translates to:
  /// **'{day} {time}'**
  String ts_whenDay(String day, String time);

  /// No description provided for @ts_previewTitle.
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get ts_previewTitle;

  /// No description provided for @ts_previewNext.
  ///
  /// In en, this message translates to:
  /// **'Your next reminder, as it will appear.'**
  String get ts_previewNext;

  /// No description provided for @ts_previewSample.
  ///
  /// In en, this message translates to:
  /// **'An example. No reminder is planned yet.'**
  String get ts_previewSample;

  /// No description provided for @ts_previewOnDevice.
  ///
  /// In en, this message translates to:
  /// **'Preview on this device'**
  String get ts_previewOnDevice;

  /// No description provided for @tt_stockTitle.
  ///
  /// In en, this message translates to:
  /// **'Stock'**
  String get tt_stockTitle;

  /// No description provided for @tt_stockEmpty.
  ///
  /// In en, this message translates to:
  /// **'Stock counts you keep for your medicines show up here.'**
  String get tt_stockEmpty;

  /// No description provided for @tt_stockLeft.
  ///
  /// In en, this message translates to:
  /// **'{count} left'**
  String tt_stockLeft(String count);

  /// No description provided for @tt_stockAsNeeded.
  ///
  /// In en, this message translates to:
  /// **'Used as needed'**
  String get tt_stockAsNeeded;

  /// No description provided for @tt_stockLong.
  ///
  /// In en, this message translates to:
  /// **'More than two months'**
  String get tt_stockLong;

  /// No description provided for @tt_stockAboutDays.
  ///
  /// In en, this message translates to:
  /// **'About {count, plural, =1{1 day} other{{count} days}}'**
  String tt_stockAboutDays(int count);

  /// No description provided for @tt_stockAboutWeeks.
  ///
  /// In en, this message translates to:
  /// **'About {count, plural, =1{1 week} other{{count} weeks}}'**
  String tt_stockAboutWeeks(int count);

  /// No description provided for @tt_stockOut.
  ///
  /// In en, this message translates to:
  /// **'Out of stock'**
  String get tt_stockOut;

  /// No description provided for @tt_stockRow.
  ///
  /// In en, this message translates to:
  /// **'{name}, {left}'**
  String tt_stockRow(String name, String left);

  /// No description provided for @tt_week.
  ///
  /// In en, this message translates to:
  /// **'This week'**
  String get tt_week;

  /// No description provided for @tt_weekRecorded.
  ///
  /// In en, this message translates to:
  /// **'{count} recorded'**
  String tt_weekRecorded(int count);

  /// No description provided for @tt_weekHint.
  ///
  /// In en, this message translates to:
  /// **'Doses you record fill these in. Taken late still counts.'**
  String get tt_weekHint;

  /// No description provided for @tt_weekDay.
  ///
  /// In en, this message translates to:
  /// **'{date}: {count, plural, =0{nothing recorded} =1{1 dose recorded} other{{count} doses recorded}}'**
  String tt_weekDay(String date, int count);

  /// No description provided for @tt_comingUp.
  ///
  /// In en, this message translates to:
  /// **'Coming up'**
  String get tt_comingUp;

  /// No description provided for @tt_comingUpPlanned.
  ///
  /// In en, this message translates to:
  /// **'Planned'**
  String get tt_comingUpPlanned;

  /// No description provided for @tt_comingUpNone.
  ///
  /// In en, this message translates to:
  /// **'Nothing is planned after today.'**
  String get tt_comingUpNone;

  /// No description provided for @tt_tomorrow.
  ///
  /// In en, this message translates to:
  /// **'Tomorrow'**
  String get tt_tomorrow;

  /// No description provided for @tt_detailsClose.
  ///
  /// In en, this message translates to:
  /// **'Close dose details'**
  String get tt_detailsClose;

  /// No description provided for @tt_otherTime.
  ///
  /// In en, this message translates to:
  /// **'Other time'**
  String get tt_otherTime;

  /// No description provided for @tt_takenOtherTime.
  ///
  /// In en, this message translates to:
  /// **'Taken at another time'**
  String get tt_takenOtherTime;

  /// No description provided for @tt_skippedAction.
  ///
  /// In en, this message translates to:
  /// **'Skipped'**
  String get tt_skippedAction;

  /// No description provided for @tt_afterTaking.
  ///
  /// In en, this message translates to:
  /// **'After taking'**
  String get tt_afterTaking;

  /// No description provided for @tt_previousNights.
  ///
  /// In en, this message translates to:
  /// **'Previous nights'**
  String get tt_previousNights;

  /// No description provided for @tt_previousMornings.
  ///
  /// In en, this message translates to:
  /// **'Previous mornings'**
  String get tt_previousMornings;

  /// No description provided for @tt_previousAfternoons.
  ///
  /// In en, this message translates to:
  /// **'Previous afternoons'**
  String get tt_previousAfternoons;

  /// No description provided for @tt_previousEvenings.
  ///
  /// In en, this message translates to:
  /// **'Previous evenings'**
  String get tt_previousEvenings;

  /// No description provided for @tt_previousCount.
  ///
  /// In en, this message translates to:
  /// **'{taken} of {total}'**
  String tt_previousCount(int taken, int total);

  /// No description provided for @tt_previousTakenAt.
  ///
  /// In en, this message translates to:
  /// **'Taken {time}'**
  String tt_previousTakenAt(String time);

  /// No description provided for @tt_previousRow.
  ///
  /// In en, this message translates to:
  /// **'{when}, {state}'**
  String tt_previousRow(String when, String state);

  /// No description provided for @tt_lowRunsIn.
  ///
  /// In en, this message translates to:
  /// **'{name} runs low in about {days, plural, =1{1 day} other{{days} days}}'**
  String tt_lowRunsIn(String name, int days);

  /// No description provided for @tt_lowNow.
  ///
  /// In en, this message translates to:
  /// **'{name} is running low: {left} left'**
  String tt_lowNow(String name, String left);

  /// No description provided for @tt_lowOut.
  ///
  /// In en, this message translates to:
  /// **'{name} is out of stock'**
  String tt_lowOut(String name);

  /// No description provided for @tt_lowDetailRunsIn.
  ///
  /// In en, this message translates to:
  /// **'Runs low in about {days, plural, =1{1 day} other{{days} days}} · {left} left'**
  String tt_lowDetailRunsIn(int days, String left);

  /// No description provided for @tt_lowDetailNow.
  ///
  /// In en, this message translates to:
  /// **'Running low · {left} left'**
  String tt_lowDetailNow(String left);

  /// No description provided for @tt_lowDetailOut.
  ///
  /// In en, this message translates to:
  /// **'Out of stock'**
  String get tt_lowDetailOut;

  /// No description provided for @tt_addStock.
  ///
  /// In en, this message translates to:
  /// **'Add stock'**
  String get tt_addStock;

  /// No description provided for @tt_later.
  ///
  /// In en, this message translates to:
  /// **'Later'**
  String get tt_later;

  /// No description provided for @tt_lowStockNotice.
  ///
  /// In en, this message translates to:
  /// **'Low stock'**
  String get tt_lowStockNotice;

  /// No description provided for @tt_status.
  ///
  /// In en, this message translates to:
  /// **'Status'**
  String get tt_status;

  /// No description provided for @tt_allDay.
  ///
  /// In en, this message translates to:
  /// **'All day'**
  String get tt_allDay;

  /// No description provided for @tt_previousDay.
  ///
  /// In en, this message translates to:
  /// **'Previous day'**
  String get tt_previousDay;

  /// No description provided for @tt_nextDay.
  ///
  /// In en, this message translates to:
  /// **'Next day'**
  String get tt_nextDay;

  /// No description provided for @tt_stockAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get tt_stockAll;

  /// No description provided for @tt_stockAllLabel.
  ///
  /// In en, this message translates to:
  /// **'All medications'**
  String get tt_stockAllLabel;

  /// No description provided for @tf_adherence.
  ///
  /// In en, this message translates to:
  /// **'Adherence'**
  String get tf_adherence;

  /// No description provided for @tr_trendsCouldNotLoad.
  ///
  /// In en, this message translates to:
  /// **'Could not load the streak and charts'**
  String get tr_trendsCouldNotLoad;

  /// No description provided for @settings_autoMissRecordTitle.
  ///
  /// In en, this message translates to:
  /// **'Record missed doses'**
  String get settings_autoMissRecordTitle;

  /// No description provided for @settings_autoMissRecordSubtitle.
  ///
  /// In en, this message translates to:
  /// **'A dose nobody recorded in time is written to the history as missed, on every device. Turning this off does not undo misses already recorded.'**
  String get settings_autoMissRecordSubtitle;

  /// No description provided for @settings_autoMissRecordAfter.
  ///
  /// In en, this message translates to:
  /// **'Record as missed after'**
  String get settings_autoMissRecordAfter;

  /// No description provided for @settings_autoMissRecordDelaySubtitle.
  ///
  /// In en, this message translates to:
  /// **'How long after its planned time a dose waits before it is recorded as missed'**
  String get settings_autoMissRecordDelaySubtitle;

  /// No description provided for @settings_autoMissServerUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This server cannot store missed doses yet. Nothing is recorded as missed for this connected workspace until the server is updated.'**
  String get settings_autoMissServerUnsupported;

  /// No description provided for @dose_takenLate.
  ///
  /// In en, this message translates to:
  /// **'Taken (late)'**
  String get dose_takenLate;

  /// No description provided for @dose_takeLateNow.
  ///
  /// In en, this message translates to:
  /// **'Taken now (late)'**
  String get dose_takeLateNow;

  /// No description provided for @dose_markedMissedAuto.
  ///
  /// In en, this message translates to:
  /// **'Marked missed automatically'**
  String get dose_markedMissedAuto;

  /// No description provided for @dose_missedHint.
  ///
  /// In en, this message translates to:
  /// **'Nobody recorded this dose in time, so it was marked missed. You can still record it as taken late, record it as skipped, or undo the miss.'**
  String get dose_missedHint;

  /// No description provided for @dose_missedCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 dose missed} other{{count} doses missed}}'**
  String dose_missedCount(int count);

  /// No description provided for @export_statusNotRecorded.
  ///
  /// In en, this message translates to:
  /// **'Not recorded'**
  String get export_statusNotRecorded;

  /// No description provided for @jrn_missed.
  ///
  /// In en, this message translates to:
  /// **'{time} · {person} missed {medication}'**
  String jrn_missed(String time, String person, String medication);

  /// No description provided for @jrn_tookLate.
  ///
  /// In en, this message translates to:
  /// **'{time} · {person} took {medication}, late'**
  String jrn_tookLate(String time, String person, String medication);

  /// No description provided for @amountReview_entry.
  ///
  /// In en, this message translates to:
  /// **'Review medication amounts'**
  String get amountReview_entry;

  /// No description provided for @amountReview_entryHint.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1 {1 medicine still shows its original dosage text} other {{count} medicines still show their original dosage text}}'**
  String amountReview_entryHint(int count);

  /// No description provided for @amountReview_title.
  ///
  /// In en, this message translates to:
  /// **'Medication amounts'**
  String get amountReview_title;

  /// No description provided for @amountReview_intro.
  ///
  /// In en, this message translates to:
  /// **'These medicines were saved with their dosage as plain text. Set an amount per use so Today and the dose editor can show it.'**
  String get amountReview_intro;

  /// No description provided for @amountReview_readable.
  ///
  /// In en, this message translates to:
  /// **'Ready to use'**
  String get amountReview_readable;

  /// No description provided for @amountReview_readableHint.
  ///
  /// In en, this message translates to:
  /// **'The original text reads as one amount. Check it, then accept all at once.'**
  String get amountReview_readableHint;

  /// No description provided for @amountReview_manual.
  ///
  /// In en, this message translates to:
  /// **'Set these yourself'**
  String get amountReview_manual;

  /// No description provided for @amountReview_manualHint.
  ///
  /// In en, this message translates to:
  /// **'The original text does not read as a single amount, so nothing is guessed. Open each one and set it.'**
  String get amountReview_manualHint;

  /// No description provided for @amountReview_original.
  ///
  /// In en, this message translates to:
  /// **'Original text: {text}'**
  String amountReview_original(String text);

  /// No description provided for @amountReview_willSet.
  ///
  /// In en, this message translates to:
  /// **'Sets {amount} per use'**
  String amountReview_willSet(String amount);

  /// No description provided for @amountReview_willKeep.
  ///
  /// In en, this message translates to:
  /// **'Keeps {amount} per use'**
  String amountReview_willKeep(String amount);

  /// No description provided for @amountReview_accept.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1 {Use this amount} other {Use these {count} amounts}}'**
  String amountReview_accept(int count);

  /// No description provided for @amountReview_saved.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1 {1 amount saved} other {{count} amounts saved}}'**
  String amountReview_saved(int count);

  /// No description provided for @amountReview_partial.
  ///
  /// In en, this message translates to:
  /// **'{saved} of {total} saved. Open the rest and set them yourself.'**
  String amountReview_partial(int saved, int total);

  /// No description provided for @amountReview_error.
  ///
  /// In en, this message translates to:
  /// **'The amounts could not be saved. Try again.'**
  String get amountReview_error;

  /// No description provided for @amountReview_empty.
  ///
  /// In en, this message translates to:
  /// **'Every medicine has an amount per use.'**
  String get amountReview_empty;

  /// No description provided for @amountReview_selectedPerson.
  ///
  /// In en, this message translates to:
  /// **'Only the person you are viewing is listed. Switch to Everyone in People to review the rest.'**
  String get amountReview_selectedPerson;

  /// No description provided for @amountReview_markReviewed.
  ///
  /// In en, this message translates to:
  /// **'I have reviewed the original dosage text'**
  String get amountReview_markReviewed;

  /// No description provided for @amountReview_markReviewedHint.
  ///
  /// In en, this message translates to:
  /// **'The original wording is always kept. This only stops the reminder to review it.'**
  String get amountReview_markReviewedHint;

  /// No description provided for @t09_legacyDosageReviewed.
  ///
  /// In en, this message translates to:
  /// **'Original dosage text · Reviewed'**
  String get t09_legacyDosageReviewed;

  /// No description provided for @updateAvailableTitle.
  ///
  /// In en, this message translates to:
  /// **'Update available'**
  String get updateAvailableTitle;

  /// No description provided for @updateAvailableBody.
  ///
  /// In en, this message translates to:
  /// **'Version {version} of Simpastil is out.'**
  String updateAvailableBody(String version);

  /// No description provided for @updateAvailableBodyGeneric.
  ///
  /// In en, this message translates to:
  /// **'A newer version of Simpastil is out.'**
  String get updateAvailableBodyGeneric;

  /// No description provided for @updateAvailableAction.
  ///
  /// In en, this message translates to:
  /// **'View release'**
  String get updateAvailableAction;

  /// No description provided for @updateCheckSwitchTitle.
  ///
  /// In en, this message translates to:
  /// **'Check for updates'**
  String get updateCheckSwitchTitle;

  /// No description provided for @updateCheckSwitchBody.
  ///
  /// In en, this message translates to:
  /// **'Once a day, ask GitHub whether a newer version is out.'**
  String get updateCheckSwitchBody;

  /// Switch in the reminders step of setup: turns this device's dose reminders on or off for the person just added. name is the person's name.
  ///
  /// In en, this message translates to:
  /// **'Remind me about {name}'**
  String onb_personRemindersTitle(String name);

  /// Hint under the per-person reminders switch in the reminders step of setup.
  ///
  /// In en, this message translates to:
  /// **'On this device. You can change it any time in People.'**
  String get onb_personRemindersBody;

  /// Switch in the reminders step of setup: whether reminders show medication names and dose actions (on) or only a generic message (off).
  ///
  /// In en, this message translates to:
  /// **'Show medication names'**
  String get onb_detailsTitle;

  /// Hint under the lock-screen names switch in the reminders step of setup.
  ///
  /// In en, this message translates to:
  /// **'On the lock screen. Turn off to keep them private; reminders then only say a dose is due.'**
  String get onb_detailsBody;

  /// Small section heading in the reminders step of setup, above the optional switches for this person, medication names and battery. All are optional and can be changed later.
  ///
  /// In en, this message translates to:
  /// **'Your choices'**
  String get onb_choicesTitle;

  /// Calm notice in the reminders step of setup when the per-person or lock-screen switch could not be saved.
  ///
  /// In en, this message translates to:
  /// **'That choice could not be saved. You can change it later in Settings.'**
  String get onb_choiceFailed;

  /// Title of the battery card in the reminders step of setup, shown when battery saving may delay reminders.
  ///
  /// In en, this message translates to:
  /// **'Keep reminders on time'**
  String get onb_batteryTitle;

  /// Plain explanation inside the battery card in the reminders step of setup.
  ///
  /// In en, this message translates to:
  /// **'Battery savers can delay or block reminders when Simpastil is closed. Letting it run in the background keeps them on time.'**
  String get onb_batteryBody;

  /// Button that asks Android to stop limiting Simpastil in the background (battery optimization exemption). Used in setup and in reminder settings.
  ///
  /// In en, this message translates to:
  /// **'Let Simpastil run in the background'**
  String get onb_batteryAllow;

  /// Button that hides the battery card for this visit to the reminders step of setup.
  ///
  /// In en, this message translates to:
  /// **'Not now'**
  String get onb_batteryNotNow;

  /// Short tip in the battery card for Samsung phones, which limit background apps on their own.
  ///
  /// In en, this message translates to:
  /// **'On Samsung phones: Settings → Battery → Background usage limits, and keep Simpastil out of the sleeping apps.'**
  String get onb_batterySamsungTip;

  /// Status chip in the reminders step of setup when Android does not limit Simpastil in the background.
  ///
  /// In en, this message translates to:
  /// **'Battery: no limits'**
  String get onb_batteryNoLimits;

  /// Status line in reminder settings when Android limits Simpastil in the background.
  ///
  /// In en, this message translates to:
  /// **'Battery saver may delay reminders'**
  String get onb_batteryLimited;

  /// Status line in reminder settings when Android does not limit Simpastil in the background.
  ///
  /// In en, this message translates to:
  /// **'No battery limits for Simpastil'**
  String get onb_batteryUnlimited;

  /// Title of the project note shown before the summary at the end of first-run setup.
  ///
  /// In en, this message translates to:
  /// **'A small project'**
  String get onb_projectTitle;

  /// Body of the project note at the end of first-run setup, under its title. Says the app is small and may not always work as it should.
  ///
  /// In en, this message translates to:
  /// **'Simpastil is a small, independent app, so now and then something may not work as it should.'**
  String get onb_projectBody;

  /// Button in the project note that opens the project's GitHub issues page in the browser.
  ///
  /// In en, this message translates to:
  /// **'Report on GitHub'**
  String get onb_projectReport;

  /// Title of the project note card about reporting problems.
  ///
  /// In en, this message translates to:
  /// **'Found a problem?'**
  String get onb_projectProblemTitle;

  /// Body of the project note card about reporting problems. Report a problem, Settings and About name existing screens and labels in the app.
  ///
  /// In en, this message translates to:
  /// **'Tell us on GitHub, or use Report a problem in Settings → About.'**
  String get onb_projectProblemBody;

  /// Title of the project note card inviting code contributions.
  ///
  /// In en, this message translates to:
  /// **'Want to help build it?'**
  String get onb_projectHelpTitle;

  /// Body of the project note card inviting code contributions; the source code is public.
  ///
  /// In en, this message translates to:
  /// **'The code is open, and contributions are welcome.'**
  String get onb_projectHelpBody;

  /// Title of the project note card with donation buttons. Shown only when a donation page exists.
  ///
  /// In en, this message translates to:
  /// **'Support the project'**
  String get onb_projectSupportTitle;

  /// Body of the project note card with donation buttons.
  ///
  /// In en, this message translates to:
  /// **'Donations help keep Simpastil going.'**
  String get onb_projectSupportBody;

  /// Button in the project note that opens the project's GitHub repository in the browser.
  ///
  /// In en, this message translates to:
  /// **'See the code'**
  String get onb_projectCode;

  /// Donation button in the project note. Shown only once the project has a GitHub Sponsors page. Product name, usually not translated.
  ///
  /// In en, this message translates to:
  /// **'GitHub Sponsors'**
  String get onb_projectSponsors;

  /// Donation button in the project note. Shown only once the project has a Ko-fi page. Product name, not translated.
  ///
  /// In en, this message translates to:
  /// **'Ko-fi'**
  String get onb_projectKofi;

  /// Heading of the short list of reminder choices on the final summary of first-run setup.
  ///
  /// In en, this message translates to:
  /// **'Your reminders'**
  String get onb_summaryTitle;

  /// Summary line when this device's dose reminders are on for the person just added. name is the person's name.
  ///
  /// In en, this message translates to:
  /// **'{name} gets reminders on this device'**
  String onb_summaryRemindersOn(String name);

  /// Summary line when this device's dose reminders are off for the person just added. name is the person's name.
  ///
  /// In en, this message translates to:
  /// **'{name} does not get reminders on this device'**
  String onb_summaryRemindersOff(String name);

  /// Hint under a summary line that is off: where to change the per-person device reminder choice. Settings and People name existing screens.
  ///
  /// In en, this message translates to:
  /// **'Change it in Settings → People.'**
  String get onb_summaryChangePeople;

  /// Summary line when the device allows Simpastil to show notifications.
  ///
  /// In en, this message translates to:
  /// **'Notifications are allowed'**
  String get onb_summaryNotificationsOn;

  /// Summary line when the device does not yet allow Simpastil to show notifications.
  ///
  /// In en, this message translates to:
  /// **'Notifications are not allowed yet'**
  String get onb_summaryNotificationsOff;

  /// Hint under a summary line that is off: where to change notification, battery or lock-screen choices. Settings and Reminders name existing screens.
  ///
  /// In en, this message translates to:
  /// **'Change it in Settings → Reminders.'**
  String get onb_summaryChangeReminders;

  /// Summary line when reminders show medication names on the lock screen.
  ///
  /// In en, this message translates to:
  /// **'Medication names show on the lock screen'**
  String get onb_summaryNamesShown;

  /// Summary line when reminders keep medication names off the lock screen.
  ///
  /// In en, this message translates to:
  /// **'Medication names are hidden on the lock screen'**
  String get onb_summaryNamesHidden;

  /// Calm line on the final summary for a device with no server account: nothing is backed up automatically. Settings and Backups name existing screens.
  ///
  /// In en, this message translates to:
  /// **'Backups are not automatic. Make one in Settings → Backups.'**
  String get onb_summaryBackups;

  /// Title of the card on Today shown when no one has dose reminders switched on on this device.
  ///
  /// In en, this message translates to:
  /// **'Reminders are off on this device'**
  String get onb_remindersOffTitle;

  /// Body of the reminders-off card on Today.
  ///
  /// In en, this message translates to:
  /// **'No one gets dose reminders here yet.'**
  String get onb_remindersOffBody;

  /// Button on the reminders-off card on Today that switches reminders on for everyone on this device.
  ///
  /// In en, this message translates to:
  /// **'Turn on'**
  String get onb_remindersOffAction;

  /// Tooltip of the close button on the reminders-off card on Today: it hides the card on this device.
  ///
  /// In en, this message translates to:
  /// **'Hide on this device'**
  String get onb_remindersOffDismiss;

  /// Message shown when the Turn on button of the reminders-off card on Today fails. Settings and Reminders name existing screens.
  ///
  /// In en, this message translates to:
  /// **'Reminders could not be turned on. You can try again in Settings → Reminders.'**
  String get onb_remindersOffFailed;

  /// No description provided for @report_title.
  ///
  /// In en, this message translates to:
  /// **'Report a problem'**
  String get report_title;

  /// No description provided for @report_settingsRowSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Send the details needed to fix it. Nothing is sent until you choose.'**
  String get report_settingsRowSubtitle;

  /// No description provided for @report_intro.
  ///
  /// In en, this message translates to:
  /// **'Something not working? Send a report so it can be found and fixed. The report holds technical details only.'**
  String get report_intro;

  /// No description provided for @report_includesTitle.
  ///
  /// In en, this message translates to:
  /// **'What is in the report'**
  String get report_includesTitle;

  /// No description provided for @report_includesBody.
  ///
  /// In en, this message translates to:
  /// **'App version, phone model and Android version, whether reminders are allowed, rough sizes such as \"2-5 medicines\", the last sync steps and recent errors.'**
  String get report_includesBody;

  /// No description provided for @report_neverBody.
  ///
  /// In en, this message translates to:
  /// **'Never included: names, medicines, doses, notes, your server address, email or account, or sign-in details.'**
  String get report_neverBody;

  /// No description provided for @report_previewTitle.
  ///
  /// In en, this message translates to:
  /// **'See exactly what will be shared'**
  String get report_previewTitle;

  /// No description provided for @report_preparing.
  ///
  /// In en, this message translates to:
  /// **'Preparing the report…'**
  String get report_preparing;

  /// No description provided for @report_githubAction.
  ///
  /// In en, this message translates to:
  /// **'Submit issue on GitHub'**
  String get report_githubAction;

  /// No description provided for @report_githubHint.
  ///
  /// In en, this message translates to:
  /// **'Public, free and the quickest way to get help.'**
  String get report_githubHint;

  /// No description provided for @report_shareAction.
  ///
  /// In en, this message translates to:
  /// **'Share another way'**
  String get report_shareAction;

  /// No description provided for @report_shareHint.
  ///
  /// In en, this message translates to:
  /// **'Save the file, email it to the maintainer, or send it with another app.'**
  String get report_shareHint;

  /// No description provided for @report_publicNote.
  ///
  /// In en, this message translates to:
  /// **'Issues on GitHub are public. This report is safe to post, and you choose what else to write. For a security problem, do not post publicly: see the security policy on GitHub.'**
  String get report_publicNote;

  /// No description provided for @report_githubSheetTitle.
  ///
  /// In en, this message translates to:
  /// **'How reporting on GitHub works'**
  String get report_githubSheetTitle;

  /// No description provided for @report_githubStep1.
  ///
  /// In en, this message translates to:
  /// **'The report is saved to your Downloads folder as {fileName}.'**
  String report_githubStep1(String fileName);

  /// No description provided for @report_githubStep2.
  ///
  /// In en, this message translates to:
  /// **'GitHub opens with the form already started.'**
  String get report_githubStep2;

  /// No description provided for @report_githubStep3.
  ///
  /// In en, this message translates to:
  /// **'Describe what happened, attach the saved file to the issue, then submit it.'**
  String get report_githubStep3;

  /// No description provided for @report_githubContinue.
  ///
  /// In en, this message translates to:
  /// **'Save and open GitHub'**
  String get report_githubContinue;

  /// No description provided for @report_githubOpenFailed.
  ///
  /// In en, this message translates to:
  /// **'GitHub could not be opened. Open github.com/LucaPisl/simpastil/issues/new in a browser and attach the saved file.'**
  String get report_githubOpenFailed;

  /// No description provided for @report_saveAction.
  ///
  /// In en, this message translates to:
  /// **'Save to Downloads'**
  String get report_saveAction;

  /// No description provided for @report_saveHint.
  ///
  /// In en, this message translates to:
  /// **'Keep the file, or attach it to a message yourself.'**
  String get report_saveHint;

  /// No description provided for @report_emailAction.
  ///
  /// In en, this message translates to:
  /// **'Email the maintainer'**
  String get report_emailAction;

  /// No description provided for @report_emailHint.
  ///
  /// In en, this message translates to:
  /// **'Opens your email app with the message and the file ready to send.'**
  String get report_emailHint;

  /// No description provided for @report_otherShareAction.
  ///
  /// In en, this message translates to:
  /// **'Share with another app'**
  String get report_otherShareAction;

  /// No description provided for @report_otherShareHint.
  ///
  /// In en, this message translates to:
  /// **'Send the file with any app you choose.'**
  String get report_otherShareHint;

  /// No description provided for @report_savedTo.
  ///
  /// In en, this message translates to:
  /// **'Saved to Downloads as {fileName}'**
  String report_savedTo(String fileName);

  /// No description provided for @report_saveUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This Android version cannot save straight to Downloads. Use Share with another app to put the file where you like.'**
  String get report_saveUnsupported;

  /// No description provided for @report_saveFailed.
  ///
  /// In en, this message translates to:
  /// **'The file could not be saved. Try Share with another app instead.'**
  String get report_saveFailed;

  /// No description provided for @report_noEmailApp.
  ///
  /// In en, this message translates to:
  /// **'No email app was found. Save the file or share it another way.'**
  String get report_noEmailApp;

  /// No description provided for @report_emailFailed.
  ///
  /// In en, this message translates to:
  /// **'The email could not be prepared. Try saving the file instead.'**
  String get report_emailFailed;

  /// No description provided for @report_shareFailed.
  ///
  /// In en, this message translates to:
  /// **'The file could not be shared. Try saving it to Downloads instead.'**
  String get report_shareFailed;

  /// No description provided for @report_crashTitle.
  ///
  /// In en, this message translates to:
  /// **'Simpastil closed unexpectedly last time'**
  String get report_crashTitle;

  /// No description provided for @report_crashBody.
  ///
  /// In en, this message translates to:
  /// **'A short report can help get it fixed.'**
  String get report_crashBody;

  /// No description provided for @report_crashAction.
  ///
  /// In en, this message translates to:
  /// **'Report'**
  String get report_crashAction;

  /// No description provided for @report_crashDismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get report_crashDismiss;

  /// No description provided for @report_syncAction.
  ///
  /// In en, this message translates to:
  /// **'Report this problem'**
  String get report_syncAction;

  /// No description provided for @report_startupAction.
  ///
  /// In en, this message translates to:
  /// **'Report this problem'**
  String get report_startupAction;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ro'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ro':
      return AppLocalizationsRo();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
