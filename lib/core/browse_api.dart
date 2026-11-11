import 'package:flutter/foundation.dart';

import '../kick/kick_api.dart';
import '../kick/kick_web.dart';
import '../twitch/twitch_api.dart';
import 'models.dart';
import 'net.dart';

/// A game / category to browse.
class BrowseCategory {
  final StreamPlatform platform;

  /// Twitch: the game's name; Kick: the category slug.
  final String key;
  final String name;
  final String? imageUrl;
  final int? viewers;
  const BrowseCategory(this.platform, this.key, this.name, {this.imageUrl, this.viewers});
}

/// Discovering streams beyond the ones you follow: top streams, categories
/// and search, on Twitch and Kick.
class BrowseApi {
  BrowseApi._();

  static const _streamFields = 'title viewersCount previewImageURL(width: 440, height: 248) createdAt '
      'game { displayName } broadcaster { id login displayName profileImageURL(width: 150) }';

  static ChannelInfo? _twitchStream(Object? raw) {
    final node = jMap(raw);
    final b = jMap(node?['broadcaster']);
    if (node == null || b == null || jStr(b['login']) == null) return null;
    return ChannelInfo(
      platform: StreamPlatform.twitch,
      login: jStr(b['login'])!,
      displayName: jStr(b['displayName']) ?? jStr(b['login'])!,
      avatarUrl: jStr(b['profileImageURL']),
      userId: jStr(b['id']),
      isLive: true,
      title: jStr(node['title']),
      category: jStr(jMap(node['game'])?['displayName']),
      viewers: jInt(node['viewersCount']),
      thumbnailUrl: jStr(node['previewImageURL']),
      startedAt: jTime(node['createdAt']),
    );
  }

  // ------------------------------------------------------------ top streams

  static Future<List<ChannelInfo>> topStreams(StreamPlatform p, {String? category}) =>
      p == StreamPlatform.twitch ? _twitchTop(category) : _kickTop(category);

  static Future<List<ChannelInfo>> _twitchTop(String? game) async {
    if (game == null) return TwitchGql.getTopStreams(first: 40);
    final data = await TwitchGql.query(
      'query(\$name: String) { game(name: \$name) { streams(first: 40) { edges { node { $_streamFields } } } } }',
      {'name': game},
    );
    return [
      for (final e in jList(jMap(jMap(data['game'])?['streams'])?['edges']))
        if (_twitchStream(jMap(e)?['node']) case final c?) c,
    ];
  }

  /// Kick has changed these addresses before; try the known ones in turn.
  static Future<Object?> _kickJson(List<String> urls) async {
    Object? lastError;
    for (final url in urls) {
      try {
        final res = await KickWeb.instance.get(url);
        if (res.ok && res.json != null) return res.json;
        lastError = 'HTTP ${res.status}';
      } catch (e) {
        lastError = e;
      }
    }
    throw ApiException('Kick: $lastError');
  }

  static List<Object?> _items(Object? json) {
    if (json is List) return json;
    final m = jMap(json);
    final data = m?['data'];
    if (data is List) return data;
    final inner = jMap(data);
    if (inner?['livestreams'] is List) return inner!['livestreams'] as List;
    if (inner?['data'] is List) return inner!['data'] as List;
    if (m?['livestreams'] is List) return m!['livestreams'] as List;
    if (m?['categories'] is List) return m!['categories'] as List;
    return const [];
  }

  /// One of Kick's live-stream entries (several shapes).
  static ChannelInfo? _kickStream(Object? raw) {
    final m = jMap(raw);
    if (m == null) return null;
    final channel = jMap(m['channel']);
    if (channel != null && (channel['slug'] != null)) {
      // { session_title, viewer_count, thumbnail, channel: { slug, user } }
      final merged = <String, dynamic>{...channel, 'livestream': {...m, 'is_live': true}};
      return KickApi.parseChannel(merged, fallbackSlug: jStr(channel['slug'])!);
    }
    if (m['slug'] != null && m['livestream'] != null) {
      return KickApi.parseChannel(m, fallbackSlug: jStr(m['slug'])!);
    }
    final slug = jStr(m['slug']) ?? jStr(m['channel_slug']);
    if (slug == null) return null;
    final thumb = m['thumbnail'];
    return ChannelInfo(
      platform: StreamPlatform.kick,
      login: slug,
      displayName: jStr(jMap(m['user'])?['username']) ?? jStr(m['username']) ?? slug,
      avatarUrl: jStr(jMap(m['user'])?['profile_pic']) ?? jStr(m['profile_picture']),
      isLive: true,
      title: jStr(m['session_title']) ?? jStr(m['title']),
      viewers: jInt(m['viewer_count']) ?? jInt(m['viewers']),
      thumbnailUrl: thumb is String ? thumb : jStr(jMap(thumb)?['src']) ?? jStr(jMap(thumb)?['url']),
      startedAt: jTime(m['start_time']) ?? jTime(m['created_at']),
    );
  }

  static Future<List<ChannelInfo>> _kickTop(String? category) async {
    final cat = category == null ? '' : '&subcategory=${Uri.encodeComponent(category)}';
    final json = await _kickJson([
      'https://kick.com/stream/livestreams/en?page=1&limit=40&sort=desc$cat',
      'https://web.kick.com/api/v1/livestreams?limit=40&sort=viewer_count_desc'
          '${category == null ? '' : '&category=${Uri.encodeComponent(category)}'}',
      if (category != null) 'https://kick.com/api/v1/subcategories/${Uri.encodeComponent(category)}/livestreams?limit=40',
    ]);
    return [
      for (final i in _items(json))
        if (_kickStream(i) case final c?) c,
    ];
  }

  // ------------------------------------------------------------ categories

  static Future<List<BrowseCategory>> topCategories(StreamPlatform p) =>
      p == StreamPlatform.twitch ? _twitchCategories() : _kickCategories();

  static Future<List<BrowseCategory>> _twitchCategories() async {
    final data = await TwitchGql.query(
      'query { games(first: 40) { edges { node { name displayName boxArtURL(width: 144, height: 192) viewersCount } } } }',
    );
    return [
      for (final e in jList(jMap(data['games'])?['edges']))
        if (jMap(jMap(e)?['node']) case final n?)
          if (jStr(n['name']) case final name?)
            BrowseCategory(StreamPlatform.twitch, name, jStr(n['displayName']) ?? name,
                imageUrl: jStr(n['boxArtURL']), viewers: jInt(n['viewersCount'])),
    ];
  }

  static BrowseCategory? _kickCategory(Object? raw) {
    final m = jMap(raw);
    final slug = jStr(m?['slug']);
    if (m == null || slug == null) return null;
    final banner = m['banner'];
    return BrowseCategory(
      StreamPlatform.kick,
      slug,
      jStr(m['name']) ?? slug,
      imageUrl: banner is String ? banner : jStr(jMap(banner)?['src']) ?? jStr(jMap(banner)?['url']),
      viewers: jInt(m['viewers']) ?? jInt(m['viewer_count']),
    );
  }

  static Future<List<BrowseCategory>> _kickCategories() async {
    final json = await _kickJson([
      'https://kick.com/api/v1/subcategories?limit=40&page=1',
      'https://web.kick.com/api/v1/categories?limit=40',
      'https://kick.com/api/v1/categories/top',
    ]);
    final list = [
      for (final i in _items(json))
        if (_kickCategory(i) case final c?) c,
    ];
    list.sort((a, b) => (b.viewers ?? 0).compareTo(a.viewers ?? 0));
    return list;
  }

  // ------------------------------------------------------------ search

  static Future<(List<ChannelInfo>, List<BrowseCategory>)> search(StreamPlatform p, String query) =>
      p == StreamPlatform.twitch ? _twitchSearch(query) : _kickSearch(query);

  static Future<(List<ChannelInfo>, List<BrowseCategory>)> _twitchSearch(String q) async {
    const userFields = 'id login displayName profileImageURL(width: 150) '
        'stream { title viewersCount previewImageURL(width: 440, height: 248) createdAt game { displayName } }';
    final channels = <ChannelInfo>[];
    final categories = <BrowseCategory>[];
    try {
      final data = await TwitchGql.query(
        'query(\$q: String!) { searchFor(userQuery: \$q, platform: "web") { '
        'channels { edges { item { ... on User { $userFields } } } } '
        'games { edges { item { ... on Game { name displayName boxArtURL(width: 144, height: 192) viewersCount } } } } } }',
        {'q': q},
      );
      final s = jMap(data['searchFor']);
      for (final e in jList(jMap(s?['channels'])?['edges'])) {
        final u = jMap(jMap(e)?['item']);
        if (u != null && u['login'] != null) channels.add(TwitchGql.parseUser(u));
      }
      for (final e in jList(jMap(s?['games'])?['edges'])) {
        final g = jMap(jMap(e)?['item']);
        final name = jStr(g?['name']);
        if (g != null && name != null) {
          categories.add(BrowseCategory(StreamPlatform.twitch, name, jStr(g['displayName']) ?? name,
              imageUrl: jStr(g['boxArtURL']), viewers: jInt(g['viewersCount'])));
        }
      }
    } catch (e) {
      debugPrint('Twitch search failed: $e');
    }
    // Always offer the exact name too.
    if (!channels.any((c) => c.login == q.toLowerCase().trim())) {
      try {
        final exact = await TwitchGql.getChannel(q.toLowerCase().trim().replaceAll(' ', ''));
        if (exact != null) channels.insert(0, exact);
      } catch (_) {}
    }
    return (channels, categories);
  }

  static Future<(List<ChannelInfo>, List<BrowseCategory>)> _kickSearch(String q) async {
    final channels = <ChannelInfo>[];
    final categories = <BrowseCategory>[];
    try {
      final json = jMap(await _kickJson([
        'https://kick.com/api/search?searched_word=${Uri.encodeComponent(q)}',
      ]));
      for (final c in jList(json?['channels'])) {
        final m = jMap(c);
        final slug = jStr(m?['slug']);
        if (m != null && slug != null) channels.add(KickApi.parseChannel(m, fallbackSlug: slug));
      }
      for (final c in jList(json?['categories'])) {
        if (_kickCategory(c) case final cat?) categories.add(cat);
      }
    } catch (e) {
      debugPrint('Kick search failed: $e');
    }
    if (!channels.any((c) => c.login == q.toLowerCase().trim())) {
      try {
        final exact = await KickApi.getChannel(q.toLowerCase().trim().replaceAll(' ', '-'));
        if (exact != null) channels.insert(0, exact);
      } catch (_) {}
    }
    // Live ones first.
    channels.sort((a, b) => (b.isLive ? 1 : 0).compareTo(a.isLive ? 1 : 0));
    return (channels, categories);
  }
}
