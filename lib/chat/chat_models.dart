import 'package:flutter/material.dart';

enum EmoteSource { twitch, kick, sevenTv, bttv, ffz }

extension EmoteSourceX on EmoteSource {
  String get label => switch (this) {
        EmoteSource.twitch => 'Twitch',
        EmoteSource.kick => 'Kick',
        EmoteSource.sevenTv => '7TV',
        EmoteSource.bttv => 'BetterTTV',
        EmoteSource.ffz => 'FrankerFaceZ',
      };
}

class Emote {
  final String name;
  final String url;
  final double? width;
  final double? height;
  final bool zeroWidth;
  final EmoteSource source;

  /// The emote's id on its service, when known.
  final String? id;

  /// Global (everywhere) or this channel's; null when unknown.
  final bool? isGlobal;

  /// Who made or uploaded it (7TV, BetterTTV, FrankerFaceZ).
  final String? creator;

  const Emote({
    required this.name,
    required this.url,
    required this.source,
    this.width,
    this.height,
    this.zeroWidth = false,
    this.id,
    this.isGlobal,
    this.creator,
  });

  /// The id, also for emotes built before ids were kept (from the address).
  String? get resolvedId {
    if (id != null) return id;
    final m = switch (source) {
      EmoteSource.twitch => RegExp(r'/emoticons/v2/([^/]+)/').firstMatch(url),
      EmoteSource.kick => RegExp(r'/emotes/(\d+)').firstMatch(url),
      EmoteSource.sevenTv => RegExp(r'/emote/([^/]+)/').firstMatch(url),
      EmoteSource.bttv => RegExp(r'/emote/([^/]+)/').firstMatch(url),
      EmoteSource.ffz => RegExp(r'/emote/(\d+)/').firstMatch(url),
    };
    return m?.group(1);
  }
}

/// A piece of a chat message: either plain text or an emote (optionally with
/// zero-width emotes stacked on top of it).
sealed class Fragment {
  const Fragment();
}

class TextFragment extends Fragment {
  final String text;
  const TextFragment(this.text);
}

class EmoteFragment extends Fragment {
  final Emote emote;
  final List<Emote> overlays;
  EmoteFragment(this.emote, [List<Emote>? overlays]) : overlays = overlays ?? [];
}

/// A badge shown before a chatter's name: Twitch's `set/version` (e.g.
/// `subscriber/3012`), or Kick's badge type (e.g. `moderator`).
class ChatBadge {
  final String set;
  final String version;

  /// Words for it from the platform, when sent (e.g. "Subscriber").
  final String? title;

  /// Months for subscriber badges, gift count for gifter badges.
  final int? count;

  const ChatBadge(this.set, [this.version = '', this.title, this.count]);
}

/// The message a reply answers.
class ChatReply {
  final String parentId;
  final String? parentLogin;
  final String? parentName;
  final String? parentBody;

  /// The first message of the conversation (Twitch says; for Kick it's
  /// worked out from the messages Bolt has seen).
  final String? threadId;

  /// The parent author's account id (Kick needs it to send a reply).
  final String? parentUserId;

  const ChatReply({
    required this.parentId,
    this.parentLogin,
    this.parentName,
    this.parentBody,
    this.threadId,
    this.parentUserId,
  });
}

class ChatMessage {
  final String id;
  final String author;
  final String authorLogin;
  final Color? authorColor;
  final Set<String> roles;
  final List<ChatBadge> badges;

  /// The chatter's account id on the platform, when known.
  final String? authorId;

  /// Set when this message replies to another one.
  final ChatReply? reply;
  final List<Fragment> fragments;
  final DateTime timestamp;
  final bool isAction;

  /// Text for system lines (subs, raids, notices). When set, [author] may be empty.
  final String? systemText;
  final bool isHistory;
  bool deleted = false;

  ChatMessage({
    required this.id,
    required this.author,
    required this.authorLogin,
    required this.fragments,
    required this.timestamp,
    this.authorColor,
    this.roles = const {},
    this.badges = const [],
    this.authorId,
    this.reply,
    this.isAction = false,
    this.systemText,
    this.isHistory = false,
  });

  /// The message as plain text (emotes by name).
  String get plainText => fragments
      .map((f) => switch (f) {
            TextFragment(:final text) => text,
            EmoteFragment(:final emote) => emote.name,
          })
      .join();

  ChatMessage copyWith({List<Fragment>? fragments}) => ChatMessage(
        id: id,
        author: author,
        authorLogin: authorLogin,
        fragments: fragments ?? this.fragments,
        timestamp: timestamp,
        authorColor: authorColor,
        roles: roles,
        badges: badges,
        authorId: authorId,
        reply: reply,
        isAction: isAction,
        systemText: systemText,
        isHistory: isHistory,
      )..deleted = deleted;
}

enum ChatConnection { connecting, connected, disconnected, error }

sealed class ChatEvent {
  const ChatEvent();
}

class ChatMessageEvent extends ChatEvent {
  final ChatMessage message;
  const ChatMessageEvent(this.message);
}

class ChatHistoryEvent extends ChatEvent {
  /// Oldest first.
  final List<ChatMessage> messages;
  const ChatHistoryEvent(this.messages);
}

class ChatDeleteEvent extends ChatEvent {
  final String messageId;
  const ChatDeleteEvent(this.messageId);
}

class ChatClearEvent extends ChatEvent {
  /// When null, the whole chat was cleared.
  final String? userLogin;
  const ChatClearEvent([this.userLogin]);
}

/// The platform's numeric id for the channel (Twitch ROOMSTATE room-id).
class ChatRoomIdEvent extends ChatEvent {
  final String roomId;
  const ChatRoomIdEvent(this.roomId);
}

/// A channel poll (null [ChatPollEvent.poll] = gone).
class ChatPoll {
  final String id;
  final String title;
  final List<(String title, int votes)> options;
  final DateTime? endsAt;
  final bool ended;
  const ChatPoll({required this.id, required this.title, required this.options, this.endsAt, this.ended = false});

  int get totalVotes => options.fold(0, (a, o) => a + o.$2);
}

/// A channel-points (Twitch) or Kick prediction.
class ChatPrediction {
  final String id;
  final String title;

  /// ACTIVE (open), LOCKED, RESOLVED or CANCELED.
  final String status;
  final List<({String id, String title, int points, int users})> outcomes;
  final DateTime? locksAt;
  final String? winnerId;
  const ChatPrediction({
    required this.id,
    required this.title,
    required this.status,
    required this.outcomes,
    this.locksAt,
    this.winnerId,
  });

  bool get isOpen => status == 'ACTIVE';
  bool get isOver => status == 'RESOLVED' || status == 'CANCELED' || status == 'CANCELLED';
}

/// The channel is raiding (Twitch) or hosting (Kick) another channel.
class ChatRaid {
  final String targetLogin;
  final String targetName;
  final int? viewers;

  /// True once it has actually happened (Twitch counts down first).
  final bool started;
  const ChatRaid({required this.targetLogin, required this.targetName, this.viewers, this.started = false});
}

class ChatPollEvent extends ChatEvent {
  final ChatPoll? poll;
  const ChatPollEvent(this.poll);
}

class ChatPredictionEvent extends ChatEvent {
  final ChatPrediction? prediction;
  const ChatPredictionEvent(this.prediction);
}

class ChatRaidEvent extends ChatEvent {
  final ChatRaid? raid;
  const ChatRaidEvent(this.raid);
}

class ChatStatusEvent extends ChatEvent {
  final ChatConnection status;
  final String? text;
  const ChatStatusEvent(this.status, [this.text]);
}

abstract class ChatClient {
  Stream<ChatEvent> get events;
  Future<void> connect();

  /// Sends [text]; with [replyTo], as a reply to that message.
  Future<void> send(String text, {ChatMessage? replyTo});
  bool get canSend;
  void dispose();
}

Color? parseHexColor(String? hex) {
  if (hex == null) return null;
  var h = hex.trim();
  if (h.startsWith('#')) h = h.substring(1);
  if (h.length != 6) return null;
  final v = int.tryParse(h, radix: 16);
  return v == null ? null : Color(0xFF000000 | v);
}

/// Splits Kick's inline emote syntax `[emote:12345:name]` into fragments.
List<Fragment> parseKickContent(String content) {
  final out = <Fragment>[];
  final re = RegExp(r'\[emote:(\d+):([^\]]*)\]');
  var cursor = 0;
  for (final m in re.allMatches(content)) {
    if (m.start > cursor) out.add(TextFragment(content.substring(cursor, m.start)));
    out.add(EmoteFragment(Emote(
      name: m.group(2) ?? 'emote',
      url: 'https://files.kick.com/emotes/${m.group(1)}/fullsize',
      source: EmoteSource.kick,
    )));
    cursor = m.end;
  }
  if (cursor < content.length) out.add(TextFragment(content.substring(cursor)));
  return out;
}

/// Replaces words in text fragments with third-party emotes, and stacks
/// zero-width emotes on top of the emote before them.
List<Fragment> applyEmotes(List<Fragment> input, Map<String, Emote> emotes) {
  final out = <Fragment>[];
  void addText(String t) {
    if (t.isEmpty) return;
    final last = out.isEmpty ? null : out.last;
    if (last is TextFragment) {
      out[out.length - 1] = TextFragment(last.text + t);
    } else {
      out.add(TextFragment(t));
    }
  }

  void addEmote(Emote e) {
    if (e.zeroWidth) {
      // Find the previous emote, skipping the single space between them.
      var i = out.length - 1;
      if (i >= 0 && out[i] is TextFragment && (out[i] as TextFragment).text.trim().isEmpty) {
        i--;
      }
      if (i >= 0 && out[i] is EmoteFragment) {
        (out[i] as EmoteFragment).overlays.add(e);
        out.removeRange(i + 1, out.length);
        return;
      }
    }
    out.add(EmoteFragment(e));
  }

  for (final f in input) {
    if (f is EmoteFragment) {
      out.add(f);
      continue;
    }
    final text = (f as TextFragment).text;
    if (emotes.isEmpty) {
      addText(text);
      continue;
    }
    // Keep the original spacing: split into words and whitespace runs.
    for (final m in RegExp(r'\S+|\s+').allMatches(text)) {
      final token = m.group(0)!;
      final emote = token.trim().isEmpty ? null : emotes[token];
      if (emote != null) {
        addEmote(emote);
      } else {
        addText(token);
      }
    }
  }
  return out;
}
