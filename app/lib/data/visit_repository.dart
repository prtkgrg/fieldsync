import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'local_db.dart';
import 'visit.dart';

/// Local reads and writes. A save updates the local copy and queues the change for the next push,
/// in one transaction, so the UI never waits on the network.
class VisitRepository {
  VisitRepository(this._local, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final LocalDb _local;
  final Uuid _uuid;

  Database get _db => _local.db;

  Future<List<Visit>> list() async {
    final rows = await _db.rawQuery('''
      SELECT r.id, r.fields, EXISTS(SELECT 1 FROM outbox o WHERE o.record_id = r.id) AS pending
      FROM records r
      WHERE r.type = ? AND r.deleted = 0
      ORDER BY r.updated_at DESC''', [Visit.type]);
    return [
      for (final r in rows)
        Visit.fromFields(r['id'] as String, jsonDecode(r['fields'] as String) as Map<String, dynamic>,
            pending: (r['pending'] as int) == 1),
    ];
  }

  /// Creates a visit (null [id]) or saves changes to one. Only fields that changed are queued.
  Future<String> save({String? id, required Map<String, dynamic> fields}) async {
    final recordId = id ?? _uuid.v4();
    await _db.transaction((txn) async {
      final existing = await txn.query('records', where: 'id = ?', whereArgs: [recordId]);
      final current = existing.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(existing.first['fields'] as String) as Map<String, dynamic>;
      final changed = {
        for (final e in fields.entries)
          if (current[e.key] != e.value) e.key: e.value,
      };
      if (changed.isEmpty) return;

      await txn.insert(
        'records',
        {
          'id': recordId,
          'type': Visit.type,
          'fields': jsonEncode({...current, ...changed}),
          'base_version': existing.isEmpty ? null : existing.first['base_version'],
          'deleted': 0,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await _queueUpsert(txn, recordId, changed);
    });
    return recordId;
  }

  Future<void> delete(String id) => _db.transaction((txn) async {
        await txn.update('records', {'deleted': 1, 'updated_at': DateTime.now().toUtc().toIso8601String()},
            where: 'id = ?', whereArgs: [id]);
        // Queued edits that haven't been sent are moot once the record is deleted.
        await txn.delete('outbox', where: 'record_id = ? AND in_flight = 0', whereArgs: [id]);
        await txn.insert('outbox', {
          'mutation_id': _uuid.v4(),
          'record_id': id,
          'type': Visit.type,
          'op': 'DELETE',
        });
      });

  /// Merges into a queued, not-yet-sent upsert for the same record, so one push carries one
  /// change per record. Rows already on the wire are left alone.
  Future<void> _queueUpsert(Transaction txn, String recordId, Map<String, dynamic> changed) async {
    final queued = await txn.query('outbox',
        where: "record_id = ? AND op = 'UPSERT' AND in_flight = 0", whereArgs: [recordId], limit: 1);
    if (queued.isNotEmpty) {
      final merged = {...jsonDecode(queued.first['fields'] as String) as Map<String, dynamic>, ...changed};
      await txn.update('outbox', {'fields': jsonEncode(merged)},
          where: 'seq = ?', whereArgs: [queued.first['seq']]);
    } else {
      await txn.insert('outbox', {
        'mutation_id': _uuid.v4(),
        'record_id': recordId,
        'type': Visit.type,
        'op': 'UPSERT',
        'fields': jsonEncode(changed),
      });
    }
  }

  Future<int> pendingCount() async =>
      Sqflite.firstIntValue(await _db.rawQuery('SELECT COUNT(*) FROM outbox')) ?? 0;

  Future<List<Map<String, Object?>>> recentConflicts({int limit = 20}) =>
      _db.query('conflicts', orderBy: 'id DESC', limit: limit);
}
