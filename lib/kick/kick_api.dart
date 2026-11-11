import '../chat/chat_models.dart';
import '../core/models.dart';
import '../core/net.dart';
import 'kick_web.dart';

class KickApi {
  /// Channel details, including the HLS playback URL and the chatroom id.
  /// Returns null when the channel doesn't exist.
  static Future<ChannelInfo?> getChannel(String slug) async {
    final res = await KickWeb.instance
        .get('https://kick.com/api/v2/channels/${Uri.encodeComponent(slug)}');
    if (res.status == 404) return null;
    if (!res.ok) throw ApiException('Kick returned HTTP ${res.status}', status: res.status);
    final j = jMap(res.json);
    if (j == null) throw ApiException('Kick returned an unexpected response');
    return parseChannel(j, fallbackSlug: slug);
  }

  static ChannelInfo parseChannel(Map<String, dynamic> j, {required String fallbackSlug}) {
    final user = jMap(j['user']);
    final live = jMap(j['livestream']);
    final thumb = live?['thumbnail'];
    String? thumbUrl;
    if (thumb is String) {
      thumbUrl = thumb;
    } else {
      final t = jMap(thumb);
      thumbUrl = jStr(t?['url']) ?? jStr(t?['src']);
    }
    final categories = jList(live?['categories']);
    final slug = jStr(j['slug']) ?? fallbackSlug;
    return ChannelInfo(
      platform: StreamPlatform.kick,
      login: slug,
      displayName: jStr(user?['username']) ?? slug,
      avatarUrl: jStr(user?['profile_pic']) ?? jStr(user?['profilepic']),
      userId: jStr(j['user_id']) ?? jStr(user?['id']),
      isLive: live != null && (live['is_live'] != false),
      title: jStr(live?['session_title']),
      category: categories.isEmpty ? null : jStr(jMap(categories.first)?['name']),
      viewers: jInt(live?['viewer_count']) ?? jInt(live?['viewers']),
      thumbnailUrl: thumbUrl,
      kickChannelId: jInt(j['id']),
      kickChatroomId: jInt(jMap(j['chatroom'])?['id']),
      playbackUrl: jStr(j['playback_url']),
    );
  }

  /// The live stream's current preview picture (the one kick.com shows on
  /// its stream cards), or null when not live / not available.
  static Future<String?> getLivePreview(String slug) async {
    final res = await KickWeb.instance
        .get('https://kick.com/api/v2/channels/${Uri.encodeComponent(slug)}/livestream');
    if (res.ok) {
      final j = jMap(res.json);
      final data = jMap(j?['data']) ?? j;
      final t = data?['thumbnail'];
      final tm = jMap(t);
      final url = jStr(tm?['src']) ?? jStr(tm?['url']) ?? (t is String ? jStr(t) : null);
      if (url != null && url.isNotEmpty) return url;
    }
    // Older shape: the channel's own details.
    return (await getChannel(slug))?.thumbnailUrl;
  }

  /// Recent chat messages (oldest first).
  static Future<List<ChatMessage>> getRecentMessages(int channelId) async {
    final res = await KickWeb.instance
        .get('https://kick.com/api/v2/channels/$channelId/messages');
    if (!res.ok) return [];
    final j = jMap(res.json);
    final list = jList(jMap(j?['data'])?['messages'] ?? j?['messages']);
    final out = <ChatMessage>[];
    for (final raw in list) {
      final m = jMap(raw);
      if (m == null) continue;
      final type = jStr(m['type']);
      if (type != null && type != 'message' && type != 'reply') continue;
      final msg = parseChatMessage(m, history: true);
      if (msg != null) out.add(msg);
    }
    out.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return out;
  }

  /// Parses a Kick chat message payload (website and realtime share the shape).
  static ChatMessage? parseChatMessage(Map<String, dynamic> d, {bool history = false}) {
    final content = jStr(d['content']);
    if (content == null) return null;
    final sender = jMap(d['sender']) ?? const {};
    final identity = jMap(sender['identity']);
    final roles = <String>{};
    final badges = <ChatBadge>[];
    for (final b in jList(identity?['badges'])) {
      final m = jMap(b);
      final type = jStr(m?['type']);
      if (type == null) continue;
      roles.add(type);
      badges.add(ChatBadge(type, '', jStr(m?['text']), jInt(m?['count'])));
    }
    final created = DateTime.tryParse(jStr(d['created_at']) ?? '')?.toLocal();
    final username = jStr(sender['username']) ?? 'unknown';
    ChatReply? reply;
    final meta = jMap(d['metadata']);
    final original = jMap(meta?['original_message']);
    final originalSender = jMap(meta?['original_sender']);
    final parentId = jStr(original?['id']);
    if (parentId != null && parentId.isNotEmpty) {
      final parentName = jStr(originalSender?['username']);
      reply = ChatReply(
        parentId: parentId,
        parentLogin: (jStr(originalSender?['slug']) ?? parentName)?.toLowerCase(),
        parentName: parentName,
        parentBody: jStr(original?['content'])
            ?.replaceAllMapped(RegExp(r'\[emote:\d+:([^\]]*)\]'), (m) => m.group(1) ?? ''),
        parentUserId: jStr(originalSender?['id']) ?? jInt(originalSender?['id'])?.toString(),
      );
    }
    return ChatMessage(
      id: jStr(d['id']) ?? 'kick-${DateTime.now().microsecondsSinceEpoch}',
      author: username,
      authorLogin: (jStr(sender['slug']) ?? username).toLowerCase(),
      authorColor: parseHexColor(jStr(identity?['color'])),
      roles: roles,
      badges: badges,
      authorId: jStr(sender['id']) ?? jInt(sender['id'])?.toString(),
      reply: reply,
      fragments: parseKickContent(content),
      timestamp: created ?? DateTime.now(),
      isHistory: history,
    );
  }
}
