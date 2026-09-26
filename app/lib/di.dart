import 'package:get_it/get_it.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'data/local_db.dart';
import 'data/visit_repository.dart';
import 'sync/sync_api.dart';
import 'sync/sync_engine.dart';

final getIt = GetIt.instance;

/// Android emulator reaches the host machine at 10.0.2.2. Override with
/// `--dart-define=SERVER_URL=http://HOST:8080` for a real device.
const serverUrl = String.fromEnvironment('SERVER_URL', defaultValue: 'http://10.0.2.2:8080');

Future<void> setupDependencies() async {
  final local = await LocalDb.open(databaseFactory, p.join(await getDatabasesPath(), 'fieldsync.db'));
  getIt
    ..registerSingleton<LocalDb>(local)
    ..registerSingleton<SyncApi>(HttpSyncApi(serverUrl))
    ..registerSingleton<VisitRepository>(VisitRepository(local))
    ..registerSingleton<SyncEngine>(SyncEngine(local, getIt<SyncApi>()));
}
