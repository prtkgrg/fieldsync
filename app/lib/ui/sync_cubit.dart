import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../data/visit_repository.dart';
import '../sync/sync_engine.dart';

class SyncState extends Equatable {
  const SyncState({
    this.syncing = false,
    this.pending = 0,
    this.lastSyncedAt,
    this.error,
    this.newConflicts = 0,
    this.deviceId = '',
  });

  final bool syncing;
  final int pending;
  final DateTime? lastSyncedAt;
  final String? error;

  /// Conflicts reported by the last sync, for a one-off notice.
  final int newConflicts;
  final String deviceId;

  SyncState copyWith({
    bool? syncing,
    int? pending,
    DateTime? lastSyncedAt,
    String? Function()? error,
    int? newConflicts,
    String? deviceId,
  }) =>
      SyncState(
        syncing: syncing ?? this.syncing,
        pending: pending ?? this.pending,
        lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
        error: error != null ? error() : this.error,
        newConflicts: newConflicts ?? this.newConflicts,
        deviceId: deviceId ?? this.deviceId,
      );

  @override
  List<Object?> get props => [syncing, pending, lastSyncedAt, error, newConflicts, deviceId];
}

/// Runs sync on demand and every [interval] while the app is open. Offline is a normal state here:
/// a failed sync just leaves changes queued and shows when the last good sync was.
class SyncCubit extends Cubit<SyncState> {
  SyncCubit(this._engine, this._repo, {this.interval = const Duration(seconds: 30), this.onSynced})
      : super(const SyncState());

  final SyncEngine _engine;
  final VisitRepository _repo;
  final Duration interval;

  /// Called after a sync that may have changed local data, so lists can reload.
  final Future<void> Function()? onSynced;

  Timer? _timer;

  Future<void> start() async {
    emit(state.copyWith(deviceId: await _engine.deviceId()));
    await refreshPending();
    _timer = Timer.periodic(interval, (_) => syncNow());
    unawaited(syncNow());
  }

  Future<void> refreshPending() async => emit(state.copyWith(pending: await _repo.pendingCount()));

  Future<void> syncNow() async {
    if (state.syncing) return;
    emit(state.copyWith(syncing: true, newConflicts: 0));
    try {
      final report = await _engine.sync();
      emit(state.copyWith(
        syncing: false,
        lastSyncedAt: DateTime.now(),
        error: () => null,
        newConflicts: report?.conflicts ?? 0,
        pending: await _repo.pendingCount(),
      ));
    } catch (e) {
      emit(state.copyWith(syncing: false, error: () => 'Offline: $e', pending: await _repo.pendingCount()));
    }
    await onSynced?.call();
  }

  @override
  Future<void> close() {
    _timer?.cancel();
    return super.close();
  }
}
