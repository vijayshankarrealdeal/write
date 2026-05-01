import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/services/analytics_service.dart';
import 'package:inkspacex/services/api/api_data_service.dart';
import 'package:inkspacex/ui/widgets/app_network_image.dart';
import 'package:inkspacex/ui/widgets/app_spinner.dart';

/// Lists users the viewer has blocked, with an inline "Unblock" action.
/// Reached from the profile hub. Empty state when nobody is blocked so
/// the page always opens cleanly even if the underlying call fails.
class BlockedUsersPage extends StatefulWidget {
  const BlockedUsersPage({super.key});

  @override
  State<BlockedUsersPage> createState() => _BlockedUsersPageState();
}

class _BlockedUsersPageState extends State<BlockedUsersPage> {
  List<PublicUser> _items = const [];
  bool _loading = true;
  final Set<String> _inFlight = <String>{};

  @override
  void initState() {
    super.initState();
    AnalyticsService.instance.track(
      'blocked_users_viewed',
      screen: '/blocked',
      action: 'view',
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final api = context.read<AuthProvider>().dataService;
    final list = await api.getBlockedUsers();
    if (!mounted) return;
    setState(() {
      _items = list;
      _loading = false;
    });
  }

  Future<void> _unblock(PublicUser target) async {
    if (_inFlight.contains(target.id)) return;
    setState(() => _inFlight.add(target.id));
    final api = context.read<AuthProvider>().dataService;
    try {
      await api.unblockUser(target.id);
      if (!mounted) return;
      setState(() {
        _items = _items.where((u) => u.id != target.id).toList(growable: false);
      });
      AnalyticsService.instance.track(
        'user_unblocked',
        screen: '/blocked',
        action: 'click',
        entityType: 'user',
        entityId: target.id,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not unblock',
            style: GoogleFonts.inter(fontSize: 13),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _inFlight.remove(target.id));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF000000) : const Color(0xFFF8F9FA);
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtle = textColor.withValues(alpha: 0.55);

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(
          'Blocked',
          style: GoogleFonts.inter(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: textColor,
          ),
        ),
      ),
      body: _loading
          ? const Center(child: AppSpinner())
          : _items.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      'You haven\'t blocked anyone yet.',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(color: subtle, fontSize: 14),
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  color: textColor,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                    itemCount: _items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 14),
                    itemBuilder: (_, i) {
                      final u = _items[i];
                      return _BlockedRow(
                        user: u,
                        isDark: isDark,
                        textColor: textColor,
                        subtle: subtle,
                        loading: _inFlight.contains(u.id),
                        onTap: () => context.push('/u/${u.id}', extra: u),
                        onUnblock: () => _unblock(u),
                      );
                    },
                  ),
                ),
    );
  }
}

class _BlockedRow extends StatelessWidget {
  final PublicUser user;
  final bool isDark;
  final Color textColor;
  final Color subtle;
  final bool loading;
  final VoidCallback onTap;
  final VoidCallback onUnblock;
  const _BlockedRow({
    required this.user,
    required this.isDark,
    required this.textColor,
    required this.subtle,
    required this.loading,
    required this.onTap,
    required this.onUnblock,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Row(
        children: [
          _Avatar(user: user, isDark: isDark, textColor: textColor),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              user.name ?? 'Unnamed',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: textColor,
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            height: 30,
            child: TextButton(
              onPressed: loading ? null : onUnblock,
              style: TextButton.styleFrom(
                foregroundColor: textColor,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.25)
                        : Colors.black.withValues(alpha: 0.15),
                    width: 1,
                  ),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                minimumSize: const Size(80, 30),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: loading
                  ? SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(textColor),
                      ),
                    )
                  : Text(
                      'Unblock',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: textColor,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final PublicUser user;
  final bool isDark;
  final Color textColor;
  const _Avatar({
    required this.user,
    required this.isDark,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    const size = 44.0;
    final url = user.photoUrl;
    final hasImage = url != null && url.isNotEmpty;
    final placeholder = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.22),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? const [Color(0xFF1F1F23), Color(0xFF111114)]
              : const [Color(0xFFEFF1F4), Color(0xFFFFFFFF)],
        ),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.black.withValues(alpha: 0.06),
          width: 1,
        ),
      ),
      child: Text(
        ((user.name ?? 'I').trim().isEmpty ? 'I' : user.name!.trim()[0])
            .toUpperCase(),
        style: GoogleFonts.playfairDisplay(
          fontSize: size * 0.46,
          fontWeight: FontWeight.w800,
          color: textColor,
          height: 1,
          letterSpacing: -1,
        ),
      ),
    );
    if (!hasImage) return placeholder;
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.22),
      child: SizedBox(
        width: size,
        height: size,
        child: AppNetworkImage(
          url: url,
          meta: user.photoMeta,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorWidget: placeholder,
        ),
      ),
    );
  }
}
