import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../core/net.dart';
import '../kick/kick_web.dart';
import '../twitch/twitch_api.dart';
import 'chat_models.dart';

/// What to draw for a badge: the platform's picture and its name.
class BadgeLook {
  final String? imageUrl;
  final String title;
  const BadgeLook(this.imageUrl, this.title);
}

/// The badge pictures for one channel's chat.
///
/// Twitch: Twitch's global badges plus the channel's own (sub badges, bits),
/// looked up once. Kick: the channel's custom subscriber badges; Kick's
/// built-in badges (mod, VIP, OG…) have no public pictures, so those are
/// drawn by Bolt.
class ChatBadges extends ChangeNotifier {
  ChatBadges(this.channel);

  final ChannelInfo channel;

  static Map<String, BadgeLook>? _twitchGlobal;
  static Future<Map<String, BadgeLook>>? _twitchGlobalLoad;

  Map<String, BadgeLook> _twitchChannel = const {};

  /// Kick subscriber badges: (months, picture), smallest first.
  List<(int, String)> _kickSubs = const [];

  bool _started = false;

  Future<void> load() async {
    if (_started) return;
    _started = true;
    try {
      if (channel.platform == StreamPlatform.twitch) {
        await Future.wait([_loadTwitchGlobal(), _loadTwitchChannel()]);
      } else {
        await _loadKick();
      }
    } catch (e) {
      debugPrint('Badges failed: $e');
    }
    notifyListeners();
  }

  static Map<String, BadgeLook> _parseTwitch(Object? list) => {
        for (final b in jList(list))
          if (jMap(b) case final m?)
            if (jStr(m['setID']) != null)
              '${jStr(m['setID'])}/${jStr(m['version']) ?? ''}':
                  BadgeLook(jStr(m['imageURL']), jStr(m['title']) ?? jStr(m['setID'])!),
      };

  Future<void> _loadTwitchGlobal() async {
    if (_twitchGlobal != null) return;
    _twitchGlobalLoad ??= TwitchGql.query(
      'query { badges { setID version title imageURL(size: DOUBLE) } }',
    ).then((data) => _parseTwitch(data['badges']));
    try {
      _twitchGlobal = await _twitchGlobalLoad;
    } catch (e) {
      _twitchGlobalLoad = null; // try again next chat
      rethrow;
    }
  }

  Future<void> _loadTwitchChannel() async {
    final data = await TwitchGql.query(
      r'query($login: String) { user(login: $login) { broadcastBadges { setID version title imageURL(size: DOUBLE) } } }',
      {'login': channel.login},
    );
    _twitchChannel = _parseTwitch(jMap(data['user'])?['broadcastBadges']);
  }

  Future<void> _loadKick() async {
    final res = await KickWeb.instance.get('https://kick.com/api/v2/channels/${Uri.encodeComponent(channel.login)}');
    if (!res.ok) return;
    final subs = <(int, String)>[];
    for (final b in jList(jMap(res.json)?['subscriber_badges'])) {
      final m = jMap(b);
      final months = jInt(m?['months']);
      final src = jStr(jMap(m?['badge_image'])?['src']);
      if (months != null && src != null) subs.add((months, src));
    }
    subs.sort((a, b) => a.$1.compareTo(b.$1));
    _kickSubs = subs;
  }

  static const _kickTitles = {
    'broadcaster': 'Broadcaster',
    'moderator': 'Moderator',
    'vip': 'VIP',
    'og': 'OG',
    'founder': 'Founder',
    'subscriber': 'Subscriber',
    'sub_gifter': 'Sub gifter',
    'staff': 'Kick staff',
    'verified': 'Verified',
    'bot': 'Bot',
    'trainwreckstv': 'Trainwreck',
  };

  /// The picture and name for [b], or a name only (Bolt draws an icon).
  BadgeLook? lookFor(ChatBadge b) {
    if (channel.platform == StreamPlatform.twitch) {
      final key = '${b.set}/${b.version}';
      final look = _twitchChannel[key] ?? _twitchGlobal?[key];
      if (look == null) return null;
      final months = b.count;
      if (b.set == 'subscriber' && months != null) {
        return BadgeLook(look.imageUrl, '${look.title} ($months ${months == 1 ? 'month' : 'months'})');
      }
      return look;
    }
    final title = b.title ?? _kickTitles[b.set] ?? b.set;
    final count = b.count;
    if (b.set == 'subscriber') {
      String? url;
      for (final (months, src) in _kickSubs) {
        if (count == null || months <= count) url = src;
      }
      return BadgeLook(url, count == null ? title : '$title ($count ${count == 1 ? 'month' : 'months'})');
    }
    if (b.set == 'sub_gifter' && count != null) return BadgeLook(null, '$title ($count gifted)');
    return BadgeLook(null, title);
  }
}
