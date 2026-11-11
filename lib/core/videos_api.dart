import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;

import '../chat/chat_models.dart';
import '../kick/kick_api.dart';
import '../kick/kick_web.dart';
import '../twitch/twitch_api.dart';
import 'models.dart';
import 'net.dart';
import 'services.dart';

/// A past broadcast (VOD) or a clip.
class VideoItem {
  final StreamPlatform platform;
  final String id;
  final String title;
  final String? thumbnailUrl;
  final Duration? duration;
  final DateTime? createdAt;
  final int? views;
  final String? category;
  final bool isClip;

  /// Who made the clip.
  final String? creator;

  /// Kick gives the video address directly.
  final String? directUrl;

  /// Kick VODs: the video's id for looking up its address later.
  final String? kickUuid;

  const VideoItem({
    required this.platform,
    required this.id,
    required this.title,
    this.thumbnailUrl,
    this.duration,
    this.createdAt,
    this.views,
    this.category,
    this.isClip = false,
    this.creator,
    this.directUrl,
    this.kickUuid,
  });
}

/// How far back to look for clips.
enum ClipPeriod { week, month, all }

/// Past broadcasts, clips, and their chat, on Twitch and Kick.
class VideosApi {
  VideosApi._();

  static const _webClientId = 'kimne78kx3ncx6brgo4mv6wki5h1ko';

  // ------------------------------------------------------------ lists

  static Future<List<VideoItem>> vods(ChannelRef ref) =>
      ref.platform == StreamPlatform.twitch ? _twitchVods(ref.login) : _kickVods(ref.login);

  static Future<List<VideoItem>> clips(ChannelRef ref, ClipPeriod period) =>
      ref.platform == StreamPlatform.twitch ? _twitchClips(ref.login, period) : _kickClips(ref.login, period);

  static Future<List<VideoItem>> _twitchVods(String login) async {
    final data = await TwitchGql.query(
      r'query($login: String) { user(login: $login) { videos(first: 40, type: ARCHIVE, sort: TIME) { edges { node { '
      'id title lengthSeconds createdAt viewCount previewThumbnailURL(width: 320, height: 180) game { displayName } '
      '} } } } }',
      {'login': login},
    );
    return [
      for (final e in jList(jMap(jMap(data['user'])?['videos'])?['edges']))
        if (jMap(jMap(e)?['node']) case final n?)
          if (jStr(n['id']) case final id?)
            VideoItem(
              platform: StreamPlatform.twitch,
              id: id,
              title: jStr(n['title']) ?? 'Past broadcast',
              thumbnailUrl: _twitchThumb(jStr(n['previewThumbnailURL'])),
              duration: jInt(n['lengthSeconds']) == null ? null : Duration(seconds: jInt(n['lengthSeconds'])!),
              createdAt: jTime(n['createdAt']),
              views: jInt(n['viewCount']),
              category: jStr(jMap(n['game'])?['displayName']),
            ),
    ];
  }

  /// Thumbnails of VODs still processing point at a placeholder.
  static String? _twitchThumb(String? url) =>
      url == null || url.contains('404_processing') ? null : url;

  static Future<List<VideoItem>> _twitchClips(String login, ClipPeriod period) async {
    final p = switch (period) {
      ClipPeriod.week => 'LAST_WEEK',
      ClipPeriod.month => 'LAST_MONTH',
      ClipPeriod.all => 'ALL_TIME',
    };
    final data = await TwitchGql.query(
      'query(\$login: String) { user(login: \$login) { clips(first: 40, criteria: { period: $p, sort: VIEWS_DESC }) '
      '{ edges { node { slug title viewCount durationSeconds createdAt thumbnailURL curator { displayName } '
      'game { displayName } } } } } }',
      {'login': login},
    );
    return [
      for (final e in jList(jMap(jMap(data['user'])?['clips'])?['edges']))
        if (jMap(jMap(e)?['node']) case final n?)
          if (jStr(n['slug']) case final slug?)
            VideoItem(
              platform: StreamPlatform.twitch,
              id: slug,
              title: jStr(n['title']) ?? 'Clip',
              thumbnailUrl: jStr(n['thumbnailURL']),
              duration: jNum(n['durationSeconds']) == null
                  ? null
                  : Duration(milliseconds: (jNum(n['durationSeconds'])! * 1000).round()),
              createdAt: jTime(n['createdAt']),
              views: jInt(n['viewCount']),
              category: jStr(jMap(n['game'])?['displayName']),
              creator: jStr(jMap(n['curator'])?['displayName']),
              isClip: true,
            ),
    ];
  }

  static String? _thumb(Object? t) {
    if (t is String) return t;
    final m = jMap(t);
    return jStr(m?['src']) ?? jStr(m?['url']);
  }

  static Future<List<VideoItem>> _kickVods(String slug) async {
    final res = await KickWeb.instance.get('https://kick.com/api/v2/channels/${Uri.encodeComponent(slug)}/videos');
    if (!res.ok) throw ApiException('Kick returned HTTP ${res.status}');
    final list = res.json is List ? res.json as List : jList(jMap(res.json)?['data']);
    return [
      for (final raw in list)
        if (jMap(raw) case final m?)
          VideoItem(
            platform: StreamPlatform.kick,
            id: jStr(m['id']) ?? jInt(m['id'])?.toString() ?? '',
            title: jStr(m['session_title']) ?? jStr(m['title']) ?? 'Past broadcast',
            thumbnailUrl: _thumb(m['thumbnail']) ?? _thumb(jMap(m['video'])?['thumbnail']),
            // Kick gives milliseconds.
            duration: jInt(m['duration']) == null ? null : Duration(milliseconds: jInt(m['duration'])!),
            createdAt: jTime(m['start_time']) ?? jTime(m['created_at']),
            views: jInt(jMap(m['video'])?['views']) ?? jInt(m['views']) ?? jInt(m['viewer_count']),
            category: jStr(jMap(jList(m['categories']).firstOrNull)?['name']),
            directUrl: jStr(m['source']),
            kickUuid: jStr(jMap(m['video'])?['uuid']),
          ),
    ];
  }

  static Future<List<VideoItem>> _kickClips(String slug, ClipPeriod period) async {
    final time = switch (period) {
      ClipPeriod.week => 'week',
      ClipPeriod.month => 'month',
      ClipPeriod.all => 'all',
    };
    final res = await KickWeb.instance
        .get('https://kick.com/api/v2/channels/${Uri.encodeComponent(slug)}/clips?sort=view&time=$time');
    if (!res.ok) throw ApiException('Kick returned HTTP ${res.status}');
    final j = jMap(res.json);
    final list = jList(j?['clips'] ?? jMap(j?['data'])?['clips'] ?? j?['data']);
    return [
      for (final raw in list)
        if (jMap(raw) case final m?)
          VideoItem(
            platform: StreamPlatform.kick,
            id: jStr(m['id']) ?? '',
            title: jStr(m['title']) ?? 'Clip',
            thumbnailUrl: jStr(m['thumbnail_url']) ?? _thumb(m['thumbnail']),
            duration: jNum(m['duration']) == null ? null : Duration(seconds: jNum(m['duration'])!.round()),
            createdAt: jTime(m['created_at']),
            views: jInt(m['views']) ?? jInt(m['view_count']),
            category: jStr(jMap(m['category'])?['name']),
            creator: jStr(jMap(m['creator'])?['username']),
            isClip: true,
            directUrl: jStr(m['video_url']) ?? jStr(m['clip_url']),
          ),
    ];
  }

  // ------------------------------------------------------------ playback

  /// The address to play [v] from.
  static Future<Uri> playUrl(VideoItem v) async {
    if (v.platform == StreamPlatform.kick) {
      var url = v.directUrl;
      if (url == null && v.kickUuid != null) {
        final res = await KickWeb.instance.get('https://kick.com/api/v1/video/${v.kickUuid}');
        url = jStr(jMap(res.json)?['source']);
      }
      if (url == null) throw ApiException('Kick has no video address for this');
      return Uri.parse(url);
    }
    return v.isClip ? _twitchClipUrl(v.id) : _twitchVodUrl(v.id);
  }

  static Future<Map<String, dynamic>?> _gql(Map<String, Object> body) async {
    final auth = Services.twitch.playbackToken;
    final res = await httpClient
        .post(
          Uri.parse('https://gql.twitch.tv/gql'),
          headers: {
            'Client-ID': _webClientId,
            'Content-Type': 'application/json',
            'User-Agent': browserUserAgent,
            if (auth != null) 'Authorization': 'OAuth $auth',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 15));
    final json = jsonDecode(utf8.decode(res.bodyBytes));
    return json is Map ? jMap(json['data']) : null;
  }

  static Future<Uri> _twitchVodUrl(String id) async {
    // Signed in: sub-only VODs of channels you're subscribed to work too.
    final data = await _gql({
      'query': r'query($id: ID!) { videoPlaybackAccessToken(id: $id, params: '
          '{platform: "web", playerBackend: "mediaplayer", playerType: "site"}) { value signature } }',
      'variables': {'id': id},
    });
    final t = jMap(data?['videoPlaybackAccessToken']);
    final value = jStr(t?['value']), sig = jStr(t?['signature']);
    if (value == null || sig == null) throw ApiException("Twitch didn't allow playing this video");
    return Uri.https('usher.ttvnw.net', '/vod/$id.m3u8', {
      'sig': sig,
      'token': value,
      'allow_source': 'true',
      'allow_audio_only': 'true',
      'player': 'twitchweb',
      'playlist_include_framerate': 'true',
      'p': '${Random().nextInt(999999)}',
    });
  }

  static Future<Uri> _twitchClipUrl(String slug) async {
    final data = await _gql({
      'query': r'query($slug: ID!) { clip(slug: $slug) { playbackAccessToken(params: '
          '{platform: "web", playerBackend: "mediaplayer", playerType: "site"}) { value signature } '
          'videoQualities { quality sourceURL } } }',
      'variables': {'slug': slug},
    });
    final clip = jMap(data?['clip']);
    final t = jMap(clip?['playbackAccessToken']);
    final qualities = [for (final q in jList(clip?['videoQualities'])) if (jMap(q) case final m?) m];
    // Best quality first.
    qualities.sort((a, b) => (int.tryParse(jStr(b['quality']) ?? '') ?? 0)
        .compareTo(int.tryParse(jStr(a['quality']) ?? '') ?? 0));
    final source = qualities.isEmpty ? null : jStr(qualities.first['sourceURL']);
    final value = jStr(t?['value']), sig = jStr(t?['signature']);
    if (source == null || value == null || sig == null) throw ApiException("Twitch didn't allow playing this clip");
    return Uri.parse('$source?sig=$sig&token=${Uri.encodeComponent(value)}');
  }

  // ------------------------------------------------------------ chat replay

  static Color? _hex(String? s) {
    final h = s?.replaceFirst('#', '');
    if (h == null || h.length != 6) return null;
    final v = int.tryParse(h, radix: 16);
    return v == null ? null : Color(0xFF000000 | v);
  }

  /// Twitch VOD chat from [from] onwards: (offset into the video, message).
  /// Throws when Twitch doesn't share it.
  static Future<List<(Duration, ChatMessage)>> twitchReplay(String videoId, Duration from) async {
    final data = await TwitchGql.query(
      r'query($id: ID!, $offset: Int) { video(id: $id) { comments(contentOffsetSeconds: $offset) { edges { node { '
      'id contentOffsetSeconds createdAt commenter { id login displayName } '
      'message { fragments { text emote { emoteID } } userColor userBadges { setID version } } '
      '} } } } }',
      {'id': videoId, 'offset': from.inSeconds},
    );
    final out = <(Duration, ChatMessage)>[];
    for (final e in jList(jMap(jMap(data['video'])?['comments'])?['edges'])) {
      final n = jMap(jMap(e)?['node']);
      if (n == null) continue;
      final commenter = jMap(n['commenter']);
      final msg = jMap(n['message']);
      final fragments = <Fragment>[
        for (final f in jList(msg?['fragments']))
          if (jMap(f) case final fr?)
            if (jStr(jMap(fr['emote'])?['emoteID']) case final eid?)
              EmoteFragment(Emote(
                name: jStr(fr['text']) ?? '',
                url: 'https://static-cdn.jtvnw.net/emoticons/v2/$eid/default/dark/2.0',
                source: EmoteSource.twitch,
              ))
            else
              TextFragment(jStr(fr['text']) ?? ''),
      ];
      final login = jStr(commenter?['login']) ?? '';
      out.add((
        Duration(seconds: jInt(n['contentOffsetSeconds']) ?? 0),
        ChatMessage(
          id: jStr(n['id']) ?? '${login}_${n['contentOffsetSeconds']}',
          author: jStr(commenter?['displayName']) ?? login,
          authorLogin: login,
          authorId: jStr(commenter?['id']),
          authorColor: _hex(jStr(msg?['userColor'])),
          badges: [
            for (final b in jList(msg?['userBadges']))
              if (jMap(b) case final bm?)
                if (jStr(bm['setID']) case final set?) ChatBadge(set, jStr(bm['version']) ?? ''),
          ],
          fragments: fragments,
          timestamp: jTime(n['createdAt']) ?? DateTime.now(),
        ),
      ));
    }
    return out;
  }

  /// Kick VOD chat around [at] (the real time of that moment in the stream).
  static Future<List<ChatMessage>> kickReplay(int channelId, DateTime at) async {
    final res = await KickWeb.instance.get(
      'https://kick.com/api/v2/channels/$channelId/messages?start_time=${Uri.encodeComponent(at.toUtc().toIso8601String())}',
    );
    if (!res.ok) throw ApiException('Kick returned HTTP ${res.status}');
    final j = jMap(res.json);
    final out = <ChatMessage>[];
    for (final raw in jList(jMap(j?['data'])?['messages'] ?? j?['messages'])) {
      final m = jMap(raw);
      if (m == null) continue;
      final msg = KickApi.parseChatMessage(m);
      if (msg != null) out.add(msg);
    }
    out.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    debugPrint('Kick replay at $at: ${out.length}');
    return out;
  }
}
