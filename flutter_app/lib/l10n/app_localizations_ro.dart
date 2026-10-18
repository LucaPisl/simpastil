// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Romanian Moldavian Moldovan (`ro`).
class AppLocalizationsRo extends AppLocalizations {
  AppLocalizationsRo([String locale = 'ro']) : super(locale);

  @override
  String get appTitle => 'Simpastil';

  @override
  String get appSubtitle => 'Companionul tău pentru medicamente';

  @override
  String get shared_cancel => 'Anulează';

  @override
  String get shared_save => 'Salvează';

  @override
  String get shared_retry => 'Reîncearcă';

  @override
  String get shared_delete => 'Șterge';

  @override
  String get shared_close => 'Închide';

  @override
  String get shared_change => 'Schimbă';

  @override
  String get shared_continue => 'Continuă';

  @override
  String get shared_skip => 'Sari peste';

  @override
  String get shared_done => 'Gata';

  @override
  String get shared_all => 'Toate';

  @override
  String get shared_none => 'Niciuna';

  @override
  String get shared_add => 'Adaugă';

  @override
  String get shared_grant => 'Acordă';

  @override
  String get shared_loading => 'Se încarcă…';

  @override
  String get shared_unknown => 'Necunoscut';

  @override
  String get shared_enabled => 'Activat';

  @override
  String get shared_disabled => 'Dezactivat';

  @override
  String get shared_cancelDeletion => 'Anulează ștergerea';

  @override
  String shared_confirmAction(String action) {
    return 'Confirmă $action';
  }

  @override
  String get shared_somethingWentWrong =>
      'Ceva nu a funcționat. Încearcă din nou.';

  @override
  String get shared_syncFailed => 'Sincronizare eșuată — verifică conexiunea';

  @override
  String get shared_unlock => 'Deblochează';

  @override
  String get shared_unlockSimpastil => 'Deblochează Simpastil';

  @override
  String get auth_tagline => 'Companionul tău pentru medicamente';

  @override
  String get auth_stepServer => 'PASUL 1 DIN 3 — SERVER';

  @override
  String get auth_stepApiKey => 'PASUL 2 DIN 3 — CHEIE API';

  @override
  String get auth_stepAccount => 'PASUL 3 DIN 3 — CONT';

  @override
  String get auth_connectToServer => 'Conectează-te la server';

  @override
  String get auth_enterServerAddress =>
      'Introdu adresa serverului tău Simpastil';

  @override
  String get auth_serverAddressLabel => 'ADRESA SERVERULUI';

  @override
  String get auth_serverAddress => 'Adresa serverului';

  @override
  String get auth_serverMustUseHttps =>
      'Adresa serverului trebuie să folosească HTTPS.';

  @override
  String get auth_couldNotReachServer =>
      'Nu s-a putut contacta serverul — verifică adresa și încearcă din nou.';

  @override
  String get auth_connect => 'Conectare';

  @override
  String auth_connectedTo(String hostname) {
    return '✓ Conectat — $hostname';
  }

  @override
  String get auth_enterApiKey => 'Introdu cheia API';

  @override
  String get auth_apiKeyHint =>
      'Administratorul serverului ți-a furnizat această cheie.';

  @override
  String get auth_apiKeyLabel => 'Cheie API';

  @override
  String get auth_verifyKey => 'Verifică cheia';

  @override
  String get auth_pleaseEnterApiKey => 'Te rugăm să introduci cheia API';

  @override
  String get auth_keyRevoked =>
      'Această cheie API a fost revocată. Contactează administratorul.';

  @override
  String get auth_unexpectedServerResponse =>
      'Răspuns neașteptat de la server.';

  @override
  String get auth_invalidApiKey => 'Cheie API invalidă.';

  @override
  String get auth_couldNotReachServerShort =>
      'Nu s-a putut realiza conexiunea cu serverul.';

  @override
  String get auth_unexpectedError => 'Eroare neașteptată.';

  @override
  String get auth_createAccount => 'Creează cont';

  @override
  String get auth_signIn => 'Conectare';

  @override
  String get auth_choosePassword => 'Alege o parolă pentru contul tău nou';

  @override
  String get auth_useCredentials => 'Folosește datele contului tău';

  @override
  String get auth_emailAddress => 'Adresă de email';

  @override
  String get auth_password => 'Parolă';

  @override
  String get auth_hidePassword => 'Ascunde parola';

  @override
  String get auth_showPassword => 'Arată parola';

  @override
  String get auth_enterValidEmail => 'Introdu o adresă de email validă';

  @override
  String get auth_passwordRequired => 'Parola este obligatorie';

  @override
  String get auth_incorrectCredentials => 'Email sau parolă incorectă';

  @override
  String get auth_tooManyAttempts =>
      'Prea multe încercări. Te rugăm să încerci mai târziu.';

  @override
  String get auth_noConnection => 'Fără conexiune. Verifică rețeaua.';

  @override
  String get auth_emailAlreadyRegistered =>
      'Email deja înregistrat — sau această cheie API este deja asociată unui cont. Încearcă să te conectezi.';

  @override
  String get auth_keyBelongsToDifferentAccount =>
      'Această cheie API aparține unui alt cont.';

  @override
  String get auth_forgotPassword => 'Ai uitat parola?';

  @override
  String get auth_createAccountButton => 'CREEAZĂ CONT';

  @override
  String get auth_logInButton => 'CONECTARE';

  @override
  String get auth_useDifferentKey => 'Folosește o altă cheie API';

  @override
  String get auth_checkEmail => 'Verifică-ți emailul';

  @override
  String get auth_resetLinkSent =>
      'Dacă emailul este înregistrat, un link de resetare a fost trimis.';

  @override
  String get auth_backToLogin => 'Înapoi la conectare';

  @override
  String get auth_resetPassword => 'Resetare parolă';

  @override
  String get auth_enterEmailForReset =>
      'Introdu emailul pentru a primi un link de resetare';

  @override
  String get auth_sendResetLink => 'Trimite link de resetare';

  @override
  String get auth_nameThisDevice => 'Denumește acest dispozitiv';

  @override
  String get auth_whatShouldDeviceBeCalled =>
      'Cum ar trebui să se numească acest dispozitiv?';

  @override
  String get auth_deviceNameHelp =>
      'Te ajută să îl identifici în panoul de administrare.';

  @override
  String get auth_deviceNameLabel => 'Numele dispozitivului';

  @override
  String get core_sessionExpired =>
      'Sesiunea a expirat. Te rugăm să te conectezi din nou.';

  @override
  String get core_notifChannelName => 'Memento-uri medicamente';

  @override
  String get core_notifChannelDesc =>
      'Mementouri discrete când e timpul pentru o doză';

  @override
  String get core_notifActionTaken => 'Luat';

  @override
  String get core_notifActionSnooze => 'Amână';

  @override
  String get core_notifActionSkip => 'Omite';

  @override
  String core_notifTitle(String pillName) {
    return 'E timpul pentru $pillName';
  }

  @override
  String get core_notifSnoozed => 'Din nou, așa cum ai cerut';

  @override
  String get dashboard_goodMorning => 'Bună dimineața';

  @override
  String get dashboard_goodAfternoon => 'Bună ziua';

  @override
  String get dashboard_goodEvening => 'Bună seara';

  @override
  String get dashboard_today => 'Astăzi';

  @override
  String get dashboard_yesterday => 'Ieri';

  @override
  String dashboard_pillsTaken(int taken, int total) {
    return '$taken din $total pastile luate';
  }

  @override
  String get dashboard_somethingWentWrong => 'Ceva nu a funcționat';

  @override
  String get dashboard_selectProfile =>
      'Selectează un profil pentru a vedea programul';

  @override
  String get dashboard_nothingScheduledToday => 'Nimic programat pentru astăzi';

  @override
  String get dashboard_nothingScheduledThisDay =>
      'Nimic programat în această zi';

  @override
  String get dashboard_asNeeded => 'LA NEVOIE';

  @override
  String get dashboard_notTakenToday => 'Neluat astăzi';

  @override
  String dashboard_takenTimesToday(int count) {
    return 'Luat de $count× astăzi';
  }

  @override
  String get dashboard_logDose => 'Înregistrează doză';

  @override
  String get dashboard_syncFailingTooltip =>
      'Sincronizare eșuată — apasă pentru detalii';

  @override
  String get dashboard_backToToday => 'Înapoi la astăzi';

  @override
  String get dashboard_previousDay => 'Ziua anterioară';

  @override
  String get dashboard_nextDay => 'Ziua următoare';

  @override
  String dashboard_scheduledTime(String time) {
    return 'Programat: $time';
  }

  @override
  String get dashboard_noteLabel => 'Notă';

  @override
  String get dashboard_noteHint => 'Adaugă o notă pentru această doză…';

  @override
  String get dashboard_statusTaken => 'Luat';

  @override
  String get dashboard_statusMissed => 'Ratat';

  @override
  String get dashboard_statusSkipped => 'Sărit';

  @override
  String get dashboard_statusPending => 'În așteptare';

  @override
  String get dashboard_statusTakenBadge => '✓ Luat';

  @override
  String get dashboard_statusMissedBadge => '✗ Ratat';

  @override
  String get dashboard_statusSkippedBadge => 'Sărit';

  @override
  String get dashboard_statusPendingBadge => 'În așteptare';

  @override
  String get history_calendar => 'Calendar';

  @override
  String get history_list => 'Listă';

  @override
  String get history_exportTooltip => 'Exportă istoricul dozelor';

  @override
  String get history_couldNotLoad => 'Nu s-a putut încărca istoricul';

  @override
  String people_dayProgress(Object planned, Object taken) {
    return '$taken din $planned luate azi';
  }

  @override
  String history_quietDay(Object date) {
    return 'Nimic înregistrat pe $date';
  }

  @override
  String get history_quietDayBody =>
      'Nicio doză nu a fost planificată sau înregistrată pentru această zi pe acest telefon. Asta nu înseamnă că îngrijirea a fost omisă.';

  @override
  String history_earlierRecords(Object date) {
    return 'Mai devreme: $date';
  }

  @override
  String history_laterRecords(Object date) {
    return 'Mai târziu: $date';
  }

  @override
  String get history_noHistory => 'Niciun istoric încă';

  @override
  String history_takenAt(String time) {
    return 'luat la $time';
  }

  @override
  String history_scheduledAt(String time) {
    return 'Programat $time';
  }

  @override
  String get history_noDoses => 'nicio doză';

  @override
  String history_adherence(String percent) {
    return '$percent aderență';
  }

  @override
  String history_ribbonDay(String date, int taken, int total) {
    return '$date, $taken din $total doze planificate luate';
  }

  @override
  String history_ribbonDayEmpty(String date) {
    return '$date, nicio doză planificată';
  }

  @override
  String history_unseenTitle(String name) {
    return 'Înainte ca $name să fie pe acest telefon';
  }

  @override
  String get history_unseenTitleAll =>
      'Înainte de începerea îngrijirii pe acest telefon';

  @override
  String history_unseenBody(String name, String date) {
    return '$name este pe acest telefon din $date. Pentru zilele de dinainte nu există înregistrări aici.';
  }

  @override
  String history_unseenBodyAll(String date) {
    return 'Îngrijirea pe acest telefon a început pe $date. Pentru zilele de dinainte nu există înregistrări aici.';
  }

  @override
  String history_ribbonDayUnseen(String date, String name) {
    return '$date, înainte ca $name să fie pe acest telefon';
  }

  @override
  String history_ribbonDayUnseenAll(String date) {
    return '$date, înainte de începerea îngrijirii pe acest telefon';
  }

  @override
  String history_lineDose(
    String time,
    String medication,
    String person,
    String outcome,
  ) {
    return '$time · $medication pentru $person · $outcome';
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
      other: '$count de doze în jurul orei $time',
      few: '$count doze în jurul orei $time',
      one: '1 doză în jurul orei $time',
    );
    return '$_temp0';
  }

  @override
  String get pills_title => 'Pastile';

  @override
  String get pills_edit => 'Editează';

  @override
  String pills_deleteCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Ștergi $count de pastile?',
      few: 'Ștergi $count pastile?',
      one: 'Ștergi 1 pastilă?',
    );
    return '$_temp0';
  }

  @override
  String pills_deleteConfirmMessage(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Aceasta va șterge și toate programările și memento-urile pentru aceste pastile. Nu se pot restaura datele după ștergere.',
      few:
          'Aceasta va șterge și toate programările și memento-urile pentru aceste pastile. Nu se pot restaura datele după ștergere.',
      one:
          'Aceasta va șterge și toate programările și memento-urile pentru această pastilă. Nu se pot restaura datele după ștergere.',
    );
    return '$_temp0';
  }

  @override
  String pills_deletedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count de pastile șterse',
      few: '$count pastile șterse',
      one: '1 pastilă ștearsă',
    );
    return '$_temp0';
  }

  @override
  String get pills_couldNotLoad => 'Nu s-au putut încărca pastilele.';

  @override
  String get pills_noPillsYet => 'Nicio pastilă încă';

  @override
  String get pills_addFirstSubtitle => 'Adaugă prima pastilă pentru a începe.';

  @override
  String get pills_addFirstCta => 'Adaugă prima pastilă';

  @override
  String get pills_noEnabledProfiles => 'Niciun profil activat';

  @override
  String get pills_enableProfileHint =>
      'Activează cel puțin un profil în Profiluri.';

  @override
  String pills_todayAt(String time) {
    return 'Astăzi la $time';
  }

  @override
  String pills_tomorrowAt(String time) {
    return 'Mâine la $time';
  }

  @override
  String pills_weekdayAt(String weekday, String time) {
    return '$weekday la $time';
  }

  @override
  String get pills_noActiveSchedules => 'Nicio programare activă';

  @override
  String get pills_daily => 'Zilnic';

  @override
  String get pills_custom => 'Personalizat';

  @override
  String pills_stockLeft(int stock) {
    return '$stock rămase';
  }

  @override
  String get pills_noSchedulesYet => 'Nicio programare încă';

  @override
  String get pills_addSchedule => 'Adaugă programare';

  @override
  String get pills_deletePill => 'Ștergi pastila?';

  @override
  String pills_deletePillMessage(String name) {
    return 'Ștergerea \"$name\" va elimina și toate programările și va anula memento-urile. Nu se pot restaura datele după ștergere.';
  }

  @override
  String get pills_couldNotDelete => 'Nu s-a putut șterge pastila';

  @override
  String get pills_deleteSelectedTooltip => 'Șterge pastilele selectate';

  @override
  String get pills_addPillTooltip => 'Adaugă pastilă';

  @override
  String get pills_editPillTooltip => 'Editează pastila';

  @override
  String get pills_deletePillTooltip => 'Șterge pastila';

  @override
  String get pills_editScheduleTooltip => 'Editează programarea';

  @override
  String get pills_deleteScheduleTooltip => 'Șterge programarea';

  @override
  String get pills_deleteScheduleTitle => 'Ștergi programarea?';

  @override
  String pills_deleteScheduleMessage(String frequency, String time) {
    return 'Elimini memento-ul $frequency de la $time? Nu se poate anula.';
  }

  @override
  String get pills_couldNotDeleteSchedule => 'Nu s-a putut șterge programarea';

  @override
  String get pills_editPillTitle => 'Editează pastila';

  @override
  String get pills_newPillTitle => 'Pastilă nouă';

  @override
  String get pills_nameRequired => 'Numele este obligatoriu';

  @override
  String get pills_nameLabel => 'Nume *';

  @override
  String get pills_dosageLabel => 'Dozaj (ex. 10 mg)';

  @override
  String get pills_notesLabel => 'Notițe';

  @override
  String get pills_colorLabel => 'Culoare';

  @override
  String get pills_inventoryLabel => 'Inventar';

  @override
  String get pills_trackStock => 'Urmărește stocul';

  @override
  String get pills_trackStockSubtitle =>
      'Primește notificare când stocul e scăzut';

  @override
  String get pills_currentStock => 'Stoc curent';

  @override
  String get pills_alertWhenBelow => 'Alertă când sub';

  @override
  String get pills_required => 'Obligatoriu';

  @override
  String get pills_enterANumber => 'Introdu un număr';

  @override
  String get pills_scheduleType => 'Tip programare';

  @override
  String get pills_asNeededPrn => 'La nevoie (PRN)';

  @override
  String get pills_asNeededSubtitle =>
      'Fără programare fixă — înregistrează dozele manual';

  @override
  String get pills_updateProfiles => 'Actualizează profiluri';

  @override
  String get pills_assignToProfiles => 'Atribuie la profiluri';

  @override
  String get pills_selectAtLeastOneProfile => 'Selectează cel puțin un profil';

  @override
  String pills_addedToProfiles(int count) {
    return 'Adăugat la $count profil(uri); unele nu s-au sincronizat.';
  }

  @override
  String pills_alsoUpdateSiblings(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Actualizează și $count de alte profiluri',
      few: 'Actualizează și $count alte profiluri',
      one: 'Actualizează și 1 alt profil',
    );
    return '$_temp0';
  }

  @override
  String get pills_applyChangesTo => 'Aplică modificările la:';

  @override
  String get pills_fieldName => 'Nume';

  @override
  String get pills_fieldDosage => 'Dozaj';

  @override
  String get pills_fieldNotes => 'Notițe';

  @override
  String get pills_fieldColor => 'Culoare';

  @override
  String get pills_noProfilesAvailable =>
      'Niciun profil disponibil. Creează mai întâi un profil.';

  @override
  String pills_savedCouldNotUpdateSiblings(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Salvat. Nu s-au putut actualiza $count de elemente asociate.',
      few: 'Salvat. Nu s-au putut actualiza $count elemente asociate.',
      one: 'Salvat. Nu s-a putut actualiza 1 element asociat.',
    );
    return '$_temp0';
  }

  @override
  String get schedules_screenTitle => 'Programări';

  @override
  String get schedules_couldNotLoad => 'Nu s-au putut încărca programările.';

  @override
  String get schedules_emptyTitle => 'Nicio programare încă';

  @override
  String get schedules_emptySubtitle =>
      'Activează un profil și adaugă medicamente pentru a crea programări.';

  @override
  String get schedules_noSchedulesYet => 'Nicio programare încă';

  @override
  String get schedules_addSchedule => 'Adaugă programare';

  @override
  String get schedules_editScheduleTooltip => 'Editează programarea';

  @override
  String get schedules_deleteScheduleTooltip => 'Șterge programarea';

  @override
  String get schedules_deleteScheduleTitle => 'Ștergi programarea?';

  @override
  String schedules_deleteScheduleMessage(String frequency, String time) {
    return 'Elimini memento-ul $frequency de la $time? Ștergerea e permanentă.';
  }

  @override
  String get schedules_custom => 'Personalizat';

  @override
  String get schedules_editTitle => 'Editează programarea';

  @override
  String get schedules_newTitle => 'Programare nouă';

  @override
  String get schedules_timeLabel => 'Ora';

  @override
  String schedules_timeSemantic(String time) {
    return 'Ora programării, $time. Apasă pentru a schimba';
  }

  @override
  String get schedules_frequencyLabel => 'Frecvență';

  @override
  String get schedules_daily => 'Zilnic';

  @override
  String get schedules_specificDays => 'Zile specifice';

  @override
  String schedules_frequencySemantic(String frequency) {
    return 'Frecvență: $frequency';
  }

  @override
  String get schedules_active => 'Activ';

  @override
  String get schedules_paused => 'în pauză';

  @override
  String get schedules_activeSubtitle =>
      'Dezactivează pentru a pune pe pauză fără a șterge';

  @override
  String get schedules_selectAtLeastOneDay =>
      'Te rugăm să selectezi cel puțin o zi';

  @override
  String get schedules_dayMon => 'Lun';

  @override
  String get schedules_dayTue => 'Mar';

  @override
  String get schedules_dayWed => 'Mie';

  @override
  String get schedules_dayThu => 'Joi';

  @override
  String get schedules_dayFri => 'Vin';

  @override
  String get schedules_daySat => 'Sâm';

  @override
  String get schedules_daySun => 'Dum';

  @override
  String get profiles_title => 'Profiluri';

  @override
  String get profiles_addTooltip => 'Adaugă profil';

  @override
  String get profiles_couldNotLoad => 'Nu s-au putut încărca profilurile.';

  @override
  String get profiles_noProfYet => 'Niciun profil încă';

  @override
  String get profiles_createToGetStarted =>
      'Creează un profil pentru a începe.';

  @override
  String get profiles_createFirstCta => 'Creează primul profil';

  @override
  String profiles_pillCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count de pastile',
      few: '$count pastile',
      one: '1 pastilă',
    );
    return '$_temp0';
  }

  @override
  String get profiles_active => 'Activ';

  @override
  String get profiles_inactive => 'Inactiv';

  @override
  String get profiles_primary => 'Principal';

  @override
  String profiles_deleteTitle(String name) {
    return 'Ștergi $name?';
  }

  @override
  String profiles_deleteMessage(String name) {
    return 'Aceasta va șterge permanent toate pastilele, programările și istoricul dozelor atribuite lui $name.';
  }

  @override
  String profiles_pillsOverviewTitle(String name) {
    return '$name — Pastile';
  }

  @override
  String get profiles_couldNotLoadPills => 'Nu s-au putut încărca pastilele.';

  @override
  String get profiles_noPillsAssigned =>
      'Nicio pastilă atribuită acestui profil';

  @override
  String get profiles_noSchedule => 'Fără programare';

  @override
  String get profiles_editTitle => 'Editează profilul';

  @override
  String get profiles_newTitle => 'Profil nou';

  @override
  String get profiles_nameLabel => 'Nume';

  @override
  String get profiles_nameRequired => 'Numele este obligatoriu';

  @override
  String get profiles_avatarLabel => 'Avatar';

  @override
  String profiles_avatarSelected(String emoji) {
    return 'Avatar $emoji, selectat';
  }

  @override
  String profiles_avatarUnselected(String emoji) {
    return 'Avatar $emoji';
  }

  @override
  String get profiles_primaryProfile => 'Profil principal';

  @override
  String get profiles_setAsPrimary => 'Setează ca profil principal';

  @override
  String get profiles_deleteProfile => 'Șterge profilul';

  @override
  String get profiles_deleted => 'Profil șters';

  @override
  String get profiles_failedToDelete => 'Ștergerea profilului a eșuat';

  @override
  String get settings_title => 'Setări';

  @override
  String get settings_appearance => 'Aspect';

  @override
  String get settings_primaryProfile => 'Profil principal';

  @override
  String get settings_pillEditing => 'Editare pastile';

  @override
  String get settings_account => 'Cont';

  @override
  String get settings_server => 'Server';

  @override
  String get settings_session => 'Sesiune';

  @override
  String get settings_notifications => 'Notificări';

  @override
  String get settings_asNeededMeds => 'Medicamente la nevoie';

  @override
  String get settings_data => 'Sincronizare';

  @override
  String get settings_about => 'Despre';

  @override
  String get settings_theme => 'Temă';

  @override
  String get settings_themeAuto => 'Auto';

  @override
  String get settings_themeLight => 'Luminos';

  @override
  String get settings_themeDark => 'Întunecat';

  @override
  String get settings_dynamicColor => 'Culoare dinamică';

  @override
  String get settings_dynamicColorSubtitle =>
      'Folosește culorile fundalului tău';

  @override
  String get settings_fontSize => 'Dimensiune font';

  @override
  String get settings_fontDefault => 'Implicit';

  @override
  String get settings_fontLarge => 'Mare';

  @override
  String get settings_fontXL => 'ExtraMare';

  @override
  String get settings_highContrast => 'Contrast ridicat';

  @override
  String get settings_highContrastSubtitle =>
      'Text mai gros, margini mai groase';

  @override
  String get settings_reduceMotion => 'Reduce mișcarea';

  @override
  String get settings_reduceMotionHint =>
      'Elementele apar direct la locul lor, fără să se miște. Textele și vibrațiile rămân la fel.';

  @override
  String get settings_reduceMotionByPhone =>
      'Activat din cauza setărilor de accesibilitate ale telefonului.';

  @override
  String get settings_language => 'Limbă';

  @override
  String get settings_languageSystem => 'Implicită sistem';

  @override
  String get settings_languageEnglish => 'English';

  @override
  String get settings_languageRomanian => 'Română';

  @override
  String get recordedBy_title => 'Înregistrat de';

  @override
  String get recordedBy_primary => 'Profilul principal';

  @override
  String get recordedBy_custom => 'Un nume scris de mine';

  @override
  String get recordedBy_person => 'Persoana care o ia';

  @override
  String get recordedBy_nameLabel => 'Nume';

  @override
  String get recordedBy_save => 'Salvează numele';

  @override
  String get recordedBy_saved => 'Salvat';

  @override
  String get recordedBy_saveFailed => 'Numele nu a putut fi salvat';

  @override
  String get recordedBy_explainer =>
      'Se aplică dozelor înregistrate de acum înainte. Înregistrările anterioare își păstrează numele.';

  @override
  String get recordedBy_personNote =>
      'Numește persoana căreia îi aparține doza, chiar dacă a înregistrat-o altcineva.';

  @override
  String get settings_couldNotLoadPrimary =>
      'Nu s-a putut încărca profilul principal';

  @override
  String get settings_couldNotLoadProfiles =>
      'Nu s-au putut încărca profilurile';

  @override
  String get settings_noProfilesAvailable => 'Niciun profil disponibil';

  @override
  String get settings_createProfileFirst => 'Creează mai întâi un profil.';

  @override
  String get settings_siblingDetection => 'Detectare elemente asociate';

  @override
  String get settings_siblingDetectionSubtitle =>
      'La editarea unei pastile, detectează copii în alte profiluri';

  @override
  String get settings_siblingName => 'Nume';

  @override
  String get settings_siblingNameDosage => 'Nume + dozaj';

  @override
  String get settings_siblingAlwaysAsk => 'Întreabă mereu';

  @override
  String get settings_changePassword => 'Schimbă parola';

  @override
  String get settings_connectedServer => 'Server conectat';

  @override
  String get settings_deviceName => 'Numele dispozitivului';

  @override
  String get settings_notSet => 'Nesetat';

  @override
  String get settings_deviceNameHint => 'ex. Telefonul meu';

  @override
  String get settings_logOut => 'Deconectare';

  @override
  String get settings_logOutSubtitle =>
      'Șterge token-urile locale și închide sesiunea';

  @override
  String get settings_snoozeDuration => 'Durata amânării';

  @override
  String get settings_snoozeSubtitle => 'Cât timp rămân amânate memento-urile';

  @override
  String get settings_notificationSound => 'Sunet notificare';

  @override
  String get settings_notificationPermission => 'Permisiune notificări';

  @override
  String get settings_permGranted => 'Acordată';

  @override
  String get settings_permDenied => 'Refuzată';

  @override
  String get settings_permNotDetermined => 'Nedeterminată';

  @override
  String get settings_openSettings => 'Deschide Setări';

  @override
  String get settings_exactAlarmPermission => 'Permisiune alarmă exactă';

  @override
  String get settings_exactAlarmDenied =>
      'Neacordată — memento-urile nu se vor activa';

  @override
  String get settings_batteryRestriction => 'Restricție baterie în fundal';

  @override
  String get settings_batteryRestrictionSubtitle =>
      'Samsung / Xiaomi / Huawei: mergi la Setări → Baterie → Limite utilizare fundal și adaugă aplicația la Aplicații mereu active. Fără aceasta, sistemul poate șterge silent memento-urile programate.';

  @override
  String get settings_appSettings => 'Setări aplicație';

  @override
  String get settings_includeInStats => 'Include în statisticile de aderență';

  @override
  String get settings_includeInStatsSubtitle =>
      'Numără dozele la nevoie (PRN) în calculele de aderență și widget-ul de acasă';

  @override
  String get settings_showPrnInWidget => 'Afișează în widget-ul de acasă';

  @override
  String get settings_showPrnInWidgetSubtitle =>
      'Afișează medicamentele la nevoie la sfârșitul listei de doze din widget';

  @override
  String get settings_syncNow => 'Sincronizează acum';

  @override
  String get settings_syncNowSubtitle => 'Descarcă ultimele date de pe server';

  @override
  String get settings_syncFailing => 'Sincronizare eșuată';

  @override
  String get settings_syncing => 'Se sincronizează…';

  @override
  String get settings_synced => 'Sincronizat';

  @override
  String get settings_syncAlreadyInProgress => 'Sincronizare deja în curs';

  @override
  String settings_syncFailedError(String error) {
    return 'Sincronizare eșuată — $error';
  }

  @override
  String get settings_syncComplete => 'Sincronizare completă';

  @override
  String settings_changesWaiting(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count de modificări în așteptare',
      few: '$count modificări în așteptare',
      one: '1 modificare în așteptare',
    );
    return '$_temp0';
  }

  @override
  String settings_changesNeedAttention(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count de modificări necesită atenția ta',
      few: '$count modificări necesită atenția ta',
      one: '1 modificare necesită atenția ta',
    );
    return '$_temp0';
  }

  @override
  String get sync_stockStaysOnPhone =>
      'Stocurile rămân pe acest telefon până când serverul tău activează sincronizarea stocului.';

  @override
  String settings_changesRetrying(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count de modificări vor fi reîncercate automat',
      few: '$count modificări vor fi reîncercate automat',
      one: '1 modificare va fi reîncercată automat',
    );
    return '$_temp0';
  }

  @override
  String get settings_justNow => 'Chiar acum';

  @override
  String settings_minutesAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'acum $count de minute',
      few: 'acum $count minute',
      one: 'acum 1 minut',
    );
    return '$_temp0';
  }

  @override
  String settings_hoursAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'acum $count de ore',
      few: 'acum $count ore',
      one: 'acum 1 oră',
    );
    return '$_temp0';
  }

  @override
  String get settings_never => 'Niciodată';

  @override
  String settings_failingSince(String time, String error) {
    return 'Eșuează de la $time — $error';
  }

  @override
  String settings_retrying(String error) {
    return 'Se reîncearcă — $error';
  }

  @override
  String get settings_syncInProgress => 'Sincronizare în curs';

  @override
  String get settings_deleteAProfile => 'Șterge un profil';

  @override
  String get settings_deleteAProfileSubtitle =>
      'Elimină permanent un profil și toate datele sale';

  @override
  String get settings_noProfilesToDelete => 'Niciun profil de șters';

  @override
  String settings_deleteProfileCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Ștergi $count de profiluri?',
      few: 'Ștergi $count profiluri?',
      one: 'Ștergi 1 profil?',
    );
    return '$_temp0';
  }

  @override
  String settings_deleteProfileConfirm(String names) {
    return 'Aceasta va șterge permanent $names și toate pastilele, programările și istoricul dozelor asociate.';
  }

  @override
  String get settings_profilesDeleted => 'Profiluri șterse';

  @override
  String get settings_deleteSelected => 'Șterge selecțiile';

  @override
  String get settings_appVersion => 'Versiunea aplicației';

  @override
  String get settings_changePasswordTitle => 'Schimbă parola';

  @override
  String get settings_currentPassword => 'Parola curentă';

  @override
  String get settings_newPassword => 'Parola nouă';

  @override
  String get settings_confirmNewPassword => 'Confirmă parola nouă';

  @override
  String get settings_currentPasswordRequired =>
      'Parola curentă este obligatorie';

  @override
  String get settings_newPasswordRequired => 'Parola nouă este obligatorie';

  @override
  String get settings_passwordMinLength =>
      'Parola trebuie să aibă cel puțin 10 caractere';

  @override
  String get settings_passwordMustDiffer =>
      'Parola nouă trebuie să fie diferită de cea curentă';

  @override
  String get settings_confirmPasswordRequired =>
      'Te rugăm să confirmi parola nouă';

  @override
  String get settings_passwordsDoNotMatch => 'Parolele nu se potrivesc';

  @override
  String get settings_updatePassword => 'Actualizează parola';

  @override
  String get settings_passwordUpdated => 'Parolă actualizată';

  @override
  String get settings_currentPasswordIncorrect =>
      'Parola curentă este incorectă';

  @override
  String get settings_minutesLabel => 'Minute';

  @override
  String settings_minutesRange(int min, int max) {
    return 'Introdu o valoare între $min și $max';
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
    return 'Scade $title';
  }

  @override
  String settings_increaseTooltip(String title) {
    return 'Crește $title';
  }

  @override
  String get analytics_last7Days => 'Ultimele 7 zile';

  @override
  String get analytics_last30Days => 'Ultimele 30 de zile';

  @override
  String get analytics_weeklyTrend => 'Tendința săptămânală';

  @override
  String get analytics_byPill30Days => 'Pe medicament (30 de zile)';

  @override
  String get analytics_noDosesLast30 => 'Nicio doză în ultimele 30 de zile';

  @override
  String get analytics_thisWeek => 'Săptămâna aceasta';

  @override
  String get analytics_noData => 'fără date';

  @override
  String get analytics_couldNotLoadStats =>
      'Nu s-au putut încărca statisticile';

  @override
  String get analytics_previousMonth => 'Luna anterioară';

  @override
  String get analytics_nextMonth => 'Luna următoare';

  @override
  String get export_title => 'Exportă istoricul dozelor';

  @override
  String export_profile(String name) {
    return 'Profil: $name';
  }

  @override
  String get export_dateRange => 'Interval de date';

  @override
  String get export_last7Days => 'Ultimele 7 zile';

  @override
  String get export_last30Days => 'Ultimele 30 de zile';

  @override
  String get export_last3Months => 'Ultimele 3 luni';

  @override
  String get export_custom => 'Personalizat…';

  @override
  String get export_format => 'Format';

  @override
  String get export_both => 'Ambele';

  @override
  String get export_generating => 'Se generează…';

  @override
  String get export_exportAndShare => 'Exportă și partajează';

  @override
  String export_failed(String error) {
    return 'Export eșuat: $error';
  }

  @override
  String get colors_coral => 'Coral';

  @override
  String get colors_amber => 'Chihlimbar';

  @override
  String get colors_yellow => 'Galben';

  @override
  String get colors_green => 'Verde';

  @override
  String get colors_teal => 'Turcoaz';

  @override
  String get colors_blue => 'Albastru';

  @override
  String get colors_lavender => 'Lavandă';

  @override
  String get colors_grey => 'Gri';

  @override
  String get colors_rose => 'Trandafir';

  @override
  String get colors_peach => 'Piersică';

  @override
  String get colors_mint => 'Mentă';

  @override
  String get colors_indigo => 'Indigo';

  @override
  String get nav_home => 'Acasă';

  @override
  String get nav_profiles => 'Profiluri';

  @override
  String get nav_pills => 'Pastile';

  @override
  String get nav_schedules => 'Programări';

  @override
  String get nav_logs => 'Istoric';

  @override
  String get nav_settings => 'Setări';

  @override
  String get nav_pressBackAgain => 'Apasă din nou Înapoi pentru a ieși';

  @override
  String get onboarding_welcome => 'Bun venit în Simpastil!';

  @override
  String get onboarding_subtitle =>
      'Hai să configurăm prima ta pastilă ca să nu uiți nicio doză.';

  @override
  String get onboarding_addPill => 'Adaugă o pastilă';

  @override
  String get onboarding_exploreLater => 'Explorează întâi';

  @override
  String get dashboard_emptyNoPillsSubtitle =>
      'Adaugă prima ta pastilă și programare pentru a vedea dozele zilnice aici.';

  @override
  String get dashboard_emptyNoPillsCta => 'Adaugă o pastilă';

  @override
  String get dashboard_emptyNoProfileSubtitle =>
      'Selectează sau creează un profil pentru a începe.';

  @override
  String get dashboard_emptyNoProfileCta => 'Mergi la Profiluri';

  @override
  String get history_emptySubtitle =>
      'Istoricul dozelor va apărea aici după ce începi să le înregistrezi.';

  @override
  String get schedules_emptyCta => 'Adaugă o pastilă întâi';

  @override
  String get semantics_loading => 'Se încarcă';

  @override
  String get semantics_selected => 'selectat';

  @override
  String get semantics_notSelected => 'neselectat';

  @override
  String semantics_doseMarked(String pill, String status) {
    return '$pill marcat ca $status';
  }

  @override
  String get settings_2faTitle => 'Autentificare în doi pași';

  @override
  String get settings_2faSubtitle =>
      'Adaugă securitate suplimentară contului tău';

  @override
  String get settings_2faFlowTitle => 'Autentificare în doi pași';

  @override
  String get settings_2faDescription =>
      'Adaugă un nivel suplimentar de securitate contului tău, solicitând un cod de verificare dintr-o aplicație de autentificare la conectare.';

  @override
  String get settings_2faSetupButton => 'Configurează 2FA';

  @override
  String get settings_2faStep1Label =>
      '1. Adaugă acest cont în aplicația de autentificare (Google Authenticator, Authy, etc.)';

  @override
  String get settings_2faManualKeyLabel => 'Cheie de introducere manuală:';

  @override
  String get settings_2faStep2Label =>
      '2. Introdu codul de 6 cifre din aplicația de autentificare pentru a verifica';

  @override
  String get settings_2faCodeLabel => 'Cod';

  @override
  String get settings_2faVerifyButton => 'Verifică și activează';

  @override
  String get settings_2faSuccess =>
      'Autentificarea în doi pași a fost activată!';

  @override
  String get settings_2faBackupCodesDescription =>
      'Salvează aceste coduri de rezervă într-un loc sigur. Le poți folosi pentru a te conecta dacă pierzi accesul la aplicația de autentificare. Fiecare cod poate fi folosit o singură dată.';

  @override
  String get settings_2faBackupCodesCopied => 'Coduri de rezervă copiate';

  @override
  String get settings_2faBackupCodesCopyButton => 'Copiază';

  @override
  String get settings_2faBackupCodesDoneButton => 'Gata';

  @override
  String get settings_2faDisabled =>
      'Autentificarea în doi pași a fost dezactivată';

  @override
  String get settings_2faDisableDescription =>
      'Introdu codul din aplicația de autentificare sau un cod de rezervă pentru a dezactiva autentificarea în doi pași.';

  @override
  String get settings_2faDisableCodeLabel => 'Cod';

  @override
  String get settings_2faDisableButton => 'Dezactivează 2FA';

  @override
  String get settings_2faCodeRequired =>
      'Introdu codul din aplicația de autentificare';

  @override
  String get settings_2faCodeRequiredDisable =>
      'Introdu codul de autentificare pentru a dezactiva 2FA';

  @override
  String get shared_copiedToClipboard => 'Copiat în clipboard';

  @override
  String get auth_2faStepLabel => 'Autentificare în doi pași';

  @override
  String get auth_2faEnterCodeTitle => 'Introdu codul de verificare';

  @override
  String get auth_2faCodeDescription =>
      'Deschide aplicația de autentificare și introdu codul de 6 cifre, sau folosește un cod de rezervă.';

  @override
  String get auth_2faCodeLabel => 'Cod';

  @override
  String get auth_2faCodeRequired => 'Introdu codul de verificare';

  @override
  String get auth_2faVerifyButton => 'Verifică';

  @override
  String get export_headerDate => 'Data';

  @override
  String get export_headerScheduledTime => 'Ora programată';

  @override
  String get export_headerPillName => 'Medicament';

  @override
  String get export_headerDosage => 'Dozaj';

  @override
  String get export_headerStatus => 'Stare';

  @override
  String get export_headerTimeTaken => 'Ora luării';

  @override
  String get export_headerNotes => 'Notițe';

  @override
  String get export_headerProfile => 'Profil';

  @override
  String get export_headerPill => 'Medicament';

  @override
  String get export_headerTakenExpected => 'Luate / Așteptate';

  @override
  String get export_headerMissed => 'Ratate';

  @override
  String get export_headerAdherence => 'Aderență';

  @override
  String get export_pdfTitle => 'Simpastil - Raport medicamente';

  @override
  String export_pdfProfile(String name) {
    return 'Profil: $name';
  }

  @override
  String export_pdfDateRange(String range) {
    return 'Interval: $range';
  }

  @override
  String export_pdfGenerated(String date) {
    return 'Generat: $date';
  }

  @override
  String get export_pdfDoseLog => 'Jurnal doze';

  @override
  String get export_pdfAdherenceSummary => 'Sumar aderență';

  @override
  String export_pdfOverallAdherence(String percent) {
    return 'Aderență generală: $percent';
  }

  @override
  String get export_pdfNoEntries =>
      'Nicio doză înregistrată pentru acest interval.';

  @override
  String export_pdfPageNumber(int current, int total) {
    return 'Pagina $current din $total';
  }

  @override
  String get export_statusTaken => 'Luat';

  @override
  String get export_statusMissed => 'Ratat';

  @override
  String get export_statusSkipped => 'Sărit';

  @override
  String get export_statusPending => 'În așteptare';

  @override
  String get export_prnLabel => 'PRN';

  @override
  String get widget_notAuthenticated => 'Deschide Simpastil pentru a începe';

  @override
  String get widget_nothingScheduled => 'Nimic programat astăzi';

  @override
  String widget_summary(int taken, int total) {
    return '$taken din $total luate';
  }

  @override
  String widget_moreDoses(int count) {
    return '+$count în plus';
  }

  @override
  String get widget_take => 'Ia';

  @override
  String get widget_log => 'Ia';

  @override
  String get error_noConnection =>
      'Fără conexiune la internet. Modificările au fost salvate local.';

  @override
  String get error_sessionExpired =>
      'Sesiunea a expirat. Te rugăm să te conectezi din nou.';

  @override
  String get error_pillNotFound => 'Pastila nu a fost găsită.';

  @override
  String get error_profileNotFound => 'Profilul nu a fost găsit.';

  @override
  String error_serverError(int statusCode) {
    return 'Eroare server ($statusCode).';
  }

  @override
  String get t08_today => 'Astăzi';

  @override
  String get t08_medications => 'Medicamente';

  @override
  String get t08_history => 'Istoric';

  @override
  String get t08_people => 'Persoane';

  @override
  String get t08_startTitle => 'Grijă,\nzi de zi.';

  @override
  String get t08_startBody =>
      'Păstrează medicamentele și îngrijirea zilnică împreună, în privat, pe acest dispozitiv.';

  @override
  String get t08_start => 'Începe';

  @override
  String get t08_connect => 'Conectează-te la îngrijirea partajată';

  @override
  String get t08_local => 'Pe acest dispozitiv';

  @override
  String get t08_personTitle => 'Pe cine îngrijim?';

  @override
  String get t08_personBody =>
      'Poți adăuga alte persoane mai târziu. Numele autorului înregistrărilor rămâne separat.';

  @override
  String get t08_personName => 'Numele persoanei';

  @override
  String get t08_personSave => 'Salvează persoana';

  @override
  String get t08_back => 'Înapoi';

  @override
  String get t08_medicationTitle => 'Adaugă un medicament';

  @override
  String get t08_medicationBody =>
      'Începe cu numele. Poți adăuga o rutină după salvare.';

  @override
  String get t08_medicationName => 'Numele medicamentului';

  @override
  String get t08_strength => 'Concentrația de pe ambalaj (opțional)';

  @override
  String get t08_strengthHint => 'De exemplu, 500 mg';

  @override
  String get t08_amount => 'Cantitate la o administrare';

  @override
  String get t08_unknown => 'Nespecificată';

  @override
  String get t08_quantity => 'Cantitate';

  @override
  String get t08_quantityHint => 'De exemplu, 1 sau 1/2';

  @override
  String get t08_unit => 'Unitate';

  @override
  String get t08_unitHint => 'De exemplu, comprimat sau mL';

  @override
  String get t08_amountHelp =>
      'Separată de concentrația de pe ambalaj. Las-o nespecificată dacă nu ești sigur.';

  @override
  String get t08_saveMedication => 'Salvează medicamentul';

  @override
  String get t08_medicationSaved => 'Medicament salvat';

  @override
  String get t08_routineTitle => 'Un loc pentru rutină';

  @override
  String get t08_routineBody =>
      'Medicamentul este deja salvat. Alege când își are locul în ziua ta.';

  @override
  String get t08_addRoutine => 'Adaugă o rutină';

  @override
  String get t08_notNow => 'Nu acum';

  @override
  String get t08_daily => 'În fiecare zi';

  @override
  String get t08_time => 'Ora';

  @override
  String get t08_addTime => 'Adaugă încă o oră';

  @override
  String get t08_removeTime => 'Elimină ora';

  @override
  String get t08_zone => 'Fusul orar al rutinei';

  @override
  String get t08_zoneHelp =>
      'Verifică locul. Orele rutinei rămân în acest fus orar când călătorești.';

  @override
  String get t08_preview => 'Verifică următoarea doză';

  @override
  String get t08_reviewRoutine => 'Următoarea doză';

  @override
  String get t08_phoneTimeUnavailable =>
      'Nu s-a putut citi fusul orar al telefonului. Încearcă din nou pentru a verifica următoarea doză.';

  @override
  String get t08_bucharest => 'București, România';

  @override
  String t08_savedPlaceTime(String time, String place) {
    return '$time, ora din $place';
  }

  @override
  String t08_hereTime(String time) {
    return '$time aici';
  }

  @override
  String get t08_effective => 'Începe de la această verificare';

  @override
  String get t08_saveRoutine => 'Salvează rutina';

  @override
  String get t08_routineSaved => 'Rutină salvată';

  @override
  String get t08_edit => 'Editează';

  @override
  String get t08_reminderTitle => 'Îngrijirea e pe primul loc.';

  @override
  String get t08_reminderBody =>
      'Îngrijirea este salvată. Mementourile sunt opționale și pot fi configurate separat.';

  @override
  String get t08_readyTitle => 'Totul e pregătit.';

  @override
  String get t08_readyBody =>
      'Persoana și medicamentul sunt salvate pe acest dispozitiv. Poți reveni oricând.';

  @override
  String get t08_openToday => 'Mergi la Astăzi';

  @override
  String get t08_saving => 'Se salvează…';

  @override
  String get t08_saved => 'Salvat pe acest dispozitiv';

  @override
  String get t08_pendingShare => 'Salvat aici · așteaptă partajarea';

  @override
  String get t08_shared => 'Acceptat în îngrijirea partajată';

  @override
  String get t08_reviewShare => 'Salvat aici · partajarea trebuie verificată';

  @override
  String get t08_unavailable => 'Îngrijirea este temporar indisponibilă';

  @override
  String get t08_unavailableBody =>
      'Datele salvate nu au fost înlocuite. Încearcă din nou să le deschizi.';

  @override
  String get t08_saveError =>
      'Nu s-a putut salva. Îngrijirea existentă este păstrată. Încearcă din nou.';

  @override
  String get t08_required => 'Introdu un nume pentru a continua';

  @override
  String get t08_invalidAmount =>
      'Introdu o cantitate pozitivă și o unitate explicită';

  @override
  String get t08_invalidRoutine =>
      'Verifică orele și încearcă din nou previzualizarea';

  @override
  String get t08_everyone => 'Toată lumea';

  @override
  String get t08_viewPerson => 'Vezi îngrijirea pentru';

  @override
  String get t08_overview => 'Ziua, dintr-o privire';

  @override
  String get t08_previous => 'Anterior';

  @override
  String get t08_next => 'Următor';

  @override
  String get t08_takenNow => 'Luat acum';

  @override
  String get t08_taken => 'Luat';

  @override
  String get t08_skipped => 'Omis';

  @override
  String get t08_unrecorded => 'Neînregistrat';

  @override
  String get t08_undo => 'Anulează înregistrarea';

  @override
  String get t08_unknownTime => 'Ora administrării necunoscută';

  @override
  String get t08_noPeople => 'Îngrijirea începe cu o persoană';

  @override
  String get t08_noMedications => 'Un loc pentru medicamentele tale';

  @override
  String get t08_noRoutine => 'Salvat, fără rutină';

  @override
  String get t08_noRoutineBody =>
      'Medicamentul este aici. Adaugă o rutină când ești pregătit.';

  @override
  String get t08_dayOff => 'Nimic planificat pentru această zi';

  @override
  String get t08_dayOffBody =>
      'Nu sunt doze planificate pentru astăzi în calendarul acestei rutine.';

  @override
  String get t08_later => 'Urmează mai târziu';

  @override
  String get t08_recorded => 'Ziua este înregistrată';

  @override
  String get t08_recordError =>
      'Înregistrarea s-a schimbat sau nu a putut fi salvată. Verific-o înainte de a încerca din nou.';

  @override
  String get t08_undoStockUnchanged =>
      'Anulat. Stocul nu a fost modificat, pentru că această doză a fost numărată înainte de începerea urmăririi stocului. Corectează stocul manual dacă este nevoie.';

  @override
  String get t08_asNeeded => 'La nevoie';

  @override
  String get t08_asNeededBody =>
      'Medicamentul la nevoie este salvat. Nu are un număr planificat de doze.';

  @override
  String get t08_date => 'Alege ziua';

  @override
  String get t08_returnToday => 'Înapoi la astăzi';

  @override
  String get t08_finishLater => 'Salvează și continuă mai târziu';

  @override
  String get t08_draftSaved => 'Progres salvat';

  @override
  String get t08_scheduleTool => 'Programe și instrumente conectate';

  @override
  String t08_position(int current, int total) {
    return 'Elementul $current din $total';
  }

  @override
  String t08_remaining(int count) {
    return '$count de înregistrat';
  }

  @override
  String t08_forPerson(String name) {
    return 'Pentru $name';
  }

  @override
  String get core_notifPrivateTitle => 'Un memento discret';

  @override
  String get core_notifPrivateBody => 'Deschide Simpastil când ai un moment.';

  @override
  String get core_notifTestTitle => 'Așa arată un memento';

  @override
  String get core_notifTestBody =>
      'Dacă vezi asta, mementourile ajung la tine. Confirmă în Simpastil.';

  @override
  String get core_notifActionOpen => 'Deschide';

  @override
  String get t09_routine => 'Rutină';

  @override
  String get t09_routineDetails => 'Detaliile rutinei';

  @override
  String get t09_editRoutine => 'Editează rutina';

  @override
  String get t09_pattern => 'Când îl folosești?';

  @override
  String get t09_weekdays => 'Anumite zile ale săptămânii';

  @override
  String get t09_interval => 'La câteva zile';

  @override
  String get t09_prn => 'La nevoie';

  @override
  String get t09_prnHelp =>
      'Fără doze zilnice așteptate. Înregistrează fiecare administrare când are loc.';

  @override
  String get t09_everyDays => 'Numărul de zile calendaristice';

  @override
  String get t09_anchor => 'Numără începând cu';

  @override
  String get t09_dates => 'Date opționale';

  @override
  String get t09_startDate => 'Prima zi';

  @override
  String get t09_endDate => 'Ultima zi (inclusă)';

  @override
  String get t09_notSet => 'Nespecificată';

  @override
  String get t09_clearDate => 'Elimină data';

  @override
  String get t09_changesFrom => 'Modificări începând cu';

  @override
  String get t09_preserveRecords =>
      'Dozele înregistrate își păstrează detaliile originale.';

  @override
  String get t09_before => 'Rutina actuală';

  @override
  String get t09_after => 'Rutina revizuită';

  @override
  String get t09_nextEntries => 'Următoarele doze planificate';

  @override
  String get t09_noPreview =>
      'Nu sunt doze în următoarele 31 de zile. Verifică tiparul și datele înainte de salvare.';

  @override
  String get t09_reviewChanges => 'Verifică modificările';

  @override
  String get t09_changeZone => 'Schimbă fusul orar';

  @override
  String get t09_chooseZone => 'Alege un loc';

  @override
  String get t09_unknownZone => 'Fusul orar trebuie verificat';

  @override
  String get sync_scheduleTimezoneReviewRequired =>
      'Fusul orar al rutinei trebuie verificat. Alege un oraș sau o regiune.';

  @override
  String get t09_searchPlace => 'Caută locuri';

  @override
  String get t09_zoneHelp =>
      'Orele rămân legate de acest loc când călătorești. Schimbarea necesită o nouă verificare.';

  @override
  String get t09_utc => 'Timpul universal coordonat';

  @override
  String get t09_noRoutine => 'Medicament salvat · Fără rutină deocamdată';

  @override
  String get t09_savedRoutine => 'Rutină salvată';

  @override
  String get t09_reviewConflict =>
      'Datele s-au schimbat în timpul verificării. Verifică din nou înainte de salvare. Alegerile tale sunt păstrate.';

  @override
  String get t09_futureBoundary =>
      'Alege o oră viitoare la „Modificări începând cu”, apoi verifică din nou.';

  @override
  String get t09_legacyDosage => 'Textul inițial al dozei · Neverificat';

  @override
  String get t09_reviewDetails => 'Verifică detaliile medicamentului';

  @override
  String get t09_editMedication => 'Editează medicamentul';

  @override
  String get t09_form => 'Formă (opțională)';

  @override
  String get t09_notes => 'Note (opționale)';

  @override
  String get t09_connectedDetails =>
      'Cantitatea, concentrația și forma verificate rămân pe acest dispozitiv. Modificările partajate sunt afișate separat.';

  @override
  String get t09_savedPending => 'Salvat aici · În așteptarea partajării';

  @override
  String get t09_viewCare => 'Vezi îngrijirea';

  @override
  String get t09_addMedication =>
      'Adaugă un medicament pentru această persoană';

  @override
  String get t09_personSaved => 'Persoană salvată';

  @override
  String get t09_remindersLater => 'Configurează mai târziu';

  @override
  String get t09_allowReminders => 'Permite mementourile';

  @override
  String get t09_checkReminders => 'Trimite un memento de verificare';

  @override
  String get t09_remindersAllowed =>
      'Acest telefon permite mementouri. Livrarea nu a fost confirmată.';

  @override
  String get t09_remindersUnavailable =>
      'Mementourile nu sunt pregătite pe acest telefon. Îngrijirea salvată este disponibilă.';

  @override
  String get t09_checkScheduled =>
      'Verificare programată. Confirmă doar dacă ai văzut-o pe acest telefon.';

  @override
  String get t09_sawReminder => 'Am văzut mementoul';

  @override
  String get t09_deliveryConfirmed =>
      'Ai confirmat că ai văzut mementoul pe acest telefon.';

  @override
  String get t09_privacy => 'Arată detaliile medicamentului în mementouri';

  @override
  String get t09_reminderSummary =>
      'Când este dezactivat, mementourile îți cer doar să deschizi Simpastil.';

  @override
  String get t09_savedSummary => 'Salvat pe acest dispozitiv';

  @override
  String get t09_continueSetup => 'Continuă configurarea';

  @override
  String t09_everyN(int days) {
    return 'La fiecare $days zile calendaristice';
  }

  @override
  String get t09_medicationAmountHelp =>
      'Aceasta este cantitatea implicită a medicamentului. Verifică separat cantitatea fiecărei rutine.';

  @override
  String get t10_details => 'Detaliile dozei';

  @override
  String get t10_recordDose => 'Înregistrează o doză';

  @override
  String get t10_recordedAmount => 'Cantitatea înregistrată';

  @override
  String get t10_planned => 'Planificat';

  @override
  String get t10_actual => 'Ora administrării';

  @override
  String get t10_entered => 'Înregistrat în Simpastil';

  @override
  String get t10_author => 'Înregistrat de';

  @override
  String get t10_unknownAuthor => 'Autor necunoscut';

  @override
  String get t10_unnamedAuthor => 'Numele autorului nu este înregistrat';

  @override
  String get t10_unknownDate => 'Dată necunoscută';

  @override
  String get t10_unknownMedication =>
      'Detaliile medicamentului nu sunt disponibile';

  @override
  String get t10_unknownPerson => 'Persoană necunoscută';

  @override
  String get t10_recordHistory => 'Înregistrare și corecturi';

  @override
  String get t10_correct => 'Corectează înregistrarea';

  @override
  String get t10_corrected => 'Corectură';

  @override
  String get t10_withdrawn => 'Anulare înregistrată';

  @override
  String get t10_skip => 'Înregistrează ca omisă';

  @override
  String get t10_outcome => 'Rezultat';

  @override
  String get t10_chooseTime => 'Alege o oră';

  @override
  String get t10_timeHere => 'Ora de pe acest dispozitiv';

  @override
  String get t10_reviewRecord => 'Verifică înregistrarea';

  @override
  String get t10_saveRecord => 'Salvează înregistrarea';

  @override
  String get t10_recordAnother => 'Înregistrează altă doză';

  @override
  String get t10_notes => 'Notă (opțional)';

  @override
  String get t10_noRecords => 'Încă nu există înregistrări';

  @override
  String get t10_noRecordsBody =>
      'Dozele înregistrate și corecturile vor apărea aici. Aceasta nu înseamnă că îngrijirea a fost omisă.';

  @override
  String get t10_historyHint =>
      'Ora planificată, ora administrării și ora înregistrării rămân separate.';

  @override
  String get t10_legacy =>
      'Înregistrare veche · unele detalii nu sunt cunoscute';

  @override
  String get t10_readOnly =>
      'Această înregistrare păstrată poate fi citită, dar nu poate fi modificată aici.';

  @override
  String get t10_select => 'Selectează doze';

  @override
  String get t10_selection => 'Verifică dozele selectate';

  @override
  String get t10_choosePerson => 'Alege o persoană înainte de a selecta doze.';

  @override
  String get t10_selectionHint =>
      'Vor fi înregistrate doar aceste doze. Dozele noi nu sunt adăugate.';

  @override
  String get t10_reviewSelection => 'Verifică selecția';

  @override
  String get t10_recordSelected => 'Înregistrează dozele selectate';

  @override
  String get t10_savedItem => 'Salvat';

  @override
  String get t10_retryItem => 'Nesalvat · poți reîncerca';

  @override
  String get t10_retryRemaining => 'Reîncearcă dozele nesalvate';

  @override
  String get t10_partial =>
      'Unele doze au fost salvate. Verifică fiecare rezultat de mai jos.';

  @override
  String get t10_allSaved => 'Fiecare doză selectată a fost salvată.';

  @override
  String get t10_done => 'Gata';

  @override
  String get t10_cancel => 'Anulează';

  @override
  String get t10_edit => 'Editează verificarea';

  @override
  String get t10_timeInvalid => 'Verifică data și ora alese.';

  @override
  String get t10_unrecordedHint =>
      'Neînregistrat înseamnă că nu există un rezultat înregistrat aici. Nu înseamnă omis.';

  @override
  String get t10_knownOutcomes =>
      'Toate dozele planificate au un rezultat înregistrat.';

  @override
  String get t10_savedLocal => 'Salvat pe acest dispozitiv';

  @override
  String get t10_sharingPending => 'Salvat aici · așteaptă trimiterea';

  @override
  String get t10_sharingAccepted => 'Înregistrare acceptată de server';

  @override
  String get t10_sharingReview =>
      'Salvat aici · înregistrarea partajată necesită verificare';

  @override
  String get t10_sharingUncertain =>
      'Salvat aici · rezultatul partajării este necunoscut';

  @override
  String get t10_freshnessUnknown =>
      'Starea actualizărilor de pe server este necunoscută. Poți înregistra îngrijirea pe acest dispozitiv.';

  @override
  String t10_sharedUpdated(String time) {
    return 'Ultima actualizare primită de pe server: $time';
  }

  @override
  String t10_sharingCounts(int pending, int review, int uncertain) {
    return '$pending în așteptare · $review de verificat · $uncertain incerte';
  }

  @override
  String get t10_syncing => 'Se primesc actualizări de pe server…';

  @override
  String get t10_asNeededUndone => 'Această doză la nevoie a fost anulată.';

  @override
  String get t10_recordError =>
      'Această înregistrare nu a fost confirmată. Reîncercarea păstrează aceeași acțiune și oră.';

  @override
  String t10_selectedCount(int count) {
    return '$count selectate';
  }

  @override
  String get t10_prnHint =>
      'Fără număr zilnic impus. Înregistrează fiecare administrare când are loc.';

  @override
  String get t10_loadMore => 'Arată înregistrări mai vechi';

  @override
  String get t10_noPeopleBody =>
      'Adaugă o persoană pentru a începe îngrijirea.';

  @override
  String get t10_noMedicationBody =>
      'Adaugă un medicament pentru această persoană.';

  @override
  String get t10_chooseDate => 'Alege o dată';

  @override
  String get t11_entry => 'Aspect și culori';

  @override
  String get t11_scope =>
      'Aspect personal pe acest dispozitiv. Îngrijirea, conexiunile și configurarea rămân neschimbate.';

  @override
  String get t11_preview => 'Previzualizare · Focus deck';

  @override
  String get t11_exampleOnly =>
      'Doar un exemplu. Previzualizarea nu poate înregistra îngrijirea.';

  @override
  String get t11_examplePerson => 'Persoană exemplu';

  @override
  String get t11_exampleMedication => 'Medicament exemplu';

  @override
  String get t11_exampleAmount => '1 comprimat · 09:00';

  @override
  String get t11_exampleField => 'Notă exemplu';

  @override
  String get t11_exampleError => 'Exemplu de mesaj care necesită atenție';

  @override
  String get t11_colors => 'Culorile temei';

  @override
  String get t11_actions => 'Acțiuni și accente';

  @override
  String get t11_surfaces => 'Suprafețe și text';

  @override
  String get t11_states => 'Stări și persoane';

  @override
  String get t11_reset => 'Restabilește aspectul implicit';

  @override
  String get t11_resetQuestion => 'Restabilești aspectul implicit?';

  @override
  String get t11_resetExplanation =>
      'Această acțiune salvează culorile și opțiunile de afișare implicite. Nu elimină îngrijirea, conexiunile, mementourile sau configurarea neterminată.';

  @override
  String get t11_apply => 'Aplică aspectul';

  @override
  String get t11_applied => 'Aspect salvat pe acest dispozitiv';

  @override
  String get t11_resetSaved => 'Aspectul implicit a fost restabilit';

  @override
  String get t11_saveError =>
      'Aspectul nu a fost salvat. Aspectul anterior este încă aplicat. Încearcă din nou.';

  @override
  String get t11_loadError =>
      'Aspectul salvat nu a putut fi citit. Reîncearcă sau restabilește aspectul implicit. Îngrijirea rămâne neschimbată.';

  @override
  String get t11_dynamicHint =>
      'Folosește culorile dispozitivului când sunt disponibile. Culorile alese individual au prioritate.';

  @override
  String get t11_dynamicUnavailable =>
      'Culorile dispozitivului nu sunt disponibile aici. Paleta Simpastil este folosită ca punct de plecare.';

  @override
  String get t11_contrastHint =>
      'Accentuează textul, culorile stărilor și contururile. Culorile alese rămân salvate; previzualizarea arată rezultatul lizibil.';

  @override
  String get t11_contrastWarning =>
      'Unele texte sau acțiuni pot fi greu de citit. Ajustează culorile sau activează contrastul ridicat. Comenzile editorului folosesc întotdeauna o paletă lizibilă.';

  @override
  String get t11_defaultColor => 'Culoarea implicită a temei';

  @override
  String get t11_customColor => 'Culoare personalizată';

  @override
  String get t11_hex => 'Codul culorii (6 cifre hexazecimale)';

  @override
  String get t11_hexError =>
      'Introdu șase cifre sau litere din intervalele 0–9 și A–F.';

  @override
  String get t11_hue => 'Nuanță';

  @override
  String get t11_saturation => 'Saturație';

  @override
  String get t11_value => 'Luminozitate';

  @override
  String get t11_useColor => 'Folosește această culoare';

  @override
  String get t11_useDefault => 'Folosește culoarea implicită';

  @override
  String get t11_primary => 'Acțiune principală';

  @override
  String get t11_onPrimary => 'Text pe acțiunea principală';

  @override
  String get t11_primaryContainer => 'Fundal selectat';

  @override
  String get t11_onPrimaryContainer => 'Text pe fundalul selectat';

  @override
  String get t11_background => 'Fundalul paginii';

  @override
  String get t11_text => 'Text principal';

  @override
  String get t11_surface => 'Panouri și dialoguri';

  @override
  String get t11_surfaceVariant => 'Carduri și câmpuri';

  @override
  String get t11_mutedText => 'Text secundar';

  @override
  String get t11_border => 'Contururi';

  @override
  String get t11_secondary => 'Accent secundar';

  @override
  String get t11_onSecondary => 'Text pe accentul secundar';

  @override
  String get t11_tertiary => 'Accent suplimentar';

  @override
  String get t11_onTertiary => 'Text pe accentul suplimentar';

  @override
  String get t11_error => 'Fundal pentru erori';

  @override
  String get t11_onError => 'Text pe fundalul erorii';

  @override
  String get t11_taken => 'Luat';

  @override
  String get t11_skipped => 'Omis';

  @override
  String get t11_unrecorded => 'Neînregistrat';

  @override
  String get t11_activePerson => 'Persoana selectată';

  @override
  String get t11_inactivePerson => 'Alte persoane';

  @override
  String get r07_setupTitle => 'Configurează Simpastil';

  @override
  String get r07_firstMedication => 'Adaugă primul medicament';

  @override
  String r07_stepCount(int current, int total) {
    return '$current din $total';
  }

  @override
  String get r07_strength => 'Concentrație (opțional)';

  @override
  String get r07_tablet => 'Comprimat';

  @override
  String get r07_capsule => 'Capsulă';

  @override
  String get r07_liquid => 'Lichid';

  @override
  String get r07_morning => 'Dimineața';

  @override
  String get r07_afternoon => 'După-amiaza';

  @override
  String get r07_evening => 'Seara';

  @override
  String get r07_night => 'Noaptea';

  @override
  String get r07_upNext => 'Urmează';

  @override
  String r07_laterDose(String name, String time) {
    return 'Mai târziu: $name la $time';
  }

  @override
  String r07_otherDose(String name, String time) {
    return '$name la $time';
  }

  @override
  String get r08_startTitle => 'Începe-ți rutina';

  @override
  String get r08_startBody =>
      'Păstrează-ți rutina pe acest dispozitiv.\nConectează un server când ești pregătit.';

  @override
  String get r08_noAccount => 'Nu ai nevoie de cont sau server';

  @override
  String get r08_startHere => 'Începe pe acest dispozitiv';

  @override
  String get r08_connect => 'Conectează un server';

  @override
  String get r08_restore => 'Restaurează o copie de siguranță';

  @override
  String get r08_choiceLater => 'Poți schimba alegerea mai târziu.';

  @override
  String get r08_personTitle => 'Pe cine vei ajuta?';

  @override
  String get r08_personHint =>
      'Începe cu o persoană. Poți adăuga altele mai târziu.';

  @override
  String get r08_personIdentity =>
      'Numele autorului înregistrărilor rămâne separat.';

  @override
  String get r08_routineTitle => 'Stabilește rutina';

  @override
  String get r08_repeat => 'Repetare';

  @override
  String get r08_scheduledTime => 'Ora programată';

  @override
  String get r08_remindersTitle => 'Mementouri discrete, dacă le vrei';

  @override
  String get r08_checkTitle => 'Verifică dacă mementourile ajung la tine';

  @override
  String get r08_reminderPreview => 'Cum arată un memento';

  @override
  String get r08_notificationsAllowed => 'Notificări permise';

  @override
  String get r08_notificationsNotAllowed =>
      'Notificările nu sunt încă activate';

  @override
  String get r08_testConfirmed => 'Mementou de test confirmat';

  @override
  String get r08_testNotConfirmed => 'Mementou de test neconfirmat';

  @override
  String get r08_checkHelp =>
      'Acest test nu înregistrează o doză. Confirmă doar după ce îl vezi pe acest telefon.';

  @override
  String get r09_medicationsBody => 'Vezi și gestionează toate medicamentele';

  @override
  String get r09_searchMedications => 'Caută medicamente';

  @override
  String get r09_noMatchingMedications => 'Niciun medicament nu corespunde';

  @override
  String get r09_addMedication => 'Adaugă un medicament';

  @override
  String get r09_noRoutine => 'Fără rutină încă';

  @override
  String get r09_medicationActions => 'Acțiuni pentru medicament';

  @override
  String get r09_viewDetails => 'Vezi detaliile';

  @override
  String get r09_selectMedication => 'Selectează medicamentul';

  @override
  String get r09_clearSearch => 'Șterge căutarea';

  @override
  String get r09_peopleToday => 'Persoane, astăzi';

  @override
  String get r09_peopleBody =>
      'Îngrijirea de azi, pe scurt, pentru persoanele tale';

  @override
  String r09_medicationCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count de medicamente',
      few: '$count medicamente',
      one: '1 medicament',
    );
    return '$_temp0';
  }

  @override
  String get r09_viewEveryone => 'Vezi toate persoanele';

  @override
  String get r09_managePeople => 'Gestionează persoanele';

  @override
  String get r09_viewRoutine => 'Vezi rutina';

  @override
  String get r09_allRecords => 'Toate înregistrările';

  @override
  String r09_recordCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count de înregistrări',
      few: '$count înregistrări',
      one: '1 înregistrare',
    );
    return '$_temp0';
  }

  @override
  String get r09_latestEntry => 'Cea mai recentă';

  @override
  String get r09_earlierDay => 'Mai devreme în această zi';

  @override
  String get r09_searchHistory => 'Caută în istoric';

  @override
  String get r09_noMatchingRecords => 'Nicio înregistrare nu corespunde';

  @override
  String get r09_previousDay => 'Ziua precedentă';

  @override
  String get r09_nextDay => 'Ziua următoare';

  @override
  String get r09_recentDays => 'Zile recente';

  @override
  String get r14_reviewDoses => 'Verifică dozele';

  @override
  String get r14_chooseDoses => 'Alege dozele de verificat';

  @override
  String r14_personDay(String person, String day) {
    return '$person · $day';
  }

  @override
  String r14_selectedDoses(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count de doze selectate',
      few: '$count doze selectate',
      one: '1 doză selectată',
    );
    return '$_temp0';
  }

  @override
  String r14_selectionCount(int count) {
    return '$count selectate · Încă nesalvate';
  }

  @override
  String r14_unrecordedCount(int count) {
    return 'Neînregistrate · $count';
  }

  @override
  String r14_reviewCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Verifică $count de doze',
      few: 'Verifică $count doze',
      one: 'Verifică 1 doză',
    );
    return '$_temp0';
  }

  @override
  String r14_recordCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Înregistrează $count ca luate',
      few: 'Înregistrează $count ca luate',
      one: 'Înregistrează 1 ca luată',
    );
    return '$_temp0';
  }

  @override
  String get r14_clearSelection => 'Golește selecția';

  @override
  String get r14_remove => 'Elimină';

  @override
  String get r14_later => 'Mai târziu';

  @override
  String r14_plannedFor(String day) {
    return 'Planificate pentru $day';
  }

  @override
  String r14_recordFor(String person) {
    return 'Aceste doze vor fi înregistrate pentru $person.';
  }

  @override
  String get r14_sameTime =>
      'Această alegere a orei se aplică fiecărei doze selectate.';

  @override
  String r14_savedCount(int saved, int total) {
    return '$saved din $total salvate';
  }

  @override
  String get r15_noMedications => 'Niciun medicament încă';

  @override
  String r15_addForPerson(String person) {
    return 'Adaugă un medicament pentru $person când ești pregătit.';
  }

  @override
  String get r15_choosePerson => 'Adaugă medicament pentru…';

  @override
  String get r15_chooseFirstPerson =>
      'Alege o persoană pentru a-i adăuga primul medicament.';

  @override
  String get r15_optionalSetup =>
      'Configurarea rutinei și a stocului este opțională.';

  @override
  String get r15_nothingToday => 'Nimic programat astăzi';

  @override
  String get r15_nothingDay => 'Nimic programat în această zi';

  @override
  String get r15_nextBody => 'Următoarea doză programată este afișată mai jos.';

  @override
  String get r15_noNext =>
      'Nu este disponibilă o doză viitoare din rutina salvată.';

  @override
  String r15_nextDate(String date) {
    return 'Urmează · $date';
  }

  @override
  String get r16_editTheme => 'Editează tema';

  @override
  String get r16_scope => 'Aspect personal pe acest dispozitiv';

  @override
  String get r16_accent => 'Accent';

  @override
  String get r16_background => 'Fundal';

  @override
  String get r16_text => 'Text';

  @override
  String get r16_allColors => 'Toate opțiunile de culoare';

  @override
  String get r16_formsPreview => 'Previzualizează formulare și stări';

  @override
  String get r16_displayOptions => 'Opțiuni de afișare';

  @override
  String get r16_example => 'Exemplu';

  @override
  String get r16_examplePerson => 'Alex · 09:00';

  @override
  String get r16_exampleMedication => 'Comprimat exemplu 20 mg';

  @override
  String get r16_exampleAmount => '1 comprimat';

  @override
  String get t14_lockUseDeviceLock => 'Folosește blocarea dispozitivului';

  @override
  String get t14_lockTitle => 'Datele de îngrijire sunt blocate';

  @override
  String get t14_lockBody =>
      'Deblochează folosind dispozitivul pentru a continua. Mementourile programate pot apărea în continuare.';

  @override
  String get t14_lockChecking => 'Se verifică autentificarea dispozitivului…';

  @override
  String get t14_lockCancelled =>
      'Deblocarea a fost anulată. Datele de îngrijire rămân ascunse.';

  @override
  String get t14_lockUnavailable =>
      'Autentificarea dispozitivului nu este disponibilă. Datele de îngrijire rămân ascunse.';

  @override
  String get t14_lockWriteFailed =>
      'Setarea de blocare nu a putut fi confirmată. Deblochează din nou pentru a continua.';

  @override
  String get t14_lockStale => 'Deblochează din nou pentru a continua.';

  @override
  String get t14_settingsLockTitle => 'Blocarea aplicației';

  @override
  String get t14_settingsLockBody =>
      'Solicită autentificarea dispozitivului la deschiderea sau revenirea în Simpastil pe acest dispozitiv. Setările de confidențialitate pentru mementouri și widget rămân separate.';

  @override
  String get t14_settingsLockEnableReason => 'Activează blocarea aplicației';

  @override
  String get t14_settingsLockDisableReason =>
      'Dezactivează blocarea aplicației';

  @override
  String get t14_settingsLockCancelled =>
      'Blocarea aplicației nu a fost modificată.';

  @override
  String get t14_settingsLockFailed =>
      'Setarea de blocare a aplicației nu a putut fi confirmată. Încearcă din nou.';

  @override
  String get t14_personReminders => 'Mementouri pe acest dispozitiv';

  @override
  String get t14_personRemindersEnabled => 'Include această persoană';

  @override
  String get t14_personRemindersBody =>
      'Include această persoană în mementourile programate și în widgetul de pe acest dispozitiv. Permisiunea Android pentru notificări este necesară în continuare.';

  @override
  String get t15_intro => 'Simpastil, așa cum îți place';

  @override
  String get t15_everyday => 'Preferințe zilnice';

  @override
  String get t15_yourData => 'Datele tale';

  @override
  String get t15_privacyAccess => 'Confidențialitate și acces';

  @override
  String get t15_layout => 'Aspectul aplicației';

  @override
  String get t15_focusDeck => 'Carduri Focus';

  @override
  String get t15_colors => 'Culori și temă';

  @override
  String get t15_defaultPalette => 'Paleta implicită';

  @override
  String get t15_customPalette => 'Paleta personală';

  @override
  String get t15_reminders => 'Mementouri';

  @override
  String get t15_remindersSubtitle => 'Livrare și detalii pe ecranul blocat';

  @override
  String get t15_accessibility => 'Accesibilitate';

  @override
  String get t15_accessibilitySubtitle => 'Afișare și interacțiune';

  @override
  String get t15_backups => 'Copii de siguranță';

  @override
  String get t15_backupsSubtitle => 'Exportă sau restaurează un fișier';

  @override
  String get t15_storageRecovery => 'Stocare și recuperare';

  @override
  String get t15_storageSubtitle => 'Fișiere locale și copii de recuperare';

  @override
  String get t15_serverConnection => 'Conexiune la server';

  @override
  String get t15_notConnected => 'Neconectat';

  @override
  String get t15_protection => 'Protecția aplicației';

  @override
  String get t15_protectionSubtitle => 'Criptare și blocare opțională';

  @override
  String get t15_peopleSubtitle => 'Persoana principală și preferințe';

  @override
  String get t15_medicationSubtitle => 'Editare și preferințe la nevoie';

  @override
  String get t15_dataSubtitle =>
      'Starea conexiunii și înregistrări care necesită atenție';

  @override
  String get t15_protectedCare => 'Stocare criptată pentru îngrijire';

  @override
  String get t15_encryptionBody =>
      'Datele sunt criptate pe acest dispozitiv chiar dacă blocarea aplicației este oprită. Blocarea adaugă autentificarea dispozitivului înainte de acces.';

  @override
  String get t15_transferTitle => 'Mutarea pe alt telefon';

  @override
  String get t15_transferBody =>
      'Datele protejate sunt excluse din copiile automate ale sistemului și transferul dispozitivului. Salvează o copie portabilă sau folosește o copie autorizată de pe server înainte de a schimba telefonul. O copie locală nu protejează împotriva pierderii telefonului.';

  @override
  String get t15_serverPrivacy =>
      'Operatorul unui server de încredere poate citi tehnic datele de îngrijire de pe acel server. Îngrijirea locală nu necesită un server.';

  @override
  String get t15_careFiles => 'Îngrijire, ciorne și modificări în așteptare';

  @override
  String get t15_recoveryCopies => 'Copii de recuperare';

  @override
  String get t15_unfinishedFiles => 'Fișiere de pornire neterminate';

  @override
  String get t15_legacyFiles => 'Fișiere originale păstrate';

  @override
  String get t15_otherFiles => 'Alte fișiere private';

  @override
  String get t15_availableSpace => 'Disponibil pe dispozitiv';

  @override
  String get t15_unknownSize => 'Indisponibil';

  @override
  String get t15_inventoryScope =>
      'Dimensiunile includ fișierele controlate de Simpastil. Ciornele și modificările în așteptare sunt incluse cu datele de îngrijire. Fișierele partajate ale sistemului nu sunt incluse.';

  @override
  String get t15_checkedRecovery => 'Copie de recuperare verificată';

  @override
  String get t15_noRecovery => 'Încă nu există o copie de recuperare';

  @override
  String get t15_recoveryUnavailable =>
      'Copia de recuperare nu a putut fi verificată. Fișierele originale sunt păstrate.';

  @override
  String get t15_savedAt => 'Salvată';

  @override
  String get t15_checkedAt => 'Verificată';

  @override
  String get t15_cleanup => 'Curăță fișierele temporare sigure';

  @override
  String get t15_cleanupBody =>
      'Pot fi eliminate doar fișierele de pornire abandonate, care nu au fost folosite ca date de îngrijire. Datele, ciornele, modificările în așteptare și copiile de recuperare sunt păstrate.';

  @override
  String get t15_cleanupConfirm => 'Elimini aceste fișiere temporare sigure?';

  @override
  String get t15_cleanupNone =>
      'Nu există fișiere temporare sigure de eliminat.';

  @override
  String get t15_cleanupDone =>
      'Curățarea sigură s-a încheiat. Datele și copiile de recuperare sunt neschimbate.';

  @override
  String get t15_cleanupRefused =>
      'Curățarea nu a putut fi efectuată în siguranță. Toate fișierele rămase sunt păstrate.';

  @override
  String get t15_accessExpired =>
      'Accesul s-a schimbat. Deblochează din nou și începe o operație nouă. Fișierele originale sunt neschimbate.';

  @override
  String get t15_loadFailed =>
      'Aceste detalii sunt temporar indisponibile. Datele sunt păstrate.';

  @override
  String get t15_createBackup => 'Creează o copie';

  @override
  String get t15_checkBackup => 'Verifică o copie';

  @override
  String get t15_backupPurpose =>
      'Un fișier portabil pentru restaurarea datelor. Rapoartele PDF sau CSV nu sunt copii restaurabile.';

  @override
  String get t15_createSubtitle =>
      'Salvează datele disponibile și preferințele aplicației';

  @override
  String get t15_checkSubtitle =>
      'Deschide un fișier fără a modifica datele curente';

  @override
  String get t15_onDevice => 'Pe acest dispozitiv';

  @override
  String get t15_contents => 'Vezi conținutul';

  @override
  String get t15_backupContents =>
      'Rutine, istoricul dozelor, stoc, ciorne, modificări în așteptare și preferințele acceptate. Datele de autentificare și accesul dispozitivului nu sunt incluse.';

  @override
  String get t15_passwordProtected => 'Protejată prin parolă';

  @override
  String get t15_unencrypted => 'Necriptată';

  @override
  String get t15_unencryptedBody => 'Oricine are fișierul îl poate citi.';

  @override
  String get t15_backupPassword => 'Parola copiei';

  @override
  String get t15_confirmPassword => 'Confirmă parola';

  @override
  String get t15_passwordNeeded =>
      'Vei avea nevoie de această parolă pentru restaurare. Simpastil nu o poate recupera.';

  @override
  String get t15_passwordMismatch =>
      'Introdu o parolă și confirmarea identică.';

  @override
  String get t15_noFileSaved => 'Nu s-a salvat niciun fișier.';

  @override
  String get t15_chooseSave => 'Alege locul de salvare';

  @override
  String get t15_chooseBackup => 'Alege fișierul copiei';

  @override
  String get t15_saveChosen => 'Salvează în locul ales';

  @override
  String get t15_openChosen => 'Deschide fișierul ales';

  @override
  String get t15_savedChecked => 'Salvată și verificată pe acest telefon';

  @override
  String get t15_savedUnchecked => 'Salvată, dar neverificată pe acest telefon';

  @override
  String get t15_saveFailed =>
      'Salvarea a eșuat. Fișierul ales poate fi incomplet; datele originale sunt neschimbate.';

  @override
  String get t15_checkFailed =>
      'Fișierul nu a putut fi verificat. Verifică parola și încearcă din nou; datele originale sunt neschimbate.';

  @override
  String get t15_checksPassed => 'Verificările au trecut';

  @override
  String get t15_supportedBackup =>
      'Această copie poate fi deschisă de această versiune Simpastil.';

  @override
  String get t15_currentUnchanged => 'Datele curente sunt neschimbate.';

  @override
  String get t15_reviewRestore => 'Revizuiește opțiunile de restaurare';

  @override
  String get t15_restoreSelection => 'Restaurează sau importă';

  @override
  String get t15_fullRestore => 'Înlocuiește datele curente';

  @override
  String get t15_fullRestoreBody =>
      'Restaurează fișierul complet. Datele curente sunt păstrate într-o copie locală verificată înainte de înlocuire. Revizuiește mai întâi toate persoanele și preferințele afectate.';

  @override
  String get t15_selectedImport => 'Importă persoanele selectate';

  @override
  String get t15_selectedImportBody =>
      'Păstrează datele și preferințele curente. Istoricul în conflict este păstrat pentru revizuire; originalele conectate rămân dovezi ale contului.';

  @override
  String get t15_reviewImport => 'Revizuiește importul';

  @override
  String get t15_applyImport => 'Aplică importul revizuit';

  @override
  String get t15_applyRestore => 'Restaurează copia revizuită';

  @override
  String get t15_confirmReplace =>
      'Am revizuit înlocuirea și necesitatea unei copii verificate.';

  @override
  String get t15_confirmApply => 'Aplici acest plan revizuit?';

  @override
  String get t15_importDone => 'Importul s-a încheiat';

  @override
  String get t15_restoreDone => 'Restaurarea s-a încheiat';

  @override
  String get t15_importFailed =>
      'Modificarea revizuită nu a putut fi finalizată. Datele originale sunt păstrate; începe o revizuire nouă.';

  @override
  String get t15_additions => 'Adăugări';

  @override
  String get t15_identical => 'Deja identice';

  @override
  String get t15_conflicts => 'Conflicte păstrate';

  @override
  String get t15_retained => 'Date păstrate';

  @override
  String get t15_preferencesChanged => 'Preferințe care se modifică';

  @override
  String get t15_alreadyApplied => 'Acest import a fost deja aplicat.';

  @override
  String get t15_projectionPending =>
      'Datele sunt salvate. Actualizarea mementourilor sau a widgetului necesită reîncercare.';

  @override
  String get t15_afterChooser =>
      'După revenirea din selectorul de fișiere, deblochează dacă ți se cere și începe această operație nouă.';

  @override
  String get t15_people => 'Persoane';

  @override
  String get t15_passwordVisibility => 'Arată sau ascunde parola';

  @override
  String get t15_dataCaptured => 'Date capturate';

  @override
  String get t15_affectedPeople => 'Date curente afectate';

  @override
  String get t15_connectedCare => 'Îngrijire conectată';

  @override
  String get t15_localCare => 'Îngrijire locală';

  @override
  String get t15_outcomeAdded => 'Adăugată';

  @override
  String get t15_outcomeMerged => 'Combinată';

  @override
  String get t15_outcomeUnchanged => 'Neschimbată';

  @override
  String get t15_outcomeReview => 'Necesită revizuire';

  @override
  String get t15_outcomeLocked => 'Cont indisponibil';

  @override
  String get t15_outcomeReplaced => 'Înlocuită';

  @override
  String get t15_medications => 'Medicamente';

  @override
  String get t15_routines => 'Rutine';

  @override
  String get t15_history => 'Istoricul dozelor';

  @override
  String get t15_preferences => 'Preferințele aplicației';

  @override
  String get t15_fullDetails => 'Detalii complete';

  @override
  String get t15_fullDetailsBody =>
      'Arată detaliile de îngrijire și acțiunile de revizuire în notificări și widgeturi. Opțiunea este independentă de blocarea aplicației.';

  @override
  String get t15_privateReminders => 'Mementouri private';

  @override
  String get t15_privateBody =>
      'Folosește notificări și widgeturi generice, doar cu Deschide, fără nume de medicamente, numărul dozelor sau acțiuni de înregistrare.';

  @override
  String get t15_reminderCoverage => 'Acoperirea mementourilor';

  @override
  String get t15_coverageShortened =>
      'Sunt programate cele mai apropiate mementouri. Deschide regulat Simpastil pentru a programa mementourile ulterioare.';

  @override
  String get t15_coverageDegraded =>
      'Unele mementouri nu au putut fi programate. Verifică permisiunile pentru notificări, apoi redeschide Simpastil pentru a încerca din nou.';

  @override
  String get t15_coverageNone =>
      'Momentan nu sunt programate mementouri viitoare pentru acest spațiu. Deschide regulat Simpastil pentru a reîmprospăta acoperirea.';

  @override
  String get t15_reminderPeople => 'Persoane incluse pe acest dispozitiv';

  @override
  String get t15_reminderPeopleBody =>
      'Alege mementourile dispozitivului din setările fiecărei persoane în Persoane. Persoanele adăugate pe acest dispozitiv pornesc cu mementourile pornite; cele din contul tău pornesc oprite. Persoana afișată nu schimbă cine primește mementouri.';

  @override
  String get t15_openPeople => 'Deschide Persoane';

  @override
  String get t15_reminderTest => 'Verifică livrarea mementourilor';

  @override
  String get t15_reminderTestBody =>
      'Un test programat nu dovedește livrarea. Confirmă doar dacă vezi notificarea de test.';

  @override
  String get t15_sendTest => 'Trimite o notificare de test';

  @override
  String get t15_testScheduled => 'Test programat · livrare neconfirmată';

  @override
  String get t15_testObserved => 'Ai confirmat că ai văzut testul';

  @override
  String get t15_testFailed =>
      'Testul nu a putut fi programat. Verifică mai jos permisiunile notificărilor și alarmelor.';

  @override
  String get t15_confirmObserved => 'Am văzut notificarea de test';

  @override
  String get t15_backupContentsShort =>
      'Rutine, istoricul dozelor, stoc și preferințele aplicației';

  @override
  String t15_retainedPeopleCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count de persoane păstrate',
      few: '$count persoane păstrate',
      one: '1 persoană păstrată',
    );
    return '$_temp0';
  }

  @override
  String get t15_backupProtection => 'Protecție';

  @override
  String get t15_differentDoseRecords =>
      'Înregistrări diferite pentru aceeași doză';

  @override
  String get t15_onThisDevice => 'Pe acest dispozitiv';

  @override
  String get t15_inBackup => 'În copia de siguranță';

  @override
  String get t15_reviewDifference => 'Revizuiește diferența';

  @override
  String get t15_differenceBody =>
      'Aceste date sunt păstrate separat pentru revizuire. Deschiderea detaliilor nu înregistrează o doză, nu alege o variantă și nu aplică importul.';

  @override
  String get t15_timeUnknown => 'Ora necunoscută';

  @override
  String get t15_notRecorded => 'Neînregistrată';

  @override
  String get t15_taken => 'Luată';

  @override
  String get t15_skipped => 'Omisă';

  @override
  String get t15_fileIntegrity => 'Integritatea fișierului';

  @override
  String get t15_backupFormat => 'Formatul copiei';

  @override
  String get t15_passed => 'Verificată';

  @override
  String get t15_supported => 'Compatibil';

  @override
  String get t15_howRestore => 'Cum restaurezi';

  @override
  String t15_selectedPeopleCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count de persoane selectate',
      few: '$count persoane selectate',
      one: '1 persoană selectată',
    );
    return '$_temp0';
  }

  @override
  String get t15_notImported => 'Nimic importat încă.';

  @override
  String get t15_applying => 'Se aplică copia de siguranță verificată…';

  @override
  String get t15_noChangeBeforeApply =>
      'Nimic nu se schimbă până când verifici și aplici.';

  @override
  String get legacyReview_title => 'Verifică orele programelor vechi';

  @override
  String get legacyReview_entry => 'Verifică orele programelor împreună';

  @override
  String get legacyReview_entryHint =>
      'Confirmă fusul orar, păstrând orele și zilele salvate.';

  @override
  String get legacyReview_intro =>
      'Alege fusul orar al orelor salvate. Verifică fiecare program de mai jos, apoi confirmă o singură dată.';

  @override
  String get legacyReview_zone => 'Fusul orar al orelor salvate';

  @override
  String get legacyReview_bucharest => 'București, România';

  @override
  String legacyReview_device(String zone) {
    return 'Ora dispozitivului ($zone)';
  }

  @override
  String get legacyReview_from => 'Aplică începând cu';

  @override
  String legacyReview_boundary(String date, String zone) {
    return 'Se aplică de la miezul nopții din $date, în $zone. Orele, zilele și înregistrările anterioare se păstrează.';
  }

  @override
  String legacyReview_ready(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count de programe gata de verificat',
      few: '$count programe gata de verificat',
      one: '1 program gata de verificat',
    );
    return '$_temp0';
  }

  @override
  String legacyReview_next(String date) {
    return 'Următoarea doză planificată: $date';
  }

  @override
  String get legacyReview_inactive => 'În pauză · rămâne în pauză';

  @override
  String legacyReview_invalid(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count de programe omise: zilele salvate necesită verificare individuală.',
      few:
          '$count programe omise: zilele salvate necesită verificare individuală.',
      one: '1 program omis: zilele salvate necesită verificare individuală.',
    );
    return '$_temp0';
  }

  @override
  String legacyReview_unavailable(int count) {
    return 'Programe omise: $count. Au modificări în așteptare, o editare anterioară sau detalii incomplete. Sincronizează și verifică-le individual.';
  }

  @override
  String get legacyReview_noChanges =>
      'Niciun program nu este pregătit pentru acest lot. Verificările existente rămân disponibile în Date.';

  @override
  String legacyReview_confirm(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Confirmă orele pentru $count de programe',
      few: 'Confirmă orele pentru $count programe',
      one: 'Confirmă ora unui program',
    );
    return '$_temp0';
  }

  @override
  String get legacyReview_retry => 'Reîncearcă această verificare';

  @override
  String legacyReview_saved(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count de programe acceptate de server. Vor apărea după următoarea sincronizare reușită.',
      few:
          '$count programe acceptate de server. Vor apărea după următoarea sincronizare reușită.',
      one:
          '1 program acceptat de server. Va apărea după următoarea sincronizare reușită.',
    );
    return '$_temp0';
  }

  @override
  String legacyReview_partial(int accepted, int total) {
    return '$accepted din $total programe acceptate. Păstrează această verificare pentru a reîncerca restul cu aceleași opțiuni.';
  }

  @override
  String get legacyReview_loadError =>
      'Verificarea nu a putut fi încărcată. Sincronizează datele, apoi încearcă din nou.';

  @override
  String get legacyReview_applyError =>
      'Serverul nu a putut confirma toate modificările. Reîncearcă verificarea sau revino la Date pentru sincronizare.';

  @override
  String get legacyReview_scope =>
      'Această verificare stabilește doar fusurile orare ale programelor. Celelalte modificări nerezolvate necesită în continuare verificare.';

  @override
  String get review_openRecovery =>
      'Așteaptă în „Rezolvă problemele de sincronizare”, unde o poți rezolva. Detaliile sunt păstrate.';

  @override
  String get sync_connectionAccessUnavailable =>
      'Conexiunea salvată necesită atenție. Verific-o și conectează-te la același cont dacă ți se cere.';

  @override
  String get sync_reviewConnection => 'Verifică conexiunea';

  @override
  String get review_incompleteDetails =>
      'Revizuirea nu este disponibilă pentru acest element. Detaliile salvate sunt păstrate mai jos.';

  @override
  String get review_errorChanged =>
      'Această revizuire s-a modificat sau nu mai este pregătită. Sincronizează, apoi deschide-o din nou.';

  @override
  String get review_errorSignIn =>
      'Autentifică-te din nou înainte de a trimite această revizuire.';

  @override
  String get review_errorMissing =>
      'Aceste detalii de revizuire nu mai sunt disponibile. Sincronizează, apoi verifică elementele rămase.';

  @override
  String get review_errorValidation =>
      'Verifică opțiunile revizuirii și fusul orar, apoi încearcă din nou.';

  @override
  String get review_errorRateLimit =>
      'Prea multe cereri. Așteaptă puțin înainte de a trimite din nou această revizuire.';

  @override
  String get review_errorServer =>
      'Serverul nu a putut confirma această revizuire. Sincronizează pentru a-i verifica starea înainte de a reîncerca.';

  @override
  String get review_errorConnection =>
      'Serverul nu a putut fi contactat. Verifică conexiunea, apoi sincronizează pentru a verifica revizuirea înainte de a reîncerca.';

  @override
  String get review_errorUnknown =>
      'Această revizuire nu a putut fi confirmată. Detaliile sunt păstrate; sincronizează înainte de a o revizui din nou.';

  @override
  String get prn_reviewAmbiguous =>
      'Sunt active mai multe programe la nevoie. Revizuiește-le înainte de a înregistra.';

  @override
  String get prn_reviewRoutine =>
      'Acest program la nevoie este întrerupt sau necesită revizuire. Verifică detaliile salvate înainte de a înregistra.';

  @override
  String get prn_reviewZone =>
      'Confirmă fusul orar al acestui program înainte de a înregistra.';

  @override
  String get prn_openReview => 'Deschide Date pentru revizuire';

  @override
  String get t10_sharingReconciled =>
      'Revizuit · trimiterea inițială este neconfirmată';

  @override
  String get schedules_restorePrnTitle => 'Restabilește rutina la nevoie';

  @override
  String get schedules_restorePrnExplanation =>
      'Activează această rutină salvată la nevoie în fusul orar de mai jos. Înregistrările anterioare sunt păstrate.';

  @override
  String get schedules_restorePrnZone =>
      'Fus orar pentru înregistrarea la nevoie';

  @override
  String get sync_todayAttention =>
      'Unele înregistrări necesită atenție · Deschide Sincronizare';

  @override
  String get sync_todayUnverified =>
      'Înregistrările serverului nu au fost verificate · Deschide Sincronizare';

  @override
  String get sync_todayPending =>
      'Modificări salvate pe acest telefon · În așteptarea sincronizării';

  @override
  String sync_retainedRemovedRecords(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count de înregistrări se referă la medicamente sau programe eliminate. Informațiile originale sunt păstrate; nu există aici nicio modificare de revizuit.',
      few:
          '$count înregistrări se referă la medicamente sau programe eliminate. Informațiile originale sunt păstrate; nu există aici nicio modificare de revizuit.',
      one:
          '1 înregistrare se referă la un medicament sau program eliminat. Informațiile originale sunt păstrate; nu există aici nicio modificare de revizuit.',
    );
    return '$_temp0';
  }

  @override
  String sync_retainedHistory(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count de înregistrări istorice sunt păstrate ca informații. Ora inițială sau efectul asupra stocului pot fi incerte; nu necesită o nouă decizie despre administrare.',
      few:
          '$count înregistrări istorice sunt păstrate ca informații. Ora inițială sau efectul asupra stocului pot fi incerte; nu necesită o nouă decizie despre administrare.',
      one:
          '1 înregistrare istorică este păstrată ca informație. Ora inițială sau efectul asupra stocului pot fi incerte; nu necesită o nouă decizie despre administrare.',
    );
    return '$_temp0';
  }

  @override
  String get backup_unattributed =>
      'O copie completă păstrează și înregistrările vechi a căror persoană nu mai poate fi stabilită. La restaurare, acestea rămân dovezi inactive, fără a fi atribuite cuiva sau trimise la server.';

  @override
  String get review_choiceAccepted =>
      'Alegerea a fost acceptată de server. Revizuirea dispare după sincronizarea confirmării pe acest telefon.';

  @override
  String get sc_allRecorded => 'Totul este înregistrat pentru azi';

  @override
  String sc_skyLabel(int recorded, int total, String next) {
    return 'Cerul zilei: $recorded din $total înregistrate, următoarea la $next';
  }

  @override
  String sc_skyNoNext(int recorded, int total) {
    return 'Cerul zilei: $recorded din $total înregistrate';
  }

  @override
  String sc_sunNext(String time, String person, String medication) {
    return 'Urmează: $time · $person · $medication';
  }

  @override
  String get sc_sunNone => 'Nimic altceva programat azi';

  @override
  String get sc_showNextDose => 'Arată următoarea doză';

  @override
  String get sc_readNextDose => 'Citește ce urmează';

  @override
  String get sc_pullToShare => 'Trage pentru a sincroniza acum';

  @override
  String get sc_sharedJustNow => 'Sincronizat chiar acum';

  @override
  String get sc_savedOnDevice => 'Salvat pe acest dispozitiv';

  @override
  String get sc_saving => 'Se salvează…';

  @override
  String sc_stockLeft(int n) {
    return '$n rămase';
  }

  @override
  String get lay_timeline => 'Cronologie';

  @override
  String get lay_peopleLanes => 'Pe persoane';

  @override
  String get lay_dayPlanner => 'Agenda zilei';

  @override
  String get lay_actionInbox => 'De rezolvat';

  @override
  String get lay_dailyJournal => 'Jurnalul zilei';

  @override
  String get lay_focusDeckBody =>
      'O doză pe rând, cu anterioara, următoarea și ziua dintr-o privire.';

  @override
  String get lay_timelineBody =>
      'Toată ziua în ordinea orelor, cu soarele arătând momentul de acum.';

  @override
  String get lay_peopleLanesBody =>
      'Îngrijirea fiecărei persoane pe un rând separat.';

  @override
  String get lay_dayPlannerBody => 'Ziua ca o agendă, oră cu oră.';

  @override
  String get lay_actionInboxBody =>
      'Întâi ce mai trebuie înregistrat, apoi separat dozele înregistrate.';

  @override
  String get lay_dailyJournalBody =>
      'Ziua ca o relatare a îngrijirii și a notițelor.';

  @override
  String get lay_intro =>
      'Alege cum este aranjat ecranul Astăzi. Culorile, persoana și data alese rămân la fel. Alegerea se păstrează doar pe acest dispozitiv.';

  @override
  String get lay_inUse => 'Folosit acum';

  @override
  String get lay_notReady => 'Încă indisponibil';

  @override
  String get lay_notReadyBody =>
      'Acest aspect este încă în lucru. Astăzi rămâne pe Carduri Focus până când va fi gata.';

  @override
  String get lay_preview => 'Previzualizare';

  @override
  String lay_previewOf(String name) {
    return 'Previzualizare: $name';
  }

  @override
  String get lay_previewNotice =>
      'Zi exemplu cu medicamente fictive. Nimic din ce atingi aici nu se înregistrează.';

  @override
  String lay_use(String name) {
    return 'Folosește aspectul „$name”';
  }

  @override
  String lay_applied(String name) {
    return 'Astăzi folosește acum aspectul „$name”.';
  }

  @override
  String get lay_saveError =>
      'Aspectul nu a putut fi salvat, deci nu s-a schimbat nimic. Încearcă din nou.';

  @override
  String get lay_exampleMorning => 'Comprimat de dimineață';

  @override
  String get lay_exampleNoon => 'Vitamina D';

  @override
  String get lay_exampleEvening => 'Comprimat de seară';

  @override
  String lay_now(String time) {
    return 'Acum, $time';
  }

  @override
  String lay_quietHours(String from, String to) {
    return 'Nimic planificat · $from – $to';
  }

  @override
  String get lay_showDetails => 'Arată detaliile';

  @override
  String get lay_hideDetails => 'Ascunde detaliile';

  @override
  String lay_itemLabel(String time, String medication, String state) {
    return '$time, $medication, $state';
  }

  @override
  String get ibx_needsYou => 'Te așteaptă';

  @override
  String get ibx_recordedToday => 'Înregistrate azi';

  @override
  String get ibx_needsNone => 'Nimic nu te așteaptă acum.';

  @override
  String get ibx_recordedNone => 'Nimic înregistrat încă.';

  @override
  String ibx_movedRecorded(String medication) {
    return '$medication a trecut la Înregistrate azi.';
  }

  @override
  String ibx_movedNeeds(String medication) {
    return '$medication s-a întors la Te așteaptă.';
  }

  @override
  String get jrn_morning => 'Dimineața';

  @override
  String get jrn_afternoon => 'După-amiaza';

  @override
  String get jrn_evening => 'Seara';

  @override
  String get jrn_night => 'Noaptea';

  @override
  String get supply_title => 'Rezervă';

  @override
  String supply_until(String date) {
    return 'Ajunge până $date';
  }

  @override
  String supply_cardUntil(String date) {
    return 'Până $date';
  }

  @override
  String supply_refillBy(String date) {
    return 'Reînnoiește până $date ca să rămâi peste pragul de stoc redus';
  }

  @override
  String get supply_pastHorizon => 'Ajunge pentru mai mult de două luni';

  @override
  String get supply_shortToday => 'Nu ajunge pentru dozele rămase azi';

  @override
  String supply_shortOn(String date) {
    return 'Nu mai ajunge din $date';
  }

  @override
  String get supply_none => 'Nu mai sunt doze';

  @override
  String get supply_estimateNote =>
      'Estimare după rutină, câte o doză la fiecare oră planificată. Dozele luate în afara ei o schimbă.';

  @override
  String jrn_periodSummary(String period, int recorded, int total) {
    return '$period, $recorded din $total înregistrate';
  }

  @override
  String jrn_took(String time, String person, String medication) {
    return '$time · $person a luat $medication';
  }

  @override
  String jrn_tookUnknown(String person, String medication) {
    return '$person a luat $medication · ora nu se știe';
  }

  @override
  String jrn_skipped(String time, String person, String medication) {
    return '$time · $person a omis $medication';
  }

  @override
  String jrn_skippedUnknown(String person, String medication) {
    return '$person a omis $medication · ora nu se știe';
  }

  @override
  String jrn_planned(String time, String person, String medication) {
    return 'Planificat $time · $person să ia $medication';
  }

  @override
  String get mf_previewPlaceholder => 'Medicamentul tău';

  @override
  String get mf_sectionWhat => 'Ce este';

  @override
  String get mf_sectionWhatHint =>
      'Un nume pe care îl recunoști și forma în care vine.';

  @override
  String get mf_sectionDose => 'La fiecare doză';

  @override
  String get mf_sectionLook => 'Cum arată';

  @override
  String get mf_sectionLookHint =>
      'Culoarea aceasta îl însoțește în Azi și Medicamente.';

  @override
  String get mf_sectionSupply => 'Stoc';

  @override
  String get mf_sectionNotes => 'De reținut';

  @override
  String get mf_sectionWho => 'Cine îl ia';

  @override
  String get mf_sectionWhen => 'Când';

  @override
  String get mf_sectionRepeat => 'Repetare';

  @override
  String mf_colorSwatch(String color) {
    return 'Culoarea $color';
  }

  @override
  String get mf_nameNeeded => 'Adaugă un nume ca să îl găsești ușor.';

  @override
  String get mf_numberNeeded => 'Folosește un număr întreg, de exemplu 30.';

  @override
  String get mf_fewer => 'Cu unul mai puțin';

  @override
  String get mf_more => 'Cu unul în plus';

  @override
  String get mf_colourAfterSave =>
      'Își primește culoarea proprie după salvare.';

  @override
  String mf_skyTime(String time, String part) {
    return '$time, $part';
  }

  @override
  String schedules_dialLabel(String times) {
    return 'Orele dozelor pe cadranul zilei: $times';
  }

  @override
  String get blister_label => 'Stocul medicamentelor';

  @override
  String blister_cellFull(String name, int stock) {
    return '$name, $stock rămase';
  }

  @override
  String blister_cellRefill(String name, int stock) {
    return '$name, e timpul să reînnoiești, $stock rămase';
  }

  @override
  String blister_cellEmpty(String name) {
    return '$name, nu mai sunt';
  }

  @override
  String blister_cellUntracked(String name) {
    return '$name, stocul nu este urmărit';
  }

  @override
  String get blister_show => 'arată în listă';

  @override
  String get blister_fine => 'Stocul este în regulă';

  @override
  String blister_refill(String names) {
    return 'De reînnoit curând: $names';
  }

  @override
  String blister_empty(String names) {
    return 'Nu mai sunt: $names';
  }

  @override
  String get mf_tapToChange => 'Atinge pentru a schimba';

  @override
  String get mf_daysNeeded => 'Alege cel puțin o zi.';

  @override
  String get mf_personHint =>
      'Numele pe care îl folosești pentru persoană este suficient.';

  @override
  String get mf_personFace => 'Un chip pentru medicamentele persoanei';

  @override
  String get r4_recoveryChecked => 'Verificată';

  @override
  String get r4_recoveryNone => 'Încă nu există';

  @override
  String get r4_recoveryUnchecked => 'Neverificată';

  @override
  String get r4_spaceUsed => 'Spațiu folosit';

  @override
  String get r4_cleanupGroup => 'Curățare';

  @override
  String get r4_syncReviewGroup => 'De revizuit';

  @override
  String get r4_syncDetails => 'Arată detaliile sincronizării';

  @override
  String r6_notifDoseBody(String dosage) {
    return '$dosage, când ești gata';
  }

  @override
  String get r6_notifNoDoseBody => 'Când ești gata.';

  @override
  String r6_notifStillTitle(String pillName) {
    return '$pillName încă te așteaptă';
  }

  @override
  String r6_notifStillBody(String dosage) {
    return '$dosage, doar dacă nu ai apucat încă';
  }

  @override
  String get r6_notifStillNoDoseBody => 'Doar dacă nu ai apucat încă.';

  @override
  String get r6_notifSubText => 'Memento doză';

  @override
  String get r6_permBody =>
      'Simpastil îți poate da un semn discret când e timpul pentru o doză. Îngrijirea rămâne salvată oricum.';

  @override
  String get r6_whyNudge => 'Un semn liniștit la fiecare oră programată';

  @override
  String get r6_whyActions =>
      'Marchează ca luat sau amână direct din notificare';

  @override
  String get r6_whyPrivacy => 'Tu alegi dacă numele apar pe ecranul blocat';

  @override
  String get r6_whyNothingRecorded =>
      'Nimic nu se înregistrează până nu spui tu';

  @override
  String get r6_sampleMedicine => 'medicamentul tău';

  @override
  String get r6_sampleDose => '1 comprimat';

  @override
  String get r6_previewNow => 'acum';

  @override
  String r6_previewSemantics(String title, String body) {
    return 'Exemplu de memento: $title. $body';
  }

  @override
  String get r6_statusTitle => 'Acest dispozitiv';

  @override
  String get r6_statusChecking => 'Se verifică dispozitivul';

  @override
  String get r6_statusOn => 'Mementouri active';

  @override
  String get r6_statusOnBody =>
      'Acest dispozitiv poate afișa mementourile la ora programată.';

  @override
  String get r6_statusNeedsPermission => 'Necesită permisiune';

  @override
  String get r6_statusNeedsPermissionBody =>
      'Notificările sunt oprite pentru Simpastil, deci mementourile nu vor apărea. Îngrijirea rămâne salvată.';

  @override
  String get r6_statusMayBeLate => 'Pot întârzia';

  @override
  String get r6_statusMayBeLateBody =>
      'Alarmele exacte sunt oprite, așa că Android poate întârzia mementourile.';

  @override
  String get r6_statusSomeMissing => 'Unele neprogramate';

  @override
  String get r6_statusUnavailable => 'Indisponibile aici';

  @override
  String get r6_statusUnavailableBody =>
      'Acest dispozitiv nu poate afișa mementouri. Îngrijirea rămâne salvată.';

  @override
  String get r6_privacyNames => 'Nume afișate';

  @override
  String get r6_privacyPrivate => 'Private';

  @override
  String get r6_dayTitle => 'Ziua ta cu mementouri';

  @override
  String get r6_dayBody => 'Mementourile urmează orele din rutină.';

  @override
  String get r6_dayEmpty =>
      'Încă nu există ore programate. Adaugă o rutină pentru a primi mementouri.';

  @override
  String get r6_dayEdit => 'Schimbă orele în Rutină';

  @override
  String get r8_syncNotConnected => 'Neconectat la un server';

  @override
  String get r8_peopleManageGroup => 'Adaugă și gestionează';

  @override
  String get r8_peopleRemoveGroup => 'Elimină';

  @override
  String r8_lowStockTitle(String pillName) {
    return '$pillName se apropie de final';
  }

  @override
  String r8_lowStockBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Au rămas $count de doze',
      few: 'Au rămas $count doze',
      one: 'A rămas 1 doză',
    );
    return '$_temp0';
  }

  @override
  String get r8_editingPalette => 'Editezi paleta pentru:';

  @override
  String get r8_paletteNote =>
      'Aici alegi doar ce culori editezi. Nu comută aplicația între luminos și întunecat.';

  @override
  String get r10_statusNobodyOn => 'Nicio persoană activată';

  @override
  String get r10_statusNobodyOnBody =>
      'Dispozitivul permite mementouri, dar nicio persoană nu este activată aici, așa că nu sunt programate mementouri, iar widgetul de pe ecranul principal rămâne gol.';

  @override
  String get r10_peopleHintNone => 'Activează o persoană pe acest dispozitiv';

  @override
  String r10_peopleHintSome(int on, int total) {
    return 'Active pentru $on din $total persoane pe acest dispozitiv';
  }

  @override
  String get r10_peopleHintBody =>
      'În Persoane, deschide meniul unei persoane și alege Mementouri pe acest dispozitiv.';

  @override
  String get lay_nothingDueYet => 'Nimic de luat încă';

  @override
  String get rv_launchTitle => 'Datele din versiunea anterioară te așteaptă';

  @override
  String get rv_launchBody =>
      'Medicamentele, programările și istoricul tău sunt în siguranță pe acest dispozitiv. Autentifică-te pe serverul folosit înainte ca să continui de unde ai rămas.';

  @override
  String get rv_launchSignIn => 'Autentifică-te pe serverul inițial';

  @override
  String get rv_launchReview => 'Verifică serverul inițial';

  @override
  String get rv_launchLocal =>
      'Configurează în schimb o îngrijire nouă pe acest dispozitiv';

  @override
  String get rv_reviewTitle => 'Confirmă serverul inițial';

  @override
  String get rv_reviewBody =>
      'Îngrijirea salvată de versiunea anterioară aparține unui cont de pe un anumit server. Confirmă că acesta este serverul folosit înainte. Dacă nu este, deconectează-te și nu se schimbă nimic.';

  @override
  String get rv_reviewAddress => 'Adresa serverului';

  @override
  String get rv_reviewConfirm => 'Da, acesta este serverul meu inițial';

  @override
  String get rv_reviewReject => 'Nu, deconectează-mă';

  @override
  String get rv_reviewError =>
      'Verificarea nu a putut fi finalizată. Încearcă din nou.';

  @override
  String get r08_connectedTitle => 'Ești conectat';

  @override
  String get r08_connectedBody =>
      'Adaugă prima persoană pe care o ajuți. Rutina ei se va sincroniza cu serverul tău.';

  @override
  String get r08_connectedCard => 'Sincronizat cu serverul tău';

  @override
  String get r08_connectedStart => 'Adaugă prima persoană';

  @override
  String r09_checkWaiting(int seconds) {
    return 'Se așteaptă mementoul… $seconds s';
  }

  @override
  String get r09_checkWaitingHint =>
      'Poate dura până la 15 secunde. Ține acest ecran deschis.';

  @override
  String get r09_checkQuestion => 'Ai văzut mementoul pe acest telefon?';

  @override
  String get r09_checkYes => 'Da, l-am văzut';

  @override
  String get r09_checkNo => 'Nu, nu l-am văzut';

  @override
  String get r09_checkNoHelp =>
      'Verifică dacă notificările Simpastil sunt activate și dacă Nu deranja sau economisirea bateriei nu le blochează, apoi trimite o nouă verificare.';

  @override
  String get thread_sending => 'Se trimit modificările către server…';

  @override
  String get thread_settled => 'La zi cu serverul';

  @override
  String get thread_falteredSaved =>
      'Ultima sincronizare nu s-a încheiat · Modificările rămân pe acest telefon';

  @override
  String get thread_faltered =>
      'Ultima sincronizare nu s-a încheiat · Deschide Sincronizare';

  @override
  String get auth_stepVerification => 'PASUL 4 — VERIFICARE';

  @override
  String story_plannedFor(Object time) {
    return 'Planificat pentru $time';
  }

  @override
  String story_takenAt(Object time) {
    return 'Luat la $time';
  }

  @override
  String story_skippedAt(Object time) {
    return 'Omis la $time';
  }

  @override
  String get story_recordedNoTime => 'Înregistrat, ora necunoscută';

  @override
  String get story_notYet => 'Încă neînregistrat';

  @override
  String get story_onTime => 'La ora planificată';

  @override
  String story_after(Object duration) {
    return '$duration după plan';
  }

  @override
  String story_before(Object duration) {
    return '$duration înainte de plan';
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
  String get recovery_title => 'Rezolvă problemele de sincronizare';

  @override
  String get recovery_entryHintNone => 'Nu e nimic de rezolvat acum';

  @override
  String recovery_entryHint(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count de modificări au nevoie de tine',
      few: '$count modificări au nevoie de tine',
      one: '1 modificare are nevoie de tine',
    );
    return '$_temp0';
  }

  @override
  String recovery_entryNotes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count de note păstrate de verificat',
      few: '$count note păstrate de verificat',
      one: '1 notă păstrată de verificat',
    );
    return '$_temp0';
  }

  @override
  String get recovery_entryChecking => 'Verifică problemele de sincronizare';

  @override
  String get recovery_intro =>
      'Aceste modificări au fost făcute pe acest telefon și nu au ajuns încă pe server. Niciuna nu se pierde: fiecare rămâne aici până e trimisă sau până decizi altfel.';

  @override
  String get recovery_nothingTitle => 'Nu e nimic de rezolvat';

  @override
  String get recovery_nothingBody =>
      'Toate modificările tale au fost trimise pe server.';

  @override
  String get recovery_waitingOnly =>
      'Acestea se vor trimite singure. Nu trebuie să faci nimic.';

  @override
  String get recovery_loadFailed =>
      'Lista modificărilor netrimise nu a putut fi încărcată.';

  @override
  String get recovery_groupChanges => 'Modificări netrimise';

  @override
  String get recovery_groupTools => 'Mai multe opțiuni';

  @override
  String get recovery_kindPerson => 'Persoană';

  @override
  String get recovery_kindMedication => 'Medicament';

  @override
  String get recovery_kindSchedule => 'Program';

  @override
  String get recovery_kindDose => 'Doză';

  @override
  String get recovery_kindOther => 'Modificare';

  @override
  String get recovery_unnamed => 'Nu mai e pe acest telefon';

  @override
  String get recovery_changeAdded => 'Adăugat pe acest telefon';

  @override
  String get recovery_changeEdited => 'Modificat pe acest telefon';

  @override
  String get recovery_changeRemoved => 'Șters de pe acest telefon';

  @override
  String get recovery_changeDose => 'Doză înregistrată';

  @override
  String get recovery_changeStock => 'Stoc modificat';

  @override
  String get recovery_changeOther => 'Modificat pe acest telefon';

  @override
  String get recovery_reasonQueued => 'Așteaptă să fie trimis';

  @override
  String recovery_reasonRetrying(String time) {
    return 'Serverul nu a putut fi contactat. Se reîncearcă la $time.';
  }

  @override
  String get recovery_reasonRetryingSoon =>
      'Serverul nu a putut fi contactat. Se reîncearcă în curând.';

  @override
  String get recovery_reasonBlocked => 'Nu poate fi trimis în forma actuală.';

  @override
  String get recovery_reasonConflict => 'A fost modificat și pe server.';

  @override
  String get recovery_reasonConflictSettled =>
      'A fost modificat și pe server. Versiunea serverului este deja afișată aici.';

  @override
  String get recovery_reasonStranded => 'Așteaptă o altă modificare blocată.';

  @override
  String get recovery_reasonWaitingForStart =>
      'Așteaptă trimiterea mai întâi a stocului inițial al acestui medicament.';

  @override
  String get recovery_reasonStartStuck =>
      'Reținută în spatele stocului inițial al acestui medicament, care necesită mai întâi o decizie. Deschide stocul inițial ca să o rezolvi.';

  @override
  String get recovery_reasonReview =>
      'Necesită o decizie. Încearcă din nou sau renunță la ea.';

  @override
  String get recovery_blockedBodyChanged =>
      'A fost modificat după prima încercare, așa că nu poate fi repetat în siguranță.';

  @override
  String get recovery_blockedExhausted =>
      'Serverul nu a putut fi contactat după mai multe încercări.';

  @override
  String get recovery_blockedUndo =>
      'Acest server nu poate anula încă această acțiune.';

  @override
  String get recovery_blockedGeneric =>
      'Serverul sau acest telefon nu l-a putut accepta în forma actuală.';

  @override
  String get reminders_resetGroup => 'Reparare';

  @override
  String get reminders_resetTitle => 'Resetează mementourile';

  @override
  String get reminders_resetHint =>
      'Șterge toate mementourile setate pe acest dispozitiv și le setează din nou din programările tale. Medicamentele și istoricul nu sunt modificate.';

  @override
  String get reminders_resetConfirmBody =>
      'Aceasta șterge toate mementourile de pe acest dispozitiv și le setează din nou. Folosește-o dacă un memento sună de două ori sau deloc.';

  @override
  String get reminders_resetAction => 'Resetează';

  @override
  String reminders_resetDone(int count) {
    return 'Mementourile au fost resetate. $count setate din nou.';
  }

  @override
  String get reminders_resetNeedsPermission =>
      'Permite mai întâi notificările și alarmele exacte, apoi resetează mementourile.';

  @override
  String get reminders_resetFailed =>
      'Mementourile nu au putut fi resetate. Încearcă din nou în câteva clipe.';

  @override
  String get reminders_resetRegistryUnreadable =>
      'Înregistrările mementourilor de pe acest dispozitiv nu au putut fi citite, așa că nu s-a modificat nimic. Medicamentele și istoricul sunt în siguranță.';

  @override
  String get reminders_resetRestoring =>
      'Mementourile se setează din nou. Poate dura câteva clipe.';

  @override
  String reminders_auditStatus(String when, int count) {
    return 'Ultima verificare: $when. Mementouri în plus șterse: $count.';
  }

  @override
  String reminders_auditDeferred(String when) {
    return 'Ultima verificare: $when. Nu s-a putut încheia și va fi reluată.';
  }

  @override
  String get reminders_auditPartial =>
      ' O parte din îngrijirea comună a fost lăsată deoparte de data aceasta.';

  @override
  String get recovery_retryAll => 'Reîncearcă toate';

  @override
  String get recovery_retryAllHint =>
      'Încearcă din nou fiecare modificare blocată, apoi verifică serverul.';

  @override
  String get recovery_useServer => 'Folosește versiunea serverului';

  @override
  String get recovery_keepMine => 'Păstrează modificarea mea';

  @override
  String get recovery_dismiss => 'Ignoră';

  @override
  String get recovery_tryAgain => 'Încearcă din nou';

  @override
  String get recovery_discard => 'Renunță la această modificare';

  @override
  String get recovery_discardTitle => 'Renunți la această modificare?';

  @override
  String recovery_discardDoseBody(String name) {
    return 'Doza înregistrată pe acest telefon pentru $name nu a fost acceptată de server. Va fi eliminată, iar doza va apărea așa cum o are serverul. Modificările care nu depind de ea vor fi apoi trimise. Nu se poate anula.';
  }

  @override
  String recovery_discardStockBody(String name) {
    return 'Modificarea de stoc făcută pe acest telefon pentru $name nu a ajuns la server. Va fi eliminată, iar stocul va apărea așa cum îl are serverul. Modificările care nu depind de ea vor fi apoi trimise. Nu se poate anula.';
  }

  @override
  String recovery_discardOtherBody(String name) {
    return 'Această modificare pentru $name nu a ajuns la server. Va fi eliminată, iar ce nu depinde de ea va fi trimis. Nu se poate anula.';
  }

  @override
  String get recovery_doneTryAgain =>
      'Am încercat din nou. Ce rămâne blocat rămâne în această listă.';

  @override
  String get recovery_doneDiscard =>
      'S-a renunțat la ea. Ce aștepta în spatele ei se trimite acum.';

  @override
  String get recovery_groupNotes => 'Note păstrate';

  @override
  String get recovery_noteTitle => 'Notă dintr-o sincronizare anterioară';

  @override
  String get recovery_noteBody =>
      'Ceva a fost păstrat pentru verificare. Nu blochează nimic, iar detaliile sunt păstrate.';

  @override
  String recovery_discardCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'În total vor fi eliminate $count de modificări, inclusiv cele care depind de ea.',
      few:
          'În total vor fi eliminate $count modificări, inclusiv cele care depind de ea.',
    );
    return '$_temp0';
  }

  @override
  String get recovery_discardHistory =>
      'Acesta a fost adăugat pe acest telefon și are deja istoric de doze, deci nu poate fi eliminat. Încearcă din nou trimiterea.';

  @override
  String get recovery_useServerTitle => 'Folosești versiunea serverului?';

  @override
  String recovery_useServerBody(String name) {
    return 'Modificarea netrimisă pentru $name va fi eliminată, iar versiunea serverului o va înlocui. Acțiunea nu poate fi anulată.';
  }

  @override
  String recovery_useServerCreateBody(String name) {
    return '$name a fost adăugat doar pe acest telefon. Va fi șters de pe acest telefon împreună cu modificările care îl așteaptă. Acțiunea nu poate fi anulată.';
  }

  @override
  String get recovery_keepMineTitle => 'Păstrezi modificarea ta?';

  @override
  String recovery_keepMineBody(String name) {
    return 'Modificarea ta pentru $name va fi trimisă din nou peste cea mai recentă versiune a serverului. Ce s-a schimbat între timp pe server va fi suprascris.';
  }

  @override
  String get recovery_redownload => 'Descarcă din nou de pe server';

  @override
  String get recovery_redownloadHint =>
      'Descarcă din nou tot de pe server. Modificările netrimise rămân.';

  @override
  String get recovery_redownloadTitle => 'Descarci din nou tot?';

  @override
  String get recovery_redownloadBody =>
      'Mai întâi se trimit modificările în așteptare, apoi se descarcă din nou tot. Modificările care încă așteaptă pe acest telefon sunt păstrate și nu sunt niciodată suprascrise. Poate folosi mai multe date.';

  @override
  String get recovery_copyDiagnostics => 'Copiază diagnosticul';

  @override
  String get recovery_copyDiagnosticsHint =>
      'Doar numere și coduri: fără nume, note sau adrese.';

  @override
  String get recovery_copied => 'Diagnosticul a fost copiat';

  @override
  String get recovery_doneRetry =>
      'Am încercat din nou. Ce rămâne blocat rămâne în această listă.';

  @override
  String get recovery_doneServer => 'Gata. Se folosește versiunea serverului.';

  @override
  String get recovery_doneKeep => 'Modificarea ta va fi trimisă din nou.';

  @override
  String get recovery_doneDismiss => 'Ignorat.';

  @override
  String get recovery_doneRedownload => 'Descărcat din nou de pe server.';

  @override
  String get recovery_busy =>
      'O sincronizare rulează deja. Încearcă din nou peste câteva clipe.';

  @override
  String get recovery_failed => 'Nu a mers. Nu s-a pierdut nimic.';

  @override
  String get recovery_refusedSending =>
      'O modificare se trimite chiar acum. Încearcă din nou peste câteva clipe.';

  @override
  String get recovery_refusedGone => 'Rezolvat deja.';

  @override
  String get recovery_refusedNotDiscardable =>
      'Aici nu există nimic de eliminat.';

  @override
  String get recovery_refusedOffline =>
      'Serverul nu poate fi contactat acum, așa că modificarea ta a fost păstrată. Încearcă din nou când ești online.';

  @override
  String get recovery_serverCopyPending =>
      'Modificarea ta a fost eliminată. Versiunea serverului așteaptă să fie descărcată și o va înlocui la următoarea sincronizare.';

  @override
  String get recovery_reasonConflictDeleted =>
      'A fost șters de pe server, așa că modificarea ta nu poate fi aplicată. Folosește versiunea serverului pentru a accepta ștergerea.';

  @override
  String get asn_hintTitle => 'Ține apăsat un card pentru a înregistra o doză';

  @override
  String get asn_hintBody =>
      'Ține degetul pe card până se umple inelul. Atinge un card pentru detalii.';

  @override
  String get asn_hintGotIt => 'Am înțeles';

  @override
  String get asn_holdToRecord => 'Ține apăsat pentru a înregistra';

  @override
  String get asn_keepHolding => 'Continuă să ții apăsat';

  @override
  String asn_todayCount(int count) {
    return '$count azi';
  }

  @override
  String get asn_notTakenYet => 'Încă nu a fost luat';

  @override
  String asn_amountAgo(String amount, String ago) {
    return '$amount · $ago';
  }

  @override
  String asn_takenAtToday(String time, int count) {
    return 'Luat la $time · $count azi';
  }

  @override
  String get asn_takenToday => 'Luat azi';

  @override
  String asn_takenTime(String time) {
    return 'Luat la $time';
  }

  @override
  String get asn_needsReview => 'Necesită revizuire';

  @override
  String asn_logLine(int count, String time) {
    return '$count azi · ultima la $time';
  }

  @override
  String asn_logLineNoTime(int count) {
    return '$count azi';
  }

  @override
  String get asn_logNone => 'Nimic azi';

  @override
  String get asn_noDosesToday => 'Nicio doză încă azi';

  @override
  String get asn_logToggle => 'Dozele luate azi';

  @override
  String get asn_statToday => 'Azi';

  @override
  String get asn_stat7Days => 'Ultimele 7 zile';

  @override
  String get asn_statLastDose => 'Ultima doză';

  @override
  String get asn_onlyWhenNeeded => 'Doar la nevoie';

  @override
  String get asn_recentDoses => 'Doze recente';

  @override
  String get asn_yesterday => 'Ieri';

  @override
  String asn_doseCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count de doze',
      few: '$count doze',
      one: '1 doză',
    );
    return '$_temp0';
  }

  @override
  String asn_groupHeader(String day, String doses) {
    return '$day · $doses';
  }

  @override
  String get asn_noRecentDoses => 'Nicio doză în ultimele 7 zile';

  @override
  String get asn_recordNow => 'Înregistrează acum';

  @override
  String get asn_openEditor => 'Deschide editorul de doze';

  @override
  String asn_usualDose(String amount) {
    return 'Doza obișnuită: $amount';
  }

  @override
  String asn_stockLeft(String amount) {
    return '$amount rămase';
  }

  @override
  String get asn_stockLow => 'Stoc scăzut';

  @override
  String get asn_stockLabel => 'Stoc';

  @override
  String get asn_editorTitle => 'Înregistrează o doză';

  @override
  String get asn_amountLabel => 'Cantitate';

  @override
  String get asn_amountDecrease => 'Micșorează cantitatea';

  @override
  String get asn_amountIncrease => 'Mărește cantitatea';

  @override
  String get asn_whenLabel => 'Când';

  @override
  String get asn_whenNow => 'Acum';

  @override
  String get asn_when15 => 'Acum 15 min';

  @override
  String get asn_when1h => 'Acum 1 h';

  @override
  String get asn_when3h => 'Acum 3 h';

  @override
  String get asn_whenPick => 'Alege ora';

  @override
  String get asn_whenUnknown => 'Nu sunt sigur';

  @override
  String get asn_amountNotSure => 'Nu sunt sigur';

  @override
  String asn_save(String amount, String time) {
    return 'Salvează $amount la $time';
  }

  @override
  String asn_saveNoTime(String amount) {
    return 'Salvează $amount, ora nu se știe';
  }

  @override
  String asn_cardLabel(String name, String person, String info) {
    return '$name, pentru $person. $info';
  }

  @override
  String get asn_recordAction => 'Înregistrează doza';

  @override
  String get asn_agoJustNow => 'Chiar acum';

  @override
  String asn_agoMinutes(int count) {
    return 'Acum $count min';
  }

  @override
  String asn_agoHours(int count) {
    return 'Acum $count h';
  }

  @override
  String asn_agoDays(int count) {
    return 'Acum $count z';
  }

  @override
  String get asn_unitPlaceholder => 'Unitate';

  @override
  String asn_detailsFor(String name) {
    return 'Detalii pentru $name';
  }

  @override
  String get asn_jumpLabel => 'Salt la secțiunea La nevoie';

  @override
  String get asn_shortcutTitle => 'Scurtătură pentru La nevoie';

  @override
  String get asn_shortcutSubtitle =>
      'Afișează un buton care duce la medicamentele luate la nevoie';

  @override
  String get asn_editorSwitch => 'Doar când am nevoie';

  @override
  String get asn_editorSwitchHint =>
      'Fără rutină și fără mementouri. Înregistrezi o doză de fiecare dată când o iei.';

  @override
  String get asn_detailIntro =>
      'Se ia doar la nevoie, deci nu există o rutină de configurat.';

  @override
  String get asn_recordDose => 'Înregistrează o doză';

  @override
  String asn_prnStat(int count) {
    return 'Doze la nevoie (ultimele 30 de zile, separat): $count';
  }

  @override
  String lay_asNeededCount(int count) {
    return '$count la nevoie';
  }

  @override
  String jrn_tookAsNeeded(String time, String person, String medication) {
    return '$time · $person a luat $medication, la nevoie';
  }

  @override
  String jrn_tookAsNeededUnknown(String person, String medication) {
    return '$person a luat $medication, la nevoie · ora nu se știe';
  }

  @override
  String get lay_exampleAsNeeded => 'Ibuprofen';

  @override
  String get tm_stockFine => 'Stocul este în regulă';

  @override
  String get tm_stockFineBody => 'Nimic nu se termină în următoarele 14 zile';

  @override
  String get tm_stockSoon => 'Se termină curând';

  @override
  String get tm_stockOut => 'Stoc epuizat';

  @override
  String get tm_stockUntracked => 'Stocul nu este urmărit încă';

  @override
  String get tm_stockUntrackedBody =>
      'Adaugă o cantitate la un medicament ca să vezi când se termină';

  @override
  String get tm_scheduledLabel => 'Programate';

  @override
  String get tm_asNeededBody => 'Se notează din Astăzi';

  @override
  String tm_stockNegativeSpoken(String label) {
    return 'Atenție: stoc negativ. $label';
  }

  @override
  String get tm_noCount => 'Fără cantitate';

  @override
  String get tm_stockTitle => 'Stoc';

  @override
  String get tm_addStock => 'Adaugă stoc';

  @override
  String get tm_stockNone =>
      'Nu ai încă o cantitate în stoc. Adaug-o ca să vezi când se termină.';

  @override
  String tm_runsOutAround(String date) {
    return 'Se termină în jurul datei de $date';
  }

  @override
  String tm_refillAt(int count) {
    return 'Memento de reaprovizionare la $count rămase';
  }

  @override
  String get tm_last14Title => 'Ultimele 14 zile';

  @override
  String tm_daysTaken(int taken, int due) {
    return '$taken din $due zile';
  }

  @override
  String tm_daysTakenSpoken(int taken, int due) {
    return 'Toate dozele au fost luate în $taken din $due zile';
  }

  @override
  String get tm_last14Empty =>
      'Nicio doză înregistrată încă. Dozele pe care le notezi în Astăzi apar aici.';

  @override
  String tm_asNeededTotal(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count de doze',
      few: '$count doze',
      one: '1 doză',
      zero: 'Nicio doză',
    );
    return '$_temp0';
  }

  @override
  String get tm_last14AsNeededNote => 'Dozele luate la nevoie în fiecare zi.';

  @override
  String get tm_dayPartial => 'Unele doze luate';

  @override
  String get tm_dayNone => 'Nicio doză planificată';

  @override
  String get tm_dayUpcoming => 'Încă nu e ora dozei';

  @override
  String tm_dayCell(String date, String state) {
    return '$date: $state';
  }

  @override
  String tm_dayCellAsNeeded(String date, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count de doze',
      few: '$count doze',
      one: '1 doză',
      zero: 'nicio doză',
    );
    return '$date: $_temp0';
  }

  @override
  String get tm_recentTitle => 'Recente';

  @override
  String get tm_seeAllHistory => 'Vezi tot în Istoric';

  @override
  String get tm_recentEmpty => 'Nimic înregistrat în ultimele 30 de zile.';

  @override
  String get tm_kindScheduled => 'Programat';

  @override
  String get tm_statSchedule => 'Program';

  @override
  String get tm_perUse => 'La o administrare';

  @override
  String get tm_edit => 'Editează';

  @override
  String get tm_previewTitle => 'Previzualizare';

  @override
  String get tm_previewNote => 'Așa apare doza în Astăzi și în mementouri.';

  @override
  String get tm_stockAfterSaving => 'Stoc după salvare';

  @override
  String tm_stockWas(int count) {
    return 'Era $count';
  }

  @override
  String get th_viewCalendar => 'Calendar';

  @override
  String get th_viewTrends => 'Tendințe';

  @override
  String get th_viewLabel => 'Vizualizare istoric';

  @override
  String th_monthSoFar(String month) {
    return '$month până acum';
  }

  @override
  String get th_tilePlannedRecorded => 'Planificate înregistrate';

  @override
  String th_tileOfTotal(int recorded, int total) {
    return '$recorded din $total';
  }

  @override
  String get th_tileAsNeededDoses => 'Doze la nevoie';

  @override
  String get th_dayPlannedRecorded => 'Doze planificate înregistrate';

  @override
  String th_dayAsNeededDoses(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Doze la nevoie',
      one: 'Doză la nevoie',
    );
    return '$_temp0';
  }

  @override
  String get th_dayStreak => 'Zile la rând';

  @override
  String th_streakBest(int days) {
    return 'Cea mai lungă în 12 săptămâni: $days';
  }

  @override
  String get th_byMedication => 'Pe medicament';

  @override
  String get th_scheduledLast30 => 'Planificate, ultimele 30 de zile';

  @override
  String get th_asNeededByMedication => 'La nevoie, pe medicament';

  @override
  String get th_asNeededNone => 'Nicio doză la nevoie în ultimele 30 de zile';

  @override
  String th_asNeededCountSemantics(String medication, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count de doze',
      few: '$count doze',
      one: 'o doză',
    );
    return '$medication: $_temp0';
  }

  @override
  String get th_unknownMedication => 'Medicament necunoscut';

  @override
  String get th_timeOfDay => 'Ora din zi';

  @override
  String get th_timeOfDayNote => 'Când s-au luat dozele, ultimele 30 de zile';

  @override
  String get th_timeOfDayNone =>
      'Nicio doză cu oră cunoscută în ultimele 30 de zile';

  @override
  String th_timeOfDaySemantics(String hour, int count) {
    return 'Doze pe ore, ultimele 30 de zile. Cele mai multe la $hour: $count.';
  }

  @override
  String th_weekOfSemantics(String date, String value) {
    return 'Săptămâna din $date: $value';
  }

  @override
  String th_pillAdherenceSemantics(
    String name,
    int taken,
    int expected,
    String percent,
  ) {
    return '$name: $taken din $expected luate, $percent aderență';
  }

  @override
  String th_calendarDayFuture(String date) {
    return '$date, în viitor';
  }

  @override
  String get th_stockChanges => 'Modificări de stoc';

  @override
  String th_stockChangeRow(String medication, int before, int after) {
    return '$medication, de la $before la $after';
  }

  @override
  String get th_stockKindRefill => 'Reaprovizionare';

  @override
  String get th_stockKindCorrection => 'Corectat';

  @override
  String get th_stockKindUndone => 'Doză anulată';

  @override
  String th_stockChangeSemantics(
    String medication,
    int before,
    int after,
    String time,
  ) {
    return '$medication: stoc de la $before la $after, la $time';
  }

  @override
  String get ts_nextTitle => 'Următoarele mementouri pe acest dispozitiv';

  @override
  String get ts_nextEmpty =>
      'Nu este programat niciun memento în următoarele 30 de zile.';

  @override
  String get ts_nextEmptyNobody =>
      'Nicio persoană nu este activată pentru mementouri pe acest dispozitiv, așa că nu este programat niciunul.';

  @override
  String get ts_nextLoadFailed =>
      'Mementourile programate nu au putut fi citite.';

  @override
  String ts_whenToday(String time) {
    return 'Azi $time';
  }

  @override
  String ts_whenTonight(String time) {
    return 'Diseară $time';
  }

  @override
  String ts_whenTomorrow(String time) {
    return 'Mâine $time';
  }

  @override
  String ts_whenDay(String day, String time) {
    return '$day $time';
  }

  @override
  String get ts_previewTitle => 'Previzualizare';

  @override
  String get ts_previewNext => 'Următorul tău memento, așa cum va apărea.';

  @override
  String get ts_previewSample =>
      'Un exemplu. Încă nu este programat niciun memento.';

  @override
  String get ts_previewOnDevice => 'Previzualizare pe acest dispozitiv';

  @override
  String get tt_stockTitle => 'Stoc';

  @override
  String get tt_stockEmpty =>
      'Aici apar stocurile pe care le ții pentru medicamente.';

  @override
  String tt_stockLeft(String count) {
    return '$count rămase';
  }

  @override
  String get tt_stockAsNeeded => 'Folosit la nevoie';

  @override
  String get tt_stockLong => 'Peste două luni';

  @override
  String tt_stockAboutDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count de zile',
      few: '$count zile',
      one: 'o zi',
    );
    return 'Aproximativ $_temp0';
  }

  @override
  String tt_stockAboutWeeks(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count de săptămâni',
      few: '$count săptămâni',
      one: 'o săptămână',
    );
    return 'Aproximativ $_temp0';
  }

  @override
  String get tt_stockOut => 'Stoc epuizat';

  @override
  String tt_stockRow(String name, String left) {
    return '$name, $left';
  }

  @override
  String get tt_week => 'Săptămâna aceasta';

  @override
  String tt_weekRecorded(int count) {
    return '$count înregistrate';
  }

  @override
  String get tt_weekHint =>
      'Bulinele se umplu pe măsură ce înregistrezi doze. Dozele luate mai târziu contează tot.';

  @override
  String tt_weekDay(String date, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count de doze înregistrate',
      few: '$count doze înregistrate',
      one: 'o doză înregistrată',
      zero: 'nimic înregistrat',
    );
    return '$date: $_temp0';
  }

  @override
  String get tt_comingUp => 'Urmează';

  @override
  String get tt_comingUpPlanned => 'Planificat';

  @override
  String get tt_comingUpNone => 'Nu mai este nimic planificat după azi.';

  @override
  String get tt_tomorrow => 'Mâine';

  @override
  String get tt_detailsClose => 'Închide detaliile dozei';

  @override
  String get tt_otherTime => 'Altă oră';

  @override
  String get tt_takenOtherTime => 'Luat la altă oră';

  @override
  String get tt_skippedAction => 'Omis';

  @override
  String get tt_afterTaking => 'După ce îl iei';

  @override
  String get tt_previousNights => 'Nopțile trecute';

  @override
  String get tt_previousMornings => 'Diminețile trecute';

  @override
  String get tt_previousAfternoons => 'După-amiezele trecute';

  @override
  String get tt_previousEvenings => 'Serile trecute';

  @override
  String tt_previousCount(int taken, int total) {
    return '$taken din $total';
  }

  @override
  String tt_previousTakenAt(String time) {
    return 'Luat la $time';
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
      other: '$days de zile',
      few: '$days zile',
      one: 'o zi',
    );
    return 'Stocul de $name se va împuțina în aproximativ $_temp0';
  }

  @override
  String tt_lowNow(String name, String left) {
    return 'Stocul de $name e redus: $left rămase';
  }

  @override
  String tt_lowOut(String name) {
    return 'Stocul de $name s-a terminat';
  }

  @override
  String tt_lowDetailRunsIn(int days, String left) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days de zile',
      few: '$days zile',
      one: 'o zi',
    );
    return 'Se împuținează în aproximativ $_temp0 · $left rămase';
  }

  @override
  String tt_lowDetailNow(String left) {
    return 'Stoc redus · $left rămase';
  }

  @override
  String get tt_lowDetailOut => 'Stoc epuizat';

  @override
  String get tt_addStock => 'Adaugă stoc';

  @override
  String get tt_later => 'Mai târziu';

  @override
  String get tt_lowStockNotice => 'Stoc redus';

  @override
  String get tt_status => 'Stare';

  @override
  String get tt_allDay => 'Toată ziua';

  @override
  String get tt_previousDay => 'Ziua precedentă';

  @override
  String get tt_nextDay => 'Ziua următoare';

  @override
  String get tt_stockAll => 'Toate';

  @override
  String get tt_stockAllLabel => 'Toate medicamentele';

  @override
  String get tf_adherence => 'Aderență';

  @override
  String get tr_trendsCouldNotLoad =>
      'Nu s-au putut încărca seria de zile și graficele';

  @override
  String get settings_autoMissRecordTitle => 'Înregistrează dozele ratate';

  @override
  String get settings_autoMissRecordSubtitle =>
      'O doză pe care nimeni nu a înregistrat-o la timp este scrisă în istoric ca ratată, pe toate dispozitivele. Dezactivarea nu anulează dozele deja înregistrate ca ratate.';

  @override
  String get settings_autoMissRecordAfter => 'Înregistrează ca ratată după';

  @override
  String get settings_autoMissRecordDelaySubtitle =>
      'Cât timp după ora planificată așteaptă o doză înainte de a fi înregistrată ca ratată';

  @override
  String get settings_autoMissServerUnsupported =>
      'Acest server nu poate încă stoca dozele ratate. Pentru acest spațiu de lucru conectat nu se înregistrează nimic ca ratat până când serverul este actualizat.';

  @override
  String get dose_takenLate => 'Luat (cu întârziere)';

  @override
  String get dose_takeLateNow => 'Luat acum (cu întârziere)';

  @override
  String get dose_markedMissedAuto => 'Marcată automat ca ratată';

  @override
  String get dose_missedHint =>
      'Nimeni nu a înregistrat această doză la timp, așa că a fost marcată ca ratată. O poți totuși înregistra ca luată cu întârziere, o poți înregistra ca omisă sau poți anula marcarea ca ratată.';

  @override
  String dose_missedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count de doze ratate',
      few: '$count doze ratate',
      one: '1 doză ratată',
    );
    return '$_temp0';
  }

  @override
  String get export_statusNotRecorded => 'Neînregistrată';

  @override
  String jrn_missed(String time, String person, String medication) {
    return '$time · $person a ratat $medication';
  }

  @override
  String jrn_tookLate(String time, String person, String medication) {
    return '$time · $person a luat $medication, cu întârziere';
  }

  @override
  String get amountReview_entry => 'Verifică dozele medicamentelor';

  @override
  String amountReview_entryHint(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count de medicamente afișează încă textul original al dozei',
      few: '$count medicamente afișează încă textul original al dozei',
      one: '1 medicament afișează încă textul original al dozei',
    );
    return '$_temp0';
  }

  @override
  String get amountReview_title => 'Dozele medicamentelor';

  @override
  String get amountReview_intro =>
      'Aceste medicamente au fost salvate cu doza scrisă ca text simplu. Stabilește cantitatea pe administrare, ca să apară în Astăzi și în editorul de doze.';

  @override
  String get amountReview_readable => 'Gata de folosit';

  @override
  String get amountReview_readableHint =>
      'Textul original se citește ca o singură cantitate. Verifică-l, apoi acceptă-le pe toate deodată.';

  @override
  String get amountReview_manual => 'Stabilește-le tu';

  @override
  String get amountReview_manualHint =>
      'Textul original nu se citește ca o singură cantitate, așa că nimic nu este ghicit. Deschide fiecare medicament și stabilește cantitatea.';

  @override
  String amountReview_original(String text) {
    return 'Text original: $text';
  }

  @override
  String amountReview_willSet(String amount) {
    return 'Stabilește $amount pe administrare';
  }

  @override
  String amountReview_willKeep(String amount) {
    return 'Păstrează $amount pe administrare';
  }

  @override
  String amountReview_accept(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Folosește aceste $count de cantități',
      few: 'Folosește aceste $count cantități',
      one: 'Folosește această cantitate',
    );
    return '$_temp0';
  }

  @override
  String amountReview_saved(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count de cantități salvate',
      few: '$count cantități salvate',
      one: '1 cantitate salvată',
    );
    return '$_temp0';
  }

  @override
  String amountReview_partial(int saved, int total) {
    return '$saved din $total salvate. Deschide-le pe celelalte și stabilește-le tu.';
  }

  @override
  String get amountReview_error =>
      'Cantitățile nu au putut fi salvate. Încearcă din nou.';

  @override
  String get amountReview_empty =>
      'Fiecare medicament are o cantitate pe administrare.';

  @override
  String get amountReview_selectedPerson =>
      'Este listată doar persoana pe care o vezi acum. Comută pe Toată lumea în Persoane ca să le verifici pe celelalte.';

  @override
  String get amountReview_markReviewed =>
      'Am verificat textul original al dozei';

  @override
  String get amountReview_markReviewedHint =>
      'Formularea originală se păstrează întotdeauna. Aceasta doar oprește reamintirea de a o verifica.';

  @override
  String get t09_legacyDosageReviewed => 'Text original al dozei · Verificat';

  @override
  String get updateAvailableTitle => 'Actualizare disponibilă';

  @override
  String updateAvailableBody(String version) {
    return 'A apărut versiunea $version din Simpastil.';
  }

  @override
  String get updateAvailableBodyGeneric =>
      'A apărut o versiune mai nouă din Simpastil.';

  @override
  String get updateAvailableAction => 'Vezi versiunea';

  @override
  String get updateCheckSwitchTitle => 'Caută actualizări';

  @override
  String get updateCheckSwitchBody =>
      'O dată pe zi, întreabă GitHub dacă a apărut o versiune mai nouă.';

  @override
  String get supportRowTitle => 'Susține Simpastil';

  @override
  String get supportRowSubtitle => 'Donează pe Ko-fi. Complet opțional.';

  @override
  String onb_personRemindersTitle(String name) {
    return 'Vreau mementouri pentru $name';
  }

  @override
  String get onb_personRemindersBody =>
      'Pe acest dispozitiv. Poți schimba oricând în Persoane.';

  @override
  String get onb_detailsTitle => 'Arată numele medicamentelor';

  @override
  String get onb_detailsBody =>
      'Pe ecranul de blocare. Oprește pentru a le păstra private; mementourile spun atunci doar că o doză e programată.';

  @override
  String get onb_choicesTitle => 'Alegerile tale';

  @override
  String get onb_choiceFailed =>
      'Alegerea nu a putut fi salvată. O poți schimba mai târziu în Setări.';

  @override
  String get onb_batteryTitle => 'Păstrează mementourile la timp';

  @override
  String get onb_batteryBody =>
      'Economisirea bateriei poate întârzia sau bloca mementourile când Simpastil este închis. Dacă îi permiți să ruleze în fundal, ele ajung la timp.';

  @override
  String get onb_batteryAllow => 'Permite Simpastil să ruleze în fundal';

  @override
  String get onb_batteryNotNow => 'Nu acum';

  @override
  String get onb_batterySamsungTip =>
      'Pe telefoanele Samsung: Setări → Baterie → Limite de utilizare în fundal, apoi ține Simpastil în afara aplicațiilor adormite.';

  @override
  String get onb_batteryNoLimits => 'Baterie: fără limite';

  @override
  String get onb_batteryLimited =>
      'Economisirea bateriei poate întârzia mementourile';

  @override
  String get onb_batteryUnlimited => 'Fără limite de baterie pentru Simpastil';

  @override
  String get onb_projectTitle => 'Un proiect mic';

  @override
  String get onb_projectBody =>
      'Simpastil este o aplicație mică și independentă, așa că uneori ceva poate să nu funcționeze cum ar trebui.';

  @override
  String get onb_projectReport => 'Raportează pe GitHub';

  @override
  String get onb_projectProblemTitle => 'Ai găsit o problemă?';

  @override
  String get onb_projectProblemBody =>
      'Spune-ne pe GitHub sau folosește „Raportează o problemă” din Setări → Despre.';

  @override
  String get onb_projectHelpTitle => 'Vrei să ajuți la dezvoltare?';

  @override
  String get onb_projectHelpBody =>
      'Codul este deschis, iar contribuțiile sunt binevenite.';

  @override
  String get onb_projectSupportTitle => 'Susține proiectul';

  @override
  String get onb_projectSupportBody =>
      'Donațiile ajută ca Simpastil să meargă mai departe.';

  @override
  String get onb_projectCode => 'Vezi codul';

  @override
  String get onb_projectSponsors => 'GitHub Sponsors';

  @override
  String get onb_projectKofi => 'Ko-fi';

  @override
  String get onb_summaryTitle => 'Mementourile tale';

  @override
  String onb_summaryRemindersOn(String name) {
    return '$name primește mementouri pe acest dispozitiv';
  }

  @override
  String onb_summaryRemindersOff(String name) {
    return '$name nu primește mementouri pe acest dispozitiv';
  }

  @override
  String get onb_summaryChangePeople => 'Schimbă în Setări → Persoane.';

  @override
  String get onb_summaryNotificationsOn => 'Notificările sunt permise';

  @override
  String get onb_summaryNotificationsOff => 'Notificările nu sunt încă permise';

  @override
  String get onb_summaryChangeReminders => 'Schimbă în Setări → Mementouri.';

  @override
  String get onb_summaryNamesShown =>
      'Numele medicamentelor apar pe ecranul de blocare';

  @override
  String get onb_summaryNamesHidden =>
      'Numele medicamentelor sunt ascunse pe ecranul de blocare';

  @override
  String get onb_summaryBackups =>
      'Copiile de siguranță nu sunt automate. Fă una în Setări → Copii de siguranță.';

  @override
  String get onb_remindersOffTitle =>
      'Mementourile sunt oprite pe acest dispozitiv';

  @override
  String get onb_remindersOffBody =>
      'Nimeni nu primește încă mementouri pentru doze aici.';

  @override
  String get onb_remindersOffAction => 'Pornește';

  @override
  String get onb_remindersOffDismiss => 'Ascunde pe acest dispozitiv';

  @override
  String get onb_remindersOffFailed =>
      'Mementourile nu au putut fi pornite. Poți încerca din nou în Setări → Mementouri.';

  @override
  String get report_title => 'Raportează o problemă';

  @override
  String get report_settingsRowSubtitle =>
      'Trimite detaliile necesare pentru remediere. Nu se trimite nimic până nu alegi tu.';

  @override
  String get report_intro =>
      'Ceva nu funcționează? Trimite un raport ca problema să poată fi găsită și rezolvată. Raportul conține doar detalii tehnice.';

  @override
  String get report_includesTitle => 'Ce conține raportul';

  @override
  String get report_includesBody =>
      'Versiunea aplicației, modelul telefonului și versiunea Android, dacă notificările sunt permise, mărimi aproximative precum „2-5 medicamente”, ultimii pași de sincronizare și erorile recente.';

  @override
  String get report_neverBody =>
      'Nu include niciodată: nume, medicamente, doze, notițe, adresa serverului, emailul sau contul, ori datele de autentificare.';

  @override
  String get report_previewTitle => 'Vezi exact ce se va trimite';

  @override
  String get report_preparing => 'Se pregătește raportul…';

  @override
  String get report_githubAction => 'Trimite o problemă pe GitHub';

  @override
  String get report_githubHint =>
      'Public, gratuit și cea mai rapidă cale de a primi ajutor.';

  @override
  String get report_shareAction => 'Trimite în alt fel';

  @override
  String get report_shareHint =>
      'Salvează fișierul, trimite-l prin email dezvoltatorului sau cu altă aplicație.';

  @override
  String get report_publicNote =>
      'Problemele de pe GitHub sunt publice. Acest raport poate fi publicat în siguranță, iar tu alegi ce mai scrii. Pentru o problemă de securitate nu posta public: vezi politica de securitate de pe GitHub.';

  @override
  String get report_githubSheetTitle => 'Cum funcționează raportarea pe GitHub';

  @override
  String report_githubStep1(String fileName) {
    return 'Raportul se salvează în dosarul Descărcări ca $fileName.';
  }

  @override
  String get report_githubStep2 =>
      'Se deschide GitHub cu formularul deja început.';

  @override
  String get report_githubStep3 =>
      'Descrie ce s-a întâmplat, atașează fișierul salvat la problemă și trimite-o.';

  @override
  String get report_githubContinue => 'Salvează și deschide GitHub';

  @override
  String get report_githubOpenFailed =>
      'GitHub nu a putut fi deschis. Deschide github.com/LucaPisl/simpastil/issues/new într-un browser și atașează fișierul salvat.';

  @override
  String get report_saveAction => 'Salvează în Descărcări';

  @override
  String get report_saveHint =>
      'Păstrează fișierul sau atașează-l tu la un mesaj.';

  @override
  String get report_emailAction => 'Trimite email dezvoltatorului';

  @override
  String get report_emailHint =>
      'Deschide aplicația de email cu mesajul și fișierul gata de trimis.';

  @override
  String get report_otherShareAction => 'Trimite cu altă aplicație';

  @override
  String get report_otherShareHint =>
      'Trimite fișierul cu orice aplicație alegi.';

  @override
  String report_savedTo(String fileName) {
    return 'Salvat în Descărcări ca $fileName';
  }

  @override
  String get report_saveUnsupported =>
      'Această versiune de Android nu poate salva direct în Descărcări. Folosește Trimite cu altă aplicație ca să pui fișierul unde vrei.';

  @override
  String get report_saveFailed =>
      'Fișierul nu a putut fi salvat. Încearcă Trimite cu altă aplicație.';

  @override
  String get report_noEmailApp =>
      'Nu s-a găsit nicio aplicație de email. Salvează fișierul sau trimite-l în alt fel.';

  @override
  String get report_emailFailed =>
      'Emailul nu a putut fi pregătit. Încearcă să salvezi fișierul.';

  @override
  String get report_shareFailed =>
      'Fișierul nu a putut fi trimis. Încearcă să-l salvezi în Descărcări.';

  @override
  String get report_crashTitle =>
      'Simpastil s-a închis neașteptat data trecută';

  @override
  String get report_crashBody =>
      'Un scurt raport poate ajuta la remedierea problemei.';

  @override
  String get report_crashAction => 'Raportează';

  @override
  String get report_crashDismiss => 'Închide';

  @override
  String get report_syncAction => 'Raportează această problemă';

  @override
  String get report_startupAction => 'Raportează această problemă';
}
