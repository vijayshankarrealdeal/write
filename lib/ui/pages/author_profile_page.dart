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

/// Public profile for any author. Reached from search results — shows
/// the author's avatar + name + post count, then their published feed
/// items as tappable rows.
///
/// Stays read-only: follow / message / report wiring lives in higher-
/// level epics, this page is purely a discovery surface.
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
      _user == null ? api.getPublicUser(widget.userId) : Future.value(_user),
      api.getFeedItemsByAuthor(widget.userId),
    ]);
    if (!mounted) return;
    setState(() {
      _user = futures[0] as PublicUser?;
      _posts = (futures[1] as List<FeedItemModel>)
          .where((p) => !p.isDraft)
          .toList(growable: false);
      _loadingUser = false;
      _loadingPosts = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF000000) : const Color(0xFFF8F9FA);
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtle = textColor.withValues(alpha: 0.55);
    final user = _user;

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
      ),
      body: _loadingUser
          ? const Center(child: CupertinoActivityIndicator())
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
                      _buildHeader(user, isDark, textColor, subtle),
                      const SizedBox(height: 24),
                      _buildPostsHeader(textColor, subtle),
                      const SizedBox(height: 12),
                      if (_loadingPosts)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Center(child: CupertinoActivityIndicator()),
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
  ) {
    return Row(
      children: [
        _Avatar(user: user, isDark: isDark, textColor: textColor, size: 64),
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
    final placeholder = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isDark ? Colors.white12 : Colors.black12,
      ),
      child: Text(
        _initials(user.name ?? '?'),
        style: GoogleFonts.inter(
          fontSize: size * 0.32,
          fontWeight: FontWeight.w700,
          color: textColor,
        ),
      ),
    );
    if (!hasImage) return placeholder;
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
          errorWidget: placeholder,
        ),
      ),
    );
  }

  String _initials(String name) {
    final parts =
        name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    final first = parts.first.substring(0, 1).toUpperCase();
    final last =
        parts.length > 1 ? parts.last.substring(0, 1).toUpperCase() : '';
    return '$first$last';
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
