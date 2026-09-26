import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'data/visit_repository.dart';
import 'di.dart';
import 'sync/sync_engine.dart';
import 'ui/sync_cubit.dart';
import 'ui/visits_cubit.dart';
import 'ui/visits_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await setupDependencies();
  runApp(const FieldSyncApp());
}

class FieldSyncApp extends StatelessWidget {
  const FieldSyncApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(create: (_) => VisitsCubit(getIt<VisitRepository>())..load()),
        BlocProvider(
          create: (context) => SyncCubit(
            getIt<SyncEngine>(),
            getIt<VisitRepository>(),
            onSynced: context.read<VisitsCubit>().load,
          )..start(),
        ),
      ],
      child: MaterialApp(
        title: 'FieldSync',
        theme: ThemeData(colorSchemeSeed: const Color(0xFF3F7D20), useMaterial3: true),
        home: const VisitsScreen(),
      ),
    );
  }
}
