import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/services/api/api_data_service.dart';
import 'package:inkspacex/ui/widgets/app_network_image.dart';
import 'package:inkspacex/ui/widgets/app_spinner.dart';

/// Pending follow-request inbox — the Instagram-style "Approve / Decline"
/// screen the author lands on when someone has requested access to their
/// `visibility='private'` writings. Approving grants the requester
/// read-through to every private item the author has now or publishes
/// later (matches the per-account approval semantics we agreed on; the
/// follow row's `status` flips from 'pending' → 'approved' atomically
/// with the requester's recommender cache invalidation server-side).
class FollowRequestsPage extends StatefulWidget {
  const FollowRequestsPage({super.key});

  @override
  State<FollowRequestsPage> createState() => _FollowRequestsPageState();
}

class _FollowRequestsPageState extends State<FollowRequestsPage> {
  List<FollowRequestEntry> _requests = const [];
  bool _loading = true;
  // followId of any in-flight approve/reject so taps don't double-fire.
  final Set<String> _inFlight = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final api = context.read<AuthProvider>().dataService;
    final result = await api.getFollowRequests();
    if (!mounted) return;
    setState(() {
      _requests = result;
      _loading = false;
    });
  }

  Future<void> _approve(FollowRequestEntry entry) async {
    if (_inFlight.contains(entry.followId)) return;
    setState(() => _inFlight.add(entry.followId));
    final api = context.read<AuthProvider>().dataService;
    try {
      await api.approveFollowRequest(entry.followId);
      if (!mounted) return;
      // Drop the row optimistically — the request is gone from the
      // pending inbox now (it's promoted to an approved follow).
      setState(() {
        _requests = _requests.where((r) => r.followId != entry.followId).toList();
      });
    } catch (_) {
      _showSnack('Could not approve request');
    } finally {
      if (mounted) setState(() => _inFlight.remove(entry.followId));
    }
  }

  Future<void> _reject(FollowRequestEntry entry) async {
    if (_inFlight.contains(entry.followId)) return;
    setState(() => _inFlight.add(entry.followId));
    final api = context.read<AuthProvider>().dataService;
    try {
      await api.rejectFollowRequest(entry.followId);
      if (!mounted) return;
      setState(() {
        _requests = _requests.where((r) => r.followId != entry.followId).toList();
      });
    } catch (_) {
      _showSnack('Could not decline request');
    } finally {
      if (mounted) setState(() => _inFlight.remove(entry.followId));
    }
  }

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text, style: GoogleFonts.inter(fontSize: 13)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF000000) : const Color(0xFFF8F9FA);
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtle = textColor.withValues(alpha: 0.55);

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: bgColor,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: Icon(CupertinoIcons.back, color: textColor),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/'),
        ),
        title: Text(
          'Follow requests',
          style: GoogleFonts.inter(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: textColor,
          ),
        ),
      ),
      body: _loading
          ? Center(child: AppSpinner(size: 28, color: textColor))
          : _requests.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'No pending requests.',
                      style: GoogleFonts.inter(fontSize: 14, color: subtle),
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  color: textColor,
                  child: ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _requests.length,
                    separatorBuilder: (_, _) => Divider(
                      height: 1,
                      thickness: 0.5,
                      color: textColor.withValues(alpha: 0.06),
                    ),
                    itemBuilder: (context, i) => _RequestRow(
                      entry: _requests[i],
                      isDark: isDark,
                      textColor: textColor,
                      subtle: subtle,
                      busy: _inFlight.contains(_requests[i].followId),
                      onApprove: () => _approve(_requests[i]),
                      onReject: () => _reject(_requests[i]),
                    ),
                  ),
                ),
    );
  }
}

class _RequestRow extends StatelessWidget {
  final FollowRequestEntry entry;
  final bool isDark;
  final Color textColor;
  final Color subtle;
  final bool busy;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  const _RequestRow({
    required this.entry,
    required this.isDark,
    required this.textColor,
    required this.subtle,
    required this.busy,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    final user = entry.requester;
    return InkWell(
      onTap: () => context.push('/u/${user.id}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            ClipOval(
              child: SizedBox(
                width: 40,
                height: 40,
                child: (user.photoUrl != null && user.photoUrl!.isNotEmpty)
                    ? AppNetworkImage(
                        url: user.photoUrl!,
                        meta: user.photoMeta,
                        width: 40,
                        height: 40,
                        fit: BoxFit.cover,
                      )
                    : Container(
                        color: textColor.withValues(alpha: 0.08),
                        alignment: Alignment.center,
                        child: Text(
                          (user.name ?? '?').characters.first.toUpperCase(),
                          style: GoogleFonts.inter(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: textColor,
                          ),
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user.name ?? 'Unknown',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'wants to follow you',
                    style: GoogleFonts.inter(fontSize: 12, color: subtle),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Two-button column — Approve (filled) and Decline (outline) —
            // Instagram-equivalent affordances. Decline silently deletes
            // the follow row server-side (no notification to requester),
            // matching the spec the backend implements.
            _ActionButton(
              label: 'Approve',
              filled: true,
              isDark: isDark,
              busy: busy,
              onPressed: onApprove,
            ),
            const SizedBox(width: 8),
            _ActionButton(
              label: 'Decline',
              filled: false,
              isDark: isDark,
              busy: busy,
              onPressed: onReject,
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final bool filled;
  final bool isDark;
  final bool busy;
  final VoidCallback onPressed;
  const _ActionButton({
    required this.label,
    required this.filled,
    required this.isDark,
    required this.busy,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final accent = isDark ? Colors.white : const Color(0xFF0F172A);
    final fg = filled ? (isDark ? Colors.black : Colors.white) : accent;
    final bg = filled ? accent : Colors.transparent;
    final border = filled
        ? Colors.transparent
        : accent.withValues(alpha: 0.20);
    return SizedBox(
      height: 30,
      child: TextButton(
        onPressed: busy ? null : onPressed,
        style: TextButton.styleFrom(
          backgroundColor: bg,
          foregroundColor: fg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(7),
            side: BorderSide(color: border, width: 1),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          minimumSize: const Size(72, 30),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: fg,
          ),
        ),
      ),
    );
  }
}
