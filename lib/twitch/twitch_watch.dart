import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../core/net.dart';
import '../core/services.dart';
import 'twitch_api.dart';

/// Tells Twitch you're watching, like its own player does: a "minute
/// watched" report every minute while the stream plays. That's what counts
/// you towards channel points, watch streaks and Drops. Only when signed in.
class TwitchWatchReporter {
  TwitchWatchReporter({required this.login, required this.isPlaying});

  final String login;

  /// Whether the video is actually playing right now.
  final bool Function() isPlaying;

  /// What happened last (shown in the stream details).
  static final status = ValueNotifier<String?>(null);

  static String? _spadeUrl;
  static Future<String?>? _spadeLoad;

  Timer? _timer;
  bool _closed = false;
  int _sent = 0;

  void start() {
    _timer = Timer.periodic(const Duration(seconds: 60), (_) => _report());
    // First one after a short while (once it's playing).
    Timer(const Duration(seconds: 15), _report);
  }

  void stop() {
    _closed = true;
    _timer?.cancel();
  }

  /// Twitch's report address, read from its website (it changes rarely).
  static Future<String?> _spade() {
    if (_spadeUrl != null) return Future.value(_spadeUrl);
    return _spadeLoad ??= () async {
      try {
        final headers = {'User-Agent': browserUserAgent};
        final page = await httpClient.get(Uri.parse('https://www.twitch.tv/'), headers: headers);
        final settings = RegExp(r'(https://(?:static\.twitchcdn\.net|assets\.twitch\.tv)/config/settings\.[^"]*?\.js)')
            .firstMatch(page.body)
            ?.group(1);
        if (settings == null) throw ApiException('settings file not found');
        final js = await httpClient.get(Uri.parse(settings), headers: headers);
        final spade = RegExp(r'"spade_url":"(.*?)"').firstMatch(js.body)?.group(1);
        if (spade == null) throw ApiException('report address not found');
        _spadeUrl = spade;
        return spade;
      } catch (e) {
        debugPrint('Twitch spade lookup failed: $e');
        _spadeLoad = null;
        return null;
      }
    }();
  }

  Future<void> _report() async {
    if (_closed || !Services.settings.countAsViewer) return;
    final userId = Services.twitch.userId;
    if (!Services.twitch.isLoggedIn || userId == null) {
      status.value = 'Not counted: sign in to Twitch';
      return;
    }
    if (!isPlaying()) return;
    try {
      final data = await TwitchGql.query(
        r'query($login: String) { user(login: $login) { id stream { id game { id name } } } }',
        {'login': login},
      );
      final user = jMap(data['user']);
      final stream = jMap(user?['stream']);
      final channelId = jStr(user?['id']);
      final broadcastId = jStr(stream?['id']);
      if (channelId == null || broadcastId == null) return; // offline
      final spade = await _spade();
      if (spade == null) {
        status.value = "Not counted: couldn't reach Twitch's report address";
        return;
      }
      final game = jMap(stream?['game']);
      final payload = [
        {
          'event': 'minute-watched',
          'properties': {
            'channel_id': channelId,
            'broadcast_id': broadcastId,
            'player': 'site',
            'user_id': userId,
            'live': true,
            'channel': login,
            if (jStr(game?['name']) != null) 'game': jStr(game?['name']),
            if (jStr(game?['id']) != null) 'game_id': jStr(game?['id']),
          },
        },
      ];
      final res = await httpClient.post(
        Uri.parse(spade),
        headers: {'User-Agent': browserUserAgent, 'Content-Type': 'application/x-www-form-urlencoded'},
        body: {'data': base64Encode(utf8.encode(jsonEncode(payload)))},
      ).timeout(const Duration(seconds: 20));
      if (res.statusCode == 204 || res.statusCode == 200) {
        _sent++;
        status.value = 'Counted as a viewer · $_sent ${_sent == 1 ? 'minute' : 'minutes'} reported';
      } else {
        status.value = 'Not counted: Twitch answered HTTP ${res.statusCode}';
      }
    } catch (e) {
      status.value = 'Not counted: $e';
    }
  }
}
