import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../../core/db/database.dart';
import '../../../shared/format/clock.dart';
import '../../../core/sync/auto_sync_service.dart';
import '../../../core/workspace/workspace_provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/layouts/window_size.dart';
import '../../../shared/widgets/readable_zone_picker.dart';
import '../../../shared/widgets/review_failure_message.dart';
import '../../pills/legacy_routine_review_repository.dart';
import '../../pills/schedule_provider.dart';
import '../../profiles/profile_provider.dart';
import 'settings_overview.dart';

final legacyRoutineReviewRepositoryProvider =
    FutureProvider<LegacyRoutineReviewRepository>((ref) async {
      final context = await ref.watch(workspaceContextProvider.future);
      return LegacyRoutineReviewRepository(
        database: ref.watch(databaseProvider),
        access: ref.watch(workspaceAccessRepositoryProvider),
        context: context,
        schedules: ref.watch(scheduleRepositoryProvider),
      );
    });

/// A read-only preview until the user confirms the exact captured batch.
class LegacyRoutineReviewScreen extends ConsumerStatefulWidget {
  const LegacyRoutineReviewScreen({super.key});

  @override
  ConsumerState<LegacyRoutineReviewScreen> createState() =>
      _LegacyRoutineReviewScreenState();
}

class _LegacyRoutineReviewScreenState
    extends ConsumerState<LegacyRoutineReviewScreen> {
  String _timeZone = 'Europe/Bucharest';
  late DateTime _effectiveDate;
  LegacyRoutineReviewRepository? _repository;
  LegacyRoutineReviewPreview? _preview;
  LegacyRoutineReviewResult? _result;
  bool _loading = true;
  bool _applying = false;
  bool _submitted = false;
  bool _loadFailed = false;
  bool _applyFailed = false;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    final now = tz.TZDateTime.now(tz.getLocation(_timeZone));
    _effectiveDate = DateTime(now.year, now.month, now.day);
    Future.microtask(_load);
  }

  Future<void> _load() async {
    if (!mounted) return;
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _loadFailed = false;
      _preview = null;
    });
    try {
      final repository = await ref.read(
        legacyRoutineReviewRepositoryProvider.future,
      );
      final preview = await repository.preview(
        timeZone: _timeZone,
        effectiveFromLocalDate: _effectiveDate,
      );
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _repository = repository;
        _preview = preview;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  Future<void> _pickDate() async {
    final now = tz.TZDateTime.now(tz.getLocation(_timeZone));
    final today = DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: _effectiveDate.isBefore(today) ? today : _effectiveDate,
      firstDate: today,
      lastDate: DateTime(today.year + 5, 12, 31),
    );
    if (picked == null || !mounted) return;
    setState(() => _effectiveDate = picked);
    await _load();
  }

  Future<void> _apply() async {
    final preview = _preview;
    final repository = _repository;
    if (_applying || preview == null || repository == null) return;
    setState(() {
      _applying = true;
      _submitted = true;
      _applyFailed = false;
    });
    try {
      final result = await repository.apply(preview);
      if (!mounted) return;
      setState(() {
        _result = result;
        _applying = false;
        _applyFailed = !result.isComplete;
      });
      if (result.acceptedCount > 0) {
        // Pull is the only authority that clears issues and publishes routines.
        // A failed pull must not turn an accepted receipt into a freshness claim.
        try {
          await ref
              .read(autoSyncServiceProvider)
              .syncNow(ref.read(currentUserIdProvider));
        } catch (_) {
          // The accepted receipt stays visible; Data exposes sync diagnostics.
        }
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _applying = false;
        _applyFailed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final date = DateFormat.yMMMMd(locale).format(_effectiveDate);
    final preview = _preview;
    final result = _result;
    final complete = result?.isComplete == true;
    return PopScope(
      canPop: !_applying,
      child: Scaffold(
        appBar: settingsDetailAppBar(context, l.legacyReview_title),
        body: ContentListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Text(l.legacyReview_intro, style: text.bodyLarge),
            const SizedBox(height: 20),
            Text(l.legacyReview_zone, style: text.labelLarge),
            const SizedBox(height: 4),
            OutlinedButton.icon(
              key: const ValueKey('legacy-review-zone'),
              onPressed: _submitted
                  ? null
                  : () async {
                      final value = await chooseReadableZone(context);
                      if (value == null || !mounted || value == _timeZone) {
                        return;
                      }
                      setState(() => _timeZone = value);
                      await _load();
                    },
              icon: const Icon(Icons.public_outlined),
              label: Text(readableZone(context, _timeZone)),
            ),
            const SizedBox(height: 16),
            Text(l.legacyReview_from, style: text.labelLarge),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const ValueKey('legacy-review-date'),
                onPressed: _submitted ? null : _pickDate,
                icon: const Icon(Icons.calendar_today_outlined),
                label: Text(date),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l.legacyReview_boundary(date, readableZone(context, _timeZone)),
            ),
            const SizedBox(height: 24),
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else if (_loadFailed) ...[
              Text(l.legacyReview_loadError),
              TextButton(onPressed: _load, child: Text(l.legacyReview_retry)),
            ] else if (preview != null) ...[
              Text(
                l.legacyReview_ready(preview.items.length),
                style: text.titleMedium,
              ),
              const SizedBox(height: 12),
              for (final item in preview.items) ...[
                _RoutinePreviewCard(item: item, timeZone: _timeZone),
                const SizedBox(height: 8),
              ],
              if (preview.items.isEmpty) Text(l.legacyReview_noChanges),
              if (preview.invalidCount > 0) ...[
                const SizedBox(height: 12),
                Text(l.legacyReview_invalid(preview.invalidCount)),
              ],
              if (preview.unavailableCount > 0) ...[
                const SizedBox(height: 12),
                Text(l.legacyReview_unavailable(preview.unavailableCount)),
              ],
              const SizedBox(height: 16),
              Text(l.legacyReview_scope, style: text.bodySmall),
            ],
            if (result != null || _applyFailed) ...[
              const SizedBox(height: 20),
              Semantics(
                liveRegion: true,
                child: Text(
                  complete
                      ? l.legacyReview_saved(result!.acceptedCount)
                      : result != null
                      ? l.legacyReview_partial(
                          result.acceptedCount,
                          result.totalCount,
                        )
                      : l.legacyReview_applyError,
                  style: text.bodyLarge,
                ),
              ),
              if (result?.error != null) ...[
                const SizedBox(height: 8),
                Semantics(
                  liveRegion: true,
                  child: Text(reviewFailureMessage(l, result!.error!)),
                ),
              ],
            ],
            if (preview != null && preview.items.isNotEmpty) ...[
              const SizedBox(height: 20),
              FilledButton(
                key: const ValueKey('legacy-review-confirm'),
                onPressed: _applying
                    ? null
                    : complete
                    ? () => Navigator.of(context).pop()
                    : _apply,
                child: Text(
                  _applying
                      ? l.shared_loading
                      : complete
                      ? l.t10_done
                      : _submitted
                      ? l.legacyReview_retry
                      : l.legacyReview_confirm(preview.items.length),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RoutinePreviewCard extends StatelessWidget {
  const _RoutinePreviewCard({required this.item, required this.timeZone});
  final LegacyRoutineReviewItem item;
  final String timeZone;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final schedule = item.schedule;
    final time = clockTime(
      context,
      TimeOfDay(hour: schedule.hour, minute: schedule.minute),
    );
    final days = item.frequencyDays;
    final frequency = schedule.frequency == 'daily'
        ? l.schedules_daily
        : (days ?? const <int>[])
              .map(
                (day) => DateFormat.E(
                  locale,
                ).format(DateTime.utc(2026, 6, 1 + day - 1)),
              )
              .join(', ');
    final next = item.nextDoseAt;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(item.pillName, style: text.titleMedium),
            Text(item.personName, style: text.bodyMedium),
            const SizedBox(height: 10),
            Text('$time · $frequency', style: text.titleSmall),
            const SizedBox(height: 6),
            Text(
              next == null
                  ? l.legacyReview_inactive
                  : l.legacyReview_next(
                      clockDateTime(
                        context,
                        tz.TZDateTime.from(next, tz.getLocation(timeZone)),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
