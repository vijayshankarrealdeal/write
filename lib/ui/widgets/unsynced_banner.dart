import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/provider/editor_provider.dart';
import 'package:inkspacex/router.dart' show rootNavigatorKey;
import 'package:inkspacex/services/sync/pending_op.dart';

/// App-wide top banner that surfaces unsynced or failed sync operations
/// regardless of which page the user is on. The status chip in the editor
/// covers the editing context; this banner covers everywhere else (My
/// Spaces, Settings, Library) so a user with stranded ops can't miss it.
///
/// - Hidden when nothing is pending/failed.
/// - Amber strip when ops are queued (offline or waiting to drain).
/// - Red strip when one or more ops gave up retrying (tap to review).
class UnsyncedBanner extends StatelessWidget {
  const UnsyncedBanner({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    if (!auth.isAuthenticated) {
      return Material(type: MaterialType.transparency, child: child);
    }
    final editor = context.watch<EditorProvider>();
    return Material(
      type: MaterialType.transparency,
      child: ListenableBuilder(
        listenable: Listenable.merge([
          editor.pendingOpsCount,
          editor.failedOpsCount,
        ]),
        builder: (context, _) {
          // pendingOpsCount is the total queue depth (failed + waiting).
          // For the user-facing label we want the count that's still
          // *trying* to sync — failed ops have given up and are surfaced
          // separately as "X failed".
          final total = editor.pendingOpsCount.value;
          final failed = editor.failedOpsCount.value;
          final pending = (total - failed).clamp(0, total);
          final visible = pending > 0 || failed > 0;
          return Column(
            children: [
              if (visible)
                _Strip(
                  pending: pending,
                  failed: failed,
                  onSyncNow: () => editor.syncNow(),
                  onReview: () => _showFailedOpsSheet(context, editor),
                ),
              Expanded(child: child),
            ],
          );
        },
      ),
    );
  }
}

class _Strip extends StatelessWidget {
  const _Strip({
    required this.pending,
    required this.failed,
    required this.onSyncNow,
    required this.onReview,
  });

  final int pending;
  final int failed;
  final Future<void> Function() onSyncNow;
  final VoidCallback onReview;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isError = failed > 0;
    final bg = isError
        ? (isDark ? const Color(0xFF3A0F0F) : const Color(0xFFFDECEA))
        : (isDark ? const Color(0xFF3A2A00) : const Color(0xFFFFF3CD));
    final fg = isError
        ? (isDark ? const Color(0xFFFFB4B4) : const Color(0xFF842029))
        : (isDark ? const Color(0xFFFFE39A) : const Color(0xFF664D03));

    final label = isError
        ? '$failed change${failed == 1 ? '' : 's'} failed to sync.'
        : '$pending change${pending == 1 ? '' : 's'} not yet synced.';

    return SafeArea(
      bottom: false,
      child: Material(
        color: bg,
        child: SizedBox(
          width: double.infinity,
          height: 30,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Spacer(),
                Icon(
                  isError
                      ? CupertinoIcons.exclamationmark_circle
                      : CupertinoIcons.cloud_upload,
                  size: 14,
                  color: fg,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: fg,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                _StripAction(
                  label: isError ? 'Review' : 'Sync now',
                  fg: fg,
                  onTap: isError ? onReview : onSyncNow,
                ),
                const Spacer(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StripAction extends StatefulWidget {
  const _StripAction({
    required this.label,
    required this.fg,
    required this.onTap,
  });

  final String label;
  final Color fg;
  final FutureOr<void> Function() onTap;

  @override
  State<_StripAction> createState() => _StripActionState();
}

class _StripActionState extends State<_StripAction>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Eager init (not `late final` with an inline initializer) — if the
    // widget mounts then unmounts without any build path touching _spin,
    // the lazy initializer would otherwise fire inside dispose() and
    // look up our TickerProvider on a deactivated widget, which is the
    // exception we hit in production.
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  Future<void> _handleTap() async {
    if (_busy) return;
    setState(() => _busy = true);
    _spin.repeat();
    final start = DateTime.now();
    try {
      await widget.onTap();
    } catch (_) {
      // Swallow — the failed-ops banner / sheet is the surface that
      // reports sync errors to the user. Re-throwing here would just
      // crash the gesture handler.
    }
    // Keep the spinner up for at least ~600ms even if the kick returns
    // synchronously — otherwise the icon flickers and the user can't
    // tell anything happened.
    final elapsed = DateTime.now().difference(start);
    const minVisible = Duration(milliseconds: 600);
    if (elapsed < minVisible) {
      await Future<void>.delayed(minVisible - elapsed);
    }
    if (!mounted) return;
    _spin.stop();
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: _handleTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_busy) ...[
              RotationTransition(
                turns: _spin,
                child: Icon(
                  CupertinoIcons.arrow_2_circlepath,
                  size: 12,
                  color: widget.fg,
                ),
              ),
              const SizedBox(width: 6),
            ],
            Text(
              _busy ? 'Syncing…' : widget.label,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: widget.fg,
                decoration: _busy ? null : TextDecoration.underline,
                decorationColor: widget.fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One-shot review experience for a failed op: show the local version
/// next to the backend version, let the user pick a winner.
class _ConflictReviewDialog extends StatefulWidget {
  const _ConflictReviewDialog({
    required this.provider,
    required this.op,
  });

  final EditorProvider provider;
  final PendingOp op;

  @override
  State<_ConflictReviewDialog> createState() => _ConflictReviewDialogState();
}

class _ConflictReviewDialogState extends State<_ConflictReviewDialog> {
  ConflictSnapshot? _snap;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final snap = await widget.provider.snapshotForOp(widget.op);
      if (!mounted) return;
      setState(() => _snap = snap);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  Future<void> _useLocal() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.provider.resolveUseLocal(widget.op.id);
    } finally {
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _useBackend() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.provider.resolveUseBackend(widget.op.id);
    } finally {
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;
    final muted = textColor.withValues(alpha: 0.6);
    final borderColor = textColor.withValues(alpha: 0.12);
    final cardBg = isDark ? const Color(0xFF141414) : const Color(0xFFF7F7F7);

    Widget body;
    if (_error != null) {
      body = Padding(
        padding: const EdgeInsets.all(24),
        child: Text('Could not load: $_error',
            style: GoogleFonts.inter(color: muted)),
      );
    } else if (_snap == null) {
      body = const Padding(
        padding: EdgeInsets.all(40),
        child: Center(child: CircularProgressIndicator()),
      );
    } else {
      final s = _snap!;
      body = Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              s.remoteMissing
                  ? "This ${s.kind} only exists on this device. The "
                      "backend has no copy."
                  : "Pick which version to keep — your device's, or the "
                      "backend's.",
              style: GoogleFonts.inter(fontSize: 13, color: muted),
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _SidePanel(
                    label: 'YOUR DEVICE',
                    title: s.localTitle ?? '(untitled)',
                    content: s.localContent,
                    isMissing: s.localTitle == null && s.localContent == null,
                    bg: cardBg,
                    border: borderColor,
                    textColor: textColor,
                    muted: muted,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _SidePanel(
                    label: 'BACKEND',
                    title: s.remoteTitle ?? '(no copy)',
                    content: s.remoteContent,
                    isMissing: s.remoteMissing,
                    bg: cardBg,
                    border: borderColor,
                    textColor: textColor,
                    muted: muted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _busy ? null : _useBackend,
                  child: Text(s.remoteMissing
                      ? 'Drop local'
                      : 'Use backend'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy ? null : _useLocal,
                  child: Text(s.remoteMissing
                      ? 'Push to backend'
                      : 'Keep mine'),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return Dialog(
      backgroundColor: isDark ? const Color(0xFF0C0C0C) : Colors.white,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                child: Text(
                  'Review sync conflict',
                  style: GoogleFonts.playfairDisplay(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: textColor,
                  ),
                ),
              ),
              body,
            ],
          ),
        ),
      ),
    );
  }
}

class _SidePanel extends StatelessWidget {
  const _SidePanel({
    required this.label,
    required this.title,
    required this.content,
    required this.isMissing,
    required this.bg,
    required this.border,
    required this.textColor,
    required this.muted,
  });

  final String label;
  final String title;
  final String? content;
  final bool isMissing;
  final Color bg;
  final Color border;
  final Color textColor;
  final Color muted;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: border),
      ),
      padding: const EdgeInsets.all(14),
      constraints: const BoxConstraints(minHeight: 200),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: muted,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: isMissing ? muted : textColor,
              fontStyle: isMissing ? FontStyle.italic : FontStyle.normal,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isMissing
                ? '—'
                : (content == null || content!.isEmpty
                    ? '(empty)'
                    : _previewText(content!)),
            maxLines: 6,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              fontSize: 12,
              color: muted,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  static String _previewText(String raw) {
    // Quill content is JSON deltas; strip down to the first inserts so
    // the preview is readable instead of showing curly braces.
    final trimmed = raw.trim();
    if (!trimmed.startsWith('[')) return trimmed;
    try {
      final list = jsonDecode(trimmed);
      if (list is! List) return trimmed;
      final out = StringBuffer();
      for (final entry in list) {
        if (entry is Map && entry['insert'] is String) {
          out.write(entry['insert']);
          if (out.length > 400) break;
        }
      }
      return out.toString().trim();
    } catch (_) {
      return trimmed;
    }
  }
}

void _showFailedOpsSheet(BuildContext context, EditorProvider provider) {
  // The banner mounts inside MaterialApp.builder, which is *above* the
  // router's Navigator. We can't push a modal sheet from this context —
  // there is no Navigator ancestor. Reach for the root navigator's
  // context (set in router.dart) so the sheet lands on the active route.
  final navContext = rootNavigatorKey.currentContext ?? context;
  final isDark = Theme.of(navContext).brightness == Brightness.dark;
  final sheetBg = isDark ? const Color(0xFF0C0C0C) : Colors.white;
  final textColor = isDark ? Colors.white : Colors.black;
  final muted = textColor.withValues(alpha: 0.6);
  showModalBottomSheet(
    context: navContext,
    backgroundColor: sheetBg,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) {
      return SafeArea(
        child: AnimatedBuilder(
          animation: provider,
          builder: (ctx, _) {
            final ops = provider.failedOps;
            if (ops.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'No failed operations.',
                  style: GoogleFonts.inter(color: muted),
                ),
              );
            }
            return ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              itemCount: ops.length,
              separatorBuilder: (_, _) => Divider(
                color: textColor.withValues(alpha: 0.08),
                height: 24,
              ),
              itemBuilder: (ctx, i) {
                final PendingOp op = ops[i];
                return InkWell(
                  onTap: () {
                    Navigator.of(ctx).pop();
                    final root = rootNavigatorKey.currentContext ?? ctx;
                    showDialog<void>(
                      context: root,
                      builder: (_) => _ConflictReviewDialog(
                        provider: provider,
                        op: op,
                      ),
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                op.kind.name,
                                style: GoogleFonts.inter(
                                  fontWeight: FontWeight.w600,
                                  color: textColor,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                op.lastError ?? 'unknown error',
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.inter(
                                  fontSize: 12,
                                  color: muted,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Tap to compare local & backend · '
                                '${op.attemptCount} attempts',
                                style: GoogleFonts.inter(
                                  fontSize: 11,
                                  color: muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Icon(
                          CupertinoIcons.chevron_right,
                          size: 14,
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
      );
    },
  );
}
