import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/models/notification_model.dart';
import 'package:inkspacex/provider/notification_provider.dart';
import 'package:inkspacex/ui/widgets/app_network_image.dart';
import 'package:inkspacex/ui/widgets/skeleton.dart';

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<NotificationProvider>().ensureStarted();
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF000000) : const Color(0xFFF8F9FA);
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);

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
          'Notifications',
          style: GoogleFonts.inter(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: textColor,
          ),
        ),
        actions: [
          Consumer<NotificationProvider>(
            builder: (context, notif, _) {
              if (!notif.hasUnread) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(right: 12),
                child: TextButton(
                  onPressed: notif.markAllRead,
                  child: Text(
                    'Mark all read',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF2563EB),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: Consumer<NotificationProvider>(
        builder: (context, notif, _) {
          if (notif.isLoading && notif.items.isEmpty) {
            return ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemBuilder: (_, __) =>
                  const _NotificationSkeletonRow(),
              separatorBuilder: (_, __) => const SizedBox(height: 4),
              itemCount: 8,
            );
          }
          if (notif.items.isEmpty) {
            return _EmptyState(textColor: textColor, isDark: isDark);
          }
          return RefreshIndicator(
            onRefresh: notif.refresh,
            color: textColor,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: notif.items.length,
              separatorBuilder: (_, __) => Divider(
                height: 1,
                color: isDark
                    ? Colors.white.withValues(alpha: 0.05)
                    : Colors.black.withValues(alpha: 0.05),
              ),
              itemBuilder: (context, i) => _NotificationRow(
                notif: notif.items[i],
                isDark: isDark,
                onTap: () {
                  notif.markRead(notif.items[i]);
                  final feedItemId = notif.items[i].feedItemId;
                  if (feedItemId != null && feedItemId.isNotEmpty) {
                    context.push('/post/$feedItemId');
                  }
                },
                onDelete: () => notif.delete(notif.items[i]),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _NotificationRow extends StatelessWidget {
  const _NotificationRow({
    required this.notif,
    required this.isDark,
    required this.onTap,
    required this.onDelete,
  });

  final NotificationModel notif;
  final bool isDark;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtle = textColor.withValues(alpha: 0.55);
    final unreadBg = isDark
        ? const Color(0xFF1E2A3A).withValues(alpha: 0.5)
        : const Color(0xFFEFF6FF);

    return Dismissible(
      key: ValueKey(notif.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: const Color(0xFFEF4444).withValues(alpha: 0.85),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: const Icon(CupertinoIcons.trash, color: Colors.white, size: 22),
      ),
      onDismissed: (_) => onDelete(),
      child: InkWell(
        onTap: onTap,
        child: Container(
          color: notif.read ? Colors.transparent : unreadBg,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Avatar(notif: notif, isDark: isDark),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (!notif.read) ...[
                          Container(
                            width: 7,
                            height: 7,
                            decoration: const BoxDecoration(
                              color: Color(0xFF2563EB),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Expanded(
                          child: Text(
                            notif.title,
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: notif.read
                                  ? FontWeight.w500
                                  : FontWeight.w600,
                              color: textColor,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          _formatRelativeTime(notif.createdAt),
                          style: GoogleFonts.inter(fontSize: 11, color: subtle),
                        ),
                      ],
                    ),
                    if (notif.subtitle != null && notif.subtitle!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Padding(
                        padding: const EdgeInsets.only(left: 0),
                        child: Text(
                          notif.subtitle!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                            fontSize: 12.5,
                            color: subtle,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.notif, required this.isDark});

  final NotificationModel notif;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final initials = (notif.actorName ?? '?').trim();
    final initial = initials.isEmpty ? '?' : initials[0].toUpperCase();
    final iconForKind = switch (notif.kind) {
      'like' => CupertinoIcons.heart_fill,
      'comment' => CupertinoIcons.chat_bubble_fill,
      'reply' => CupertinoIcons.arrowshape_turn_up_left_fill,
      _ => CupertinoIcons.bell_fill,
    };
    final colorForKind = switch (notif.kind) {
      'like' => const Color(0xFFEF4444),
      'comment' => const Color(0xFF2563EB),
      'reply' => const Color(0xFF8B5CF6),
      _ => const Color(0xFF6B7280),
    };

    return Stack(
      clipBehavior: Clip.none,
      children: [
        ClipOval(
          child: SizedBox(
            width: 44,
            height: 44,
            child: notif.actorPhotoUrl != null
                ? AppNetworkImage(
                    url: notif.actorPhotoUrl,
                    width: 44,
                    height: 44,
                    fit: BoxFit.cover,
                  )
                : Container(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.08)
                        : Colors.black.withValues(alpha: 0.06),
                    alignment: Alignment.center,
                    child: Text(
                      initial,
                      style: GoogleFonts.inter(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color:
                            isDark ? Colors.white : const Color(0xFF0F172A),
                      ),
                    ),
                  ),
          ),
        ),
        Positioned(
          bottom: -2,
          right: -2,
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: Theme.of(context).scaffoldBackgroundColor,
              shape: BoxShape.circle,
            ),
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: colorForKind,
                shape: BoxShape.circle,
              ),
              child: Icon(iconForKind, size: 9, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.textColor, required this.isDark});

  final Color textColor;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.05)
                    : Colors.black.withValues(alpha: 0.04),
                shape: BoxShape.circle,
              ),
              child: Icon(
                CupertinoIcons.bell,
                size: 40,
                color: textColor.withValues(alpha: 0.3),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'You\'re all caught up',
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: textColor,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'When someone likes or comments on your\nstories, you\'ll see it here.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 13,
                color: textColor.withValues(alpha: 0.5),
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NotificationSkeletonRow extends StatelessWidget {
  const _NotificationSkeletonRow();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          const Skeleton(width: 44, height: 44, shape: BoxShape.circle),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Skeleton(height: 12, widthFactor: 0.7),
                SizedBox(height: 8),
                Skeleton(height: 10, widthFactor: 0.45),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _formatRelativeTime(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 1) return 'now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m';
  if (diff.inHours < 24) return '${diff.inHours}h';
  if (diff.inDays < 7) return '${diff.inDays}d';
  if (diff.inDays < 30) return '${(diff.inDays / 7).floor()}w';
  return '${(diff.inDays / 30).floor()}mo';
}
