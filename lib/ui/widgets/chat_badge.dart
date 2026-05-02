import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/provider/chat_provider.dart';

/// Chat icon with unread-count badge. Watches [ChatProvider] so the count
/// updates live as new messages arrive on the SSE channel.
class ChatBadgeButton extends StatelessWidget {
  const ChatBadgeButton({
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
    final chat = context.watch<ChatProvider>();
    final unread = chat.totalUnread;
    final hasUnread = unread > 0;
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
                      ? CupertinoIcons.chat_bubble_2_fill
                      : CupertinoIcons.chat_bubble_2,
                  color: iconColor,
                  size: size,
                ),
                if (hasUnread)
                  Positioned(
                    top: 0,
                    right: 0,
                    child: Container(
                      constraints: const BoxConstraints(
                          minWidth: 16, minHeight: 16),
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
                        unread > 99 ? '99+' : '$unread',
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
