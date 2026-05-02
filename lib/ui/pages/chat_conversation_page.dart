import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/models/chat_message_model.dart';
import 'package:inkspacex/models/conversation_model.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/provider/chat_provider.dart';
import 'package:inkspacex/services/api/api_storage_service.dart';
import 'package:inkspacex/services/app_log.dart';
import 'package:inkspacex/ui/widgets/app_network_image.dart';
import 'package:inkspacex/ui/widgets/app_spinner.dart';

/// One-on-one chat thread.
///
/// Loaded by user id (the route is /chat/:userId). On mount we
/// `startConversation` to get-or-create the thread, then load messages
/// and mark them read. The provider keeps the message list fresh via the
/// shared SSE channel.
class ChatConversationPage extends StatefulWidget {
  const ChatConversationPage({super.key, required this.otherUserId});

  final String otherUserId;

  @override
  State<ChatConversationPage> createState() => _ChatConversationPageState();
}

class _ChatConversationPageState extends State<ChatConversationPage> {
  final _composerCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  ConversationModel? _conversation;
  bool _bootError = false;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    final chat = context.read<ChatProvider>();
    chat.ensureStarted();
    try {
      final convo = await chat.openConversationWith(widget.otherUserId);
      if (!mounted) return;
      setState(() => _conversation = convo);
      await chat.loadMessages(convo.id);
      await chat.markRead(convo.id);
      _scrollToBottom();
    } catch (e) {
      log.w('[chat-page] bootstrap failed: $e');
      if (mounted) setState(() => _bootError = true);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Future<void> _sendText() async {
    final convo = _conversation;
    final auth = context.read<AuthProvider>();
    final userId = auth.currentUser?.id;
    if (convo == null || userId == null) return;
    final text = _composerCtrl.text.trim();
    if (text.isEmpty) return;
    _composerCtrl.clear();
    setState(() => _sending = true);
    try {
      await context.read<ChatProvider>().sendText(convo.id, userId, text);
      _scrollToBottom();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _attachImage() async {
    final convo = _conversation;
    final auth = context.read<AuthProvider>();
    final userId = auth.currentUser?.id;
    if (convo == null || userId == null) return;

    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    final Uint8List bytes = await picked.readAsBytes();
    if (!mounted) return;
    setState(() => _sending = true);
    final chat = context.read<ChatProvider>();
    try {
      final storage = ApiStorageService(auth.apiClient);
      final upload = await storage.uploadEditorImage(userId, bytes);
      if (!mounted) return;
      await chat.sendAttachment(
        convo.id,
        userId,
        kind: ChatMessageKind.image,
        attachment: {
          'url': upload.url,
          if (upload.meta != null) 'image_meta': upload.meta!.toJson(),
        },
      );
      _scrollToBottom();
    } catch (e) {
      log.w('[chat-page] image upload failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to send photo: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _shareCustomAttachment(ChatMessageKind kind) async {
    final convo = _conversation;
    final auth = context.read<AuthProvider>();
    final userId = auth.currentUser?.id;
    if (convo == null || userId == null) return;

    final chat = context.read<ChatProvider>();
    final result = await showModalBottomSheet<_ShareDraft>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ShareSheet(kind: kind),
    );
    if (result == null || !mounted) return;
    setState(() => _sending = true);
    try {
      await chat.sendAttachment(
        convo.id,
        userId,
        kind: kind,
        body: result.body,
        attachment: result.attachment,
      );
      _scrollToBottom();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _openAttachmentMenu() {
    showModalBottomSheet(
      context: context,
      builder: (sheetCtx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(CupertinoIcons.photo),
                title: const Text('Photo'),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _attachImage();
                },
              ),
              ListTile(
                leading: const Icon(CupertinoIcons.book),
                title: const Text('Share a book'),
                subtitle: const Text('Send a book from the app'),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _shareCustomAttachment(ChatMessageKind.book);
                },
              ),
              ListTile(
                leading: const Icon(CupertinoIcons.quote_bubble),
                title: const Text('Share lines'),
                subtitle: const Text('A few lines from a book'),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _shareCustomAttachment(ChatMessageKind.excerpt);
                },
              ),
              ListTile(
                leading: const Icon(CupertinoIcons.doc_text),
                title: const Text('Share a section'),
                subtitle: const Text('A whole chapter or section'),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _shareCustomAttachment(ChatMessageKind.section);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _composerCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF000000) : const Color(0xFFF8F9FA);
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final auth = context.watch<AuthProvider>();
    final myId = auth.currentUser?.id;

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: bgColor,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: Icon(CupertinoIcons.back, color: textColor),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/chats'),
        ),
        titleSpacing: 0,
        title: _conversation == null
            ? Text(
                'Chat',
                style: GoogleFonts.inter(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
              )
            : _ConversationHeader(
                participant: _conversation!.otherUser,
                isDark: isDark,
              ),
      ),
      body: _conversation == null
          ? _bootError
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Could not open this chat.',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        color: textColor.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                )
              : const Center(child: AppSpinner())
          : Column(
              children: [
                Expanded(
                  child: Consumer<ChatProvider>(
                    builder: (context, chat, _) {
                      final messages = chat.messagesFor(_conversation!.id);
                      if (chat.isLoadingMessages(_conversation!.id) &&
                          messages.isEmpty) {
                        return const Center(child: AppSpinner());
                      }
                      if (messages.isEmpty) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              'Say hello.',
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                color: textColor.withValues(alpha: 0.5),
                              ),
                            ),
                          ),
                        );
                      }
                      return ListView.builder(
                        controller: _scrollCtrl,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 12),
                        itemCount: messages.length,
                        itemBuilder: (_, i) {
                          final msg = messages[i];
                          final mine = msg.senderId == myId;
                          return _MessageBubble(
                            message: msg,
                            mine: mine,
                            isDark: isDark,
                          );
                        },
                      );
                    },
                  ),
                ),
                _Composer(
                  controller: _composerCtrl,
                  isDark: isDark,
                  sending: _sending,
                  onSend: _sendText,
                  onAttach: _openAttachmentMenu,
                ),
              ],
            ),
    );
  }
}

class _ConversationHeader extends StatelessWidget {
  const _ConversationHeader({required this.participant, required this.isDark});

  final ConversationParticipant participant;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final initials = (participant.name ?? '?').trim();
    final initial = initials.isEmpty ? '?' : initials[0].toUpperCase();
    return GestureDetector(
      onTap: () => context.push('/u/${participant.id}'),
      child: Row(
        children: [
          ClipOval(
            child: SizedBox(
              width: 34,
              height: 34,
              child: participant.photoUrl != null
                  ? AppNetworkImage(
                      url: participant.photoUrl,
                      width: 34,
                      height: 34,
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
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: textColor,
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              participant.name ?? 'Unknown',
              style: GoogleFonts.inter(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: textColor,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.mine,
    required this.isDark,
  });

  final ChatMessageModel message;
  final bool mine;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final myBg = const Color(0xFF2563EB);
    final theirBg = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.06);
    final myFg = Colors.white;
    final theirFg = isDark ? Colors.white : const Color(0xFF0F172A);
    final fg = mine ? myFg : theirFg;
    final bg = mine ? myBg : theirBg;

    Widget body;
    switch (message.kind) {
      case ChatMessageKind.text:
        body = Text(
          message.body ?? '',
          style: GoogleFonts.inter(fontSize: 14.5, color: fg, height: 1.35),
        );
      case ChatMessageKind.image:
        body = _ImageAttachment(message: message, fg: fg);
      case ChatMessageKind.book:
        body = _AttachmentCard(
          icon: CupertinoIcons.book,
          title: message.attachmentTitle ?? 'Book',
          subtitle: message.attachmentSubtitle,
          body: message.body,
          fg: fg,
        );
      case ChatMessageKind.excerpt:
        body = _AttachmentCard(
          icon: CupertinoIcons.quote_bubble,
          title: message.attachmentTitle ?? 'Excerpt',
          subtitle: message.attachmentSubtitle,
          body: message.body,
          fg: fg,
        );
      case ChatMessageKind.section:
        body = _AttachmentCard(
          icon: CupertinoIcons.doc_text,
          title: message.attachmentTitle ?? 'Section',
          subtitle: message.attachmentSubtitle,
          body: message.body,
          fg: fg,
        );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment:
            mine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width * 0.78,
              ),
              child: Container(
                padding: message.kind == ChatMessageKind.image
                    ? const EdgeInsets.all(4)
                    : const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: const Radius.circular(16),
                    bottomLeft: Radius.circular(mine ? 16 : 4),
                    bottomRight: Radius.circular(mine ? 4 : 16),
                  ),
                ),
                child: body,
              ),
            ),
          ),
          if (mine && message.pending) ...[
            const SizedBox(width: 6),
            const Padding(
              padding: EdgeInsets.only(bottom: 6),
              child: SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ImageAttachment extends StatelessWidget {
  const _ImageAttachment({required this.message, required this.fg});

  final ChatMessageModel message;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    final url = message.attachmentUrl ?? '';
    if (url.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: Text(
          message.body ?? '📷 Photo',
          style: GoogleFonts.inter(fontSize: 14, color: fg),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: AppNetworkImage(
        url: url,
        meta: message.attachmentImageMeta,
        width: 220,
        fit: BoxFit.cover,
      ),
    );
  }
}

class _AttachmentCard extends StatelessWidget {
  const _AttachmentCard({
    required this.icon,
    required this.title,
    this.subtitle,
    this.body,
    required this.fg,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final String? body;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: fg),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                title,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: fg,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        if (subtitle != null && subtitle!.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            subtitle!,
            style: GoogleFonts.inter(
              fontSize: 12,
              color: fg.withValues(alpha: 0.85),
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        if (body != null && body!.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: fg.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              body!,
              style: GoogleFonts.inter(
                fontSize: 13,
                color: fg,
                height: 1.4,
                fontStyle: FontStyle.italic,
              ),
              maxLines: 8,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ],
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.isDark,
    required this.sending,
    required this.onSend,
    required this.onAttach,
  });

  final TextEditingController controller;
  final bool isDark;
  final bool sending;
  final VoidCallback onSend;
  final VoidCallback onAttach;

  @override
  Widget build(BuildContext context) {
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final fillColor = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.04);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              icon: Icon(CupertinoIcons.add_circled,
                  color: textColor.withValues(alpha: 0.7)),
              tooltip: 'Attach',
              onPressed: sending ? null : onAttach,
            ),
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                style: GoogleFonts.inter(fontSize: 14.5, color: textColor),
                decoration: InputDecoration(
                  hintText: 'Message',
                  hintStyle: GoogleFonts.inter(
                    fontSize: 14.5,
                    color: textColor.withValues(alpha: 0.45),
                  ),
                  filled: true,
                  fillColor: fillColor,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none,
                  ),
                ),
                onSubmitted: (_) => onSend(),
              ),
            ),
            IconButton(
              icon: const Icon(CupertinoIcons.arrow_up_circle_fill,
                  color: Color(0xFF2563EB), size: 30),
              tooltip: 'Send',
              onPressed: sending ? null : onSend,
            ),
          ],
        ),
      ),
    );
  }
}

class _ShareDraft {
  _ShareDraft({this.body, this.attachment});
  final String? body;
  final Map<String, dynamic>? attachment;
}

class _ShareSheet extends StatefulWidget {
  const _ShareSheet({required this.kind});
  final ChatMessageKind kind;

  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  final _titleCtrl = TextEditingController();
  final _subtitleCtrl = TextEditingController();
  final _bodyCtrl = TextEditingController();

  @override
  void dispose() {
    _titleCtrl.dispose();
    _subtitleCtrl.dispose();
    _bodyCtrl.dispose();
    super.dispose();
  }

  String get _heading {
    switch (widget.kind) {
      case ChatMessageKind.book:
        return 'Share a book';
      case ChatMessageKind.excerpt:
        return 'Share lines';
      case ChatMessageKind.section:
        return 'Share a section';
      default:
        return 'Share';
    }
  }

  String get _bodyHint {
    switch (widget.kind) {
      case ChatMessageKind.excerpt:
        return 'Paste the lines from the book';
      case ChatMessageKind.section:
        return 'Paste the section text (or a summary)';
      default:
        return 'Add a note (optional)';
    }
  }

  bool get _bodyRequired =>
      widget.kind == ChatMessageKind.excerpt ||
      widget.kind == ChatMessageKind.section;

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.viewInsetsOf(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        16 + viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _heading,
            style: GoogleFonts.playfairDisplay(
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _titleCtrl,
            decoration: const InputDecoration(
              labelText: 'Title',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _subtitleCtrl,
            decoration: const InputDecoration(
              labelText: 'Author / subtitle (optional)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _bodyCtrl,
            minLines: 3,
            maxLines: 8,
            decoration: InputDecoration(
              labelText: _bodyRequired ? 'Text' : 'Note (optional)',
              hintText: _bodyHint,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () {
                  final title = _titleCtrl.text.trim();
                  final subtitle = _subtitleCtrl.text.trim();
                  final body = _bodyCtrl.text.trim();
                  if (title.isEmpty) return;
                  if (_bodyRequired && body.isEmpty) return;
                  Navigator.pop(
                    context,
                    _ShareDraft(
                      body: body.isEmpty ? null : body,
                      attachment: {
                        'title': title,
                        if (subtitle.isNotEmpty) 'subtitle': subtitle,
                      },
                    ),
                  );
                },
                child: const Text('Send'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
