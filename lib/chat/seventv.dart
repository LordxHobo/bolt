import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../core/net.dart';
import 'chat_models.dart';

/// 7TV emotes for Twitch and Kick channels (https://github.com/SevenTV).
class SevenTv {
  static Map<String, Emote>? _global;
  static Future<Map<String, Emote>>? _globalLoading;

  static Future<Map<String, Emote>> global() {
    if (_global != null) return Future.value(_global!);
    return _globalLoading ??= _fetchSet('https://7tv.io/v3/emote-sets/global')
        .then((m) => _global = m)
        .whenComplete(() => _globalLoading = null);
  }

  /// Channel emotes. [platform] is the 7TV connection platform and [userId]
  /// the platform's numeric user id.
  static Future<Map<String, Emote>> forChannel(
      StreamPlatform platform, String? userId) async {
    if (userId == null || userId.isEmpty) return {};
    final paths = switch (platform) {
      StreamPlatform.twitch => ['twitch/$userId'],
      // 7TV's API takes the platform name; accept either casing.
      StreamPlatform.kick => ['kick/$userId', 'KICK/$userId'],
    };
    for (final p in paths) {
      try {
        final res = await httpClient.get(Uri.parse('https://7tv.io/v3/users/$p'));
        if (res.statusCode == 404) continue;
        final json = jMap(decodeJson(res, '7TV'));
        return _parseEmotes(jList(jMap(json?['emote_set'])?['emotes']), global: false);
      } catch (e) {
        debugPrint('7TV lookup $p failed: $e');
      }
    }
    return {};
  }

  static Future<Map<String, Emote>> _fetchSet(String url) async {
    try {
      final res = await httpClient.get(Uri.parse(url));
      final json = jMap(decodeJson(res, '7TV'));
      return _parseEmotes(jList(json?['emotes']), global: true);
    } catch (e) {
      debugPrint('7TV global failed: $e');
      return {};
    }
  }

  static Map<String, Emote> _parseEmotes(List<dynamic> list, {required bool global}) {
    final out = <String, Emote>{};
    for (final raw in list) {
      final e = jMap(raw);
      final name = jStr(e?['name']);
      final data = jMap(e?['data']);
      final host = jMap(data?['host']);
      final base = jStr(host?['url']);
      if (name == null || host == null || base == null) continue;
      final files = jList(host['files']).map(jMap).whereType<Map<String, dynamic>>().toList();
      if (files.isEmpty) continue;
      // Flutter can't decode AVIF; prefer 2x WebP, then any 2x, then anything.
      Map<String, dynamic>? pick;
      for (final f in files) {
        final fname = jStr(f['name']) ?? '';
        final fmt = (jStr(f['format']) ?? '').toUpperCase();
        if (fmt == 'AVIF' || fname.endsWith('.avif')) continue;
        if (fname.startsWith('2x') && (fmt == 'WEBP' || fname.endsWith('.webp'))) {
          pick = f;
          break;
        }
        if (fname.startsWith('2x')) {
          pick ??= f;
        }
      }
      final chosen = pick ??
          files.firstWhere(
            (f) => (jStr(f['format']) ?? '').toUpperCase() != 'AVIF',
            orElse: () => files.first,
          );
      final first = files.first;
      final flags = jInt(data?['flags']) ?? 0;
      final prefix = base.startsWith('http') ? base : 'https:$base';
      out[name] = Emote(
        name: name,
        url: '$prefix/${jStr(chosen['name'])}',
        width: (jInt(first['width']) ?? 0).toDouble(),
        height: (jInt(first['height']) ?? 0).toDouble(),
        zeroWidth: (flags & 256) == 256,
        source: EmoteSource.sevenTv,
        id: jStr(e?['id']) ?? jStr(data?['id']),
        isGlobal: global,
        creator: jStr(jMap(data?['owner'])?['display_name']) ?? jStr(jMap(data?['owner'])?['username']),
      );
    }
    return out;
  }
}
