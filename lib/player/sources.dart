import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/net.dart';
import 'hls.dart';

class StreamOfflineException implements Exception {
  @override
  String toString() => 'This channel is offline.';
}

/// A fetched master playlist plus the server clock, used to measure latency.
class MasterInfo {
  MasterInfo(this.variants, {this.serverOffset});

  final List<HlsVariant> variants;

  /// Server clock minus device clock, when the server told us its time.
  final Duration? serverOffset;
}

/// Where a live stream's playlists come from.
abstract class StreamSource {
  /// Loads (or reloads) the master playlist.
  Future<MasterInfo> loadMaster();

  /// Fetches the media playlist of [variant] from the main stream.
  Future<HlsMediaPlaylist> loadVariant(HlsVariant variant);

  /// Whether [segment] is an ad.
  bool isAd(HlsSegment segment) => false;

  /// Ad-free segments for [variant] from a backup stream, or null when none
  /// is available. Only called while the main stream is showing ads.
  Future<({String source, HlsMediaPlaylist playlist})?> loadBackup(HlsVariant variant) async => null;

  bool get blocksAds => false;
}

Duration? _offsetFromDateHeader(http.Response res) {
  final date = res.headers['date'];
  if (date == null) return null;
  try {
    return HttpDateParser.parse(date).difference(DateTime.now().toUtc());
  } catch (_) {
    return null;
  }
}

/// Parses RFC 1123 dates from HTTP "Date" headers.
class HttpDateParser {
  static const _months = {
    'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6,
    'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
  };

  /// e.g. "Mon, 19 Oct 2026 14:05:00 GMT"
  static DateTime parse(String s) {
    final p = s.split(RegExp(r'[ ,:]+')).where((e) => e.isNotEmpty).toList();
    // [Mon, 19, Oct, 2026, 14, 05, 00, GMT]
    return DateTime.utc(int.parse(p[3]), _months[p[2]]!, int.parse(p[1]), int.parse(p[4]),
        int.parse(p[5]), int.parse(p[6]));
  }
}

Future<http.Response> _get(Uri uri, {Map<String, String>? headers}) => httpClient
    .get(uri, headers: {'User-Agent': browserUserAgent, ...?headers})
    .timeout(const Duration(seconds: 10));

/// Picks the variant in [list] closest in size to [target].
HlsVariant? closestVariant(List<HlsVariant> list, HlsVariant target) {
  final candidates = list.where((v) => !v.isAudioOnly).toList();
  if (candidates.isEmpty) return null;
  for (final v in candidates) {
    if (v.resolution == target.resolution && v.frameRate == target.frameRate) return v;
  }
  candidates.sort((a, b) =>
      (a.pixels - target.pixels).abs().compareTo((b.pixels - target.pixels).abs()));
  return candidates.first;
}

// ---------------------------------------------------------------------------
// Kick
// ---------------------------------------------------------------------------

class KickSource extends StreamSource {
  KickSource(this.playbackUrl);

  final String playbackUrl;

  @override
  Future<MasterInfo> loadMaster() async {
    final uri = Uri.parse(playbackUrl);
    final res = await _get(uri);
    if (res.statusCode == 404 || res.statusCode == 403) throw StreamOfflineException();
    if (res.statusCode != 200) throw ApiException('Kick stream returned HTTP ${res.statusCode}');
    final master = parseMasterPlaylist(utf8.decode(res.bodyBytes), uri);
    final variants = master.variants.where((v) => !v.isAudioOnly).toList();
    if (variants.isEmpty) throw StreamOfflineException();
    return MasterInfo(variants, serverOffset: _offsetFromDateHeader(res));
  }

  @override
  Future<HlsMediaPlaylist> loadVariant(HlsVariant variant) async {
    final res = await _get(variant.uri);
    if (res.statusCode != 200) throw ApiException('Kick playlist HTTP ${res.statusCode}');
    return parseMediaPlaylist(utf8.decode(res.bodyBytes), variant.uri);
  }
}

// ---------------------------------------------------------------------------
// Twitch
// ---------------------------------------------------------------------------

/// Twitch playback with TwitchAdSolutions-style ("vaft") ad handling: when the
/// main stream has ads, the same moment is taken from a backup stream
/// requested as a different player type, which usually has no ads.
class TwitchSource extends StreamSource {
  TwitchSource(this.login, {this.blockAds = true});

  final String login;
  final bool blockAds;

  static const _webClientId = 'kimne78kx3ncx6brgo4mv6wki5h1ko';

  /// vaft's choices: embed and popout give Source quality, autoplay 360p.
  static const backupPlayerTypes = ['embed', 'popout', 'autoplay'];

  final String _deviceId = _randomId(32);
  final String _sessionId = _randomHex(32);
  final Map<String, MasterInfo> _backupMasters = {};

  @override
  bool get blocksAds => blockAds;

  String get _mainPlayerType => blockAds ? 'popout' : 'site';

  @override
  Future<MasterInfo> loadMaster() => _master(_mainPlayerType);

  @override
  bool isAd(HlsSegment segment) => !segment.title.toLowerCase().startsWith('live');

  @override
  Future<HlsMediaPlaylist> loadVariant(HlsVariant variant) async {
    final res = await _get(variant.uri);
    if (res.statusCode != 200) {
      throw ApiException('Twitch playlist HTTP ${res.statusCode}', status: res.statusCode);
    }
    return parseMediaPlaylist(utf8.decode(res.bodyBytes), variant.uri);
  }

  @override
  Future<({String source, HlsMediaPlaylist playlist})?> loadBackup(HlsVariant variant) async {
    if (!blockAds) return null;
    for (final type in backupPlayerTypes) {
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          var master = _backupMasters[type];
          final fresh = master == null;
          master ??= _backupMasters[type] = await _master(type);
          final match = closestVariant(master.variants, variant);
          if (match == null) break;
          final playlist = await loadVariant(match);
          // Only non-ad segments are ever used, so any are good enough.
          if (playlist.segments.any((s) => !isAd(s))) {
            return (source: type, playlist: playlist);
          }
          // Only ads here: forget this backup. If it was cached, try once
          // more with a fresh token; if it was just fetched, move on.
          _backupMasters.remove(type);
          if (fresh) break;
        } catch (e) {
          debugPrint('Twitch backup $type failed: $e');
          _backupMasters.remove(type);
          break;
        }
      }
    }
    return null;
  }

  Future<MasterInfo> _master(String playerType) async {
    final token = await _accessToken(playerType);
    final uri = Uri.https('usher.ttvnw.net', '/api/v2/channel/hls/$login.m3u8', {
      'sig': token.signature,
      'token': token.value,
      'allow_source': 'true',
      'allow_audio_only': 'true',
      'fast_bread': 'true',
      'supported_codecs': 'h264',
      'reassignments_supported': 'true',
      'platform': 'web',
      'player_backend': 'mediaplayer',
      'playlist_include_framerate': 'true',
      'play_session_id': _sessionId,
      'p': '${Random().nextInt(999999)}',
    });
    final res = await _get(uri, headers: const {
      'Referer': 'https://player.twitch.tv',
      'Origin': 'https://player.twitch.tv',
    });
    if (res.statusCode == 404 || res.statusCode == 403) throw StreamOfflineException();
    if (res.statusCode != 200) throw ApiException('Twitch stream returned HTTP ${res.statusCode}');
    final master = parseMasterPlaylist(utf8.decode(res.bodyBytes), uri);
    final variants = master.variants.where((v) => !v.isAudioOnly).toList();
    if (variants.isEmpty) throw StreamOfflineException();
    final serverTime = master.serverTime;
    final offset = serverTime != null
        ? serverTime.difference(DateTime.now().toUtc())
        : _offsetFromDateHeader(res);
    return MasterInfo(variants, serverOffset: offset);
  }

  Future<({String value, String signature})> _accessToken(String playerType) async {
    final variables = {
      'isLive': true,
      'login': login,
      'isVod': false,
      'vodID': '',
      'playerType': playerType,
      'platform': playerType == 'autoplay' ? 'android' : 'web',
    };
    Future<Map<String, dynamic>?> query(Map<String, Object> body) async {
      final res = await httpClient
          .post(
            Uri.parse('https://gql.twitch.tv/gql'),
            headers: {
              'Client-ID': _webClientId,
              'X-Device-Id': _deviceId,
              'Content-Type': 'application/json',
              'User-Agent': browserUserAgent,
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 10));
      final json = jsonDecode(utf8.decode(res.bodyBytes));
      return json is Map ? json.cast<String, dynamic>() : null;
    }

    var json = await query({
      'operationName': 'PlaybackAccessToken',
      'variables': variables,
      'extensions': {
        'persistedQuery': {
          'version': 1,
          'sha256Hash': 'ed230aa1e33e07eebb8928504583da78a5173989fadfb1ac94be06a04f3cdbe9',
        },
      },
    });
    if (json?['data'] == null) {
      // Twitch rotated the persisted query: send the full query instead.
      json = await query({
        'operationName': 'PlaybackAccessToken_Template',
        'query': r'query PlaybackAccessToken_Template($login: String!, $isLive: Boolean!, $vodID: ID!, $isVod: Boolean!, $playerType: String!, $platform: String!) { streamPlaybackAccessToken(channelName: $login, params: {platform: $platform, playerBackend: "mediaplayer", playerType: $playerType}) @include(if: $isLive) { value signature __typename } videoPlaybackAccessToken(id: $vodID, params: {platform: $platform, playerBackend: "mediaplayer", playerType: $playerType}) @include(if: $isVod) { value signature __typename } }',
        'variables': variables,
      });
    }
    final data = json?['data'];
    final token = data is Map ? data['streamPlaybackAccessToken'] : null;
    if (token is! Map) throw StreamOfflineException();
    final value = token['value'];
    final signature = token['signature'];
    if (value is! String || signature is! String) throw StreamOfflineException();
    return (value: value, signature: signature);
  }

  static String _randomId(int length) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random();
    return List.generate(length, (_) => chars[r.nextInt(chars.length)]).join();
  }

  static String _randomHex(int length) {
    final r = Random();
    return List.generate(length, (_) => r.nextInt(16).toRadixString(16)).join();
  }
}
