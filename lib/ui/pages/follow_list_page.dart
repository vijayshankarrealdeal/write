import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/services/analytics_service.dart';
import 'package:inkspacex/services/api/api_data_service.dart';
import 'package:inkspacex/services/format_count.dart';
import 'package:inkspacex/ui/widgets/app_network_image.dart';
import 'package:inkspacex/ui/widgets/app_spinner.dart';
import 'package:inkspacex/ui/widgets/user_badge_chip.dart';

enum FollowListMode { followers, following }

/// Followers / Following list for a given user. Same row treatment as
/// search results so a tap drops the viewer onto the author's profile.
/// The `Follow` button on each row is hidden for self-rows and toggles
/// optimistically against the same /api/users/{id}/follow endpoints
/// used on the profile page.
class FollowListPage extends StatefulWidget {
  final String userId;
  final FollowListMode mode;
  final PublicUser? seed;
  const FollowListPage({
    super.key,
    required this.userId,
    required this.mode,
    this.seed,
  });

  @override
  State<FollowListPage> createState() => _FollowListPageState();
}

class _FollowListPageState extends State<FollowListPage> {
  List<PublicUser> _items = const [];
  bool _loading = true;
  final Set<String> _inFlight = <String>{};

  @override
  void initState() {
    super.initState();
    AnalyticsService.instance.track(
      widget.mode == FollowListMode.followers
          ? 'followers_viewed'
          : 'following_viewed',
      screen: widget.mode == FollowListMode.followers
          ? '/u/:id/followers'
          : '/u/:id/following',
      action: 'view',
      entityType: 'user',
      entityId: widget.userId,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final api = context.read<AuthProvider>().dataService;
    final list = widget.mode == FollowListMode.followers
        ? await api.getFollowers(widget.userId)
        : await api.getFollowing(widget.userId);
    if (!mounted) return;
    setState(() {
      _items = list;
      _loading = false;
    });
  }

  Future<void> _toggleFollow(PublicUser target) async {
    if (_inFlight.contains(target.id)) return;
    final wasFollowing = target.isFollowing;
    setState(() {
      _inFlight.add(target.id);
      _items = _items
          .map((u) => u.id == target.id
              ? u.copyWith(
                  isFollowing: !wasFollowing,
                  followersCount: (u.followersCount + (wasFollowing ? -1 : 1))
                      .clamp(0, 1 << 30),
                )
              : u)
          .toList(growable: false);
    });
    final api = context.read<AuthProvider>().dataService;
    try {
      final result = wasFollowing
          ? await api.unfollowUser(target.id)
          : await api.followUser(target.id);
      if (!mounted) return;
      setState(() {
        _items = _items
            .map((u) => u.id == target.id
                ? u.copyWith(
                    isFollowing: result.isFollowing,
                    followersCount: result.followersCount,
                  )
                : u)
            .toList(growable: false);
      });
    } catch (_) {
      if (!mounted) return;
      // Revert.
      setState(() {
        _items = _items
            .map((u) => u.id == target.id ? target : u)
            .toList(growable: false);
      });
    } finally {
      if (mounted) {
        setState(() => _inFlight.remove(target.id));
      }
    }
  }

  Future<void> _removeFollower(PublicUser target) async {
    if (_inFlight.contains(target.id)) return;
    final ok = await _confirm(
      title: 'Remove follower?',
      message:
          '${target.name ?? 'This person'} won\'t be told they were removed.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _inFlight.add(target.id));
    final api = context.read<AuthProvider>().dataService;
    try {
      await api.removeFollower(target.id);
      if (!mounted) return;
      setState(() {
        _items = _items.where((u) => u.id != target.id).toList(growable: false);
      });
      AnalyticsService.instance.track(
        'follower_removed',
        screen: '/u/:id/followers',
        action: 'click',
        entityType: 'user',
        entityId: target.id,
      );
    } catch (_) {
      if (mounted) _toast('Could not remove follower');
    } finally {
      if (mounted) {
        setState(() => _inFlight.remove(target.id));
      }
    }
  }

  Future<void> _block(PublicUser target) async {
    if (_inFlight.contains(target.id)) return;
    final ok = await _confirm(
      title: 'Block ${target.name ?? 'this user'}?',
      message:
          'They won\'t be able to follow you or see your profile, and you won\'t see theirs.',
      confirmLabel: 'Block',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _inFlight.add(target.id));
    final api = context.read<AuthProvider>().dataService;
    try {
      await api.blockUser(target.id);
      if (!mounted) return;
      // Block also tears down follow rows server-side, so the row no
      // longer belongs in either the followers or following list.
      setState(() {
        _items = _items.where((u) => u.id != target.id).toList(growable: false);
      });
      AnalyticsService.instance.track(
        'user_blocked',
        screen: widget.mode == FollowListMode.followers
            ? '/u/:id/followers'
            : '/u/:id/following',
        action: 'click',
        entityType: 'user',
        entityId: target.id,
      );
    } catch (_) {
      if (mounted) _toast('Could not block user');
    } finally {
      if (mounted) {
        setState(() => _inFlight.remove(target.id));
      }
    }
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
    bool destructive = false,
  }) async {
    final result = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (_) => CupertinoActionSheet(
        title: Text(title),
        message: Text(message),
        actions: [
          CupertinoActionSheetAction(
            isDestructiveAction: destructive,
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmLabel),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
      ),
    );
    return result ?? false;
  }

  void _showRowActions(PublicUser target) {
    final isFollower = widget.mode == FollowListMode.followers;
    showCupertinoModalPopup<void>(
      context: context,
      builder: (sheetCtx) => CupertinoActionSheet(
        title: Text(target.name ?? 'Options'),
        actions: [
          if (isFollower)
            CupertinoActionSheetAction(
              isDestructiveAction: true,
              onPressed: () {
                Navigator.pop(sheetCtx);
                _removeFollower(target);
              },
              child: const Text('Remove follower'),
            ),
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.pop(sheetCtx);
              _block(target);
            },
            child: const Text('Block'),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(sheetCtx);
              context.push('/u/${target.id}', extra: target);
            },
            child: const Text('View profile'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(sheetCtx),
          child: const Text('Cancel'),
        ),
      ),
    );
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: GoogleFonts.inter(fontSize: 13)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF000000) : const Color(0xFFF8F9FA);
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtle = textColor.withValues(alpha: 0.55);
    final viewerId = context.watch<AuthProvider>().currentUser?.id;
    final isOwnList = viewerId != null && viewerId == widget.userId;
    final title = widget.mode == FollowListMode.followers
        ? 'Followers'
        : 'Following';

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(
          widget.seed?.name == null ? title : '${widget.seed!.name} · $title',
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
                  child: Text(
                    widget.mode == FollowListMode.followers
                        ? 'No followers yet.'
                        : 'Not following anyone yet.',
                    style: GoogleFonts.inter(color: subtle),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  color: textColor,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                        child: Row(
                          children: [
                            Text(
                              '${_items.length}',
                              style: GoogleFonts.inter(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: textColor,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              title.toLowerCase(),
                              style: GoogleFonts.inter(
                                fontSize: 13,
                                color: subtle,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: ListView.separated(
                          padding:
                              const EdgeInsets.fromLTRB(16, 4, 16, 32),
                          itemCount: _items.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 14),
                          itemBuilder: (_, i) {
                            final u = _items[i];
                            return _UserRow(
                              user: u,
                              isDark: isDark,
                              textColor: textColor,
                              subtle: subtle,
                              isSelf: viewerId != null && viewerId == u.id,
                              showOwnerActions: isOwnList,
                              followLoading: _inFlight.contains(u.id),
                              onTap: () =>
                                  context.push('/u/${u.id}', extra: u),
                              onFollow: () => _toggleFollow(u),
                              onMore: () => _showRowActions(u),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }
}

class _UserRow extends StatelessWidget {
  final PublicUser user;
  final bool isDark;
  final Color textColor;
  final Color subtle;
  final bool isSelf;
  final bool showOwnerActions;
  final bool followLoading;
  final VoidCallback onTap;
  final VoidCallback onFollow;
  final VoidCallback onMore;
  const _UserRow({
    required this.user,
    required this.isDark,
    required this.textColor,
    required this.subtle,
    required this.isSelf,
    required this.showOwnerActions,
    required this.followLoading,
    required this.onTap,
    required this.onFollow,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Row(
        children: [
          _RowAvatar(user: user, isDark: isDark, textColor: textColor),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
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
                    if (user.writerBadge != null && user.writerBadge!.tier > 0) ...[
                      const SizedBox(width: 6),
                      UserBadgeChip(badge: user.writerBadge!),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${formatCount(user.postsCount)} ${user.postsCount == 1 ? 'story' : 'stories'} · ${formatCount(user.followersCount)} followers',
                  style: GoogleFonts.inter(fontSize: 12, color: subtle),
                ),
              ],
            ),
          ),
          if (showOwnerActions && !isSelf) ...[
            const SizedBox(width: 10),
            _MoreButton(
              isDark: isDark,
              loading: followLoading,
              onPressed: onMore,
            ),
          ] else if (!isSelf) ...[
            const SizedBox(width: 10),
            _SmallFollowButton(
              isFollowing: user.isFollowing,
              loading: followLoading,
              isDark: isDark,
              onPressed: onFollow,
            ),
          ],
        ],
      ),
    );
  }
}

class _MoreButton extends StatelessWidget {
  final bool isDark;
  final bool loading;
  final VoidCallback onPressed;
  const _MoreButton({
    required this.isDark,
    required this.loading,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final fg = isDark ? Colors.white : const Color(0xFF0F172A);
    return SizedBox(
      width: 36,
      height: 30,
      child: TextButton(
        onPressed: loading ? null : onPressed,
        style: TextButton.styleFrom(
          foregroundColor: fg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.18)
                  : Colors.black.withValues(alpha: 0.12),
              width: 1,
            ),
          ),
          padding: EdgeInsets.zero,
          minimumSize: const Size(36, 30),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: loading
            ? SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(fg),
                ),
              )
            : Icon(CupertinoIcons.ellipsis, size: 16, color: fg),
      ),
    );
  }
}

class _RowAvatar extends StatelessWidget {
  final PublicUser user;
  final bool isDark;
  final Color textColor;
  const _RowAvatar({
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

class _SmallFollowButton extends StatelessWidget {
  final bool isFollowing;
  final bool loading;
  final bool isDark;
  final VoidCallback onPressed;
  const _SmallFollowButton({
    required this.isFollowing,
    required this.loading,
    required this.isDark,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final fg = isFollowing
        ? (isDark ? Colors.white : const Color(0xFF0F172A))
        : (isDark ? Colors.black : Colors.white);
    final bg = isFollowing
        ? Colors.transparent
        : (isDark ? Colors.white : const Color(0xFF0F172A));
    final border = isFollowing
        ? (isDark
            ? Colors.white.withValues(alpha: 0.25)
            : Colors.black.withValues(alpha: 0.15))
        : Colors.transparent;
    return SizedBox(
      height: 30,
      child: TextButton(
        onPressed: loading ? null : onPressed,
        style: TextButton.styleFrom(
          backgroundColor: bg,
          foregroundColor: fg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: border, width: 1),
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
                  valueColor: AlwaysStoppedAnimation(fg),
                ),
              )
            : Text(
                isFollowing ? 'Following' : 'Follow',
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
