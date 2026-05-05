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

/// Public profile page — what one user sees when opening another user's
/// space. Treats the page as the author's "shelf": a tall masthead with
/// avatar + name + tier crest, a stats strip, and a curated grid of
/// their stories filterable by sort + genre. Designed to make a strong
/// authorial impression on first scroll, then reward exploration.
class AuthorProfilePage extends StatefulWidget {
  final String userId;
  final PublicUser? seed;
  const AuthorProfilePage({super.key, required this.userId, this.seed});

  @override
  State<AuthorProfilePage> createState() => _AuthorProfilePageState();
}

enum _SortMode { latest, top }

class _AuthorProfilePageState extends State<AuthorProfilePage> {
  PublicUser? _user;
  List<FeedItemModel> _posts = const [];
  bool _loadingUser = true;
  bool _loadingPosts = true;
  bool _followInFlight = false;
  _SortMode _sort = _SortMode.latest;
  String? _activeGenre;

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
    final hadRelationship = user.isFollowing || user.followRequestPending;
    setState(() {
      _followInFlight = true;
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
    final surface = isDark ? const Color(0xFF111114) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtle = textColor.withValues(alpha: 0.55);
    final user = _user;
    final viewerId = context.watch<AuthProvider>().currentUser?.id;
    final isSelf = viewerId != null && viewerId == widget.userId;

    return Scaffold(
      backgroundColor: bg,
      body: _loadingUser
          ? const Center(child: AppSpinner())
          : user == null
              ? _NotFound(textColor: textColor, subtle: subtle)
              : RefreshIndicator(
                  onRefresh: _load,
                  color: textColor,
                  child: CustomScrollView(
                    slivers: [
                      _buildAppBar(user, textColor, isSelf),
                      SliverToBoxAdapter(
                        child: _Hero(
                          user: user,
                          isDark: isDark,
                          surface: surface,
                          textColor: textColor,
                          subtle: subtle,
                          isSelf: isSelf,
                          followInFlight: _followInFlight,
                          onFollow: _toggleFollow,
                          onFollowersTap: () => context.push(
                            '/u/${user.id}/followers',
                            extra: user,
                          ),
                          onFollowingTap: () => context.push(
                            '/u/${user.id}/following',
                            extra: user,
                          ),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: _SectionHeader(
                          textColor: textColor,
                          subtle: subtle,
                          count: _posts.length,
                          sort: _sort,
                          onSortChanged: (m) => setState(() => _sort = m),
                        ),
                      ),
                      if (_genreOptions().length > 1)
                        SliverToBoxAdapter(
                          child: _GenreFilterStrip(
                            genres: _genreOptions(),
                            active: _activeGenre,
                            isDark: isDark,
                            textColor: textColor,
                            subtle: subtle,
                            onTap: (g) => setState(() => _activeGenre = g),
                          ),
                        ),
                      _buildPostsSlivers(isDark, surface, textColor, subtle),
                      const SliverToBoxAdapter(child: SizedBox(height: 40)),
                    ],
                  ),
                ),
    );
  }

  Widget _buildAppBar(PublicUser user, Color textColor, bool isSelf) {
    return SliverAppBar(
      pinned: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor.withValues(alpha: 0.85),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      title: Text(
        user.name ?? 'Profile',
        style: GoogleFonts.inter(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: textColor,
        ),
      ),
      actions: [
        if (!isSelf)
          IconButton(
            tooltip: 'Report user',
            icon: Icon(CupertinoIcons.flag, color: textColor, size: 19),
            onPressed: () => showReportSheet(
              context,
              targetType: ReportTarget.user,
              targetId: user.id,
              targetLabel: user.name,
            ),
          ),
      ],
    );
  }

  List<String> _genreOptions() {
    final set = <String>{};
    for (final p in _posts) {
      for (final g in p.genres) {
        if (g.trim().isNotEmpty) set.add(g);
      }
    }
    final list = set.toList()..sort();
    return ['All', ...list];
  }

  List<FeedItemModel> _filteredPosts() {
    var list = [..._posts];
    if (_activeGenre != null && _activeGenre != 'All') {
      list = list.where((p) => p.genres.contains(_activeGenre)).toList();
    }
    if (_sort == _SortMode.top) {
      list.sort((a, b) => b.likesCount.compareTo(a.likesCount));
    } else {
      list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
    return list;
  }

  Widget _buildPostsSlivers(
    bool isDark,
    Color surface,
    Color textColor,
    Color subtle,
  ) {
    if (_loadingPosts) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 28),
          child: Center(child: AppSpinner()),
        ),
      );
    }
    final list = _filteredPosts();
    if (list.isEmpty) {
      return SliverToBoxAdapter(
        child: _PostsEmpty(textColor: textColor, subtle: subtle),
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      sliver: SliverList.separated(
        itemCount: list.length,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (_, i) => _StoryCard(
          item: list[i],
          isDark: isDark,
          surface: surface,
          textColor: textColor,
          subtle: subtle,
        ),
      ),
    );
  }
}

// ============================================================================
// Hero
// ============================================================================

class _Hero extends StatelessWidget {
  final PublicUser user;
  final bool isDark;
  final Color surface;
  final Color textColor;
  final Color subtle;
  final bool isSelf;
  final bool followInFlight;
  final VoidCallback onFollow;
  final VoidCallback onFollowersTap;
  final VoidCallback onFollowingTap;
  const _Hero({
    required this.user,
    required this.isDark,
    required this.surface,
    required this.textColor,
    required this.subtle,
    required this.isSelf,
    required this.followInFlight,
    required this.onFollow,
    required this.onFollowersTap,
    required this.onFollowingTap,
  });

  @override
  Widget build(BuildContext context) {
    final isMaster = user.writerBadge?.slug == 'master';
    final accent = user.writerBadge != null
        ? UserBadgeChip.parseHex(user.writerBadge!.colorHex)
        : (isDark ? Colors.white24 : Colors.black12);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            alignment: Alignment.bottomRight,
            children: [
              _BigAvatar(
                user: user,
                isDark: isDark,
                textColor: textColor,
                ringColor: isMaster ? accent : null,
                size: 96,
              ),
              if (isMaster)
                Container(
                  margin: const EdgeInsets.only(right: 2, bottom: 2),
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: accent,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isDark ? Colors.black : Colors.white,
                      width: 2,
                    ),
                  ),
                  child: const Icon(
                    CupertinoIcons.checkmark_seal_fill,
                    size: 14,
                    color: Colors.white,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  user.name ?? 'Unnamed',
                  style: GoogleFonts.playfairDisplay(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: textColor,
                    height: 1.05,
                    letterSpacing: -0.5,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (user.writerBadge != null || user.readerBadge != null)
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
          const SizedBox(height: 16),
          _StatsStrip(
            user: user,
            surface: surface,
            isDark: isDark,
            textColor: textColor,
            subtle: subtle,
            onFollowersTap: onFollowersTap,
            onFollowingTap: onFollowingTap,
          ),
          if (!isSelf) ...[
            const SizedBox(height: 14),
            _ActionsRow(
              user: user,
              loading: followInFlight,
              isDark: isDark,
              onFollow: onFollow,
            ),
          ],
        ],
      ),
    );
  }
}

class _BigAvatar extends StatelessWidget {
  final PublicUser user;
  final bool isDark;
  final Color textColor;
  final Color? ringColor;
  final double size;
  const _BigAvatar({
    required this.user,
    required this.isDark,
    required this.textColor,
    required this.ringColor,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final inner = SizedBox(
      width: size,
      height: size,
      child: ClipOval(
        child: (user.photoUrl != null && user.photoUrl!.isNotEmpty)
            ? AppNetworkImage(
                url: user.photoUrl!,
                meta: user.photoMeta,
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorWidget: _Monogram(user: user, isDark: isDark, textColor: textColor, size: size),
              )
            : _Monogram(user: user, isDark: isDark, textColor: textColor, size: size),
      ),
    );
    if (ringColor == null) return inner;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: SweepGradient(
          colors: [
            ringColor!,
            ringColor!.withValues(alpha: 0.4),
            ringColor!,
          ],
        ),
      ),
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isDark ? const Color(0xFF000000) : const Color(0xFFF8F9FA),
        ),
        child: inner,
      ),
    );
  }
}

class _Monogram extends StatelessWidget {
  final PublicUser user;
  final bool isDark;
  final Color textColor;
  final double size;
  const _Monogram({
    required this.user,
    required this.isDark,
    required this.textColor,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final tileTop = isDark ? const Color(0xFF1F1F23) : const Color(0xFFEFF1F4);
    final tileBottom = isDark ? const Color(0xFF111114) : const Color(0xFFFFFFFF);
    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [tileTop, tileBottom],
        ),
      ),
      child: Text(
        ((user.name ?? '?').trim().isEmpty ? 'I' : user.name!.trim()[0]).toUpperCase(),
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
}

// ============================================================================
// Stats strip — surface card with three counts
// ============================================================================

class _StatsStrip extends StatelessWidget {
  final PublicUser user;
  final Color surface;
  final bool isDark;
  final Color textColor;
  final Color subtle;
  final VoidCallback onFollowersTap;
  final VoidCallback onFollowingTap;
  const _StatsStrip({
    required this.user,
    required this.surface,
    required this.isDark,
    required this.textColor,
    required this.subtle,
    required this.onFollowersTap,
    required this.onFollowingTap,
  });

  @override
  Widget build(BuildContext context) {
    final border = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.05);
    return Container(
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border, width: 1),
      ),
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          _Stat(
            count: user.postsCount,
            label: 'Stories',
            textColor: textColor,
            subtle: subtle,
          ),
          _Sep(subtle: subtle),
          _Stat(
            count: user.followersCount,
            label: 'Followers',
            textColor: textColor,
            subtle: subtle,
            onTap: onFollowersTap,
          ),
          _Sep(subtle: subtle),
          _Stat(
            count: user.followingCount,
            label: 'Following',
            textColor: textColor,
            subtle: subtle,
            onTap: onFollowingTap,
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final int count;
  final String label;
  final Color textColor;
  final Color subtle;
  final VoidCallback? onTap;
  const _Stat({
    required this.count,
    required this.label,
    required this.textColor,
    required this.subtle,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            children: [
              Text(
                _fmt(count),
                style: GoogleFonts.inter(
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  color: textColor,
                  letterSpacing: -0.4,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: GoogleFonts.inter(
                  fontSize: 11.5,
                  color: subtle,
                  letterSpacing: 0.3,
                  fontWeight: FontWeight.w500,
                ),
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

class _Sep extends StatelessWidget {
  final Color subtle;
  const _Sep({required this.subtle});
  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 30,
        color: subtle.withValues(alpha: 0.18),
      );
}

// ============================================================================
// Actions row — Follow + Share/Message
// ============================================================================

class _ActionsRow extends StatelessWidget {
  final PublicUser user;
  final bool loading;
  final bool isDark;
  final VoidCallback onFollow;
  const _ActionsRow({
    required this.user,
    required this.loading,
    required this.isDark,
    required this.onFollow,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          flex: 5,
          child: _PrimaryFollow(
            user: user,
            loading: loading,
            isDark: isDark,
            onPressed: onFollow,
          ),
        ),
        const SizedBox(width: 8),
        _IconAction(
          icon: CupertinoIcons.bubble_left,
          isDark: isDark,
          onTap: () {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Messaging this author isn\'t available yet.',
                  style: GoogleFonts.inter(fontSize: 13),
                ),
                duration: const Duration(seconds: 2),
              ),
            );
          },
        ),
        const SizedBox(width: 8),
        _IconAction(
          icon: CupertinoIcons.share,
          isDark: isDark,
          onTap: () {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Profile link copied to share sheet.',
                  style: GoogleFonts.inter(fontSize: 13),
                ),
                duration: const Duration(seconds: 2),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _PrimaryFollow extends StatelessWidget {
  final PublicUser user;
  final bool loading;
  final bool isDark;
  final VoidCallback onPressed;
  const _PrimaryFollow({
    required this.user,
    required this.loading,
    required this.isDark,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final hasRelationship = user.isFollowing || user.followRequestPending;
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
    if (user.isFollowing) {
      label = 'Following';
    } else if (user.followRequestPending) {
      label = 'Requested';
    } else if (user.requiresFollowApproval) {
      label = 'Request to follow';
    } else {
      label = 'Follow';
    }
    return SizedBox(
      height: 40,
      child: TextButton(
        onPressed: loading ? null : onPressed,
        style: TextButton.styleFrom(
          backgroundColor: bg,
          foregroundColor: fg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: border, width: 1),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16),
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
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: fg,
                  letterSpacing: 0.1,
                ),
              ),
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  final IconData icon;
  final bool isDark;
  final VoidCallback onTap;
  const _IconAction({
    required this.icon,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final border = isDark
        ? Colors.white.withValues(alpha: 0.25)
        : Colors.black.withValues(alpha: 0.15);
    return SizedBox(
      width: 40,
      height: 40,
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          padding: EdgeInsets.zero,
          backgroundColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: border, width: 1),
          ),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Icon(
          icon,
          size: 17,
          color: isDark ? Colors.white : const Color(0xFF0F172A),
        ),
      ),
    );
  }
}

// ============================================================================
// Section header — "Stories" + sort segmented control
// ============================================================================

class _SectionHeader extends StatelessWidget {
  final Color textColor;
  final Color subtle;
  final int count;
  final _SortMode sort;
  final ValueChanged<_SortMode> onSortChanged;
  const _SectionHeader({
    required this.textColor,
    required this.subtle,
    required this.count,
    required this.sort,
    required this.onSortChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Row(
        children: [
          Text(
            'Stories',
            style: GoogleFonts.inter(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: textColor,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$count',
            style: GoogleFonts.inter(
              fontSize: 13,
              color: subtle,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          _SortToggle(
            sort: sort,
            textColor: textColor,
            subtle: subtle,
            onChanged: onSortChanged,
          ),
        ],
      ),
    );
  }
}

class _SortToggle extends StatelessWidget {
  final _SortMode sort;
  final Color textColor;
  final Color subtle;
  final ValueChanged<_SortMode> onChanged;
  const _SortToggle({
    required this.sort,
    required this.textColor,
    required this.subtle,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    Widget chip(String label, _SortMode mode) {
      final active = sort == mode;
      return InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () => onChanged(mode),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              color: active ? textColor : subtle,
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: subtle.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      padding: const EdgeInsets.all(2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          chip('Latest', _SortMode.latest),
          chip('Top', _SortMode.top),
        ],
      ),
    );
  }
}

// ============================================================================
// Genre filter strip — quick filter into a single genre
// ============================================================================

class _GenreFilterStrip extends StatelessWidget {
  final List<String> genres;
  final String? active;
  final bool isDark;
  final Color textColor;
  final Color subtle;
  final ValueChanged<String?> onTap;
  const _GenreFilterStrip({
    required this.genres,
    required this.active,
    required this.isDark,
    required this.textColor,
    required this.subtle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        scrollDirection: Axis.horizontal,
        itemCount: genres.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final g = genres[i];
          final isActive = (active ?? 'All') == g;
          return ChoiceChip(
            label: Text(
              g,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                color: isActive
                    ? (isDark ? Colors.black : Colors.white)
                    : textColor,
              ),
            ),
            selected: isActive,
            onSelected: (_) => onTap(g == 'All' ? null : g),
            selectedColor: isDark ? Colors.white : const Color(0xFF0F172A),
            backgroundColor: subtle.withValues(alpha: 0.08),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(999),
              side: BorderSide.none,
            ),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            showCheckmark: false,
          );
        },
      ),
    );
  }
}

// ============================================================================
// Story card — richer than a row, with cover, title, snippet, meta strip
// ============================================================================

class _StoryCard extends StatelessWidget {
  final FeedItemModel item;
  final bool isDark;
  final Color surface;
  final Color textColor;
  final Color subtle;
  const _StoryCard({
    required this.item,
    required this.isDark,
    required this.surface,
    required this.textColor,
    required this.subtle,
  });

  @override
  Widget build(BuildContext context) {
    final border = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.05);
    return InkWell(
      onTap: () => context.push('/post/${item.id}', extra: item),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: border, width: 1),
        ),
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 78,
                height: 102,
                child: _cover(item, isDark),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title.isEmpty ? 'Untitled' : item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: textColor,
                      height: 1.25,
                      letterSpacing: -0.1,
                    ),
                  ),
                  if (item.description.trim().isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      item.description.trim(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 12.5,
                        color: subtle,
                        height: 1.35,
                      ),
                    ),
                  ],
                  const Spacer(),
                  _MetaStrip(item: item, subtle: subtle),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cover(FeedItemModel item, bool isDark) {
    final placeholder = Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [const Color(0xFF1F1F23), const Color(0xFF111114)]
              : [const Color(0xFFEFF1F4), const Color(0xFFFFFFFF)],
        ),
      ),
      alignment: Alignment.center,
      child: Icon(
        CupertinoIcons.book,
        color: isDark ? Colors.white24 : Colors.black26,
        size: 26,
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

class _MetaStrip extends StatelessWidget {
  final FeedItemModel item;
  final Color subtle;
  const _MetaStrip({required this.item, required this.subtle});

  @override
  Widget build(BuildContext context) {
    final genre = item.genres.isNotEmpty ? item.genres.first : null;
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _meta(CupertinoIcons.heart, '${item.likesCount}'),
        _meta(CupertinoIcons.chat_bubble, '${item.commentsCount}'),
        if (genre != null) _genreTag(genre),
      ],
    );
  }

  Widget _meta(IconData icon, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: subtle),
        const SizedBox(width: 4),
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 11.5,
            color: subtle,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _genreTag(String genre) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: subtle.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        genre,
        style: GoogleFonts.inter(
          fontSize: 10.5,
          color: subtle,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

// ============================================================================
// Empty + not-found states
// ============================================================================

class _PostsEmpty extends StatelessWidget {
  final Color textColor;
  final Color subtle;
  const _PostsEmpty({required this.textColor, required this.subtle});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
      child: Column(
        children: [
          Icon(CupertinoIcons.book, size: 36, color: subtle.withValues(alpha: 0.5)),
          const SizedBox(height: 10),
          Text(
            'No stories yet',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: textColor,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'When this author publishes, you\'ll see it here.',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(fontSize: 12.5, color: subtle),
          ),
        ],
      ),
    );
  }
}

class _NotFound extends StatelessWidget {
  final Color textColor;
  final Color subtle;
  const _NotFound({required this.textColor, required this.subtle});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(CupertinoIcons.person_crop_circle_badge_xmark, size: 38, color: subtle),
          const SizedBox(height: 10),
          Text(
            'User not found',
            style: GoogleFonts.inter(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: textColor,
            ),
          ),
        ],
      ),
    );
  }
}
