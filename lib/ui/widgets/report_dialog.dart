import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/provider/auth_provider.dart';

/// Wire-format target types — must match `TARGET_TYPES` in
/// `backend/app/models/report.py`.
class ReportTarget {
  static const story = 'story';
  static const comment = 'comment';
  static const user = 'user';
  static const chatMessage = 'chat_message';
}

class _ReasonOption {
  const _ReasonOption(this.value, this.label, this.subtitle);
  final String value;
  final String label;
  final String subtitle;
}

const List<_ReasonOption> _reasons = [
  _ReasonOption('spam', 'Spam', 'Repetitive, scammy, or unwanted promotion'),
  _ReasonOption('harassment', 'Harassment',
      'Bullying, threats, or targeted abuse'),
  _ReasonOption('hate', 'Hate speech',
      'Slurs or attacks on a protected group'),
  _ReasonOption(
      'sexual', 'Sexual content', 'Explicit or inappropriate sexual content'),
  _ReasonOption(
      'violence', 'Violence', 'Graphic violence or threats of violence'),
  _ReasonOption('self_harm', 'Self-harm',
      'Promotes or glorifies self-harm or suicide'),
  _ReasonOption('other', 'Something else', 'Tell us more in the note'),
];

/// Show the report sheet for [targetId] of [targetType]. Returns true
/// when the user submitted, false / null otherwise.
Future<bool?> showReportSheet(
  BuildContext context, {
  required String targetType,
  required String targetId,
  String? targetLabel,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => ReportSheet(
      targetType: targetType,
      targetId: targetId,
      targetLabel: targetLabel,
    ),
  );
}

class ReportSheet extends StatefulWidget {
  const ReportSheet({
    super.key,
    required this.targetType,
    required this.targetId,
    this.targetLabel,
  });

  final String targetType;
  final String targetId;
  final String? targetLabel;

  @override
  State<ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<ReportSheet> {
  String? _reason;
  final _noteCtrl = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final reason = _reason;
    if (reason == null) return;
    setState(() => _submitting = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final navigator = Navigator.of(context);
    try {
      final api = context.read<AuthProvider>().dataService;
      await api.submitReport(
        targetType: widget.targetType,
        targetId: widget.targetId,
        reason: reason,
        note: _noteCtrl.text.trim(),
      );
      if (!mounted) return;
      navigator.pop(true);
      messenger?.showSnackBar(
        const SnackBar(
          content: Text('Thanks — our team will review this.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not submit report: $e')),
      );
    }
  }

  String get _heading {
    switch (widget.targetType) {
      case ReportTarget.story:
        return 'Report this story';
      case ReportTarget.comment:
        return 'Report this comment';
      case ReportTarget.user:
        return 'Report this user';
      case ReportTarget.chatMessage:
        return 'Report this message';
      default:
        return 'Report';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark ? const Color(0xFF1A1A1A) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtleColor =
        isDark ? Colors.white60 : const Color(0xFF64748B);
    final viewInsets = MediaQuery.viewInsetsOf(context);

    return Container(
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(0, 0, 0, viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 8),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: isDark ? Colors.white24 : Colors.black12,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
              child: Row(
                children: [
                  Icon(CupertinoIcons.flag, color: textColor, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _heading,
                      style: GoogleFonts.inter(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: textColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (widget.targetLabel != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(
                  widget.targetLabel!,
                  style: GoogleFonts.inter(fontSize: 13, color: subtleColor),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            Divider(
              height: 1,
              color:
                  isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.06),
            ),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final r in _reasons)
                      ListTile(
                        dense: true,
                        onTap: _submitting
                            ? null
                            : () => setState(() => _reason = r.value),
                        leading: Icon(
                          _reason == r.value
                              ? CupertinoIcons.checkmark_circle_fill
                              : CupertinoIcons.circle,
                          color: _reason == r.value
                              ? Colors.redAccent
                              : subtleColor,
                          size: 20,
                        ),
                        title: Text(
                          r.label,
                          style: GoogleFonts.inter(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                            color: textColor,
                          ),
                        ),
                        subtitle: Text(
                          r.subtitle,
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            color: subtleColor,
                          ),
                        ),
                      ),
                    Padding(
                      padding:
                          const EdgeInsets.fromLTRB(20, 12, 20, 12),
                      child: TextField(
                        controller: _noteCtrl,
                        enabled: !_submitting,
                        minLines: 2,
                        maxLines: 4,
                        maxLength: 500,
                        style: GoogleFonts.inter(
                            fontSize: 13.5, color: textColor),
                        decoration: InputDecoration(
                          labelText: 'Additional details (optional)',
                          labelStyle: GoogleFonts.inter(
                              fontSize: 13, color: subtleColor),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: _submitting
                          ? null
                          : () => Navigator.pop(context, false),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.redAccent,
                      ),
                      onPressed:
                          (_reason == null || _submitting) ? null : _submit,
                      child: _submitting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Submit report'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
