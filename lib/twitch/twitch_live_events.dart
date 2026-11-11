import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../chat/chat_models.dart';
import '../core/models.dart';
import '../core/services.dart';

/// Raids, polls and predictions for a Twitch channel, from Twitch's own
/// live-update service ("Hermes", which replaced PubSub; it carries the same
/// topics the website listens to: `raid.<id>`, `polls.<id>`,
/// `predictions-channel-v1.<id>`).
class TwitchLiveEvents {
  TwitchLiveEvents(this.channelId);

  final String channelId;

  static const _url = 'wss://hermes.twitch.tv/v1?clientId=kimne78kx3ncx6brgo4mv6wki5h1ko';

  final _events = StreamController<ChatEvent>.broadcast();
  Stream<ChatEvent> get events => _events.stream;

  WebSocketChannel? _ws;
  StreamSubscription? _sub;
  Timer? _reconnect;
  bool _closed = false;
  int _backoff = 2;
  final Map<String, String> _topicBySubscription = {};

  static final _rnd = Random();
  static String _id() {
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-';
    return List.generate(21, (_) => chars[_rnd.nextInt(chars.length)]).join();
  }

  static String _now() => DateTime.now().toUtc().toIso8601String();

  Future<void> connect([String? url]) async {
    if (_closed) return;
    try {
      final ws = WebSocketChannel.connect(Uri.parse(url ?? _url));
      _ws = ws;
      await _sub?.cancel();
      _sub = ws.stream.listen(_onText, onDone: _onDone, onError: (_) => _onDone());
      await ws.ready;
      // Subscriptions go out once Hermes says hello ("welcome").
      _backoff = 2;
    } catch (e) {
      debugPrint('Twitch live events failed: $e');
      _onDone();
    }
  }

  Future<void> _subscribeAll() async {
    final ws = _ws;
    if (ws == null) return;
    // Signed in: some topics (polls) may want it; the rest don't mind.
    final token = await Services.twitch.validAccessToken();
    if (token != null) {
      ws.sink.add(jsonEncode({
        'type': 'authenticate',
        'id': _id(),
        'authenticate': {'token': token},
        'timestamp': _now(),
      }));
    }
    for (final topic in ['raid.$channelId', 'polls.$channelId', 'predictions-channel-v1.$channelId']) {
      final subId = _id();
      _topicBySubscription[subId] = topic.split('.').first;
      ws.sink.add(jsonEncode({
        'type': 'subscribe',
        'id': _id(),
        'subscribe': {
          'id': subId,
          'type': 'pubsub',
          'pubsub': {'topic': topic},
        },
        'timestamp': _now(),
      }));
    }
  }

  void _onDone() {
    if (_closed) return;
    _reconnect?.cancel();
    _reconnect = Timer(Duration(seconds: _backoff), connect);
    _backoff = min(_backoff * 2, 60);
  }

  void _onText(dynamic raw) {
    Map<String, dynamic>? m;
    try {
      m = jMap(jsonDecode(raw as String));
    } catch (_) {
      return;
    }
    if (m == null) return;
    switch (jStr(m['type'])) {
      case 'welcome':
        _subscribeAll();
      case 'reconnect':
        final url = jStr(jMap(m['reconnect'])?['url']);
        _sub?.cancel();
        _ws?.sink.close();
        connect(url);
      case 'notification':
        final n = jMap(m['notification']);
        final topic = _topicBySubscription[jStr(jMap(n?['subscription'])?['id']) ?? ''];
        final body = n?['pubsub'];
        Map<String, dynamic>? msg;
        try {
          msg = jMap(body is String ? jsonDecode(body) : body);
        } catch (_) {}
        if (msg != null) _handle(topic, msg);
    }
  }

  void _handle(String? topic, Map<String, dynamic> msg) {
    final type = jStr(msg['type']) ?? '';
    final data = jMap(msg['data']);
    if (type.startsWith('raid_') || topic == 'raid') {
      final raid = jMap(msg['raid']) ?? jMap(data?['raid']);
      if (type == 'raid_cancel_v2') {
        _events.add(const ChatRaidEvent(null));
      } else if (raid != null && jStr(raid['target_login']) != null) {
        _events.add(ChatRaidEvent(ChatRaid(
          targetLogin: jStr(raid['target_login'])!,
          targetName: jStr(raid['target_display_name']) ?? jStr(raid['target_login'])!,
          viewers: jInt(raid['viewer_count']),
          started: type == 'raid_go_v2',
        )));
      }
      return;
    }
    if (type.startsWith('POLL_') || topic == 'polls') {
      final p = jMap(data?['poll']);
      if (p == null) return;
      if (type == 'POLL_ARCHIVE') {
        _events.add(const ChatPollEvent(null));
        return;
      }
      final remaining = jInt(p['remaining_duration_milliseconds']);
      final status = jStr(p['status']) ?? '';
      _events.add(ChatPollEvent(ChatPoll(
        id: jStr(p['poll_id']) ?? '',
        title: jStr(p['title']) ?? 'Poll',
        options: [
          for (final c in jList(p['choices']))
            if (jMap(c) case final ch?)
              (jStr(ch['title']) ?? '', jInt(jMap(ch['votes'])?['total']) ?? jInt(ch['votes']) ?? 0),
        ],
        endsAt: remaining == null ? null : DateTime.now().add(Duration(milliseconds: remaining)),
        ended: status != 'ACTIVE' || type == 'POLL_COMPLETE' || type == 'POLL_TERMINATE',
      )));
      return;
    }
    if (type.startsWith('event-') || topic == 'predictions-channel-v1') {
      final e = jMap(data?['event']);
      if (e == null) return;
      final created = jTime(e['created_at']);
      final window = jNum(e['prediction_window_seconds']);
      _events.add(ChatPredictionEvent(ChatPrediction(
        id: jStr(e['id']) ?? '',
        title: jStr(e['title']) ?? 'Prediction',
        status: jStr(e['status']) ?? 'ACTIVE',
        outcomes: [
          for (final o in jList(e['outcomes']))
            if (jMap(o) case final oc?)
              (
                id: jStr(oc['id']) ?? '',
                title: jStr(oc['title']) ?? '',
                points: jInt(oc['total_points']) ?? 0,
                users: jInt(oc['total_users']) ?? 0,
              ),
        ],
        locksAt: created == null || window == null ? null : created.add(Duration(seconds: window.round())),
        winnerId: jStr(e['winning_outcome_id']),
      )));
    }
  }

  void close() {
    _closed = true;
    _reconnect?.cancel();
    _sub?.cancel();
    _ws?.sink.close();
    _events.close();
  }
}
