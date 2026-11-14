import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../core/services.dart';
import '../kick/kick_chat.dart';
import '../kick/kick_web.dart';
import '../twitch/twitch_api.dart';
import '../twitch/twitch_chat.dart';
import '../twitch/twitch_live_events.dart';
import 'badges.dart';
import 'chat_models.dart';
import 'third_party_emotes.dart';
import 'seventv_cosmetics.dart';

/// Owns one channel's chat connection, emotes and message list.
class ChatController extends ChangeNotifier {
  ChatController(this.channel);

  final ChannelInfo channel;

  /// Badge pictures for this channel (redraws chat once they're in).
  late final ChatBadges badges = ChatBadges(channel)..addListener(_badgesLoaded);

  void _badgesLoaded() {
    if (!_disposed) notifyListeners();
  }

  /// Redraws the chat when 7TV badges/paints come in.
  bool _listeningToCosmetics = false;

  static const maxMessages = 400;

  /// Newest first (the chat list is drawn bottom-up).
  final List<ChatMessage> messages = [];

  /// Messages that arrived while the user was scrolled up.
  final List<ChatMessage> _pending = [];
  bool _paused = false;

  ChatConnection status = ChatConnection.connecting;
  String? statusText;

  Map<String, Emote> _emotes = {};

  /// What's happening in the channel right now (shown above chat).
  ChatPoll? poll;
  ChatPrediction? prediction;
  ChatRaid? raid;
  Timer? _pollClear, _predictionClear;
  TwitchLiveEvents? _twitchLive;
  StreamSubscription<ChatEvent>? _twitchLiveSub;

  void _startTwitchLive(String? channelId) {
    if (_disposed || channel.platform != StreamPlatform.twitch || channelId == null || _twitchLive != null) return;
    final live = TwitchLiveEvents(channelId);
    _twitchLive = live;
    _twitchLiveSub = live.events.listen(_onEvent);
    unawaited(live.connect());
  }

  /// For the emote picker: 7TV channel and global emotes, and (loaded when
  /// the picker first opens) the Twitch/Kick emotes you can use.
  Map<String, Emote> sevenTvChannel = const {};
  Map<String, Emote> sevenTvGlobal = const {};

  /// Every add-on emote set (7TV, BetterTTV, FrankerFaceZ).
  EmoteSets emoteSets = const EmoteSets();
  List<(String, List<Emote>)> platformEmotes = const [];
  Future<void>? _platformEmotesLoad;

  /// Kick only takes its own emotes as [emote:id:name]; name → id.
  final Map<String, String> _kickEmoteIds = {};
  ChatClient? _client;
  StreamSubscription<ChatEvent>? _sub;
  bool _disposed = false;

  int get pendingCount => _pending.length;
  bool get canSend => _client?.canSend ?? false;
  bool get isPaused => _paused;

  /// All third-party emote names, for autocomplete.
  Iterable<String> get emoteNames => _emotes.keys;

  Future<void> start() async {
    if (!_listeningToCosmetics) {
      _listeningToCosmetics = true;
      SevenTvCosmetics.instance.addListener(_badgesLoaded);
    }
    unawaited(_loadEmotes());
    unawaited(badges.load());
    _startTwitchLive(channel.userId);
    await _connect();
  }

  String? _emoteUserId;

  Future<void> _loadEmotes([String? userId]) async {
    final id = userId ?? channel.userId;
    _emoteUserId = id;
    final sets = await EmoteSets.load(channel.platform, id);
    // A newer load (with the real channel id) superseded this one.
    if (_disposed || _emoteUserId != id) return;
    _emotes = sets.merged;
    emoteSets = sets;
    sevenTvGlobal = sets.sevenTvGlobal;
    sevenTvChannel = sets.sevenTvChannel;
    // Re-render messages that arrived before the emotes did.
    for (var i = 0; i < messages.length; i++) {
      messages[i] = messages[i].copyWith(fragments: applyEmotes(messages[i].fragments, _emotes));
    }
    notifyListeners();
  }

  Future<void> _connect() async {
    final ChatClient client;
    switch (channel.platform) {
      case StreamPlatform.twitch:
        final token = await Services.twitch.validAccessToken();
        final twitch = TwitchChatClient(
          channel: channel.login,
          token: token,
          login: token == null ? null : Services.twitch.login,
        );
        client = twitch;
        _attach(client);
        unawaited(twitch.loadHistory());
      case StreamPlatform.kick:
        final chatroomId = channel.kickChatroomId;
        if (chatroomId == null) {
          status = ChatConnection.error;
          statusText = 'This Kick channel has no chatroom.';
          notifyListeners();
          return;
        }
        final kick = KickChatClient(
          chatroomId: chatroomId,
          channelId: channel.kickChannelId,
          broadcasterUserId: int.tryParse(channel.userId ?? ''),
          auth: Services.kick,
        );
        client = kick;
        _attach(client);
        unawaited(kick.loadHistory());
    }
    if (_disposed) {
      client.dispose();
      return;
    }
    await client.connect();
  }

  void _attach(ChatClient client) {
    _client = client;
    _sub = client.events.listen(_onEvent);
  }

  void _onEvent(ChatEvent e) {
    if (_disposed) return;
    switch (e) {
      case ChatStatusEvent ev:
        status = ev.status;
        statusText = ev.text;
      case ChatPollEvent ev:
        poll = ev.poll;
        _pollClear?.cancel();
        final endsAt = ev.poll?.endsAt;
        if (ev.poll != null && endsAt != null && !ev.poll!.ended) {
          // Kick doesn't always say it ended; keep the results a bit after.
          _pollClear = Timer(endsAt.difference(DateTime.now()) + const Duration(seconds: 20), () {
            poll = null;
            if (!_disposed) notifyListeners();
          });
        } else if (ev.poll?.ended ?? false) {
          _pollClear = Timer(const Duration(seconds: 30), () {
            poll = null;
            if (!_disposed) notifyListeners();
          });
        }
      case ChatPredictionEvent ev:
        prediction = ev.prediction;
        _predictionClear?.cancel();
        if (ev.prediction?.isOver ?? false) {
          _predictionClear = Timer(const Duration(seconds: 60), () {
            prediction = null;
            if (!_disposed) notifyListeners();
          });
        }
      case ChatRaidEvent ev:
        raid = ev.raid;
      case ChatRoomIdEvent ev:
        _startTwitchLive(ev.roomId);
        // The channel lookup may have failed; chat still tells us the id.
        if (_emoteUserId == null) unawaited(_loadEmotes(ev.roomId));
      case ChatMessageEvent ev:
        _add(ev.message);
      case ChatHistoryEvent ev:
        // History is oldest first; insert it below anything already shown.
        final existing = messages.map((m) => m.id).toSet();
        for (final m in ev.messages) {
          if (existing.contains(m.id)) continue;
          SevenTvCosmetics.instance.request(channel.platform, m.authorId);
          messages.add(m.copyWith(fragments: applyEmotes(m.fragments, _emotes)));
        }
        messages.sort((a, b) => b.timestamp.compareTo(a.timestamp));
        _trim();
      case ChatDeleteEvent ev:
        for (final m in [...messages, ..._pending]) {
          if (m.id == ev.messageId) m.deleted = true;
        }
      case ChatClearEvent ev:
        final login = ev.userLogin;
        if (login == null) {
          messages.clear();
          _pending.clear();
          _add(ChatMessage(
            id: 'clear-${DateTime.now().microsecondsSinceEpoch}',
            author: '',
            authorLogin: '',
            fragments: const [],
            timestamp: DateTime.now(),
            systemText: 'Chat was cleared by a moderator',
          ));
          return;
        }
        for (final m in [...messages, ..._pending]) {
          if (m.authorLogin == login) m.deleted = true;
        }
    }
    notifyListeners();
  }

  void _add(ChatMessage m) {
    // Their 7TV badge and name paint, if they have one on.
    SevenTvCosmetics.instance.request(channel.platform, m.authorId);
    final processed = m.copyWith(fragments: applyEmotes(m.fragments, _emotes));
    if (_paused) {
      _pending.add(processed);
      if (_pending.length > maxMessages) _pending.removeAt(0);
    } else {
      messages.insert(0, processed);
      _trim();
    }
    notifyListeners();
  }

  void _trim() {
    if (messages.length > maxMessages) {
      messages.removeRange(maxMessages, messages.length);
    }
  }

  /// Called by the chat list when the user scrolls away from / back to the
  /// newest message.
  void setPaused(bool paused) {
    if (paused == _paused) return;
    _paused = paused;
    if (!paused && _pending.isNotEmpty) {
      messages.insertAll(0, _pending.reversed);
      _pending.clear();
      _trim();
    }
    // Always: the "Back to live chat" button comes and goes with this.
    notifyListeners();
  }

  Future<void> send(String text, {ChatMessage? replyTo}) async {
    final client = _client;
    if (client == null) return;
    var out = text;
    if (channel.platform == StreamPlatform.kick && _kickEmoteIds.isNotEmpty) {
      // Kick emotes picked by name go out the way kick.com sends them.
      out = text.split(' ').map((w) {
        final id = _kickEmoteIds[w];
        return id == null ? w : '[emote:$id:$w]';
      }).join(' ');
    }
    await client.send(out, replyTo: replyTo);
  }

  /// Every emote by name (for the picker's Recent row).
  Emote? emoteNamed(String name) {
    final e = _emotes[name];
    if (e != null) return e;
    for (final (_, list) in platformEmotes) {
      for (final x in list) {
        if (x.name == name) return x;
      }
    }
    return null;
  }

  /// The Twitch/Kick emotes you can use here (once; for the picker).
  Future<void> loadPlatformEmotes() => _platformEmotesLoad ??= () async {
        try {
          platformEmotes = channel.platform == StreamPlatform.twitch
              ? await _twitchUserEmotes()
              : await _kickEmotes();
        } catch (e) {
          debugPrint('Platform emotes failed: $e');
          _platformEmotesLoad = null;
        }
        if (!_disposed) notifyListeners();
      }();

  Future<List<(String, List<Emote>)>> _twitchUserEmotes() async {
    final token = await Services.twitch.validAccessToken();
    if (token == null) return const [];
    final data = await TwitchGql.query(
      'query { currentUser { emoteSets { id owner { displayName } emotes { id token } } } }',
      const {},
      token,
    );
    final groups = <String, List<Emote>>{};
    for (final set in jList(jMap(data['currentUser'])?['emoteSets'])) {
      final m = jMap(set);
      final owner = jStr(jMap(m?['owner'])?['displayName']) ?? 'Twitch';
      final list = groups.putIfAbsent(owner, () => []);
      for (final e in jList(m?['emotes'])) {
        final em = jMap(e);
        final id = jStr(em?['id']);
        final token = jStr(em?['token']);
        // Old text smileys like :) have regex names; skip those.
        if (id == null || token == null || token.contains('\\')) continue;
        list.add(Emote(
          name: token,
          url: 'https://static-cdn.jtvnw.net/emoticons/v2/$id/default/dark/2.0',
          source: EmoteSource.twitch,
        ));
      }
    }
    // The channel's own emotes first, then the rest by name.
    final keys = groups.keys.toList()
      ..sort((a, b) {
        final ca = a.toLowerCase() == channel.displayName.toLowerCase() ? 0 : 1;
        final cb = b.toLowerCase() == channel.displayName.toLowerCase() ? 0 : 1;
        return ca != cb ? ca - cb : a.toLowerCase().compareTo(b.toLowerCase());
      });
    return [
      for (final k in keys)
        if (groups[k]!.isNotEmpty) ('Twitch · $k', groups[k]!),
    ];
  }

  Future<List<(String, List<Emote>)>> _kickEmotes() async {
    final res = await KickWeb.instance.get('https://kick.com/emotes/${Uri.encodeComponent(channel.login)}');
    if (!res.ok) return const [];
    final out = <(String, List<Emote>)>[];
    for (final g in jList(res.json)) {
      final m = jMap(g);
      if (m == null) continue;
      final title = jStr(jMap(m['user'])?['username']) ?? jStr(m['name']) ?? jStr(m['slug']) ?? 'Kick';
      final list = <Emote>[];
      for (final e in jList(m['emotes'])) {
        final em = jMap(e);
        final id = jStr(em?['id']) ?? jInt(em?['id'])?.toString();
        final name = jStr(em?['name']);
        if (id == null || name == null) continue;
        _kickEmoteIds[name] = id;
        list.add(Emote(name: name, url: 'https://files.kick.com/emotes/$id/fullsize', source: EmoteSource.kick));
      }
      if (list.isNotEmpty) out.add(('Kick · $title', list));
    }
    return out;
  }

  ChatMessage? byId(String id) {
    for (final m in messages) {
      if (m.id == id) return m;
    }
    for (final m in _pending) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// The id of the first message of [m]'s conversation (its own id when
  /// it isn't part of one).
  String threadOf(ChatMessage m) {
    final reply = m.reply;
    if (reply == null) return m.id;
    if (reply.threadId != null) return reply.threadId!;
    // Kick only says the direct parent: walk up the replies Bolt has seen.
    var parentId = reply.parentId;
    for (var i = 0; i < 20; i++) {
      final parent = byId(parentId);
      final up = parent?.reply;
      if (parent == null || up == null) break;
      if (up.threadId != null) return up.threadId!;
      parentId = up.parentId;
    }
    return parentId;
  }

  /// The conversation started by [rootId], oldest first, as far as Bolt has
  /// seen it.
  List<ChatMessage> thread(String rootId) => [
        for (final m in messages.reversed)
          if (m.id == rootId || (m.reply != null && threadOf(m) == rootId)) m,
      ];

  @override
  void dispose() {
    _pollClear?.cancel();
    _predictionClear?.cancel();
    _twitchLiveSub?.cancel();
    _twitchLive?.close();
    badges.removeListener(_badgesLoaded);
    if (_listeningToCosmetics) SevenTvCosmetics.instance.removeListener(_badgesLoaded);
    _disposed = true;
    _sub?.cancel();
    _client?.dispose();
    super.dispose();
  }
}
