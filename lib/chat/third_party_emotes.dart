import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../core/net.dart';
import '../core/services.dart';
import 'chat_models.dart';
import 'seventv.dart';

/// BetterTTV and FrankerFaceZ emotes (both through BetterTTV's API, which
/// also serves FrankerFaceZ's). Channel emotes exist for Twitch channels only.
class ThirdPartyEmotes {
  ThirdPartyEmotes._();

  static const _api = 'https://api.betterttv.net/3/cached';

  // BetterTTV's zero-width ("put on top") emotes.
  static const _bttvZeroWidth = {
    'SoSnowy', 'IceCold', 'SantaHat', 'TopHat', 'ReinDeer', 'CandyCane', 'cvMask', 'cvHazmat',
  };

  static Map<String, Emote>? _bttvGlobal, _ffzGlobal;

  // Kept once loaded (an empty result is tried again next time).
  static Future<Map<String, Emote>> bttvGlobal() async {
    if (_bttvGlobal case final g?) return g;
    final m = _bttv(await _get('$_api/emotes/global'), global: true);
    if (m.isNotEmpty) _bttvGlobal = m;
    return m;
  }

  static Future<Map<String, Emote>> ffzGlobal() async {
    if (_ffzGlobal case final g?) return g;
    final m = _ffz(await _get('$_api/frankerfacez/emotes/global'), global: true);
    if (m.isNotEmpty) _ffzGlobal = m;
    return m;
  }

  static Future<Map<String, Emote>> bttvChannel(StreamPlatform platform, String? userId) async {
    if (platform != StreamPlatform.twitch || userId == null || userId.isEmpty) return {};
    final j = jMap(await _get('$_api/users/twitch/$userId'));
    return {
      ..._bttv(j?['sharedEmotes'], global: false),
      ..._bttv(j?['channelEmotes'], global: false),
    };
  }

  static Future<Map<String, Emote>> ffzChannel(StreamPlatform platform, String? userId) async {
    if (platform != StreamPlatform.twitch || userId == null || userId.isEmpty) return {};
    return _ffz(await _get('$_api/frankerfacez/users/twitch/$userId'), global: false);
  }

  static Future<Object?> _get(String url) async {
    try {
      final res = await httpClient.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
      if (res.statusCode == 404) return null;
      return decodeJson(res, 'BetterTTV');
    } catch (e) {
      debugPrint('Emotes $url failed: $e');
      return null;
    }
  }

  static Map<String, Emote> _bttv(Object? list, {required bool global}) {
    final out = <String, Emote>{};
    for (final raw in jList(list)) {
      final e = jMap(raw);
      final id = jStr(e?['id']), code = jStr(e?['code']);
      if (id == null || code == null) continue;
      out[code] = Emote(
        name: code,
        url: 'https://cdn.betterttv.net/emote/$id/2x.webp',
        source: EmoteSource.bttv,
        id: id,
        isGlobal: global,
        zeroWidth: _bttvZeroWidth.contains(code),
        creator: jStr(jMap(e?['user'])?['displayName']) ?? jStr(jMap(e?['user'])?['name']),
      );
    }
    return out;
  }

  static Map<String, Emote> _ffz(Object? list, {required bool global}) {
    final out = <String, Emote>{};
    for (final raw in jList(list)) {
      final e = jMap(raw);
      final code = jStr(e?['code']);
      final id = jStr(e?['id']) ?? jInt(e?['id'])?.toString();
      final images = jMap(e?['images']);
      final url = jStr(images?['2x']) ?? jStr(images?['1x']) ?? jStr(images?['4x']);
      if (code == null || url == null) continue;
      out[code] = Emote(
        name: code,
        url: url,
        source: EmoteSource.ffz,
        id: id,
        isGlobal: global,
        creator: jStr(jMap(e?['user'])?['displayName']) ?? jStr(jMap(e?['user'])?['name']),
      );
    }
    return out;
  }
}

/// All the add-on emotes for one channel: 7TV, BetterTTV, FrankerFaceZ.
class EmoteSets {
  const EmoteSets({
    this.sevenTvGlobal = const {},
    this.sevenTvChannel = const {},
    this.bttvGlobal = const {},
    this.bttvChannel = const {},
    this.ffzGlobal = const {},
    this.ffzChannel = const {},
  });

  final Map<String, Emote> sevenTvGlobal, sevenTvChannel, bttvGlobal, bttvChannel, ffzGlobal, ffzChannel;

  /// By name. Channel emotes win over global ones; 7TV wins over BetterTTV,
  /// which wins over FrankerFaceZ (as in the 7TV browser extension).
  Map<String, Emote> get merged => {
        ...ffzGlobal,
        ...bttvGlobal,
        ...sevenTvGlobal,
        ...ffzChannel,
        ...bttvChannel,
        ...sevenTvChannel,
      };

  static Future<EmoteSets> load(StreamPlatform platform, String? userId) async {
    final s = Services.settings;
    Future<Map<String, Emote>> none() async => const {};
    final r = await Future.wait([
      SevenTv.global(),
      SevenTv.forChannel(platform, userId),
      s.bttvEmotes ? ThirdPartyEmotes.bttvGlobal() : none(),
      s.bttvEmotes ? ThirdPartyEmotes.bttvChannel(platform, userId) : none(),
      s.ffzEmotes ? ThirdPartyEmotes.ffzGlobal() : none(),
      s.ffzEmotes ? ThirdPartyEmotes.ffzChannel(platform, userId) : none(),
    ]);
    return EmoteSets(
      sevenTvGlobal: r[0],
      sevenTvChannel: r[1],
      bttvGlobal: r[2],
      bttvChannel: r[3],
      ffzGlobal: r[4],
      ffzChannel: r[5],
    );
  }
}
