import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../core/services.dart';
import '../kick/kick_chat.dart';
import '../twitch/twitch_chat.dart';
import 'chat_models.dart';
import 'seventv.dart';

/// Owns one channel's chat connection, emotes and message list.
class ChatController extends ChangeNotifier {
  ChatController(this.channel);

  final ChannelInfo channel;

  static const maxMessages = 400;

  /// Newest first (the chat list is drawn bottom-up).
  final List<ChatMessage> messages = [];

  /// Messages that arrived while the user was scrolled up.
  final List<ChatMessage> _pending = [];
  bool _paused = false;

  ChatConnection status = ChatConnection.connecting;
  String? statusText;

  Map<String, Emote> _emotes = {};
  ChatClient? _client;
  StreamSubscription<ChatEvent>? _sub;
  bool _disposed = false;

  int get pendingCount => _pending.length;
  bool get canSend => _client?.canSend ?? false;
  bool get isPaused => _paused;

  /// All third-party emote names, for autocomplete.
  Iterable<String> get emoteNames => _emotes.keys;

  Future<void> start() async {
    unawaited(_loadEmotes());
    await _connect();
  }

  String? _emoteUserId;

  Future<void> _loadEmotes([String? userId]) async {
    final id = userId ?? channel.userId;
    _emoteUserId = id;
    final results = await Future.wait([
      SevenTv.global(),
      SevenTv.forChannel(channel.platform, id),
    ]);
    // A newer load (with the real channel id) superseded this one.
    if (_disposed || _emoteUserId != id) return;
    // Channel emotes win over global ones with the same name.
    _emotes = {...results[0], ...results[1]};
    // Re-render messages that arrived before the emotes did.
    for (var i = 0; i < messages.length; i++) {
      messages[i] = messages[i].copyWith(fragments: applyEmotes(messages[i].fragments, _emotes));
    }
    notifyListeners();
  }

  Future<void> _connect() async {
    final ChatClient client;
    switch (channel.platform) {
      case StreamPlatform.twitch:
        final token = await Services.twitch.validAccessToken();
        final twitch = TwitchChatClient(
          channel: channel.login,
          token: token,
          login: token == null ? null : Services.twitch.login,
        );
        client = twitch;
        _attach(client);
        unawaited(twitch.loadHistory());
      case StreamPlatform.kick:
        final chatroomId = channel.kickChatroomId;
        if (chatroomId == null) {
          status = ChatConnection.error;
          statusText = 'This Kick channel has no chatroom.';
          notifyListeners();
          return;
        }
        final kick = KickChatClient(
          chatroomId: chatroomId,
          channelId: channel.kickChannelId,
          broadcasterUserId: int.tryParse(channel.userId ?? ''),
          auth: Services.kick,
        );
        client = kick;
        _attach(client);
        unawaited(kick.loadHistory());
    }
    if (_disposed) {
      client.dispose();
      return;
    }
    await client.connect();
  }

  void _attach(ChatClient client) {
    _client = client;
    _sub = client.events.listen(_onEvent);
  }

  void _onEvent(ChatEvent e) {
    if (_disposed) return;
    switch (e) {
      case ChatStatusEvent ev:
        status = ev.status;
        statusText = ev.text;
      case ChatRoomIdEvent ev:
        // The channel lookup may have failed; chat still tells us the id.
        if (_emoteUserId == null) unawaited(_loadEmotes(ev.roomId));
      case ChatMessageEvent ev:
        _add(ev.message);
      case ChatHistoryEvent ev:
        // History is oldest first; insert it below anything already shown.
        final existing = messages.map((m) => m.id).toSet();
        for (final m in ev.messages) {
          if (existing.contains(m.id)) continue;
          messages.add(m.copyWith(fragments: applyEmotes(m.fragments, _emotes)));
        }
        messages.sort((a, b) => b.timestamp.compareTo(a.timestamp));
        _trim();
      case ChatDeleteEvent ev:
        for (final m in [...messages, ..._pending]) {
          if (m.id == ev.messageId) m.deleted = true;
        }
      case ChatClearEvent ev:
        final login = ev.userLogin;
        if (login == null) {
          messages.clear();
          _pending.clear();
          _add(ChatMessage(
            id: 'clear-${DateTime.now().microsecondsSinceEpoch}',
            author: '',
            authorLogin: '',
            fragments: const [],
            timestamp: DateTime.now(),
            systemText: 'Chat was cleared by a moderator',
          ));
          return;
        }
        for (final m in [...messages, ..._pending]) {
          if (m.authorLogin == login) m.deleted = true;
        }
    }
    notifyListeners();
  }

  void _add(ChatMessage m) {
    final processed = m.copyWith(fragments: applyEmotes(m.fragments, _emotes));
    if (_paused) {
      _pending.add(processed);
      if (_pending.length > maxMessages) _pending.removeAt(0);
    } else {
      messages.insert(0, processed);
      _trim();
    }
    notifyListeners();
  }

  void _trim() {
    if (messages.length > maxMessages) {
      messages.removeRange(maxMessages, messages.length);
    }
  }

  /// Called by the chat list when the user scrolls away from / back to the
  /// newest message.
  void setPaused(bool paused) {
    if (paused == _paused) return;
    _paused = paused;
    if (!paused && _pending.isNotEmpty) {
      messages.insertAll(0, _pending.reversed);
      _pending.clear();
      _trim();
      notifyListeners();
    } else if (paused) {
      notifyListeners();
    }
  }

  Future<void> send(String text) async {
    final client = _client;
    if (client == null) return;
    await client.send(text);
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _client?.dispose();
    super.dispose();
  }
}
