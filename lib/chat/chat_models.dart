import 'package:flutter/material.dart';

enum EmoteSource { twitch, kick, sevenTv }

class Emote {
  final String name;
  final String url;
  final double? width;
  final double? height;
  final bool zeroWidth;
  final EmoteSource source;

  const Emote({
    required this.name,
    required this.url,
    required this.source,
    this.width,
    this.height,
    this.zeroWidth = false,
  });
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

class ChatMessage {
  final String id;
  final String author;
  final String authorLogin;
  final Color? authorColor;
  final Set<String> roles;
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
    this.isAction = false,
    this.systemText,
    this.isHistory = false,
  });

  ChatMessage copyWith({List<Fragment>? fragments}) => ChatMessage(
        id: id,
        author: author,
        authorLogin: authorLogin,
        fragments: fragments ?? this.fragments,
        timestamp: timestamp,
        authorColor: authorColor,
        roles: roles,
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

class ChatStatusEvent extends ChatEvent {
  final ChatConnection status;
  final String? text;
  const ChatStatusEvent(this.status, [this.text]);
}

abstract class ChatClient {
  Stream<ChatEvent> get events;
  Future<void> connect();
  Future<void> send(String text);
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
