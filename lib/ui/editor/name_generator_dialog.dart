import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:inkspacex/services/gemini_service.dart';

/// AI-powered character name generator. Replaces Scrivener's hardcoded
/// list (gender / country / alliteration) with a richer prompt-driven
/// generator. Returned suggestions can be inserted at the caret or
/// copied to the clipboard.
class NameGeneratorDialog extends StatefulWidget {
  const NameGeneratorDialog({super.key});

  static Future<String?> show(BuildContext context) {
    return showDialog<String>(
      context: context,
      builder: (_) => const NameGeneratorDialog(),
    );
  }

  @override
  State<NameGeneratorDialog> createState() => _NameGeneratorDialogState();
}

class _NameGeneratorDialogState extends State<NameGeneratorDialog> {
  final _genderCtrl = TextEditingController(text: 'female');
  final _originCtrl = TextEditingController(text: 'coastal Maine');
  final _eraCtrl = TextEditingController(text: '1920s');
  final _alliterationCtrl = TextEditingController();
  final _surnameCtrl = TextEditingController();
  int _count = 5;

  bool _loading = false;
  String? _error;
  List<String> _names = const [];

  @override
  void dispose() {
    _genderCtrl.dispose();
    _originCtrl.dispose();
    _eraCtrl.dispose();
    _alliterationCtrl.dispose();
    _surnameCtrl.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final names = await GeminiService().generateNames(
        gender: _genderCtrl.text.trim(),
        origin: _originCtrl.text.trim(),
        era: _eraCtrl.text.trim(),
        alliteration: _alliterationCtrl.text.trim(),
        surname: _surnameCtrl.text.trim(),
        count: _count,
      );
      setState(() {
        _names = names;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Could not generate names. Try again in a moment.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(
        'Generate names',
        style: GoogleFonts.inter(fontWeight: FontWeight.w700),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360, maxHeight: 460),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _field(_genderCtrl, 'Gender (e.g. female, male, nonbinary)'),
              _field(_originCtrl, 'Origin / culture (e.g. coastal Maine)'),
              _field(_eraCtrl, 'Era (e.g. 1920s, modern, fantasy)'),
              _field(_alliterationCtrl, 'Alliteration on letter (optional)'),
              _field(_surnameCtrl, 'Surname constraint (optional)'),
              Row(
                children: [
                  Text(
                    'Count: ',
                    style: GoogleFonts.inter(fontSize: 12),
                  ),
                  Expanded(
                    child: Slider(
                      value: _count.toDouble(),
                      min: 1,
                      max: 10,
                      divisions: 9,
                      label: _count.toString(),
                      onChanged: (v) => setState(() => _count = v.round()),
                    ),
                  ),
                  Text(_count.toString(),
                      style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: 8),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    _error!,
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              if (_names.isNotEmpty) ...[
                const Divider(),
                ...[for (final n in _names) _resultTile(n)],
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        ElevatedButton(
          onPressed: _loading ? null : _generate,
          child: _loading
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_names.isEmpty ? 'Generate' : 'Regenerate'),
        ),
      ],
    );
  }

  Widget _field(TextEditingController c, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: c,
        style: GoogleFonts.inter(fontSize: 13),
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
    );
  }

  Widget _resultTile(String name) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      title: Text(
        name,
        style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w500),
      ),
      trailing: Wrap(
        spacing: 4,
        children: [
          IconButton(
            tooltip: 'Insert at caret',
            icon: const Icon(Icons.subdirectory_arrow_left, size: 16),
            onPressed: () => Navigator.pop(context, name),
          ),
        ],
      ),
    );
  }
}
