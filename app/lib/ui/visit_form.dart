import 'package:flutter/material.dart';

import '../data/visit.dart';

/// Add or edit a visit. Returns the fields to save, or null if cancelled.
class VisitForm extends StatefulWidget {
  const VisitForm({super.key, this.visit});

  final Visit? visit;

  @override
  State<VisitForm> createState() => _VisitFormState();
}

class _VisitFormState extends State<VisitForm> {
  final _formKey = GlobalKey<FormState>();
  late final _household = TextEditingController(text: widget.visit?.household);
  late final _village = TextEditingController(text: widget.visit?.village);
  late final _notes = TextEditingController(text: widget.visit?.notes);
  late VisitStatus _status = widget.visit?.status ?? VisitStatus.planned;

  @override
  void dispose() {
    _household.dispose();
    _village.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final values = <String, dynamic>{
      'household': _household.text.trim(),
      'village': _village.text.trim(),
      'status': _status.name,
      'notes': _notes.text.trim(),
    };
    // Only send what the user changed. Sending untouched fields would claim edits the user never
    // made and turn another device's real change into a false conflict.
    final before = widget.visit?.toFields();
    Navigator.of(context).pop(before == null
        ? values
        : {for (final e in values.entries) if (before[e.key] != e.value) e.key: e.value});
  }

  String? _required(String? v) => (v == null || v.trim().isEmpty) ? 'Required' : null;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.visit == null ? 'New visit' : 'Edit visit')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _household,
              decoration: const InputDecoration(labelText: 'Household'),
              validator: _required,
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _village,
              decoration: const InputDecoration(labelText: 'Village'),
              validator: _required,
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 16),
            SegmentedButton<VisitStatus>(
              segments: [
                for (final s in VisitStatus.values) ButtonSegment(value: s, label: Text(s.name)),
              ],
              selected: {_status},
              onSelectionChanged: (s) => setState(() => _status = s.first),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _notes,
              decoration: const InputDecoration(labelText: 'Notes'),
              maxLines: 3,
            ),
            const SizedBox(height: 24),
            FilledButton(onPressed: _submit, child: const Text('Save')),
          ],
        ),
      ),
    );
  }
}
