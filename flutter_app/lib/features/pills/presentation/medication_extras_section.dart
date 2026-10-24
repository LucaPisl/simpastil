import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/medication/expiry.dart';
import '../../../core/medication/medication_extras.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/app_theme.dart';
import '../../dashboard/today_layout/low_stock_notice.dart'
    show expiryDetail, lowStockInk;
import 'medication_detail_sections.dart';
import 'medication_extras_fields.dart';

/// Opens the phone app for a number. Overridable in tests. Returns whether
/// something handled the link.
final phoneLauncherProvider = Provider<Future<bool> Function(Uri)>(
  (ref) =>
      (uri) async => launchUrl(uri),
);

/// The `tel:` link for a stored phone number: digits and a leading plus
/// only, so spaces and punctuation never reach the dialer.
Uri telUri(String phone) {
  final dialable = phone.replaceAll(RegExp(r'[^0-9+#*]'), '');
  return Uri(scheme: 'tel', path: dialable);
}

/// The optional medication facts on the details page: as-needed limits, the
/// expiry date, and the prescriber and pharmacy with tap to call. Nothing is
/// drawn when none of them is set.
class MedicationExtrasSection extends ConsumerWidget {
  const MedicationExtrasSection({
    super.key,
    required this.extras,
    this.flat = false,
    this.now,
  });

  final MedicationExtras extras;
  final bool flat;

  /// The current time; tests pin it.
  final DateTime? now;

  /// Whether [extras] has anything to show on the page.
  static bool hasContent(MedicationExtras extras) => !extras.isEmpty;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (extras.isEmpty) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final expiry = expiryState(extras.expiresOn, now ?? DateTime.now());
    final date = parseExpiryDate(extras.expiresOn);
    final locale = Localizations.localeOf(context).toString();
    final limits = <String>[
      if (extras.prnMaxPer24h case final max?) l.mx_limitsLine(max),
      if (extras.prnMinGapMinutes case final gap?)
        l.mx_gapLine(
          MedicationExtrasEditor.formatGapHours(gap, locale: locale),
          MedicationExtrasEditor.gapHoursCount(gap),
        ),
    ];
    final contacts = extras.hasPrescriber || extras.hasPharmacy;
    // One kind of fact keeps its own heading; a mix gets a neutral one, with
    // each part labelled the way the contact rows already are.
    final mixed =
        [limits.isNotEmpty, date != null, contacts].where((on) => on).length >
        1;
    final dateText = date == null
        ? null
        : DateFormat.yMMMd(locale).format(date);
    final expiryInk = switch (expiry.phase) {
      ExpiryPhase.expired => semantic.statusMissed,
      _ when expiry.needsNotice => lowStockInk(context),
      _ => null,
    };
    final cs = Theme.of(context).colorScheme;
    final label = text.labelMedium?.copyWith(color: cs.onSurfaceVariant);
    return MedicationSection(
      key: const ValueKey('medication-extras-section'),
      flat: flat,
      title: mixed
          ? l.mx_sectionDetails
          : contacts
          ? l.mx_sectionContacts
          : date != null
          ? l.mx_sectionExpiry
          : l.mx_sectionLimits,
      children: [
        if (mixed && limits.isNotEmpty) Text(l.mx_sectionLimits, style: label),
        for (final line in limits)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(line, style: text.bodyLarge),
          ),
        if (dateText != null)
          // The label and the date are one item, so the date is read next
          // to "Expiry date".
          MergeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (mixed) Text(l.mx_sectionExpiry, style: label),
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    key: const ValueKey('medication-expiry'),
                    // "Expires in 19 days · Nov 10, 2026" once the notice is due,
                    // so the verb is said once; a calm date otherwise.
                    expiry.phase == ExpiryPhase.expired
                        ? '${l.mx_expiredLabel} $dateText'
                        : expiry.needsNotice
                        ? '${expiryDetail(l, expiry)} · $dateText'
                        : '${l.mx_expiresLabel} $dateText',
                    style: text.bodyLarge?.copyWith(
                      fontWeight: expiryInk == null ? null : FontWeight.w700,
                      color: expiryInk == null
                          ? null
                          : AppTheme.readable(expiryInk, [
                              cs.surface,
                              cs.surfaceContainerLow,
                              cs.surfaceContainer,
                            ], minimum: 4.5),
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (extras.hasPrescriber)
          _ContactRow(
            keyPrefix: 'prescriber',
            role: l.mx_prescriber,
            name: extras.prescriberName,
            phone: extras.prescriberPhone,
          ),
        if (extras.hasPharmacy)
          _ContactRow(
            keyPrefix: 'pharmacy',
            role: l.mx_pharmacy,
            name: extras.pharmacyName,
            phone: extras.pharmacyPhone,
          ),
      ],
    );
  }
}

class _ContactRow extends ConsumerWidget {
  const _ContactRow({
    required this.keyPrefix,
    required this.role,
    required this.name,
    required this.phone,
  });

  final String keyPrefix;
  final String role;
  final String? name;
  final String? phone;

  Future<void> _call(BuildContext context, WidgetRef ref, String phone) async {
    final launch = ref.read(phoneLauncherProvider);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final failed = AppLocalizations.of(context).mx_callFailed;
    var ok = false;
    try {
      ok = await launch(telUri(phone));
    } on Object {
      ok = false;
    }
    if (!ok) messenger?.showSnackBar(SnackBar(content: Text(failed)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final phone = this.phone;
    final who = name ?? role;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  role,
                  style: text.labelMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
                if (name != null)
                  Text(
                    name!,
                    key: ValueKey('medication-$keyPrefix-name'),
                    style: text.bodyLarge,
                  ),
                if (phone != null)
                  Text(
                    phone,
                    key: ValueKey('medication-$keyPrefix-phone'),
                    style: text.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          if (phone != null)
            Semantics(
              button: true,
              label: l.mx_callA11y(who, phone),
              excludeSemantics: true,
              child: IconButton.filledTonal(
                key: ValueKey('medication-$keyPrefix-call'),
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: () => _call(context, ref, phone),
                icon: const Icon(Icons.call_outlined),
              ),
            ),
        ],
      ),
    );
  }
}
