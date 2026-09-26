import 'package:flutter_bloc/flutter_bloc.dart';

import '../data/visit.dart';
import '../data/visit_repository.dart';

class VisitsCubit extends Cubit<List<Visit>> {
  VisitsCubit(this._repo) : super(const []);

  final VisitRepository _repo;

  Future<void> load() async => emit(await _repo.list());

  Future<void> save({String? id, required Map<String, dynamic> fields}) async {
    await _repo.save(id: id, fields: fields);
    await load();
  }

  Future<void> delete(String id) async {
    await _repo.delete(id);
    await load();
  }
}
