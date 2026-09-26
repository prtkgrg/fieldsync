import 'package:fieldsync_app/data/visit.dart';
import 'package:fieldsync_app/ui/visit_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<Map<String, dynamic>?> editAndSave(WidgetTester tester, Visit? visit, Future<void> Function() edit) async {
    Map<String, dynamic>? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await Navigator.of(context)
              .push<Map<String, dynamic>>(MaterialPageRoute(builder: (_) => VisitForm(visit: visit))),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await edit();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('editing sends only the fields the user changed', (tester) async {
    // A record that arrived without a notes field: the form shows it as empty.
    final visit = Visit.fromFields('v1', {'household': 'Sharma', 'village': 'Sonpur', 'status': 'completed'});

    final result = await editAndSave(tester, visit, () async {
      await tester.tap(find.text('cancelled'));
      await tester.pump();
    });

    expect(result, {'status': 'cancelled'});
  });

  testWidgets('a new visit sends every field', (tester) async {
    final result = await editAndSave(tester, null, () async {
      await tester.enterText(find.widgetWithText(TextFormField, 'Household'), 'Verma');
      await tester.enterText(find.widgetWithText(TextFormField, 'Village'), 'Rampur');
    });

    expect(result, {'household': 'Verma', 'village': 'Rampur', 'status': 'planned', 'notes': ''});
  });
}
