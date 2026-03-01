import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import 'package:inkspacex/models/comment_model.dart';
import 'package:inkspacex/models/feed_item_model.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/provider/feed_provider.dart';
import 'package:inkspacex/services/firestore_service.dart';

class PostDetailPage extends StatefulWidget {
  final FeedItemModel item;
  const PostDetailPage({super.key, required this.item});

  @override
  State<PostDetailPage> createState() => _PostDetailPageState();
}

class _PostDetailPageState extends State<PostDetailPage> {
  late quill.QuillController _quillController;
  final _commentController = TextEditingController();
  final _commentFocus = FocusNode();
  final _scrollController = ScrollController();
  bool _sendingComment = false;
  bool _hasContent = false;

  final _firestoreService = FirestoreService();
  Timer? _debounce;
  String? _userId;

  @override
  void initState() {
    super.initState();
    _initQuill();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadProgress());
  }

  void _onScroll() {
    if (_userId == null || !_scrollController.hasClients) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _firestoreService.updateReadingProgress(
        _userId!,
        widget.item.id,
        _scrollController.offset,
      );
    });
  }

  Future<void> _loadProgress() async {
    final auth = context.read<AuthProvider>();
    _userId = auth.currentUser?.id;
    if (_userId == null) return;
    final progress = await _firestoreService.getReadingProgress(
      _userId!,
      widget.item.id,
    );
    if (progress != null && _scrollController.hasClients && mounted) {
      _scrollController.jumpTo(progress.scrollPosition);
    }
  }

  void _initQuill() {
    try {
      if (widget.item.content.isNotEmpty) {
        final delta = quill.Document.fromJson(jsonDecode(widget.item.content));
        _quillController = quill.QuillController(
          document: delta,
          selection: const TextSelection.collapsed(offset: 0),
        );
        _hasContent = true;
      } else {
        _quillController = quill.QuillController.basic();
      }
    } catch (_) {
      _quillController = quill.QuillController.basic();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    if (_userId != null && _scrollController.hasClients) {
      _firestoreService.updateReadingProgress(
        _userId!,
        widget.item.id,
        _scrollController.offset,
      );
    }
    _scrollController.dispose();
    _quillController.dispose();
    _commentController.dispose();
    _commentFocus.dispose();
    super.dispose();
  }

  Future<void> _submitComment() async {
    final text = _commentController.text.trim();
    if (text.isEmpty) return;
    final auth = context.read<AuthProvider>();
    final feed = context.read<FeedProvider>();
    final user = auth.currentUser;
    if (user == null) return;

    setState(() => _sendingComment = true);
    try {
      final comment = CommentModel(
        id: const Uuid().v4(),
        feedItemId: widget.item.id,
        authorId: user.id,
        authorName: user.name,
        authorPhotoUrl: user.photoUrl,
        text: text,
        createdAt: DateTime.now(),
      );
      await feed.addComment(comment);
      _commentController.clear();
      _commentFocus.unfocus();
    } catch (_) {}
    if (mounted) setState(() => _sendingComment = false);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF000000) : const Color(0xFFFAFAFA);
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtleColor = isDark ? Colors.white54 : Colors.black45;
    final cardColor = isDark ? const Color(0xFF1A1A1A) : Colors.white;
    final item = widget.item;

    return Scaffold(
      backgroundColor: bgColor,
      body: Column(
        children: [
          Expanded(
            child: CustomScrollView(
              controller: _scrollController,
              slivers: [
                // App bar
                CupertinoSliverNavigationBar(
                  backgroundColor: bgColor,
                  border: null,
                  largeTitle: Text(
                    item.title,
                    style: GoogleFonts.playfairDisplay(
                      fontWeight: FontWeight.bold,
                      color: textColor,
                    ),
                  ),
                  leading: CupertinoButton(
                    padding: EdgeInsets.zero,
                    child: Icon(
                      CupertinoIcons.back,
                      color: textColor,
                    ),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),

                // Author + Book info
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            CircleAvatar(
                              radius: 18,
                              backgroundColor:
                                  isDark ? Colors.white12 : Colors.black12,
                              child: Text(
                                item.author.isNotEmpty
                                    ? item.author[0].toUpperCase()
                                    : '?',
                                style: GoogleFonts.inter(
                                  fontWeight: FontWeight.w700,
                                  color: textColor,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.author,
                                    style: GoogleFonts.inter(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      color: textColor,
                                    ),
                                  ),
                                  if (item.bookTitle.isNotEmpty)
                                    Text(
                                      "From: ${item.bookTitle}",
                                      style: GoogleFonts.inter(
                                        fontSize: 12,
                                        color: subtleColor,
                                        fontStyle: FontStyle.italic,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        if (item.genres.isNotEmpty ||
                            item.writingTypes.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: [
                              ...item.writingTypes.map(
                                (t) => _buildChip(t, isDark, textColor),
                              ),
                              ...item.genres.map(
                                (g) => _buildChip(g, isDark, textColor),
                              ),
                            ],
                          ),
                        ],
                        if (item.description.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(
                            item.description,
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              color: subtleColor,
                              height: 1.5,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                // Like / Comment bar
                SliverToBoxAdapter(
                  child: Consumer<AuthProvider>(
                    builder: (context, auth, _) {
                      final liked =
                          auth.currentUser?.likes.contains(item.id) ?? false;
                      return Container(
                        margin: const EdgeInsets.symmetric(horizontal: 20),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: cardColor,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            GestureDetector(
                              onTap: () => auth.toggleLike(item.id),
                              child: Row(
                                children: [
                                  Icon(
                                    liked
                                        ? CupertinoIcons.heart_fill
                                        : CupertinoIcons.heart,
                                    color: liked ? Colors.red : subtleColor,
                                    size: 22,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    "${item.likesCount}",
                                    style: GoogleFonts.inter(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      color: textColor,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 24),
                            GestureDetector(
                              onTap: () => _commentFocus.requestFocus(),
                              child: Row(
                                children: [
                                  Icon(
                                    CupertinoIcons.chat_bubble,
                                    color: subtleColor,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    "${item.commentsCount}",
                                    style: GoogleFonts.inter(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      color: textColor,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),

                // Content (Quill read-only)
                if (_hasContent)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                      child: quill.QuillEditor(
                        controller: _quillController,
                        focusNode: FocusNode(canRequestFocus: false),
                        scrollController: ScrollController(),
                        config: quill.QuillEditorConfig(
                          showCursor: false,
                          autoFocus: false,
                          expands: false,
                          padding: EdgeInsets.zero,
                          customStyles: quill.DefaultStyles(
                            paragraph: quill.DefaultTextBlockStyle(
                              GoogleFonts.inter(
                                fontSize: 16,
                                color: textColor,
                                height: 1.7,
                              ),
                              quill.HorizontalSpacing.zero,
                              const quill.VerticalSpacing(8, 0),
                              quill.VerticalSpacing.zero,
                              null,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                // Divider
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 16,
                    ),
                    child: Divider(
                      color: isDark ? Colors.white10 : Colors.black12,
                    ),
                  ),
                ),

                // Comments header
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    child: Text(
                      "Comments",
                      style: GoogleFonts.inter(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: textColor,
                      ),
                    ),
                  ),
                ),

                // Comments list (streamed)
                SliverToBoxAdapter(
                  child: StreamBuilder<List<CommentModel>>(
                    stream: context
                        .read<FeedProvider>()
                        .getCommentsStream(item.id),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(child: CupertinoActivityIndicator()),
                        );
                      }
                      final comments = snapshot.data ?? [];
                      if (comments.isEmpty) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                          child: Text(
                            "No comments yet. Be the first to share your thoughts.",
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              color: subtleColor,
                            ),
                          ),
                        );
                      }
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Column(
                          children: comments.map((c) {
                            return _CommentTile(
                              comment: c,
                              isDark: isDark,
                              isOwn: c.authorId ==
                                  context
                                      .read<AuthProvider>()
                                      .currentUser
                                      ?.id,
                              onDelete: () {
                                context
                                    .read<FeedProvider>()
                                    .deleteComment(item.id, c.id);
                              },
                            );
                          }).toList(),
                        ),
                      );
                    },
                  ),
                ),

                const SliverToBoxAdapter(child: SizedBox(height: 80)),
              ],
            ),
          ),

          // Comment input bar
          Container(
            padding: EdgeInsets.fromLTRB(
              16,
              12,
              16,
              12 + MediaQuery.of(context).padding.bottom,
            ),
            decoration: BoxDecoration(
              color: cardColor,
              border: Border(
                top: BorderSide(
                  color: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.06),
                ),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: CupertinoTextField(
                    controller: _commentController,
                    focusNode: _commentFocus,
                    placeholder: "Write a comment...",
                    placeholderStyle: GoogleFonts.inter(
                      color: subtleColor,
                      fontSize: 15,
                    ),
                    style: GoogleFonts.inter(
                      color: textColor,
                      fontSize: 15,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.08)
                          : Colors.black.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    maxLines: 3,
                    minLines: 1,
                  ),
                ),
                const SizedBox(width: 8),
                CupertinoButton(
                  padding: const EdgeInsets.all(10),
                  onPressed: _sendingComment ? null : _submitComment,
                  child: _sendingComment
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: textColor,
                          ),
                        )
                      : Icon(
                          CupertinoIcons.arrow_up_circle_fill,
                          size: 32,
                          color: isDark ? Colors.white : Colors.black,
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChip(String label, bool isDark, Color textColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.black.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: textColor.withValues(alpha: 0.7),
        ),
      ),
    );
  }
}

class _CommentTile extends StatelessWidget {
  final CommentModel comment;
  final bool isDark;
  final bool isOwn;
  final VoidCallback onDelete;

  const _CommentTile({
    required this.comment,
    required this.isDark,
    required this.isOwn,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtleColor = isDark ? Colors.white38 : Colors.black38;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: isDark ? Colors.white12 : Colors.black12,
            backgroundImage: comment.authorPhotoUrl != null
                ? NetworkImage(comment.authorPhotoUrl!)
                : null,
            child: comment.authorPhotoUrl == null
                ? Text(
                    comment.authorName.isNotEmpty
                        ? comment.authorName[0].toUpperCase()
                        : '?',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                  )
                : null,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      comment.authorName,
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: textColor,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _timeAgo(comment.createdAt),
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        color: subtleColor,
                      ),
                    ),
                    const Spacer(),
                    if (isOwn)
                      GestureDetector(
                        onTap: onDelete,
                        child: Icon(
                          CupertinoIcons.trash,
                          size: 14,
                          color: subtleColor,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  comment.text,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    color: textColor.withValues(alpha: 0.85),
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.day}/${dt.month}/${dt.year}';
  }
}
