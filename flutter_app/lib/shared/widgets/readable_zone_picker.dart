import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;
import '../../l10n/app_localizations.dart';

String readableZone(BuildContext context, String identifier) {
  final l = AppLocalizations.of(context);
  if (identifier == 'UTC' ||
      identifier == 'Etc/UTC' ||
      identifier == 'Etc/GMT') {
    return l.t09_utc;
  }
  if (!tz.timeZoneDatabase.locations.containsKey(identifier)) {
    return l.t09_unknownZone;
  }
  if (identifier == 'Europe/Bucharest') return l.t08_bucharest;
  final parts = identifier.split('/');
  return parts.reversed.take(2).map((p) => p.replaceAll('_', ' ')).join(' · ');
}

Future<String?> chooseReadableZone(BuildContext context) => showSearch<String>(
  context: context,
  delegate: _ZoneSearch(AppLocalizations.of(context).t09_searchPlace),
);

String _normalizeSearch(String text) {
  const replacements = {
    'ă': 'a',
    'â': 'a',
    'î': 'i',
    'ș': 's',
    'ş': 's',
    'ț': 't',
    'ţ': 't',
  };
  var normalized = text.trim().toLowerCase();
  for (final entry in replacements.entries) {
    normalized = normalized.replaceAll(entry.key, entry.value);
  }
  return normalized;
}

class _ZoneSearch extends SearchDelegate<String> {
  _ZoneSearch(String label) : super(searchFieldLabel: label);
  @override
  List<Widget> buildActions(BuildContext context) => [
    if (query.isNotEmpty)
      IconButton(
        tooltip: MaterialLocalizations.of(context).deleteButtonTooltip,
        onPressed: () => query = '',
        icon: const Icon(Icons.clear),
      ),
  ];
  @override
  Widget buildLeading(BuildContext context) =>
      BackButton(onPressed: () => Navigator.of(context).pop());
  @override
  Widget buildResults(BuildContext context) => _places(context);
  @override
  Widget buildSuggestions(BuildContext context) => _places(context);
  Widget _places(BuildContext context) {
    final normalizedQuery = _normalizeSearch(query);
    final places =
        tz.timeZoneDatabase.locations.keys.where((zone) {
          if (zone != 'UTC' &&
              (!zone.contains('/') || zone.startsWith('Etc/'))) {
            return false;
          }
          return _normalizeSearch(
            readableZone(context, zone),
          ).contains(normalizedQuery);
        }).toList()..sort(
          (a, b) =>
              readableZone(context, a).compareTo(readableZone(context, b)),
        );
    return ListView.builder(
      itemCount: places.length,
      itemBuilder: (context, index) => ListTile(
        title: Text(readableZone(context, places[index])),
        onTap: () => close(context, places[index]),
      ),
    );
  }
}
