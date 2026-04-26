import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/services/sync/merge_log.dart';

/// Floating toast that appears for a few seconds whenever the sync
/// drainer reports that a remote merge replaced the user's local
/// edit. Wraps [child] near the app root and otherwise stays out of
/// the way.
class SyncConflictBanner extends StatefulWidget {
  const SyncConflictBanner({super.key, required this.child});

  final Widget child;

  @override
  State<SyncConflictBanner> createState() => _SyncConflictBannerState();
}

class _SyncConflictBannerState extends State<SyncConflictBanner> {
  StreamSubscription<MergeLogEntry>? _sub;
  MergeLogEntry? _activeEntry;
  Timer? _dismissTimer;

  @override
  void initState() {
    super.initState();
    final mergeLog = context.read<MergeLog>();
    _sub = mergeLog.conflicts.listen(_onConflict);
  }

  void _onConflict(MergeLogEntry entry) {
    _dismissTimer?.cancel();
    if (!mounted) return;
    setState(() => _activeEntry = entry);
    _dismissTimer = Timer(const Duration(seconds: 6), _dismiss);
  }

  void _dismiss() {
    _dismissTimer?.cancel();
    if (!mounted) return;
    setState(() => _activeEntry = null);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _dismissTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (_activeEntry != null)
          Positioned(
            left: 16,
            right: 16,
            bottom: 24 + MediaQuery.of(context).padding.bottom,
            child: SafeArea(
              top: false,
              child: _ConflictCard(
                entry: _activeEntry!,
                onDismiss: _dismiss,
                onView: () {
                  _dismiss();
                  // Deep link to the merge log for users who want detail.
                  context.push('/debug/merge-log');
                },
              ),
            ),
          ),
      ],
    );
  }
}

class _ConflictCard extends StatelessWidget {
  const _ConflictCard({
    required this.entry,
    required this.onDismiss,
    required this.onView,
  });

  final MergeLogEntry entry;
  final VoidCallback onDismiss;
  final VoidCallback onView;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = isDark ? const Color(0xFF1A1A1A) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtle = textColor.withValues(alpha: 0.6);

    return Material(
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Center(
          child: Container(
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: const Color(0xFFF59E0B).withValues(alpha: 0.4),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.5 : 0.15),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF59E0B).withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    CupertinoIcons.arrow_2_circlepath,
                    color: Color(0xFFF59E0B),
                    size: 18,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Synced from another device',
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: textColor,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'A newer edit was applied to one of your sections. '
                        'Your local changes were saved to the merge log.',
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          color: subtle,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          GestureDetector(
                            onTap: onView,
                            child: Text(
                              'View details',
                              style: GoogleFonts.inter(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: const Color(0xFF2563EB),
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          GestureDetector(
                            onTap: onDismiss,
                            child: Text(
                              'Dismiss',
                              style: GoogleFonts.inter(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: subtle,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
