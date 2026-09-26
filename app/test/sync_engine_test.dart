import 'dart:convert';

import 'package:fieldsync_app/data/local_db.dart';
import 'package:fieldsync_app/data/visit_repository.dart';
import 'package:fieldsync_app/sync/sync_api.dart';
import 'package:fieldsync_app/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A minimal stand-in for the FieldSync server: applies every mutation, versions it, and serves
/// changes by cursor. Tests can make the next push fail or script conflict results.
class FakeServer implements SyncApi {
  final records = <String, RemoteRecord>{};
  final received = <List<OutgoingMutation>>[];
  final appliedIds = <String>{};
  int _version = 0;
  bool failNextPush = false;
  Map<String, List<FieldConflict>> conflictsFor = {};

  @override
  Future<List<MutationResult>> push(String deviceId, List<OutgoingMutation> mutations) async {
    if (failNextPush) {
      failNextPush = false;
      throw SyncApiException('network down');
    }
    received.add(mutations);
    return [
      for (final m in mutations)
        if (appliedIds.add(m.mutationId)) _apply(m) else MutationResult(
          mutationId: m.mutationId, recordId: m.recordId, status: 'APPLIED', version: records[m.recordId]!.version),
    ];
  }

  MutationResult _apply(OutgoingMutation m) {
    final current = records[m.recordId];
    final conflicts = conflictsFor[m.recordId] ?? const [];
    records[m.recordId] = RemoteRecord(
      id: m.recordId,
      type: m.type,
      fields: {...?current?.fields, ...?m.fields},
      version: ++_version,
      deleted: m.op == 'DELETE',
    );
    return MutationResult(
      mutationId: m.mutationId,
      recordId: m.recordId,
      status: conflicts.isEmpty ? 'APPLIED' : 'CONFLICT',
      version: _version,
      conflicts: conflicts,
    );
  }

  /// Simulates another device changing a record.
  void remoteEdit(String id, Map<String, dynamic> fields, {bool deleted = false}) {
    final current = records[id];
    records[id] = RemoteRecord(
      id: id,
      type: 'visit',
      fields: {...?current?.fields, ...fields},
      version: ++_version,
      deleted: deleted,
    );
  }

  @override
  Future<PullPage> pull(int cursor, {int limit = 500}) async {
    final changed = records.values.where((r) => r.version > cursor).toList()
      ..sort((a, b) => a.version.compareTo(b.version));
    final page = changed.take(limit).toList();
    return PullPage(
      records: page,
      nextCursor: page.isEmpty ? cursor : page.last.version,
      hasMore: changed.length > limit,
    );
  }
}

void main() {
  sqfliteFfiInit();

  late LocalDb local;
  late VisitRepository repo;
  late FakeServer server;
  late SyncEngine engine;

  setUp(() async {
    local = await LocalDb.open(databaseFactoryFfi, inMemoryDatabasePath);
    repo = VisitRepository(local);
    server = FakeServer();
    engine = SyncEngine(local, server);
  });

  tearDown(() => local.close());

  Future<Map<String, dynamic>> localFields(String id) async {
    final row = (await local.db.query('records', where: 'id = ?', whereArgs: [id])).single;
    return jsonDecode(row['fields'] as String) as Map<String, dynamic>;
  }

  Future<int?> baseVersion(String id) async =>
      (await local.db.query('records', where: 'id = ?', whereArgs: [id])).single['base_version'] as int?;

  test('offline edits are queued, then pushed and cleared on sync', () async {
    final id = await repo.save(fields: {'household': 'Sharma', 'village': 'Rampur'});
    expect(await repo.pendingCount(), 1);

    await engine.sync();

    expect(await repo.pendingCount(), 0);
    expect(server.records[id]!.fields, {'household': 'Sharma', 'village': 'Rampur'});
    expect(await baseVersion(id), server.records[id]!.version);
  });

  test('repeated edits before a sync go out as one mutation with only changed fields', () async {
    final id = await repo.save(fields: {'household': 'Sharma', 'status': 'planned'});
    await repo.save(id: id, fields: {'household': 'Sharma', 'status': 'completed'});
    await repo.save(id: id, fields: {'household': 'Sharma', 'status': 'completed', 'notes': 'ok'});

    await engine.sync();

    expect(server.received.single, hasLength(1));
    expect(server.received.single.single.fields, {'household': 'Sharma', 'status': 'completed', 'notes': 'ok'});
  });

  test('a failed push keeps changes and resends the same mutation ids', () async {
    await repo.save(fields: {'household': 'Sharma'});
    server.failNextPush = true;

    await expectLater(engine.sync(), throwsA(isA<SyncApiException>()));
    expect(await repo.pendingCount(), 1);

    await engine.sync();
    expect(await repo.pendingCount(), 0);
    expect(server.appliedIds, hasLength(1));
  });

  test('edits after a sync are based on the version the server returned', () async {
    final id = await repo.save(fields: {'household': 'Sharma'});
    await engine.sync();
    final v = server.records[id]!.version;

    await repo.save(id: id, fields: {'household': 'Sharma Ji'});
    await engine.sync();

    expect(server.received.last.single.baseVersion, v);
  });

  test('pull brings in records from other devices and advances the cursor', () async {
    server.remoteEdit('r1', {'household': 'Khan', 'village': 'Sonpur'});
    server.remoteEdit('r2', {'household': 'Das', 'village': 'Rampur'});

    final report = await engine.sync();

    expect(report!.pulled, 2);
    expect((await repo.list()).map((v) => v.household), containsAll(['Khan', 'Das']));
    expect(await local.getMeta(local.db, 'cursor'), '2');
    expect((await engine.sync())!.pulled, 0, reason: 'nothing new after the cursor');
  });

  test('pull pages through large change sets', () async {
    for (var i = 0; i < 1203; i++) {
      server.remoteEdit('r$i', {'household': 'H$i'});
    }
    await engine.sync();
    expect(await repo.list(), hasLength(1203));
  });

  test('local edits made during a sync survive the pull (rebase)', () async {
    final id = await repo.save(fields: {'household': 'Sharma', 'village': 'Rampur'});
    await engine.sync();

    // Another device changes the village; meanwhile this device edits notes and hasn't pushed yet.
    server.remoteEdit(id, {'village': 'Sonpur'});
    await repo.save(id: id, fields: {'household': 'Sharma', 'village': 'Rampur', 'notes': 'follow up'});
    await engine.sync();

    expect(await localFields(id), containsPair('village', 'Sonpur'));
    expect(await localFields(id), containsPair('notes', 'follow up'));
  });

  test('a delete from another device wins over local edits', () async {
    final id = await repo.save(fields: {'household': 'Sharma'});
    await engine.sync();
    server.remoteEdit(id, {}, deleted: true);

    // Pull runs before this device's next push reaches the server.
    await local.db.insert('outbox', {
      'mutation_id': 'late-edit',
      'record_id': id,
      'type': 'visit',
      'op': 'UPSERT',
      'fields': jsonEncode({'notes': 'x'}),
      'in_flight': 1,
    });
    await engine.sync();

    expect(await repo.list(), isEmpty);
    expect(await repo.pendingCount(), 0);
    expect(await repo.recentConflicts(), isNotEmpty);
  });

  test('conflicts reported by the server are recorded for the user', () async {
    final id = await repo.save(fields: {'status': 'cancelled'});
    server.conflictsFor[id] = const [
      FieldConflict(field: 'status', clientValue: 'cancelled', serverValue: 'completed', reason: 'changed'),
    ];

    final report = await engine.sync();

    expect(report!.conflicts, 1);
    expect((await repo.recentConflicts()).single['field'], 'status');
  });

  test('one push request never carries two mutations for the same record', () async {
    final id = await repo.save(fields: {'household': 'Sharma'});
    // A row left over from an interrupted push plus a newer edit to the same record.
    await local.db.update('outbox', {'in_flight': 1});
    await repo.save(id: id, fields: {'household': 'Sharma Ji'});
    await local.db.update('outbox', {'in_flight': 0});

    await engine.sync();

    for (final request in server.received) {
      final ids = request.map((m) => m.recordId).toList();
      expect(ids.toSet(), hasLength(ids.length));
    }
    expect(server.received, hasLength(2));
    expect(server.records[id]!.fields['household'], 'Sharma Ji');
  });
}
