import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/models/feed_item_model.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/services/analytics_service.dart';
import 'package:inkspacex/services/api/api_data_service.dart';
import 'package:inkspacex/ui/widgets/app_network_image.dart';
import 'package:inkspacex/ui/widgets/app_spinner.dart';
import 'package:inkspacex/ui/widgets/report_dialog.dart';
import 'package:inkspacex/ui/widgets/user_badge_chip.dart';

/// Public profile for any author. Reached from search results — shows
/// the author's avatar + name + post count + follower stats, then their
/// published feed items as tappable rows.
///
/// Follow / unfollow lives here; messaging + reporting are higher-level
/// epics handled elsewhere.
class AuthorProfilePage extends StatefulWidget {
  final String userId;
  final PublicUser? seed;
  const AuthorProfilePage({super.key, required this.userId, this.seed});

  @override
  State<AuthorProfilePage> createState() => _AuthorProfilePageState();
}

class _AuthorProfilePageState extends State<AuthorProfilePage> {
  PublicUser? _user;
  List<FeedItemModel> _posts = const [];
  bool _loadingUser = true;
  bool _loadingPosts = true;
  bool _followInFlight = false;

  @override
  void initState() {
    super.initState();
    AnalyticsService.instance.track(
      'profile_viewed',
      screen: '/u/:id',
      action: 'view',
      entityType: 'user',
      entityId: widget.userId,
    );
    _user = widget.seed;
    _loadingUser = widget.seed == null;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final api = context.read<AuthProvider>().dataService;
    final futures = await Future.wait([
      api.getPublicUser(widget.userId),
      api.getFeedItemsByAuthor(widget.userId),
    ]);
    if (!mounted) return;
    setState(() {
      _user = (futures[0] as PublicUser?) ?? _user;
      _posts = (futures[1] as List<FeedItemModel>)
          .where((p) => !p.isDraft)
          .toList(growable: false);
      _loadingUser = false;
      _loadingPosts = false;
    });
  }

  Future<void> _toggleFollow() async {
    final user = _user;
    if (user == null || _followInFlight) return;
    // Three input states map to two server calls:
    //   - approved follow ('Following' label) → unfollowUser
    //   - pending request ('Requested' label) → unfollowUser (cancels)
    //   - no relationship ('Follow' or 'Request to follow') → followUser
    final hadRelationship = user.isFollowing || user.followRequestPending;
    setState(() {
      _followInFlight = true;
      // Optimistic projection — if we're starting a follow, guess at
      // whether it'll land 'pending' from `requires_follow_approval`.
      // Server reconciles after the round-trip.
      if (hadRelationship) {
        _user = user.copyWith(
          isFollowing: false,
          followRequestPending: false,
          followersCount: user.isFollowing
              ? (user.followersCount - 1).clamp(0, 1 << 30)
              : user.followersCount,
        );
      } else {
        final goesPending = user.requiresFollowApproval;
        _user = user.copyWith(
          isFollowing: !goesPending,
          followRequestPending: goesPending,
          // Pending requests don't bump the public follower count —
          // matches the server's filter of `status = 'approved'` on
          // every count subquery.
          followersCount: goesPending
              ? user.followersCount
              : user.followersCount + 1,
        );
      }
    });
    final api = context.read<AuthProvider>().dataService;
    try {
      final result = hadRelationship
          ? await api.unfollowUser(user.id)
          : await api.followUser(user.id);
      if (!mounted) return;
      setState(() {
        _user = _user?.copyWith(
          isFollowing: result.isFollowing,
          followRequestPending: result.followRequestPending,
          followersCount: result.followersCount,
        );
      });
      String event;
      if (hadRelationship) {
        event = user.isFollowing ? 'user_unfollowed' : 'follow_request_cancelled';
      } else {
        event = result.followRequestPending
            ? 'follow_requested'
            : 'user_followed';
      }
      AnalyticsService.instance.track(
        event,
        screen: '/u/:id',
        action: 'click',
        entityType: 'user',
        entityId: user.id,
      );
    } catch (_) {
      if (!mounted) return;
      // Revert on failure.
      setState(() => _user = user);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            hadRelationship ? 'Could not unfollow' : 'Could not follow',
            style: GoogleFonts.inter(fontSize: 13),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    } finally {
      if (mounted) setState(() => _followInFlight = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF000000) : const Color(0xFFF8F9FA);
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtle = textColor.withValues(alpha: 0.55);
    final user = _user;
    final viewerId = context.watch<AuthProvider>().currentUser?.id;
    final isSelf = viewerId != null && viewerId == widget.userId;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(
          user?.name ?? 'Profile',
          style: GoogleFonts.inter(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: textColor,
          ),
        ),
        actions: [
          if (!isSelf && user != null)
            IconButton(
              tooltip: 'Report user',
              icon: Icon(CupertinoIcons.flag, color: textColor, size: 20),
              onPressed: () => showReportSheet(
                context,
                targetType: ReportTarget.user,
                targetId: user.id,
                targetLabel: user.name,
              ),
            ),
        ],
      ),
      body: _loadingUser
          ? const Center(child: AppSpinner())
          : user == null
              ? Center(
                  child: Text(
                    'User not found',
                    style: GoogleFonts.inter(color: subtle),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  color: textColor,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                    children: [
                      _buildHeader(user, isDark, textColor, subtle, isSelf),
                      const SizedBox(height: 18),
                      _StatsRow(
                        user: user,
                        textColor: textColor,
                        subtle: subtle,
                        onFollowersTap: () => context.push(
                          '/u/${user.id}/followers',
                          extra: user,
                        ),
                        onFollowingTap: () => context.push(
                          '/u/${user.id}/following',
                          extra: user,
                        ),
                      ),
                      const SizedBox(height: 24),
                      _buildPostsHeader(textColor, subtle),
                      const SizedBox(height: 12),
                      if (_loadingPosts)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Center(child: AppSpinner()),
                        )
                      else if (_posts.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Center(
                            child: Text(
                              'No published stories yet.',
                              style: GoogleFonts.inter(color: subtle, fontSize: 13),
                            ),
                          ),
                        )
                      else
                        ..._posts.map((p) => Padding(
                              padding: const EdgeInsets.only(bottom: 14),
                              child: _PostRow(item: p, isDark: isDark),
                            )),
                    ],
                  ),
                ),
    );
  }

  Widget _buildHeader(
    PublicUser user,
    bool isDark,
    Color textColor,
    Color subtle,
    bool isSelf,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _Avatar(user: user, isDark: isDark, textColor: textColor, size: 72),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                user.name ?? 'Unnamed',
                style: GoogleFonts.inter(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: textColor,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                user.postsCount == 1
                    ? '1 published story'
                    : '${user.postsCount} published stories',
                style: GoogleFonts.inter(fontSize: 13, color: subtle),
              ),
              if (user.writerBadge != null || user.readerBadge != null) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (user.writerBadge != null)
                      UserBadgeChip(
                        badge: user.writerBadge!,
                        compact: false,
                        onTap: () => showBadgeDetailSheet(
                          context,
                          badge: user.writerBadge!,
                          isSelf: isSelf,
                        ),
                      ),
                    if (user.readerBadge != null)
                      UserBadgeChip(
                        badge: user.readerBadge!,
                        compact: false,
                        onTap: () => showBadgeDetailSheet(
                          context,
                          badge: user.readerBadge!,
                          isSelf: isSelf,
                        ),
                      ),
                  ],
                ),
              ],
              if (!isSelf) ...[
                const SizedBox(height: 10),
                _FollowButton(
                  isFollowing: user.isFollowing,
                  followRequestPending: user.followRequestPending,
                  requiresApproval: user.requiresFollowApproval,
                  loading: _followInFlight,
                  isDark: isDark,
                  onPressed: _toggleFollow,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPostsHeader(Color textColor, Color subtle) {
    return Row(
      children: [
        Text(
          'Stories',
          style: GoogleFonts.inter(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: textColor,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          _loadingPosts ? '' : '${_posts.length}',
          style: GoogleFonts.inter(fontSize: 13, color: subtle),
        ),
      ],
    );
  }
}

/// Avatar with a refreshed brand-mark fallback. When the user has no
/// photo we render a rounded-square monogram tile (instead of the old
/// linked-rings circle) so the public profile reads as a "space" — a
/// little card-like surface — rather than a chat bubble.
class _Avatar extends StatelessWidget {
  final PublicUser user;
  final bool isDark;
  final Color textColor;
  final double size;
  const _Avatar({
    required this.user,
    required this.isDark,
    required this.textColor,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final url = user.photoUrl;
    final hasImage = url != null && url.isNotEmpty;
    if (hasImage) {
      return ClipOval(
        child: SizedBox(
          width: size,
          height: size,
          child: AppNetworkImage(
            url: url,
            meta: user.photoMeta,
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorWidget: _BrandMark(
              user: user,
              isDark: isDark,
              textColor: textColor,
              size: size,
            ),
          ),
        ),
      );
    }
    return _BrandMark(
      user: user,
      isDark: isDark,
      textColor: textColor,
      size: size,
    );
  }
}

/// Rounded-square monogram tile — the new "inkspace" brand mark. The
/// gradient + border treatment mirrors the brand surfaces in the rest of
/// the app and reads better than a flat grey circle when an author has
/// no profile photo.
class _BrandMark extends StatelessWidget {
  final PublicUser user;
  final bool isDark;
  final Color textColor;
  final double size;
  const _BrandMark({
    required this.user,
    required this.isDark,
    required this.textColor,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final tileTop =
        isDark ? const Color(0xFF1F1F23) : const Color(0xFFEFF1F4);
    final tileBottom =
        isDark ? const Color(0xFF111114) : const Color(0xFFFFFFFF);
    final border = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.06);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [tileTop, tileBottom],
        ),
        border: Border.all(color: border, width: 1),
      ),
      child: Text(
        _initial(user.name),
        style: GoogleFonts.playfairDisplay(
          fontSize: size * 0.46,
          fontWeight: FontWeight.w800,
          color: textColor,
          height: 1,
          letterSpacing: -1,
        ),
      ),
    );
  }

  String _initial(String? name) {
    final t = (name ?? '').trim();
    if (t.isEmpty) return 'I';
    return t.substring(0, 1).toUpperCase();
  }
}

class _FollowButton extends StatelessWidget {
  final bool isFollowing;
  /// Viewer has sent a follow request the target hasn't yet approved.
  /// Renders as 'Requested' — same outline-only treatment as
  /// 'Following' so the user reads it as "tap again to undo".
  final bool followRequestPending;
  /// True if the target has private writings and a follow needs approval.
  /// Lets the CTA read 'Request to follow' before the round-trip,
  /// matching Instagram's pattern of telegraphing the gate up-front.
  final bool requiresApproval;
  final bool loading;
  final bool isDark;
  final VoidCallback onPressed;
  const _FollowButton({
    required this.isFollowing,
    required this.followRequestPending,
    required this.requiresApproval,
    required this.loading,
    required this.isDark,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    // 'Following' and 'Requested' share the outline-only treatment —
    // both signal "you have a relationship, tap to undo". Plain
    // 'Follow' / 'Request to follow' are the filled CTA that draws
    // the eye when no relationship exists.
    final hasRelationship = isFollowing || followRequestPending;
    final fg = hasRelationship
        ? (isDark ? Colors.white : const Color(0xFF0F172A))
        : (isDark ? Colors.black : Colors.white);
    final bg = hasRelationship
        ? Colors.transparent
        : (isDark ? Colors.white : const Color(0xFF0F172A));
    final border = hasRelationship
        ? (isDark
            ? Colors.white.withValues(alpha: 0.25)
            : Colors.black.withValues(alpha: 0.15))
        : Colors.transparent;
    final String label;
    if (isFollowing) {
      label = 'Following';
    } else if (followRequestPending) {
      label = 'Requested';
    } else if (requiresApproval) {
      label = 'Request to follow';
    } else {
      label = 'Follow';
    }
    return SizedBox(
      height: 34,
      child: TextButton(
        onPressed: loading ? null : onPressed,
        style: TextButton.styleFrom(
          backgroundColor: bg,
          foregroundColor: fg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: border, width: 1),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          minimumSize: const Size(96, 34),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: loading
            ? SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(fg),
                ),
              )
            : Text(
                label,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
      ),
    );
  }
}

class _StatsRow extends StatelessWidget {
  final PublicUser user;
  final Color textColor;
  final Color subtle;
  final VoidCallback onFollowersTap;
  final VoidCallback onFollowingTap;
  const _StatsRow({
    required this.user,
    required this.textColor,
    required this.subtle,
    required this.onFollowersTap,
    required this.onFollowingTap,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _StatTile(
          count: user.postsCount,
          label: 'Stories',
          textColor: textColor,
          subtle: subtle,
          onTap: null,
        ),
        _Divider(subtle: subtle),
        _StatTile(
          count: user.followersCount,
          label: 'Followers',
          textColor: textColor,
          subtle: subtle,
          onTap: onFollowersTap,
        ),
        _Divider(subtle: subtle),
        _StatTile(
          count: user.followingCount,
          label: 'Following',
          textColor: textColor,
          subtle: subtle,
          onTap: onFollowingTap,
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  final int count;
  final String label;
  final Color textColor;
  final Color subtle;
  final VoidCallback? onTap;
  const _StatTile({
    required this.count,
    required this.label,
    required this.textColor,
    required this.subtle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              Text(
                _fmt(count),
                style: GoogleFonts.inter(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: GoogleFonts.inter(fontSize: 12, color: subtle),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _fmt(int n) {
    if (n < 1000) return '$n';
    if (n < 1000000) {
      final v = n / 1000;
      return v >= 10 ? '${v.toStringAsFixed(0)}k' : '${v.toStringAsFixed(1)}k';
    }
    final v = n / 1000000;
    return v >= 10 ? '${v.toStringAsFixed(0)}M' : '${v.toStringAsFixed(1)}M';
  }
}

class _Divider extends StatelessWidget {
  final Color subtle;
  const _Divider({required this.subtle});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 28,
      color: subtle.withValues(alpha: 0.25),
    );
  }
}

class _PostRow extends StatelessWidget {
  final FeedItemModel item;
  final bool isDark;
  const _PostRow({required this.item, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtle = textColor.withValues(alpha: 0.55);
    return GestureDetector(
      onTap: () => context.push('/post/${item.id}', extra: item),
      behavior: HitTestBehavior.opaque,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 56,
              height: 78,
              child: _cover(item, isDark),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: textColor,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(CupertinoIcons.heart, size: 11, color: subtle),
                    const SizedBox(width: 3),
                    Text('${item.likesCount}',
                        style: GoogleFonts.inter(fontSize: 11, color: subtle)),
                    const SizedBox(width: 10),
                    Icon(CupertinoIcons.chat_bubble, size: 11, color: subtle),
                    const SizedBox(width: 3),
                    Text('${item.commentsCount}',
                        style: GoogleFonts.inter(fontSize: 11, color: subtle)),
                  ],
                ),
              ],
            ),
          ),
          Icon(CupertinoIcons.chevron_right, size: 14, color: subtle),
        ],
      ),
    );
  }

  Widget _cover(FeedItemModel item, bool isDark) {
    final placeholder = Container(
      color: isDark ? const Color(0xFF1A1A1A) : const Color(0xFFEDEFF2),
      alignment: Alignment.center,
      child: Icon(
        CupertinoIcons.book,
        color: isDark ? Colors.white24 : Colors.black26,
      ),
    );
    if (item.imageUrl.isEmpty && item.imageMeta == null) return placeholder;
    return AppNetworkImage(
      url: item.imageUrl,
      meta: item.imageMeta,
      fit: BoxFit.cover,
      errorWidget: placeholder,
    );
  }
}
