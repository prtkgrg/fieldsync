import 'package:equatable/equatable.dart';

enum VisitStatus { planned, completed, cancelled }

/// A household visit: the one record type this demo syncs. The sync layer itself is type-agnostic.
class Visit extends Equatable {
  const Visit({
    required this.id,
    required this.household,
    required this.village,
    required this.status,
    this.notes = '',
    this.pending = false,
  });

  static const type = 'visit';

  final String id;
  final String household;
  final String village;
  final VisitStatus status;
  final String notes;

  /// True while local changes are waiting to be pushed.
  final bool pending;

  factory Visit.fromFields(String id, Map<String, dynamic> f, {bool pending = false}) => Visit(
        id: id,
        household: f['household'] as String? ?? '',
        village: f['village'] as String? ?? '',
        status: VisitStatus.values.asNameMap()[f['status']] ?? VisitStatus.planned,
        notes: f['notes'] as String? ?? '',
        pending: pending,
      );

  Map<String, dynamic> toFields() =>
      {'household': household, 'village': village, 'status': status.name, 'notes': notes};

  @override
  List<Object?> get props => [id, household, village, status, notes, pending];
}
