import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../core/videos_api.dart';
import 'badges.dart';
import 'chat_models.dart';
import 'seventv.dart';

/// Chat of a past broadcast, kept in step with the video's position.
class ChatReplay extends ChangeNotifier {
  ChatReplay(this.channel, this.video) {
    badges.addListener(notifyListeners);
    unawaited(badges.load());
    unawaited(_loadEmotes());
  }

  final ChannelInfo channel;
  final VideoItem video;
  late final ChatBadges badges = ChatBadges(channel);

  /// Messages up to the current position, newest first.
  List<ChatMessage> shown = const [];

  /// Why there's no chat, if there isn't.
  String? unavailable;
  bool loading = false;

  // Everything fetched so far around the current position, oldest first.
  final List<(Duration, ChatMessage)> _buffer = [];
  Duration _fetchedUntil = Duration.zero;
  Duration _bufferStart = Duration.zero;
  Duration _position = Duration.zero;
  int _generation = 0;
  bool _disposed = false;
  Map<String, Emote> _emotes = const {};

  bool get supported =>
      !video.isClip &&
      (video.platform == StreamPlatform.twitch ||
          (channel.kickChannelId != null && video.createdAt != null));

  Future<void> _loadEmotes() async {
    try {
      final r = await Future.wait([SevenTv.global(), SevenTv.forChannel(channel.platform, channel.userId)]);
      _emotes = {...r[0], ...r[1]};
      for (var i = 0; i < _buffer.length; i++) {
        final (t, m) = _buffer[i];
        _buffer[i] = (t, m.copyWith(fragments: applyEmotes(m.fragments, _emotes)));
      }
      _refresh();
    } catch (_) {}
  }

  /// The video is at [p] now.
  void seek(Duration p) {
    if (!supported || unavailable != null || _disposed) return;
    final jumped = p < _bufferStart || p > _fetchedUntil + const Duration(seconds: 30) || p < _position - const Duration(seconds: 5);
    _position = p;
    if (jumped) {
      _buffer.clear();
      _bufferStart = p;
      _fetchedUntil = p;
      _generation++;
      loading = false;
    }
    _refresh();
    if (!loading && p >= _fetchedUntil - const Duration(seconds: 10)) unawaited(_fetch());
  }

  Future<void> _fetch() async {
    final gen = _generation;
    final from = _fetchedUntil;
    loading = true;
    try {
      final batch = await _load(from);
      if (_disposed || gen != _generation) return;
      final known = {for (final (_, m) in _buffer) m.id};
      var latest = from;
      for (final (t, m) in batch) {
        if (t > latest) latest = t;
        if (t < from || known.contains(m.id)) continue;
        _buffer.add((t, m.copyWith(fragments: applyEmotes(m.fragments, _emotes))));
      }
      _buffer.sort((a, b) => a.$1.compareTo(b.$1));
      // A page with nothing newer: step forward so we don't ask again.
      _fetchedUntil = latest > from ? latest : from + const Duration(seconds: 15);
      // Don't hold on to hours of chat.
      if (_buffer.length > 3000) _buffer.removeRange(0, _buffer.length - 2000);
      _refresh();
    } catch (e) {
      debugPrint('Chat replay failed: $e');
      if (gen == _generation && _buffer.isEmpty) {
        unavailable = video.platform == StreamPlatform.twitch
            ? "Twitch didn't share this video's chat."
            : "Kick didn't share this video's chat.";
        notifyListeners();
      }
    } finally {
      if (gen == _generation) loading = false;
    }
  }

  Future<List<(Duration, ChatMessage)>> _load(Duration from) async {
    if (video.platform == StreamPlatform.twitch) return VideosApi.twitchReplay(video.id, from);
    final start = video.createdAt!;
    final msgs = await VideosApi.kickReplay(channel.kickChannelId!, start.add(from));
    return [for (final m in msgs) (m.timestamp.difference(start), m)];
  }

  void _refresh() {
    final out = <ChatMessage>[];
    for (var i = _buffer.length - 1; i >= 0 && out.length < 150; i--) {
      if (_buffer[i].$1 <= _position) out.add(_buffer[i].$2);
    }
    if (out.length != shown.length || (out.isNotEmpty && out.first.id != shown.first.id)) {
      shown = out;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    badges.removeListener(notifyListeners);
    badges.dispose();
    super.dispose();
  }
}
