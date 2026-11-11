import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../chat/chat_models.dart';
import '../core/models.dart';
import '../core/net.dart';
import '../core/services.dart';
import 'kick_web.dart';

class KickSignedOutException implements Exception {
  @override
  String toString() => 'Your Kick sign-in has expired. Sign in again in Settings.';
}

/// The channels you follow on Kick.
///
/// Kick's official API has no "followed channels" endpoint yet, so this uses
/// the one kick.com's own website calls, with your kick.com website login.
/// It's unofficial: Kick can change it at any time, so the parsing below is
/// deliberately forgiving.
class KickFollows {
  static const _endpoints = [
    'https://kick.com/api/v2/channels/followed',
    'https://kick.com/api/v1/channels/followed',
  ];

  static bool get isSignedIn => Services.settings.prefs.getBool('kickWebSignedIn') ?? false;

  /// Your Kick name, when known.
  static String? get username => Services.settings.prefs.getString('kickWebUsername');

  static Future<void> _loadUsername() async {
    try {
      final res = await KickWeb.instance.getSignedIn('https://kick.com/api/v1/user');
      final m = jMap(res.json);
      final name = jStr(m?['username']) ?? jStr(jMap(m?['user'])?['username']);
      if (res.ok && name != null) {
        await Services.settings.prefs.setString('kickWebUsername', name);
      }
    } catch (e) {
      debugPrint('Kick username lookup failed: $e');
    }
  }

  /// Sends a chat message the way kick.com does, with your kick.com login.
  static Future<void> sendChat({required int chatroomId, required String content, ChatMessage? replyTo}) async {
    final res = await KickWeb.instance.requestSignedIn(
      'https://kick.com/api/v2/messages/send/$chatroomId',
      method: 'POST',
      jsonBody: replyTo == null
          ? {'content': content, 'type': 'message'}
          : {
              'content': content,
              'type': 'reply',
              'metadata': {
                'original_message': {'id': replyTo.id, 'content': replyTo.plainText},
                'original_sender': {
                  if (replyTo.authorId != null) 'id': int.tryParse(replyTo.authorId!) ?? replyTo.authorId,
                  'username': replyTo.author,
                },
              },
            },
    );
    if (res.status == 401) {
      await _setSignedIn(false);
      throw KickSignedOutException();
    }
    if (!res.ok) {
      final m = jMap(res.json);
      final detail = jStr(m?['message']) ?? jStr(jMap(m?['status'])?['message']) ?? '';
      throw ApiException('Kick refused the message (HTTP ${res.status}'
          '${detail.isEmpty ? '' : ': $detail'})');
    }
  }

  static Future<void> _setSignedIn(bool v) async {
    await Services.settings.prefs.setBool('kickWebSignedIn', v);
    Services.settings.notifyChanged();
  }

  /// Checks the sign-in right after the user finished the kick.com login page.
  static Future<bool> confirmSignIn() async {
    await KickWeb.instance.reloadPage();
    try {
      await load();
      await _loadUsername();
      await _setSignedIn(true);
      return true;
    } catch (e) {
      debugPrint('Kick follows check failed: $e');
      await _setSignedIn(false);
      return false;
    }
  }

  static Future<void> signOut() async {
    try {
      await CookieManager.instance().deleteCookies(url: WebUri('https://kick.com'));
    } catch (e) {
      debugPrint('Clearing kick.com cookies failed: $e');
    }
    await KickWeb.instance.reloadPage();
    await Services.settings.prefs.remove('kickWebUsername');
    await _setSignedIn(false);
  }

  /// Loads every followed channel (live ones carry viewers and titles).
  static Future<List<ChannelInfo>> load() async {
    Object? lastError;
    for (final base in _endpoints) {
      try {
        final out = <ChannelInfo>[];
        final seen = <String>{};
        String? cursor;
        for (var page = 0; page < 20; page++) {
          final url = cursor == null ? base : '$base?cursor=${Uri.encodeQueryComponent(cursor)}';
          final res = await KickWeb.instance.getSignedIn(url);
          if (res.status == 401 || res.status == 403) throw KickSignedOutException();
          if (res.status == 404) throw ApiException('Not found', status: 404);
          if (!res.ok) throw ApiException('kick.com returned HTTP ${res.status}', status: res.status);
          final json = res.json;
          final items = _items(json);
          for (final raw in items) {
            final info = _parse(raw);
            if (info != null && seen.add(info.login)) out.add(info);
          }
          cursor = _nextCursor(json);
          if (cursor == null || items.isEmpty) break;
        }
        return out;
      } on KickSignedOutException {
        await _setSignedIn(false);
        rethrow;
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? ApiException('Could not load your Kick follows');
  }

  static List<dynamic> _items(Object? json) {
    if (json is List) return json;
    final m = jMap(json);
    if (m == null) return const [];
    for (final key in ['channels', 'data', 'followed', 'items']) {
      final v = m[key];
      if (v is List) return v;
      final inner = jMap(v);
      if (inner != null) {
        for (final k2 in ['channels', 'data', 'items']) {
          if (inner[k2] is List) return inner[k2] as List;
        }
      }
    }
    return const [];
  }

  static String? _nextCursor(Object? json) {
    final m = jMap(json);
    if (m == null) return null;
    final v = m['nextCursor'] ?? m['next_cursor'] ?? m['cursor'] ?? jMap(m['meta'])?['next_cursor'];
    if (v == null || v == false) return null;
    final s = v.toString();
    return s.isEmpty || s == 'null' ? null : s;
  }

  /// Kick sends the stream preview in a few shapes.
  static String? _thumbnail(Map<String, dynamic>? m) {
    if (m == null) return null;
    final t = m['thumbnail'];
    final tm = jMap(t);
    return jStr(tm?['src']) ?? jStr(tm?['url']) ?? jStr(tm?['responsive']) ?? (t is String ? jStr(t) : null);
  }

  static ChannelInfo? _parse(Object? raw) {
    final m = jMap(raw);
    if (m == null) return null;
    final channel = jMap(m['channel']) ?? m;
    final user = jMap(channel['user']) ?? jMap(m['user']);
    final live = jMap(channel['livestream']) ?? jMap(m['livestream']) ?? jMap(m['current_livestream']);
    final slug = jStr(m['channel_slug']) ?? jStr(channel['slug']) ?? jStr(m['slug']) ??
        jStr(user?['username'])?.toLowerCase();
    if (slug == null) return null;
    final name = jStr(m['user_username']) ?? jStr(user?['username']) ?? jStr(m['username']) ?? slug;
    final isLive = m['is_live'] == true ||
        channel['is_live'] == true ||
        (live != null && live['is_live'] != false);
    final categories = jList(live?['categories']);
    return ChannelInfo(
      platform: StreamPlatform.kick,
      login: slug.toLowerCase(),
      displayName: name,
      avatarUrl: jStr(m['profile_picture']) ?? jStr(user?['profile_pic']) ?? jStr(user?['profilepic']),
      userId: jStr(channel['user_id']) ?? jStr(user?['id']),
      isLive: isLive,
      title: jStr(m['session_title']) ?? jStr(live?['session_title']),
      category: jStr(m['category_name']) ??
          (categories.isEmpty ? null : jStr(jMap(categories.first)?['name'])),
      viewers: jInt(m['viewer_count']) ?? jInt(live?['viewer_count']) ?? jInt(live?['viewers']),
      thumbnailUrl: _thumbnail(live) ?? _thumbnail(m),
      kickChannelId: jInt(channel['id']),
    );
  }
}
