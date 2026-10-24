/// Where a setting lives: on the account (it follows the person across their
/// devices) or on this device only.
enum SettingScope { account, device }

/// One declaration per setting the app knows about. Every setting is declared
/// here exactly once; the settings screens read the scope to label the rows
/// that stay on this device, and the account sync reads the account entries to
/// know which keys it may send.
class SettingDeclaration {
  const SettingDeclaration(this.id, this.scope, {this.accountKey});

  /// Stable identifier the screens use, for example `autoMiss`.
  final String id;
  final SettingScope scope;

  /// The wire key (`contracts/account-settings-v1.json`) of an account
  /// setting. Per-record families end with a dot: `reminders.routine.`.
  final String? accountKey;
}

class SettingScopeRegistry {
  const SettingScopeRegistry._();

  static const _decls = <SettingDeclaration>[
    // Follow the account.
    SettingDeclaration(
      'snoozeLength',
      SettingScope.account,
      accountKey: 'reminders.snoozeMinutes',
    ),
    SettingDeclaration(
      'routineReminders',
      SettingScope.account,
      accountKey: 'reminders.routine.',
    ),
    SettingDeclaration(
      'personReminders',
      SettingScope.account,
      accountKey: 'reminders.person.',
    ),
    SettingDeclaration(
      'recordedBy',
      SettingScope.account,
      accountKey: 'recordedBy',
    ),
    SettingDeclaration(
      'asNeededInStats',
      SettingScope.account,
      accountKey: 'asNeeded.inStats',
    ),
    SettingDeclaration(
      'siblingDetection',
      SettingScope.account,
      accountKey: 'medications.siblingDetection',
    ),
    SettingDeclaration(
      'noticesLater',
      SettingScope.account,
      accountKey: 'today.noticesLater',
    ),
    SettingDeclaration(
      'textAppearance',
      SettingScope.account,
      accountKey: 'appearance.text',
    ),
    SettingDeclaration(
      'customColors',
      SettingScope.account,
      accountKey: 'appearance.colors',
    ),
    SettingDeclaration(
      'language',
      SettingScope.account,
      accountKey: 'language',
    ),
    // Stay on this device.
    SettingDeclaration('autoMiss', SettingScope.device),
    SettingDeclaration('remindOnThisDevice', SettingScope.device),
    SettingDeclaration('notificationSound', SettingScope.device),
    SettingDeclaration('lockScreenDetails', SettingScope.device),
    SettingDeclaration('appLock', SettingScope.device),
    SettingDeclaration('deviceName', SettingScope.device),
    SettingDeclaration('todayLayout', SettingScope.device),
    SettingDeclaration('focusAsNeededShortcut', SettingScope.device),
    SettingDeclaration('themeMode', SettingScope.device),
    SettingDeclaration('wallpaperColors', SettingScope.device),
    SettingDeclaration('asNeededInWidget', SettingScope.device),
  ];

  static List<SettingDeclaration> get all => _decls;

  static SettingDeclaration? byId(String id) {
    for (final d in _decls) {
      if (d.id == id) return d;
    }
    return null;
  }

  /// The scope of a declared setting. An undeclared id is a programming
  /// error, so tests fail on a typo instead of silently showing no label.
  static SettingScope scopeOf(String id) {
    final decl = byId(id);
    if (decl == null) throw ArgumentError.value(id, 'id', 'Undeclared setting');
    return decl.scope;
  }

  static bool isDeviceOnly(String id) => scopeOf(id) == SettingScope.device;

  /// Wire keys and key families that follow the account.
  static Iterable<String> get accountKeys =>
      _decls.map((d) => d.accountKey).whereType<String>();
}
