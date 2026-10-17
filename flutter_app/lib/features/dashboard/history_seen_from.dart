import 'package:flutter/material.dart' show DateUtils;

import 'models/history_entry.dart';

/// The first day this phone can speak for when viewing [people]: the earliest
/// day it first knew one of them ([firstSeen], per person), or of any record
/// in [entries] if one is older, so a day with records is never before it.
///
/// Null when that can't be known: nobody to view, or someone this phone has
/// no first-seen moment for. Every day then reads as it did before.
DateTime? historySeenFrom({
  required Iterable<String> people,
  required Map<String, DateTime> firstSeen,
  required Iterable<HistoryEntry> entries,
}) {
  DateTime? from;
  void consider(DateTime? moment) {
    if (moment == null) return;
    final day = DateUtils.dateOnly(moment);
    if (from == null || day.isBefore(from!)) from = day;
  }

  if (people.isEmpty) return null;
  for (final id in people) {
    final seen = firstSeen[id];
    if (seen == null) return null;
    consider(seen.toLocal());
  }
  for (final e in entries) {
    consider(DateTime.tryParse(e.plannedLocalDate ?? ''));
    consider(e.takenAt?.toLocal());
    consider(e.recordedAt?.toLocal());
  }
  return from;
}
