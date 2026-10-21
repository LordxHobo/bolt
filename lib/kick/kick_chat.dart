import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../chat/chat_models.dart';
import '../core/models.dart';
import '../core/net.dart';
import 'kick_api.dart';
import 'kick_auth.dart';
import 'kick_follows.dart';
import 'kick_web.dart';

/// Kick chat. Since October 2026 Kick serves chat from its own Centrifugo
/// server instead of Pusher:
///   1. POST web.kick.com/api/v1/realtime/connection  -> server URL
///   2. POST web.kick.com/api/v1/realtime/auth/connection -> JWT (~45 min)
///   3. `{connect:{token}}` then `{subscribe:{channel:'chatrooms.<id>.v2'}}`
/// Publications carry the same {event, data} envelope Pusher used to.
class KickChatClient implements ChatClient {
  KickChatClient({
    required this.chatroomId,
    required this.channelId,
    required this.broadcasterUserId,
    required this.auth,
  });

  final int chatroomId;
  final int? channelId;
  final int? broadcasterUserId;
  final KickAuth auth;

  static const _webApi = 'https://web.kick.com/api/v1/realtime';
  static const _fallbackServer =
      'wss://realtime.us-west-2.platform.kick.com/connection/websocket';

  final _events = StreamController<ChatEvent>.broadcast();
  final String _clientId = _uuid();
  WebSocketChannel? _ws;
  StreamSubscription? _sub;
  Timer? _refreshTimer;
  Timer? _reconnectTimer;
  bool _disposed = false;
  int _backoff = 2;
  int _seq = 0;
  int _connectId = -1;
  int _subscribeId = -1;
  bool _subscribed = false;

  @override
  Stream<ChatEvent> get events => _events.stream;

  @override
  // The kick.com login sends like the website; the older developer-app
  // login uses Kick's official API.
  bool get canSend => KickFollows.isSignedIn || (auth.isLoggedIn && broadcasterUserId != null);

  void _emit(ChatEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  static String _uuid() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20)}';
  }

  Future<void> loadHistory() async {
    final id = channelId;
    if (id == null) return;
    try {
      final messages = await KickApi.getRecentMessages(id);
      if (messages.isNotEmpty) _emit(ChatHistoryEvent(messages));
    } catch (e) {
      debugPrint('Kick history failed: $e');
    }
  }

  Future<String> _serverUrl() async {
    try {
      final res = await KickWeb.instance.post('$_webApi/connection', {
        'client': {'id': _clientId, 'type': 'web'},
        'capabilities': {
          'accepted_providers': [
            {'provider': 'centrifugo'},
          ],
        },
      });
      final connections = jList(jMap(jMap(res.json)?['data'])?['connections']);
      for (final c in connections) {
        final m = jMap(c);
        if (jStr(m?['provider']) != 'centrifugo') continue;
        final url = jStr(jMap(m?['credentials'])?['url']);
        if (url != null && (url.startsWith('wss://') || url.startsWith('ws://'))) {
          return url;
        }
      }
    } catch (e) {
      debugPrint('Kick realtime descriptor failed: $e');
    }
    return _fallbackServer;
  }

  Future<String> _token() async {
    final res = await KickWeb.instance.post('$_webApi/auth/connection', {'client_id': _clientId});
    final token = jStr(jMap(jMap(res.json)?['data'])?['token']);
    if (token == null) {
      throw ApiException('Kick did not hand out a chat token (HTTP ${res.status})');
    }
    return token;
  }

  @override
  Future<void> connect() async {
    if (_disposed) return;
    _emit(const ChatStatusEvent(ChatConnection.connecting, 'Connecting to Kick chat…'));
    try {
      final url = await _serverUrl();
      final token = await _token();
      if (_disposed) return;
      final ws = IOWebSocketChannel.connect(
        Uri.parse(url),
        headers: {'Origin': 'https://kick.com', 'User-Agent': browserUserAgent},
      );
      _ws = ws;
      await ws.ready;
      _subscribed = false;
      _sub = ws.stream.listen(
        (data) => _onData(data is String ? data : utf8.decode(data as List<int>)),
        onDone: _onClosed,
        onError: (_) => _onClosed(),
        cancelOnError: true,
      );
      _connectId = ++_seq;
      ws.sink.add(jsonEncode({
        'connect': {'token': token, 'name': 'js'},
        'id': _connectId,
      }));
    } catch (e) {
      _emit(ChatStatusEvent(ChatConnection.error, 'Kick chat: $e'));
      _scheduleReconnect();
    }
  }

  void _onData(String data) {
    for (final line in data.split('\n')) {
      final text = line.trim();
      if (text.isEmpty) continue;
      if (text == '{}') {
        _ws?.sink.add('{}'); // Centrifugo ping -> pong
        continue;
      }
      Map<String, dynamic>? m;
      try {
        m = jMap(jsonDecode(text));
      } catch (_) {
        continue;
      }
      if (m != null) _handle(m);
    }
  }

  void _handle(Map<String, dynamic> m) {
    final id = jInt(m['id']);
    if (id == _connectId && m['connect'] != null) {
      final connect = jMap(m['connect']);
      if (connect?['expires'] != false) _scheduleRefresh(jInt(connect?['ttl']));
      _subscribeId = ++_seq;
      _ws?.sink.add(jsonEncode({
        'subscribe': {'channel': 'chatrooms.$chatroomId.v2'},
        'id': _subscribeId,
      }));
      return;
    }
    if (id == _subscribeId && m['subscribe'] != null) {
      _subscribed = true;
      _backoff = 2;
      _emit(const ChatStatusEvent(ChatConnection.connected));
      return;
    }
    if (m['refresh'] != null) {
      final refresh = jMap(m['refresh']);
      if (refresh?['expires'] != false) _scheduleRefresh(jInt(refresh?['ttl']));
      return;
    }
    if (m['error'] != null) {
      final err = jMap(m['error']);
      debugPrint('Kick realtime error: $err');
      if (!_subscribed) _ws?.sink.close();
      return;
    }
    if (m['disconnect'] != null) {
      _ws?.sink.close();
      return;
    }
    final pub = jMap(jMap(m['push'])?['pub']);
    if (pub == null) return;
    var envelope = pub['data'];
    if (envelope is String) {
      try {
        envelope = jsonDecode(envelope);
      } catch (_) {
        return;
      }
    }
    final env = jMap(envelope);
    if (env == null) return;
    _handleEvent(jStr(env['event']) ?? '', env['data']);
  }

  void _handleEvent(String event, Object? rawData) {
    Map<String, dynamic>? data;
    if (rawData is String) {
      try {
        data = jMap(jsonDecode(rawData));
      } catch (_) {
        return;
      }
    } else {
      data = jMap(rawData);
    }
    if (data == null) return;
    final name = event.split('\\').last;
    switch (name) {
      case 'ChatMessageEvent':
        final msg = KickApi.parseChatMessage(data);
        if (msg != null) _emit(ChatMessageEvent(msg));
      case 'MessageDeletedEvent':
        final id = jStr(jMap(data['message'])?['id']) ?? jStr(data['id']);
        if (id != null) _emit(ChatDeleteEvent(id));
      case 'UserBannedEvent':
        final user = jMap(data['user']);
        final login = jStr(user?['slug']) ?? jStr(user?['username']);
        if (login != null) _emit(ChatClearEvent(login.toLowerCase()));
      case 'ChatroomClearEvent':
        _emit(const ChatClearEvent());
    }
  }

  void _scheduleRefresh(int? ttl) {
    _refreshTimer?.cancel();
    final seconds = max(5, min(ttl ?? 2700, 86400) - 60);
    _refreshTimer = Timer(Duration(seconds: seconds), () async {
      final ws = _ws;
      if (ws == null || _disposed) return;
      try {
        final token = await _token();
        if (_ws != ws) return;
        ws.sink.add(jsonEncode({
          'refresh': {'token': token},
          'id': ++_seq,
        }));
      } catch (_) {
        ws.sink.close(); // Reconnect from scratch.
      }
    });
  }

  @override
  Future<void> send(String text) async {
    final clean = text.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    if (clean.isEmpty) return;
    if (KickFollows.isSignedIn) {
      await KickFollows.sendChat(chatroomId: chatroomId, content: clean);
      return;
    }
    final id = broadcasterUserId;
    if (!auth.isLoggedIn || id == null) {
      throw ApiException('Sign in to Kick in Settings to chat.');
    }
    // Kick echoes our message back through the realtime connection.
    await auth.sendChat(broadcasterUserId: id, content: clean);
  }

  void _onClosed() {
    _sub?.cancel();
    _sub = null;
    _ws = null;
    _refreshTimer?.cancel();
    if (_disposed) return;
    _emit(const ChatStatusEvent(ChatConnection.disconnected, 'Reconnecting…'));
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: _backoff), connect);
    _backoff = min(_backoff * 2, 60);
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _refreshTimer?.cancel();
    _sub?.cancel();
    _ws?.sink.close();
    _events.close();
  }
}
