import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/medication/medication_detail_provider.dart';
import '../../../core/workspace/workspace_provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/care_state.dart';
import '../../pills/presentation/pills_screen.dart';

class SchedulesScreen extends ConsumerWidget {
  const SchedulesScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final list = ref.watch(medicationListProvider);
    final workspace = ref.watch(workspaceContextProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l.t09_routine)),
      body: list.hasError || workspace.hasError
          ? CareState(
              title: l.t08_unavailable,
              body: l.t08_unavailableBody,
              actionLabel: l.shared_retry,
              action: () => ref.invalidate(medicationListProvider),
            )
          : list.isLoading || workspace.isLoading
          ? CareState(title: l.shared_loading, loading: true)
          : list.requireValue.isEmpty
          ? CareState(
              title: l.schedules_emptyTitle,
              body: l.schedules_emptySubtitle,
              actionLabel: l.schedules_emptyCta,
              action: () => context.go('/pills'),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(24),
              itemCount: list.requireValue.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final detail = list.requireValue[index];
                return Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.all(20),
                    title: Text(detail.pill.name),
                    subtitle: Text(
                      '${detail.person.name}\n${medicationRoutineLabel(context, detail, local: workspace.requireValue.isLocal)}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () =>
                        context.push('/pills/${detail.pill.id}/routine'),
                  ),
                );
              },
            ),
    );
  }
}
