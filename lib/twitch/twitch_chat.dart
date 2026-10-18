import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../chat/chat_models.dart';
import '../core/models.dart';
import '../core/net.dart';

class IrcMessage {
  final Map<String, String> tags;
  final String? prefix;
  final String command;
  final List<String> params;

  IrcMessage(this.tags, this.prefix, this.command, this.params);

  String? get nick {
    final p = prefix;
    if (p == null) return null;
    final bang = p.indexOf('!');
    return bang > 0 ? p.substring(0, bang) : p;
  }

  String? get trailing => params.isEmpty ? null : params.last;

  static IrcMessage? parse(String line) {
    var rest = line;
    final tags = <String, String>{};
    if (rest.startsWith('@')) {
      final sp = rest.indexOf(' ');
      if (sp < 0) return null;
      for (final pair in rest.substring(1, sp).split(';')) {
        final eq = pair.indexOf('=');
        if (eq < 0) {
          tags[pair] = '';
        } else {
          tags[pair.substring(0, eq)] = _unescape(pair.substring(eq + 1));
        }
      }
      rest = rest.substring(sp + 1);
    }
    String? prefix;
    if (rest.startsWith(':')) {
      final sp = rest.indexOf(' ');
      if (sp < 0) return null;
      prefix = rest.substring(1, sp);
      rest = rest.substring(sp + 1);
    }
    final sp = rest.indexOf(' ');
    final command = sp < 0 ? rest : rest.substring(0, sp);
    rest = sp < 0 ? '' : rest.substring(sp + 1);
    final params = <String>[];
    while (rest.isNotEmpty) {
      if (rest.startsWith(':')) {
        params.add(rest.substring(1));
        break;
      }
      final next = rest.indexOf(' ');
      if (next < 0) {
        params.add(rest);
        break;
      }
      params.add(rest.substring(0, next));
      rest = rest.substring(next + 1);
    }
    return IrcMessage(tags, prefix, command, params);
  }

  static String _unescape(String v) {
    if (!v.contains('\\')) return v;
    final b = StringBuffer();
    for (var i = 0; i < v.length; i++) {
      final c = v[i];
      if (c == '\\' && i + 1 < v.length) {
        final n = v[++i];
        switch (n) {
          case 's':
            b.write(' ');
          case ':':
            b.write(';');
          case 'r':
            b.write('\r');
          case 'n':
            b.write('\n');
          default:
            b.write(n);
        }
      } else if (c != '\\') {
        b.write(c);
      }
    }
    return b.toString();
  }
}

/// Twitch chat over the IRC WebSocket. Anonymous when [token] is null.
class TwitchChatClient implements ChatClient {
  TwitchChatClient({required this.channel, this.token, this.login});

  final String channel;
  final String? token;
  final String? login;

  final _events = StreamController<ChatEvent>.broadcast();
  WebSocketChannel? _ws;
  StreamSubscription? _sub;
  Timer? _reconnectTimer;
  bool _disposed = false;
  int _backoff = 1;

  // From USERSTATE, used to show our own messages (Twitch doesn't echo them).
  String? _myDisplayName;
  Color? _myColor;
  Set<String> _myRoles = {};

  @override
  Stream<ChatEvent> get events => _events.stream;

  @override
  bool get canSend => token != null && login != null;

  void _emit(ChatEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  @override
  Future<void> connect() async {
    if (_disposed) return;
    _emit(const ChatStatusEvent(ChatConnection.connecting, 'Connecting to Twitch chat…'));
    try {
      final ws = WebSocketChannel.connect(Uri.parse('wss://irc-ws.chat.twitch.tv:443'));
      _ws = ws;
      await ws.ready;
      _sub = ws.stream.listen(
        (data) => _onData(data is String ? data : utf8.decode(data as List<int>)),
        onDone: _onClosed,
        onError: (_) => _onClosed(),
        cancelOnError: true,
      );
      ws.sink.add('CAP REQ :twitch.tv/tags twitch.tv/commands');
      if (canSend) {
        ws.sink.add('PASS oauth:$token');
        ws.sink.add('NICK $login');
      } else {
        ws.sink.add('PASS SCHMOOPIIE');
        ws.sink.add('NICK justinfan${10000 + Random().nextInt(80000)}');
      }
      ws.sink.add('JOIN #$channel');
    } catch (e) {
      _emit(ChatStatusEvent(ChatConnection.error, 'Twitch chat: $e'));
      _scheduleReconnect();
    }
  }

  /// Loads the last messages from the community recent-messages service.
  Future<void> loadHistory() async {
    try {
      final res = await httpClient.get(Uri.parse(
          'https://recent-messages.robotty.de/api/v2/recent-messages/$channel?limit=100'));
      if (res.statusCode != 200) return;
      final json = jMap(jsonDecode(utf8.decode(res.bodyBytes)));
      final out = <ChatMessage>[];
      for (final raw in jList(json?['messages'])) {
        final msg = IrcMessage.parse(raw.toString());
        if (msg == null) continue;
        final chat = _toChatMessage(msg, history: true);
        if (chat != null) out.add(chat);
      }
      if (out.isNotEmpty) _emit(ChatHistoryEvent(out));
    } catch (e) {
      debugPrint('Twitch history failed: $e');
    }
  }

  void _onData(String data) {
    for (final line in data.split('\r\n')) {
      if (line.isEmpty) continue;
      final msg = IrcMessage.parse(line);
      if (msg == null) continue;
      switch (msg.command) {
        case 'PING':
          _ws?.sink.add('PONG :${msg.trailing ?? 'tmi.twitch.tv'}');
        case 'RECONNECT':
          _ws?.sink.close();
        case 'JOIN':
          if (msg.nick == (login ?? '').toLowerCase() || !canSend) {
            _backoff = 1;
            _emit(const ChatStatusEvent(ChatConnection.connected));
          }
        case 'ROOMSTATE':
          _backoff = 1;
          _emit(const ChatStatusEvent(ChatConnection.connected));
          final roomId = msg.tags['room-id'];
          if (roomId != null && roomId.isNotEmpty) _emit(ChatRoomIdEvent(roomId));
        case 'USERSTATE':
          _myDisplayName = msg.tags['display-name'];
          _myColor = parseHexColor(msg.tags['color']);
          _myRoles = _roles(msg.tags['badges']);
        case 'PRIVMSG':
        case 'USERNOTICE':
          final chat = _toChatMessage(msg);
          if (chat != null) _emit(ChatMessageEvent(chat));
        case 'CLEARCHAT':
          final target = msg.params.length > 1 ? msg.params[1] : null;
          _emit(ChatClearEvent(target));
        case 'CLEARMSG':
          final id = msg.tags['target-msg-id'];
          if (id != null) _emit(ChatDeleteEvent(id));
        case 'NOTICE':
          final text = msg.trailing;
          if (text != null) {
            if (text.contains('Login authentication failed') ||
                text.contains('Improperly formatted auth')) {
              _emit(const ChatStatusEvent(ChatConnection.error,
                  'Twitch rejected the login. Log out and back in from Settings.'));
            }
            _emit(ChatMessageEvent(_system(text)));
          }
      }
    }
  }

  ChatMessage _system(String text) => ChatMessage(
        id: 'sys-${DateTime.now().microsecondsSinceEpoch}',
        author: '',
        authorLogin: '',
        fragments: const [],
        timestamp: DateTime.now(),
        systemText: text,
      );

  static Set<String> _roles(String? badges) {
    if (badges == null || badges.isEmpty) return {};
    return badges.split(',').map((b) => b.split('/').first).toSet();
  }

  ChatMessage? _toChatMessage(IrcMessage msg, {bool history = false}) {
    if (msg.command != 'PRIVMSG' && msg.command != 'USERNOTICE') return null;
    final tags = msg.tags;
    final ts = int.tryParse(tags['tmi-sent-ts'] ?? '');
    final timestamp = ts == null ? DateTime.now() : DateTime.fromMillisecondsSinceEpoch(ts);
    var text = msg.command == 'PRIVMSG' ? (msg.trailing ?? '') : (msg.params.length > 1 ? msg.trailing ?? '' : '');
    var isAction = false;
    if (text.startsWith('\u0001ACTION ') && text.endsWith('\u0001')) {
      text = text.substring(8, text.length - 1);
      isAction = true;
    }
    final login = tags['login'] ?? msg.nick ?? '';
    return ChatMessage(
      id: tags['id'] ?? 'tw-${timestamp.microsecondsSinceEpoch}-${login.hashCode}',
      author: (tags['display-name']?.isNotEmpty ?? false) ? tags['display-name']! : login,
      authorLogin: login,
      authorColor: parseHexColor(tags['color']),
      roles: _roles(tags['badges']),
      fragments: text.isEmpty ? const [] : _fragments(text, tags['emotes']),
      timestamp: timestamp,
      isAction: isAction,
      systemText: msg.command == 'USERNOTICE' ? tags['system-msg'] : null,
      isHistory: history,
    );
  }

  /// Splits text using Twitch's emote tag, e.g. `25:0-4,12-16/1902:6-10`.
  /// Positions count Unicode code points, not UTF-16 units.
  static List<Fragment> _fragments(String text, String? emotesTag) {
    if (emotesTag == null || emotesTag.isEmpty) return [TextFragment(text)];
    final ranges = <(int, int, String)>[];
    for (final part in emotesTag.split('/')) {
      final colon = part.indexOf(':');
      if (colon < 0) continue;
      final id = part.substring(0, colon);
      for (final r in part.substring(colon + 1).split(',')) {
        final dash = r.indexOf('-');
        if (dash < 0) continue;
        final start = int.tryParse(r.substring(0, dash));
        final end = int.tryParse(r.substring(dash + 1));
        if (start != null && end != null) ranges.add((start, end, id));
      }
    }
    ranges.sort((a, b) => a.$1.compareTo(b.$1));
    final runes = text.runes.toList();
    final out = <Fragment>[];
    var cursor = 0;
    for (final (start, end, id) in ranges) {
      if (start < cursor || end >= runes.length) continue;
      if (start > cursor) {
        out.add(TextFragment(String.fromCharCodes(runes.sublist(cursor, start))));
      }
      final name = String.fromCharCodes(runes.sublist(start, end + 1));
      out.add(EmoteFragment(Emote(
        name: name,
        url: 'https://static-cdn.jtvnw.net/emoticons/v2/$id/default/dark/2.0',
        source: EmoteSource.twitch,
      )));
      cursor = end + 1;
    }
    if (cursor < runes.length) {
      out.add(TextFragment(String.fromCharCodes(runes.sublist(cursor))));
    }
    return out;
  }

  @override
  Future<void> send(String text) async {
    final ws = _ws;
    if (!canSend || ws == null) {
      throw ApiException('Log in to Twitch in Settings to chat.');
    }
    final clean = text.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    if (clean.isEmpty) return;
    ws.sink.add('PRIVMSG #$channel :$clean');
    var body = clean;
    var isAction = false;
    if (body.startsWith('/me ')) {
      body = body.substring(4);
      isAction = true;
    } else if (body.startsWith('/')) {
      return; // A command; Twitch replies with a NOTICE if relevant.
    }
    _emit(ChatMessageEvent(ChatMessage(
      id: 'self-${DateTime.now().microsecondsSinceEpoch}',
      author: _myDisplayName ?? login!,
      authorLogin: login!,
      authorColor: _myColor,
      roles: _myRoles,
      fragments: [TextFragment(body)],
      timestamp: DateTime.now(),
      isAction: isAction,
    )));
  }

  void _onClosed() {
    _sub?.cancel();
    _sub = null;
    _ws = null;
    if (_disposed) return;
    _emit(const ChatStatusEvent(ChatConnection.disconnected, 'Reconnecting…'));
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: _backoff), connect);
    _backoff = min(_backoff * 2, 30);
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _sub?.cancel();
    _ws?.sink.close();
    _events.close();
  }
}
