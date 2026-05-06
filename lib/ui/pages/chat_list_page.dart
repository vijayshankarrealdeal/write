import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/models/conversation_model.dart';
import 'package:inkspacex/provider/chat_provider.dart';
import 'package:inkspacex/ui/widgets/app_network_image.dart';
import 'package:inkspacex/ui/widgets/skeleton.dart';

class ChatListPage extends StatefulWidget {
  const ChatListPage({super.key});

  @override
  State<ChatListPage> createState() => _ChatListPageState();
}

class _ChatListPageState extends State<ChatListPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final chat = context.read<ChatProvider>();
      chat.ensureStarted();
      chat.refreshConversations();
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
        centerTitle: true,
        backgroundColor: bgColor,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: Icon(CupertinoIcons.back, color: textColor),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/'),
        ),
        title: Text(
          'Messages',
          style: GoogleFonts.inter(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: textColor,
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(
              CupertinoIcons.add,
              color: textColor.withValues(alpha: 0.8),
            ),
            tooltip: 'New chat',
            onPressed: () => context.push('/chat/new'),
          ),
        ],
      ),
      body: Consumer<ChatProvider>(
        builder: (context, chat, _) {
          if (chat.isLoadingConversations && chat.conversations.isEmpty) {
            return ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemBuilder: (_, _) => const _ChatSkeletonRow(),
              separatorBuilder: (_, _) => const SizedBox(height: 4),
              itemCount: 8,
            );
          }
          if (chat.conversations.isEmpty) {
            return _EmptyState(textColor: textColor, isDark: isDark);
          }
          return RefreshIndicator(
            onRefresh: chat.refreshConversations,
            color: textColor,
            child: ListView.separated(
              itemCount: chat.conversations.length,
              separatorBuilder: (_, _) => Divider(
                height: 1,
                color: isDark
                    ? Colors.white.withValues(alpha: 0.05)
                    : Colors.black.withValues(alpha: 0.05),
              ),
              itemBuilder: (context, i) {
                final convo = chat.conversations[i];
                return _ConversationRow(
                  convo: convo,
                  isDark: isDark,
                  onTap: () =>
                      context.push('/chat/${convo.otherUser.id}'),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _ConversationRow extends StatelessWidget {
  const _ConversationRow({
    required this.convo,
    required this.isDark,
    required this.onTap,
  });

  final ConversationModel convo;
  final bool isDark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtle = textColor.withValues(alpha: 0.55);
    final unread = convo.unreadCount > 0;

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ParticipantAvatar(participant: convo.otherUser, isDark: isDark),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          convo.otherUser.name ?? 'Unknown',
                          style: GoogleFonts.inter(
                            fontSize: 14.5,
                            fontWeight:
                                unread ? FontWeight.w700 : FontWeight.w600,
                            color: textColor,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (convo.lastMessageAt != null)
                        Text(
                          _formatRelativeTime(convo.lastMessageAt!),
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            color: subtle,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          convo.lastMessagePreview ?? 'Say hello',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            color: unread ? textColor : subtle,
                            fontWeight: unread
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                      if (unread) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: const BoxDecoration(
                            color: Color(0xFF2563EB),
                            borderRadius: BorderRadius.all(Radius.circular(10)),
                          ),
                          child: Text(
                            convo.unreadCount > 99
                                ? '99+'
                                : convo.unreadCount.toString(),
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ParticipantAvatar extends StatelessWidget {
  const _ParticipantAvatar({required this.participant, required this.isDark});

  final ConversationParticipant participant;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final initials = (participant.name ?? '?').trim();
    final initial = initials.isEmpty ? '?' : initials[0].toUpperCase();
    return ClipOval(
      child: SizedBox(
        width: 48,
        height: 48,
        child: participant.photoUrl != null
            ? AppNetworkImage(
                url: participant.photoUrl,
                width: 48,
                height: 48,
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
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white : const Color(0xFF0F172A),
                  ),
                ),
              ),
      ),
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
                CupertinoIcons.chat_bubble_2,
                size: 40,
                color: textColor.withValues(alpha: 0.3),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'No messages yet',
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: textColor,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Start a conversation with another reader\nto share books, lines, and ideas.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 13,
                color: textColor.withValues(alpha: 0.5),
                height: 1.5,
              ),
            ),
            const SizedBox(height: 20),
            CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
              color: CupertinoColors.activeBlue,
              borderRadius: BorderRadius.circular(28),
              onPressed: () => context.push('/chat/new'),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    CupertinoIcons.square_pencil,
                    size: 18,
                    color: CupertinoColors.white,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Start a chat',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: CupertinoColors.white,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatSkeletonRow extends StatelessWidget {
  const _ChatSkeletonRow();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: const [
          Skeleton(width: 48, height: 48, shape: BoxShape.circle),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Skeleton(height: 12, widthFactor: 0.6),
                SizedBox(height: 8),
                Skeleton(height: 10, widthFactor: 0.85),
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
