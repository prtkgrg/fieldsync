import 'package:sqflite/sqflite.dart';

/// On-device SQLite store. Everything the user does lands here first, so the app works offline.
class LocalDb {
  LocalDb._(this.db);

  final Database db;

  static Future<LocalDb> open(DatabaseFactory factory, String path) async {
    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 1, onCreate: _create),
    );
    return LocalDb._(db);
  }

  static Future<void> _create(Database db, int version) async {
    // The device's copy of each record. base_version is the server version this copy is based on
    // (null until the record has reached the server).
    await db.execute('''
      CREATE TABLE records (
        id TEXT PRIMARY KEY,
        type TEXT NOT NULL,
        fields TEXT NOT NULL,
        base_version INTEGER,
        deleted INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL
      )''');
    // Changes waiting to be pushed, oldest first. in_flight marks rows in the request being sent,
    // so later edits don't get merged into a request that is already on the wire.
    await db.execute('''
      CREATE TABLE outbox (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        mutation_id TEXT NOT NULL UNIQUE,
        record_id TEXT NOT NULL,
        type TEXT NOT NULL,
        op TEXT NOT NULL,
        fields TEXT,
        in_flight INTEGER NOT NULL DEFAULT 0
      )''');
    await db.execute('''
      CREATE TABLE conflicts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        record_id TEXT NOT NULL,
        field TEXT,
        client_value TEXT,
        server_value TEXT,
        reason TEXT NOT NULL,
        at TEXT NOT NULL
      )''');
    await db.execute('CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
  }

  Future<String?> getMeta(DatabaseExecutor ex, String key) async {
    final rows = await ex.query('meta', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> setMeta(DatabaseExecutor ex, String key, String value) =>
      ex.insert('meta', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> close() => db.close();
}
