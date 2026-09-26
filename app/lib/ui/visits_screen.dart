import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../data/visit.dart';
import 'sync_cubit.dart';
import 'visit_form.dart';
import 'visits_cubit.dart';

class VisitsScreen extends StatelessWidget {
  const VisitsScreen({super.key});

  Future<void> _edit(BuildContext context, [Visit? visit]) async {
    final visits = context.read<VisitsCubit>();
    final sync = context.read<SyncCubit>();
    final fields = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(builder: (_) => VisitForm(visit: visit)),
    );
    if (fields == null) return;
    await visits.save(id: visit?.id, fields: fields);
    await sync.refreshPending();
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<SyncCubit, SyncState>(
      listenWhen: (a, b) => b.newConflicts > 0 && a.newConflicts != b.newConflicts,
      listener: (context, s) {
        final plural = s.newConflicts == 1 ? 'change' : 'changes';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${s.newConflicts} $plural conflicted with another device. The server version was kept.'),
        ));
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('FieldSync visits'),
          actions: [
            BlocBuilder<SyncCubit, SyncState>(
              builder: (context, s) => IconButton(
                tooltip: 'Sync now',
                onPressed: s.syncing ? null : context.read<SyncCubit>().syncNow,
                icon: s.syncing
                    ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.sync),
              ),
            ),
          ],
          bottom: const PreferredSize(preferredSize: Size.fromHeight(28), child: _SyncBar()),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _edit(context),
          icon: const Icon(Icons.add),
          label: const Text('New visit'),
        ),
        body: BlocBuilder<VisitsCubit, List<Visit>>(
          builder: (context, visits) {
            if (visits.isEmpty) {
              return const Center(child: Text('No visits yet. Add one, even offline.'));
            }
            return ListView.separated(
              itemCount: visits.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) => _VisitTile(visit: visits[i], onTap: () => _edit(context, visits[i])),
            );
          },
        ),
      ),
    );
  }
}

class _VisitTile extends StatelessWidget {
  const _VisitTile({required this.visit, required this.onTap});

  final Visit visit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: ValueKey(visit.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Theme.of(context).colorScheme.errorContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.delete),
      ),
      onDismissed: (_) async {
        final sync = context.read<SyncCubit>();
        await context.read<VisitsCubit>().delete(visit.id);
        await sync.refreshPending();
      },
      child: ListTile(
        title: Text(visit.household),
        subtitle: Text('${visit.village} · ${visit.status.name}'),
        trailing: visit.pending
            ? const Tooltip(message: 'Waiting to sync', child: Icon(Icons.cloud_upload_outlined))
            : const Icon(Icons.cloud_done_outlined),
        onTap: onTap,
      ),
    );
  }
}

class _SyncBar extends StatelessWidget {
  const _SyncBar();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SyncCubit, SyncState>(
      builder: (context, s) {
        final last = s.lastSyncedAt == null
            ? 'not synced yet'
            : 'synced ${TimeOfDay.fromDateTime(s.lastSyncedAt!).format(context)}';
        final parts = [
          if (s.deviceId.isNotEmpty) s.deviceId,
          if (s.pending > 0) '${s.pending} waiting',
          s.error != null ? 'offline' : last,
        ];
        final theme = Theme.of(context);
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            parts.join(' · '),
            style: theme.textTheme.bodySmall?.copyWith(color: s.error != null ? theme.colorScheme.error : null),
          ),
        );
      },
    );
  }
}
