import 'dart:convert';

import 'package:http/http.dart' as http;

class OutgoingMutation {
  const OutgoingMutation({
    required this.mutationId,
    required this.recordId,
    required this.type,
    required this.op,
    this.baseVersion,
    this.fields,
  });

  final String mutationId;
  final String recordId;
  final String type;
  final String op;
  final int? baseVersion;
  final Map<String, dynamic>? fields;

  Map<String, dynamic> toJson() => {
        'mutationId': mutationId,
        'recordId': recordId,
        'type': type,
        'op': op,
        if (baseVersion != null) 'baseVersion': baseVersion,
        if (fields != null) 'fields': fields,
      };
}

class FieldConflict {
  const FieldConflict({this.field, this.clientValue, this.serverValue, required this.reason});

  final String? field;
  final Object? clientValue;
  final Object? serverValue;
  final String reason;

  factory FieldConflict.fromJson(Map<String, dynamic> j) => FieldConflict(
        field: j['field'] as String?,
        clientValue: j['clientValue'],
        serverValue: j['serverValue'],
        reason: j['reason'] as String,
      );
}

class MutationResult {
  const MutationResult({
    required this.mutationId,
    required this.recordId,
    required this.status,
    required this.version,
    this.conflicts = const [],
    this.message,
  });

  final String mutationId;
  final String recordId;

  /// APPLIED, MERGED, CONFLICT or REJECTED.
  final String status;
  final int version;
  final List<FieldConflict> conflicts;
  final String? message;

  factory MutationResult.fromJson(Map<String, dynamic> j) => MutationResult(
        mutationId: j['mutationId'] as String,
        recordId: j['recordId'] as String,
        status: j['status'] as String,
        version: (j['version'] as num).toInt(),
        conflicts: [
          for (final c in (j['conflicts'] as List? ?? const [])) FieldConflict.fromJson(c as Map<String, dynamic>),
        ],
        message: j['message'] as String?,
      );
}

class RemoteRecord {
  const RemoteRecord({
    required this.id,
    required this.type,
    required this.fields,
    required this.version,
    required this.deleted,
  });

  final String id;
  final String type;
  final Map<String, dynamic> fields;
  final int version;
  final bool deleted;

  factory RemoteRecord.fromJson(Map<String, dynamic> j) => RemoteRecord(
        id: j['id'] as String,
        type: j['type'] as String,
        fields: (j['fields'] as Map<String, dynamic>?) ?? const {},
        version: (j['version'] as num).toInt(),
        deleted: j['deleted'] as bool,
      );
}

class PullPage {
  const PullPage({required this.records, required this.nextCursor, required this.hasMore});

  final List<RemoteRecord> records;
  final int nextCursor;
  final bool hasMore;

  factory PullPage.fromJson(Map<String, dynamic> j) => PullPage(
        records: [for (final r in j['records'] as List) RemoteRecord.fromJson(r as Map<String, dynamic>)],
        nextCursor: (j['nextCursor'] as num).toInt(),
        hasMore: j['hasMore'] as bool,
      );
}

/// The two FieldSync endpoints. Abstract so the sync engine can be tested without a server.
abstract class SyncApi {
  Future<List<MutationResult>> push(String deviceId, List<OutgoingMutation> mutations);

  Future<PullPage> pull(int cursor, {int limit = 500});
}

class SyncApiException implements Exception {
  SyncApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class HttpSyncApi implements SyncApi {
  HttpSyncApi(this.baseUrl, {http.Client? client, this.timeout = const Duration(seconds: 20)})
      : _client = client ?? http.Client();

  final String baseUrl;
  final Duration timeout;
  final http.Client _client;

  @override
  Future<List<MutationResult>> push(String deviceId, List<OutgoingMutation> mutations) async {
    final res = await _client
        .post(
          Uri.parse('$baseUrl/api/v1/sync/push'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'deviceId': deviceId, 'mutations': [for (final m in mutations) m.toJson()]}),
        )
        .timeout(timeout);
    final body = _decode(res);
    return [for (final r in body['results'] as List) MutationResult.fromJson(r as Map<String, dynamic>)];
  }

  @override
  Future<PullPage> pull(int cursor, {int limit = 500}) async {
    final res = await _client
        .get(Uri.parse('$baseUrl/api/v1/sync/pull?cursor=$cursor&limit=$limit'))
        .timeout(timeout);
    return PullPage.fromJson(_decode(res));
  }

  Map<String, dynamic> _decode(http.Response res) {
    if (res.statusCode != 200) {
      throw SyncApiException('Server returned ${res.statusCode}: ${res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }
}
