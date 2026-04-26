import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/provider/notification_provider.dart';

/// Bell icon with unread-count badge. Watches [NotificationProvider]
/// so the count updates live as SSE events arrive.
class NotificationBellButton extends StatelessWidget {
  const NotificationBellButton({
    super.key,
    required this.onTap,
    this.color,
    this.size = 22,
  });

  final VoidCallback onTap;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final notif = context.watch<NotificationProvider>();
    final hasUnread = notif.hasUnread;
    final badgeCount = notif.unreadCount;
    final iconColor = color ?? CupertinoColors.label.resolveFrom(context);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: SizedBox(
            width: size + 12,
            height: size + 12,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(
                  hasUnread
                      ? CupertinoIcons.bell_fill
                      : CupertinoIcons.bell,
                  color: iconColor,
                  size: size,
                ),
                if (hasUnread)
                  Positioned(
                    top: 0,
                    right: 0,
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEF4444),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: Theme.of(context).scaffoldBackgroundColor,
                          width: 1.5,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        badgeCount > 99 ? '99+' : '$badgeCount',
                        style: GoogleFonts.inter(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          height: 1.0,
                        ),
                      ),
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

/// Compact pill version for the desktop sidebar.
class NotificationSidebarTile extends StatelessWidget {
  const NotificationSidebarTile({
    super.key,
    required this.expanded,
    required this.isDark,
    required this.onTap,
  });

  final bool expanded;
  final bool isDark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final notif = context.watch<NotificationProvider>();
    final fg = isDark ? Colors.white : const Color(0xFF0F172A);
    final hasUnread = notif.hasUnread;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        expanded ? 12 : 14,
        2,
        expanded ? 12 : 14,
        2,
      ),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: 38,
            padding: EdgeInsets.symmetric(horizontal: expanded ? 12 : 0),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisAlignment: expanded
                  ? MainAxisAlignment.start
                  : MainAxisAlignment.center,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Icon(
                      hasUnread
                          ? CupertinoIcons.bell_fill
                          : CupertinoIcons.bell,
                      size: 18,
                      color: fg.withValues(alpha: hasUnread ? 0.9 : 0.55),
                    ),
                    if (hasUnread)
                      Positioned(
                        top: -3,
                        right: -3,
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: Color(0xFFEF4444),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                  ],
                ),
                if (expanded) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Notifications',
                      style: GoogleFonts.inter(
                        fontSize: 13.5,
                        fontWeight: hasUnread ? FontWeight.w600 : FontWeight.w500,
                        color: fg.withValues(alpha: 0.75),
                      ),
                    ),
                  ),
                  if (hasUnread)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEF4444),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        notif.unreadCount > 99 ? '99+' : '${notif.unreadCount}',
                        style: GoogleFonts.inter(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          height: 1.0,
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
