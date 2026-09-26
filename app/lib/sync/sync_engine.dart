import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../data/local_db.dart';
import 'sync_api.dart';

class SyncReport {
  const SyncReport({this.pushed = 0, this.pulled = 0, this.conflicts = 0});

  final int pushed;
  final int pulled;
  final int conflicts;
}

/// Moves changes between the local store and the server: push the outbox, then pull until caught up.
///
/// Safe to interrupt at any point. Unsent changes stay in the outbox, a lost push response is
/// absorbed by the server's idempotency (same mutation IDs are resent), and the pull cursor only
/// advances in the same transaction that applies the page.
class SyncEngine {
  SyncEngine(this._local, this._api, {this.batchSize = 100, Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final LocalDb _local;
  final SyncApi _api;
  final int batchSize;
  final Uuid _uuid;

  bool _running = false;

  Database get _db => _local.db;

  bool get isRunning => _running;

  Future<String> deviceId() async {
    final existing = await _local.getMeta(_db, 'device_id');
    if (existing != null) return existing;
    final id = 'device-${_uuid.v4().substring(0, 8)}';
    await _local.setMeta(_db, 'device_id', id);
    return id;
  }

  /// Runs one full sync. Returns null if a sync is already running.
  Future<SyncReport?> sync() async {
    if (_running) return null;
    _running = true;
    try {
      final device = await deviceId();
      var pushed = 0;
      var conflicts = 0;
      while (true) {
        final round = await _pushRound(device);
        if (round == null) break;
        pushed += round.$1;
        conflicts += round.$2;
      }
      final pulled = await _pullAll();
      return SyncReport(pushed: pushed, pulled: pulled, conflicts: conflicts);
    } finally {
      _running = false;
    }
  }

  /// Sends one batch holding at most one mutation per record, so no mutation in a request is based
  /// on a version that an earlier one in the same request replaces. Returns (sent, conflicts), or
  /// null when the outbox is empty.
  Future<(int, int)?> _pushRound(String device) async {
    final batch = await _db.transaction((txn) async {
      final rows = await txn.rawQuery('''
        SELECT o.seq, o.mutation_id, o.record_id, o.type, o.op, o.fields, r.base_version
        FROM outbox o LEFT JOIN records r ON r.id = o.record_id
        WHERE o.in_flight = 0
        ORDER BY o.seq''');
      final seen = <String>{};
      final picked = <Map<String, Object?>>[];
      for (final row in rows) {
        if (picked.length == batchSize) break;
        if (seen.add(row['record_id'] as String)) picked.add(row);
      }
      if (picked.isNotEmpty) {
        await txn.rawUpdate(
            'UPDATE outbox SET in_flight = 1 WHERE seq IN (${List.filled(picked.length, '?').join(',')})',
            [for (final p in picked) p['seq']]);
      }
      return picked;
    });
    if (batch.isEmpty) return null;

    final List<MutationResult> results;
    try {
      results = await _api.push(device, [
        for (final row in batch)
          OutgoingMutation(
            mutationId: row['mutation_id'] as String,
            recordId: row['record_id'] as String,
            type: row['type'] as String,
            op: row['op'] as String,
            baseVersion: row['base_version'] as int?,
            fields: row['fields'] == null ? null : jsonDecode(row['fields'] as String) as Map<String, dynamic>,
          ),
      ]);
    } catch (_) {
      // Put the batch back; the same mutation IDs are resent next time, so a push that actually
      // reached the server is not applied twice.
      await _db.rawUpdate(
          'UPDATE outbox SET in_flight = 0 WHERE seq IN (${List.filled(batch.length, '?').join(',')})',
          [for (final b in batch) b['seq']]);
      rethrow;
    }

    var conflicts = 0;
    await _db.transaction((txn) async {
      final now = DateTime.now().toUtc().toIso8601String();
      for (final r in results) {
        await txn.delete('outbox', where: 'mutation_id = ?', whereArgs: [r.mutationId]);
        if (r.status != 'REJECTED') {
          // Later edits to this record build on our own write, not on the version before it.
          await txn.update('records', {'base_version': r.version}, where: 'id = ?', whereArgs: [r.recordId]);
        }
        final problems = r.status == 'REJECTED'
            ? [FieldConflict(reason: r.message ?? 'Rejected by the server')]
            : r.conflicts;
        for (final c in problems) {
          conflicts++;
          await txn.insert('conflicts', {
            'record_id': r.recordId,
            'field': c.field,
            'client_value': c.clientValue == null ? null : jsonEncode(c.clientValue),
            'server_value': c.serverValue == null ? null : jsonEncode(c.serverValue),
            'reason': c.reason,
            'at': now,
          });
        }
      }
    });
    return (batch.length, conflicts);
  }

  Future<int> _pullAll() async {
    var total = 0;
    var cursor = int.parse(await _local.getMeta(_db, 'cursor') ?? '0');
    while (true) {
      final page = await _api.pull(cursor);
      await _db.transaction((txn) async {
        for (final remote in page.records) {
          await _applyRemote(txn, remote);
        }
        await _local.setMeta(txn, 'cursor', page.nextCursor.toString());
      });
      total += page.records.length;
      cursor = page.nextCursor;
      if (!page.hasMore) return total;
    }
  }

  /// Takes the server's copy, then re-applies any local edits still waiting in the outbox (made
  /// while this sync was running), so nothing typed on the device is lost.
  Future<void> _applyRemote(Transaction txn, RemoteRecord remote) async {
    final pending = await txn.query('outbox', where: 'record_id = ?', whereArgs: [remote.id], orderBy: 'seq');
    final existing = await txn.query('records', columns: ['updated_at'], where: 'id = ?', whereArgs: [remote.id]);
    final updatedAt = existing.isEmpty
        ? DateTime.now().toUtc().toIso8601String()
        : existing.first['updated_at'] as String;

    var fields = remote.fields;
    var deleted = remote.deleted;
    if (remote.deleted && pending.isNotEmpty) {
      // Delete wins: local edits to a record deleted elsewhere are dropped and recorded.
      await txn.delete('outbox', where: 'record_id = ?', whereArgs: [remote.id]);
      await txn.insert('conflicts', {
        'record_id': remote.id,
        'reason': 'Deleted on another device; local changes discarded',
        'at': DateTime.now().toUtc().toIso8601String(),
      });
    } else if (pending.isNotEmpty) {
      deleted = pending.any((p) => p['op'] == 'DELETE');
      fields = {
        ...remote.fields,
        for (final p in pending)
          if (p['op'] == 'UPSERT') ...jsonDecode(p['fields'] as String) as Map<String, dynamic>,
      };
    }

    await txn.insert(
      'records',
      {
        'id': remote.id,
        'type': remote.type,
        'fields': jsonEncode(fields),
        'base_version': remote.version,
        'deleted': deleted ? 1 : 0,
        'updated_at': updatedAt,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
