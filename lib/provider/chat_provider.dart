import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:inkspacex/models/chat_message_model.dart';
import 'package:inkspacex/models/conversation_model.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/services/api/api_data_service.dart';
import 'package:inkspacex/services/api/api_realtime_service.dart';
import 'package:inkspacex/services/app_log.dart';

/// State for the one-on-one chat screens.
///
/// Hot list: per-conversation messages cached in [_messagesByConvo] so
/// reopening a thread paints instantly. SSE push (`chat.message` on the
/// user channel) appends in real time; REST is the source of truth on
/// cold start.
class ChatProvider extends ChangeNotifier {
  ChatProvider({
    required ApiDataService api,
    required ApiRealtimeService realtime,
  })  : _api = api,
        _realtime = realtime;

  final ApiDataService _api;
  final ApiRealtimeService _realtime;

  StreamSubscription<Map<String, dynamic>>? _sseSub;
  bool _initialized = false;
  bool _conversationsLoading = false;
  String? _conversationsError;
  List<ConversationModel> _conversations = const [];

  final Map<String, List<ChatMessageModel>> _messagesByConvo = {};
  final Set<String> _loadingConvos = {};
  int _totalUnread = 0;

  bool get isLoadingConversations => _conversationsLoading;
  String? get conversationsError => _conversationsError;
  List<ConversationModel> get conversations => _conversations;
  int get totalUnread => _totalUnread;

  bool isLoadingMessages(String conversationId) =>
      _loadingConvos.contains(conversationId);

  List<ChatMessageModel> messagesFor(String conversationId) =>
      _messagesByConvo[conversationId] ?? const [];

  /// Idempotent — first call loads conversations and opens the SSE
  /// subscription. Safe to call from any auth-state change.
  Future<void> ensureStarted() async {
    if (_initialized) return;
    _initialized = true;
    await refreshConversations();
    _sseSub = _realtime.notificationsChannel().listen(
      _onSseEvent,
      onError: (e, st) {
        log.w('[chat] sse error: $e');
      },
    );
  }

  Future<void> refreshConversations() async {
    _conversationsLoading = true;
    notifyListeners();
    try {
      final results = await Future.wait([
        _api.listConversations(),
        _api.chatUnreadCount(),
      ]);
      _conversations = results[0] as List<ConversationModel>;
      _totalUnread = results[1] as int;
      _conversationsError = null;
    } catch (e, st) {
      log.e('[chat] refreshConversations failed', error: e, stackTrace: st);
      _conversationsError = e.toString();
    } finally {
      _conversationsLoading = false;
      notifyListeners();
    }
  }

  Future<ConversationModel> openConversationWith(String otherUserId) async {
    final fresh = await _api.startConversation(otherUserId);
    // /start hardcodes unread_count=0 — it's a get-or-create, not a
    // counter. If we already have the convo locally, keep our count so
    // markRead can decrement totalUnread and hit the backend.
    final existingIdx = _conversations.indexWhere((c) => c.id == fresh.id);
    final merged = existingIdx == -1
        ? fresh
        : fresh.copyWith(unreadCount: _conversations[existingIdx].unreadCount);
    final without = _conversations.where((c) => c.id != merged.id).toList();
    _conversations = [merged, ...without];
    notifyListeners();
    return merged;
  }

  Future<void> loadMessages(String conversationId, {bool force = false}) async {
    if (!force && _messagesByConvo.containsKey(conversationId)) return;
    _loadingConvos.add(conversationId);
    notifyListeners();
    try {
      final list = await _api.listMessages(conversationId);
      _messagesByConvo[conversationId] = list;
    } catch (e) {
      log.w('[chat] loadMessages failed: $e');
    } finally {
      _loadingConvos.remove(conversationId);
      notifyListeners();
    }
  }

  Future<void> sendText(
    String conversationId,
    String currentUserId,
    String text,
  ) async {
    final body = text.trim();
    if (body.isEmpty) return;
    await _send(
      conversationId,
      currentUserId,
      kind: ChatMessageKind.text,
      body: body,
    );
  }

  Future<void> sendAttachment(
    String conversationId,
    String currentUserId, {
    required ChatMessageKind kind,
    String? body,
    Map<String, dynamic>? attachment,
  }) async {
    await _send(
      conversationId,
      currentUserId,
      kind: kind,
      body: body,
      attachment: attachment,
    );
  }

  Future<void> _send(
    String conversationId,
    String currentUserId, {
    required ChatMessageKind kind,
    String? body,
    Map<String, dynamic>? attachment,
  }) async {
    // Optimistic insert — replaced when the server echoes the row back.
    final tempId = 'tmp-${DateTime.now().microsecondsSinceEpoch}';
    final optimistic = ChatMessageModel(
      id: tempId,
      conversationId: conversationId,
      senderId: currentUserId,
      kind: kind,
      body: body,
      attachment: attachment,
      createdAt: DateTime.now(),
      pending: true,
    );
    _appendMessage(conversationId, optimistic);
    try {
      final saved = await _api.sendMessage(
        conversationId,
        kind: kind,
        body: body,
        attachment: attachment,
      );
      _replacePending(conversationId, tempId, saved);
    } catch (e) {
      log.w('[chat] send failed: $e');
      // Mark the optimistic row as failed by leaving it pending — UI
      // surfaces the spinner so the user knows it didn't go through.
      // (Future: surface a retry affordance.)
    }
  }

  Future<void> markRead(String conversationId) async {
    final convo = _conversations.firstWhere(
      (c) => c.id == conversationId,
      orElse: () => ConversationModel(
        id: conversationId,
        otherUser: ConversationParticipant(id: ''),
        unreadCount: 0,
        createdAt: DateTime.now(),
      ),
    );
    if (convo.unreadCount > 0) {
      _totalUnread = (_totalUnread - convo.unreadCount).clamp(0, 1 << 30);
      _conversations = _conversations
          .map((c) => c.id == conversationId ? c.copyWith(unreadCount: 0) : c)
          .toList();
      notifyListeners();
    }
    // Always hit the backend — the local count can be stale (e.g. a
    // stray refresh hardcoded it to 0), and the backend mark-read is
    // a cheap idempotent UPDATE.
    try {
      await _api.markConversationRead(conversationId);
    } catch (e) {
      log.w('[chat] markRead failed: $e');
    }
  }

  void _onSseEvent(Map<String, dynamic> event) {
    if (event['type'] != 'chat.message') return;
    final raw = event['message'];
    if (raw is! Map) return;
    try {
      final msg = ChatMessageModel.fromJson(Map<String, dynamic>.from(raw));
      // Dedup against an optimistic copy (same sender, same body,
      // pending). Prefer matching the most recent pending message.
      final list = _messagesByConvo[msg.conversationId];
      if (list != null) {
        final pendingIdx = list.lastIndexWhere(
          (m) => m.pending && m.senderId == msg.senderId && m.body == msg.body,
        );
        if (pendingIdx >= 0) {
          _replacePending(msg.conversationId, list[pendingIdx].id, msg);
        } else if (!list.any((m) => m.id == msg.id)) {
          _appendMessage(msg.conversationId, msg);
        }
      }
      _bumpConversationOnNewMessage(msg);
      notifyListeners();
    } catch (e) {
      log.w('[chat] failed to parse sse message: $e');
    }
  }

  void _appendMessage(String conversationId, ChatMessageModel msg) {
    final existing = _messagesByConvo[conversationId] ?? const [];
    _messagesByConvo[conversationId] = [...existing, msg];
    notifyListeners();
  }

  void _replacePending(
    String conversationId,
    String pendingId,
    ChatMessageModel saved,
  ) {
    final list = _messagesByConvo[conversationId];
    if (list == null) return;
    _messagesByConvo[conversationId] = list
        .map((m) => m.id == pendingId ? saved : m)
        .toList();
    notifyListeners();
  }

  void _bumpConversationOnNewMessage(ChatMessageModel msg) {
    final idx = _conversations.indexWhere((c) => c.id == msg.conversationId);
    if (idx == -1) {
      // New conversation — defer to the next refresh, since we don't
      // have the participant info yet.
      unawaited(refreshConversations());
      return;
    }
    final convo = _conversations[idx];
    final preview = _previewFor(msg);
    final newUnread = msg.senderId == convo.otherUser.id
        ? convo.unreadCount + 1
        : convo.unreadCount;
    final updated = convo.copyWith(
      lastMessageAt: msg.createdAt,
      lastMessagePreview: preview,
      unreadCount: newUnread,
    );
    final list = [..._conversations]..removeAt(idx);
    _conversations = [updated, ...list];
    if (msg.senderId == convo.otherUser.id) {
      _totalUnread += 1;
    }
  }

  String _previewFor(ChatMessageModel msg) {
    switch (msg.kind) {
      case ChatMessageKind.text:
        return (msg.body ?? '').isEmpty ? '' : msg.body!;
      case ChatMessageKind.image:
        return '📷 Photo';
      case ChatMessageKind.book:
        return '📖 ${msg.attachmentTitle ?? 'Shared a book'}';
      case ChatMessageKind.excerpt:
        return '❝ ${msg.attachmentTitle ?? 'Shared lines'}';
      case ChatMessageKind.section:
        return '📄 ${msg.attachmentTitle ?? 'Shared a section'}';
    }
  }

  Future<void> reset() async {
    await _sseSub?.cancel();
    _sseSub = null;
    _initialized = false;
    _conversations = const [];
    _messagesByConvo.clear();
    _loadingConvos.clear();
    _totalUnread = 0;
    _conversationsError = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _sseSub?.cancel();
    super.dispose();
  }
}

ChatProvider buildChatProvider(AuthProvider auth) {
  return ChatProvider(
    api: auth.dataService,
    realtime: auth.realtimeService,
  );
}
