import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/ui/widgets/app_spinner.dart';

/// User-facing form for submitting feedback about the app. Sits at the
/// `/feedback` route and is reachable from the Settings page. The
/// payload schema is defined in `backend/app/schemas/feedback.py`.
class FeedbackPage extends StatefulWidget {
  const FeedbackPage({super.key});

  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  final TextEditingController _messageController = TextEditingController();
  String _category = 'bug';
  bool _submitting = false;

  static const _categories = <_Category>[
    _Category('bug', 'Report a bug', CupertinoIcons.ant),
    _Category('feature', 'Suggest a feature', CupertinoIcons.lightbulb),
    _Category('praise', 'Share praise', CupertinoIcons.heart),
    _Category('other', 'Something else', CupertinoIcons.chat_bubble_2),
  ];

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  String _detectPlatform() {
    if (kIsWeb) return 'web';
    try {
      if (Platform.isAndroid) return 'android';
      if (Platform.isIOS) return 'ios';
      if (Platform.isMacOS) return 'macos';
      if (Platform.isWindows) return 'windows';
      if (Platform.isLinux) return 'linux';
    } catch (_) {}
    return 'unknown';
  }

  Future<void> _submit() async {
    final message = _messageController.text.trim();
    if (message.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please write your feedback first.')),
      );
      return;
    }
    setState(() => _submitting = true);
    try {
      await context.read<AuthProvider>().dataService.submitFeedback(
            message: message,
            category: _category,
            platform: _detectPlatform(),
          );
      if (!mounted) return;
      _messageController.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Thanks — your feedback has been sent.')),
      );
      Navigator.of(context).maybePop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not send feedback: $e')),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF000000) : const Color(0xFFFAFAFA);
    final textColor = isDark ? Colors.white : Colors.black;
    final cardColor = isDark ? const Color(0xFF1A1A1A) : Colors.white;
    final border = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.08);

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        title: Text(
          'Send Feedback',
          style: GoogleFonts.inter(
            color: textColor,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: textColor),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                child: Text(
                  "Tell us what's working, what's broken, or what you wish we'd build. Your message goes straight to the team.",
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: textColor.withValues(alpha: 0.6),
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _sectionHeader('TYPE', textColor),
              Container(
                decoration: BoxDecoration(
                  color: cardColor,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: border),
                ),
                child: Column(
                  children: [
                    for (var i = 0; i < _categories.length; i++) ...[
                      _categoryTile(
                        _categories[i],
                        textColor: textColor,
                        isDark: isDark,
                      ),
                      if (i != _categories.length - 1)
                        Padding(
                          padding: const EdgeInsets.only(left: 60),
                          child: Divider(
                            color: border,
                            height: 1,
                            thickness: 1,
                          ),
                        ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 28),
              _sectionHeader('MESSAGE', textColor),
              Container(
                decoration: BoxDecoration(
                  color: cardColor,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: border),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: TextField(
                  controller: _messageController,
                  maxLines: 7,
                  minLines: 5,
                  maxLength: 4000,
                  style: GoogleFonts.inter(
                    color: textColor,
                    fontSize: 15,
                    height: 1.45,
                  ),
                  decoration: InputDecoration(
                    hintText:
                        'Describe what happened or what you have in mind...',
                    hintStyle: GoogleFonts.inter(
                      color: textColor.withValues(alpha: 0.35),
                      fontSize: 15,
                    ),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                    counterStyle: GoogleFonts.inter(
                      color: textColor.withValues(alpha: 0.35),
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _submitting ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isDark ? Colors.white : Colors.black87,
                    foregroundColor: isDark ? Colors.black : Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 0,
                  ),
                  child: _submitting
                      ? AppSpinner(color: isDark ? Colors.black : Colors.white)
                      : Text(
                          'Send Feedback',
                          style: GoogleFonts.inter(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionHeader(String label, Color textColor) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, bottom: 12),
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: textColor.withValues(alpha: 0.4),
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _categoryTile(
    _Category cat, {
    required Color textColor,
    required bool isDark,
  }) {
    final selected = cat.id == _category;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => setState(() => _category = cat.id),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.05)
                      : Colors.black.withValues(alpha: 0.04),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  cat.icon,
                  color: textColor.withValues(alpha: 0.8),
                  size: 18,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  cat.label,
                  style: GoogleFonts.inter(
                    color: textColor,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (selected)
                Icon(
                  CupertinoIcons.check_mark_circled_solid,
                  color: isDark ? Colors.white : Colors.black87,
                  size: 22,
                )
              else
                Icon(
                  CupertinoIcons.circle,
                  color: textColor.withValues(alpha: 0.25),
                  size: 22,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Category {
  final String id;
  final String label;
  final IconData icon;
  const _Category(this.id, this.label, this.icon);
}
