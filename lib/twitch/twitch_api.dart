import 'dart:convert';

import '../core/models.dart';
import '../core/net.dart';

/// Twitch's public web GraphQL endpoint, used for anonymous channel lookups.
class TwitchGql {
  static const webClientId = 'kimne78kx3ncx6brgo4mv6wki5h1ko';

  static Future<Map<String, dynamic>> _query(
      String query, Map<String, dynamic> variables, {String? token}) async {
    final res = await httpClient.post(
      Uri.parse('https://gql.twitch.tv/gql'),
      headers: {
        'Client-ID': webClientId,
        'Content-Type': 'application/json',
        'User-Agent': browserUserAgent,
        if (token != null) 'Authorization': 'OAuth $token',
      },
      body: jsonEncode({'query': query, 'variables': variables}),
    );
    final json = jMap(decodeJson(res, 'Twitch lookup'));
    final data = jMap(json?['data']);
    if (data == null) {
      throw ApiException('Twitch lookup failed: ${json?['errors'] ?? 'no data'}');
    }
    return data;
  }

  /// Any site-API query (used for badges and chatter profiles).
  static Future<Map<String, dynamic>> query(String query,
          [Map<String, dynamic> variables = const {}, String? token]) =>
      _query(query, variables, token: token);

  static const _userFields = '''
    id
    login
    displayName
    profileImageURL(width: 150)
    stream {
      title
      viewersCount
      previewImageURL(width: 440, height: 248)
      createdAt
      game { displayName }
    }
  ''';

  /// Looks up to 100 channels in one request. Unknown logins are skipped.
  static Future<List<ChannelInfo>> getChannels(List<String> logins) async {
    if (logins.isEmpty) return [];
    final results = <ChannelInfo>[];
    for (var i = 0; i < logins.length; i += 100) {
      final chunk = logins.sublist(i, i + 100 > logins.length ? logins.length : i + 100);
      final data = await _query(
        'query(\$logins: [String!]) { users(logins: \$logins) { $_userFields } }',
        {'logins': chunk},
      );
      for (final u in jList(data['users'])) {
        final user = jMap(u);
        if (user != null) results.add(_parseUser(user));
      }
    }
    return results;
  }

  /// Channels [login] follows, via Twitch's site API (works with the
  /// twitch.tv login).
  static Future<List<String>> getFollowedLogins({
    required String login,
    required String token,
    int max = 2000,
  }) async {
    final out = <String>[];
    String? cursor;
    while (out.length < max) {
      // "My own follows" (currentUser), the way twitch.tv's Following page
      // asks: Twitch hides other people's follow lists, so looking yourself
      // up by name comes back empty.
      final res = await httpClient.post(
        Uri.parse('https://gql.twitch.tv/gql'),
        headers: {
          'Client-ID': webClientId,
          'Content-Type': 'application/json',
          'User-Agent': browserUserAgent,
          'Authorization': 'OAuth $token',
        },
        body: jsonEncode({
          'query': r'query($after: Cursor) { currentUser { login '
              r'follows(first: 100, after: $after) { edges { cursor node { login } } '
              r'pageInfo { hasNextPage } } } }',
          'variables': {'after': cursor},
        }),
      );
      final json = jMap(decodeJson(res, 'Loading your Twitch follows'));
      final me = jMap(jMap(json?['data'])?['currentUser']);
      final follows = jMap(me?['follows']);
      if (follows == null) {
        // Say why instead of showing an empty list.
        final errors = jList(json?['errors'])
            .map((e) => jStr(jMap(e)?['message']) ?? e.toString())
            .join('; ');
        throw ApiException(me == null
            ? 'Twitch did not accept the sign-in ($login)${errors.isEmpty ? '' : ': $errors'}'
            : 'Twitch did not return your follows${errors.isEmpty ? '' : ': $errors'}');
      }
      final edges = jList(follows['edges']);
      for (final e in edges) {
        final l = jStr(jMap(jMap(e)?['node'])?['login']);
        if (l != null) out.add(l);
      }
      final more = jMap(follows['pageInfo'])?['hasNextPage'] == true;
      cursor = edges.isEmpty ? null : jStr(jMap(edges.last)?['cursor']);
      if (!more || cursor == null) break;
    }
    return out;
  }

  static Future<ChannelInfo?> getChannel(String login) async {
    final list = await getChannels([login]);
    return list.isEmpty ? null : list.first;
  }

  /// The most-watched live channels right now.
  static Future<List<ChannelInfo>> getTopStreams({int first = 30}) async {
    final data = await _query(
      'query(\$first: Int) { streams(first: \$first) { edges { node { '
      'title viewersCount previewImageURL(width: 440, height: 248) createdAt '
      'game { displayName } '
      'broadcaster { id login displayName profileImageURL(width: 150) } '
      '} } } }',
      {'first': first},
    );
    final edges = jList(jMap(data['streams'])?['edges']);
    final out = <ChannelInfo>[];
    for (final e in edges) {
      final node = jMap(jMap(e)?['node']);
      final b = jMap(node?['broadcaster']);
      if (node == null || b == null) continue;
      out.add(ChannelInfo(
        platform: StreamPlatform.twitch,
        login: jStr(b['login']) ?? '',
        displayName: jStr(b['displayName']) ?? jStr(b['login']) ?? '',
        avatarUrl: jStr(b['profileImageURL']),
        userId: jStr(b['id']),
        isLive: true,
        title: jStr(node['title']),
        category: jStr(jMap(node['game'])?['displayName']),
        viewers: jInt(node['viewersCount']),
        thumbnailUrl: jStr(node['previewImageURL']),
        startedAt: jTime(node['createdAt']),
      ));
    }
    return out;
  }

  static ChannelInfo parseUser(Map<String, dynamic> u) => _parseUser(u);

  static ChannelInfo _parseUser(Map<String, dynamic> u) {
    final stream = jMap(u['stream']);
    return ChannelInfo(
      platform: StreamPlatform.twitch,
      login: jStr(u['login']) ?? '',
      displayName: jStr(u['displayName']) ?? jStr(u['login']) ?? '',
      avatarUrl: jStr(u['profileImageURL']),
      userId: jStr(u['id']),
      isLive: stream != null,
      title: jStr(stream?['title']),
      category: jStr(jMap(stream?['game'])?['displayName']),
      viewers: jInt(stream?['viewersCount']),
      thumbnailUrl: jStr(stream?['previewImageURL']),
      startedAt: jTime(stream?['createdAt']),
    );
  }
}

/// The official Helix API, used for things that need the user's login.
class TwitchHelix {
  /// Logins of every channel the user follows (live or not), newest first.
  static Future<List<String>> getFollowedLogins({
    required String clientId,
    required String accessToken,
    required String userId,
    int max = 2000,
  }) async {
    final out = <String>[];
    String? cursor;
    do {
      final uri = Uri.https('api.twitch.tv', '/helix/channels/followed', {
        'user_id': userId,
        'first': '100',
        if (cursor != null) 'after': cursor,
      });
      final res = await httpClient.get(uri, headers: {
        'Client-Id': clientId,
        'Authorization': 'Bearer $accessToken',
      });
      final json = jMap(decodeJson(res, 'Loading followed channels'));
      for (final f in jList(json?['data'])) {
        final login = jStr(jMap(f)?['broadcaster_login']);
        if (login != null) out.add(login);
      }
      cursor = jStr(jMap(json?['pagination'])?['cursor']);
    } while (cursor != null && out.length < max);
    return out;
  }

  /// Live channels the logged-in user follows.
  static Future<List<ChannelInfo>> getFollowedLive({
    required String clientId,
    required String accessToken,
    required String userId,
  }) async {
    final out = <ChannelInfo>[];
    String? cursor;
    do {
      final uri = Uri.https('api.twitch.tv', '/helix/streams/followed', {
        'user_id': userId,
        'first': '100',
        if (cursor != null) 'after': cursor,
      });
      final res = await httpClient.get(uri, headers: {
        'Client-Id': clientId,
        'Authorization': 'Bearer $accessToken',
      });
      final json = jMap(decodeJson(res, 'Loading followed channels'));
      for (final s in jList(json?['data'])) {
        final m = jMap(s);
        if (m == null) continue;
        out.add(ChannelInfo(
          platform: StreamPlatform.twitch,
          login: jStr(m['user_login']) ?? '',
          displayName: jStr(m['user_name']) ?? jStr(m['user_login']) ?? '',
          userId: jStr(m['user_id']),
          isLive: true,
          title: jStr(m['title']),
          category: jStr(m['game_name']),
          viewers: jInt(m['viewer_count']),
          thumbnailUrl: jStr(m['thumbnail_url'])
              ?.replaceAll('{width}', '440')
              .replaceAll('{height}', '248'),
        ));
      }
      cursor = jStr(jMap(json?['pagination'])?['cursor']);
    } while (cursor != null && out.length < 500);
    return out;
  }
}
