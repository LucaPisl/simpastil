import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../../core/medication/expiry.dart';
import '../../../core/medication/medication_extras.dart';
import '../../../l10n/app_localizations.dart';
import 'medication_form_kit.dart';

/// The state behind the optional medication extras of an edit form: the
/// as-needed limits, the expiry date and the prescriber and pharmacy contacts.
///
/// One holder serves both edit forms, so they read, check and save the same
/// way. The values are personal data: nothing here is ever logged.
class MedicationExtrasEditor extends ChangeNotifier {
  MedicationExtrasEditor(MedicationExtras initial)
    : _expiresOn = initial.expiresOn,
      _initialGapMinutes = initial.prnMinGapMinutes,
      maxPer24h = TextEditingController(
        text: initial.prnMaxPer24h?.toString() ?? '',
      ),
      gapHours = TextEditingController(
        text: initial.prnMinGapMinutes == null
            ? ''
            : formatGapHours(initial.prnMinGapMinutes!),
      ),
      prescriberName = TextEditingController(text: initial.prescriberName),
      prescriberPhone = TextEditingController(text: initial.prescriberPhone),
      pharmacyName = TextEditingController(text: initial.pharmacyName),
      pharmacyPhone = TextEditingController(text: initial.pharmacyPhone);

  final TextEditingController maxPer24h;
  final TextEditingController gapHours;
  final TextEditingController prescriberName;
  final TextEditingController prescriberPhone;
  final TextEditingController pharmacyName;
  final TextEditingController pharmacyPhone;
  String? _expiresOn;
  final int? _initialGapMinutes;
  String? _gapShown;

  /// Writes the saved gap with the decimal separator of [locale] (`1,5` in
  /// Romanian). It runs once the screen knows its locale, which is after the
  /// editor is built, and it leaves the field alone when it was already edited.
  /// [parseHours] reads either separator, so a typed `1.5` or `1,5` both work.
  void applyLocale(String locale) {
    final minutes = _initialGapMinutes;
    if (minutes == null) return;
    final shown = _gapShown ?? formatGapHours(minutes);
    if (gapHours.text != shown) return;
    final localized = formatGapHours(minutes, locale: locale);
    _gapShown = localized;
    if (localized != shown) gapHours.text = localized;
  }

  String? get expiresOn => _expiresOn;
  set expiresOn(String? value) {
    _expiresOn = value;
    notifyListeners();
  }

  /// Whole hours without a decimal, otherwise up to two decimals (`4`, `4.5`).
  ///
  /// With a [locale] the decimal separator follows it, so Romanian reads
  /// `1,5`. Without one the text keeps a dot, which is what the edit field
  /// starts with; [parseHours] accepts both.
  static String formatGapHours(int minutes, {String? locale}) {
    final hours = minutes / 60;
    final plain = hours == hours.roundToDouble()
        ? hours.round().toString()
        : hours.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');
    if (locale == null) return plain;
    return NumberFormat('0.##', locale).format(double.parse(plain));
  }

  /// The hours as a number for a plural: a whole `int` when it is whole, so
  /// "1 hour" is chosen for exactly one hour and "1.5 hours" for a half.
  static num gapHoursCount(int minutes) {
    final hours = minutes / 60;
    return hours == hours.roundToDouble() ? hours.round() : hours;
  }

  /// The hours as written, accepting a comma as the decimal separator.
  static double? parseHours(String text) =>
      double.tryParse(text.trim().replaceAll(',', '.'));

  String? maxError(AppLocalizations l) {
    final text = maxPer24h.text.trim();
    if (text.isEmpty) return null;
    final value = int.tryParse(text);
    return value == null || value < 1 || value > maxPrnPer24h
        ? l.mx_numberRange(maxPrnPer24h)
        : null;
  }

  String? gapError(AppLocalizations l) {
    final text = gapHours.text.trim();
    if (text.isEmpty) return null;
    final hours = parseHours(text);
    if (hours == null || hours < .5 || hours > 24) return l.mx_hoursRange;
    return null;
  }

  String? phoneError(AppLocalizations l, TextEditingController c) {
    final text = c.text.trim();
    if (text.isEmpty) return null;
    return contactPhonePattern.hasMatch(text) ? null : l.mx_phoneInvalid;
  }

  String? nameError(AppLocalizations l, TextEditingController c) =>
      c.text.trim().length > maxContactNameLength ? l.mx_nameTooLong : null;

  /// True when every field holds an acceptable value.
  bool isValid(AppLocalizations l) =>
      maxError(l) == null &&
      gapError(l) == null &&
      phoneError(l, prescriberPhone) == null &&
      phoneError(l, pharmacyPhone) == null &&
      nameError(l, prescriberName) == null &&
      nameError(l, pharmacyName) == null;

  /// The extras as typed. Call only when [isValid].
  MedicationExtras read() {
    String? optional(TextEditingController c) =>
        c.text.trim().isEmpty ? null : c.text.trim();
    final max = int.tryParse(maxPer24h.text.trim());
    final hours = parseHours(gapHours.text);
    return MedicationExtras(
      prnMaxPer24h: max,
      prnMinGapMinutes: hours == null ? null : (hours * 60).round(),
      expiresOn: _expiresOn,
      prescriberName: optional(prescriberName),
      prescriberPhone: optional(prescriberPhone),
      pharmacyName: optional(pharmacyName),
      pharmacyPhone: optional(pharmacyPhone),
    );
  }

  @override
  void dispose() {
    for (final c in [
      maxPer24h,
      gapHours,
      prescriberName,
      prescriberPhone,
      pharmacyName,
      pharmacyPhone,
    ]) {
      c.dispose();
    }
    super.dispose();
  }
}

/// The sections of [editor]: limits (as-needed medicines only), expiry date
/// and contacts. Returns plain [FormSection]s so a form places them like its
/// own.
List<Widget> medicationExtrasSections({
  required BuildContext context,
  required MedicationExtrasEditor editor,
  required Object identity,
  required int firstIndex,
  required bool enabled,
  required bool showLimits,
}) {
  final l = AppLocalizations.of(context);
  return [
    if (showLimits)
      FormSection(
        index: firstIndex,
        identity: identity,
        icon: Icons.speed_rounded,
        title: l.mx_sectionLimits,
        hint: l.mx_sectionLimitsHint,
        children: [
          ListenableBuilder(
            listenable: Listenable.merge([editor.maxPer24h]),
            builder: (context, _) => TextField(
              key: const ValueKey('edit-medication-max-per-24h'),
              controller: editor.maxPer24h,
              enabled: enabled,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: l.mx_maxPer24h,
                errorText: editor.maxError(l),
              ),
            ),
          ),
          const SizedBox(height: 14),
          ListenableBuilder(
            listenable: Listenable.merge([editor.gapHours]),
            builder: (context, _) => TextField(
              key: const ValueKey('edit-medication-min-gap-hours'),
              controller: editor.gapHours,
              enabled: enabled,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: l.mx_minGapHours,
                errorText: editor.gapError(l),
              ),
            ),
          ),
        ],
      ),
    FormSection(
      index: firstIndex + 1,
      identity: identity,
      icon: Icons.event_busy_outlined,
      title: l.mx_sectionExpiry,
      hint: l.mx_sectionExpiryHint,
      children: [_ExpiryField(editor: editor, enabled: enabled)],
    ),
    FormSection(
      index: firstIndex + 2,
      identity: identity,
      icon: Icons.contact_phone_outlined,
      title: l.mx_sectionContacts,
      hint: l.mx_sectionContactsHint,
      children: [
        _ContactFields(
          editor: editor,
          enabled: enabled,
          name: editor.prescriberName,
          phone: editor.prescriberPhone,
          nameLabel: l.mx_prescriberName,
          phoneLabel: l.mx_prescriberPhone,
          keyPrefix: 'edit-medication-prescriber',
        ),
        const SizedBox(height: 18),
        _ContactFields(
          editor: editor,
          enabled: enabled,
          name: editor.pharmacyName,
          phone: editor.pharmacyPhone,
          nameLabel: l.mx_pharmacyName,
          phoneLabel: l.mx_pharmacyPhone,
          keyPrefix: 'edit-medication-pharmacy',
        ),
      ],
    ),
  ];
}

class _ContactFields extends StatelessWidget {
  const _ContactFields({
    required this.editor,
    required this.enabled,
    required this.name,
    required this.phone,
    required this.nameLabel,
    required this.phoneLabel,
    required this.keyPrefix,
  });
  final MedicationExtrasEditor editor;
  final bool enabled;
  final TextEditingController name;
  final TextEditingController phone;
  final String nameLabel;
  final String phoneLabel;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([name, phone]),
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: ValueKey('$keyPrefix-name'),
            controller: name,
            enabled: enabled,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              labelText: nameLabel,
              errorText: editor.nameError(l, name),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: ValueKey('$keyPrefix-phone'),
            controller: phone,
            enabled: enabled,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(
              labelText: phoneLabel,
              errorText: editor.phoneError(l, phone),
            ),
          ),
        ],
      ),
    );
  }
}

class _ExpiryField extends StatelessWidget {
  const _ExpiryField({required this.editor, required this.enabled});
  final MedicationExtrasEditor editor;
  final bool enabled;

  Future<void> _pick(BuildContext context) async {
    final now = DateTime.now();
    final current = parseExpiryDate(editor.expiresOn);
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime(now.year, now.month, now.day),
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 30, 12, 31),
    );
    if (picked != null) editor.expiresOn = expiryDateKey(picked);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: editor,
      builder: (context, _) {
        final date = parseExpiryDate(editor.expiresOn);
        final text = date == null
            ? l.mx_expiryNone
            : DateFormat.yMMMd(
                Localizations.localeOf(context).toString(),
              ).format(date);
        return Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              text,
              key: const ValueKey('edit-medication-expiry-text'),
              style: theme.textTheme.bodyLarge,
            ),
            OutlinedButton(
              key: const ValueKey('edit-medication-expiry-pick'),
              onPressed: enabled ? () => _pick(context) : null,
              child: Text(l.mx_expiryPick),
            ),
            if (date != null)
              TextButton(
                key: const ValueKey('edit-medication-expiry-clear'),
                onPressed: enabled ? () => editor.expiresOn = null : null,
                child: Text(l.mx_expiryClear),
              ),
          ],
        );
      },
    );
  }
}
