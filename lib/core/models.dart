import 'package:flutter/material.dart';

/// Short commit id of this build (set by CI), shown in Settings and on the
/// startup error screen so it's clear which build is installed.
const relayBuild = String.fromEnvironment('RELAY_BUILD', defaultValue: 'dev');

enum StreamPlatform { twitch, kick }

extension StreamPlatformX on StreamPlatform {
  String get label => switch (this) {
        StreamPlatform.twitch => 'Twitch',
        StreamPlatform.kick => 'Kick',
      };

  Color get color => switch (this) {
        StreamPlatform.twitch => const Color(0xFF9146FF),
        StreamPlatform.kick => const Color(0xFF53FC18),
      };

  /// Text color that reads well on top of [color].
  Color get onColor => switch (this) {
        StreamPlatform.twitch => Colors.white,
        StreamPlatform.kick => Colors.black,
      };

  static StreamPlatform parse(String value) => StreamPlatform.values
      .firstWhere((p) => p.name == value, orElse: () => StreamPlatform.twitch);
}

/// A channel the user can open, identified by platform + login/slug.
@immutable
class ChannelRef {
  final StreamPlatform platform;
  final String login;

  ChannelRef(this.platform, String login) : login = normalizeLogin(login);

  static String normalizeLogin(String raw) {
    var s = raw.trim().toLowerCase();
    // Accept pasted URLs like https://twitch.tv/name or kick.com/name.
    final uri = Uri.tryParse(s.contains('://') ? s : 'https://$s');
    if (uri != null &&
        (uri.host.endsWith('twitch.tv') || uri.host.endsWith('kick.com')) &&
        uri.pathSegments.isNotEmpty) {
      s = uri.pathSegments.firstWhere((p) => p.isNotEmpty, orElse: () => s);
    }
    if (s.startsWith('@')) s = s.substring(1);
    return s;
  }

  String get key => '${platform.name}:$login';

  Map<String, dynamic> toJson() => {'p': platform.name, 'l': login};

  static ChannelRef fromJson(Map<String, dynamic> json) =>
      ChannelRef(StreamPlatformX.parse(json['p'] as String), json['l'] as String);

  @override
  bool operator ==(Object other) =>
      other is ChannelRef && other.platform == platform && other.login == login;

  @override
  int get hashCode => Object.hash(platform, login);
}

/// Everything the UI needs to show a channel and play it.
class ChannelInfo {
  final StreamPlatform platform;
  final String login;
  final String displayName;
  final String? avatarUrl;

  /// Twitch user id, or Kick user id (used for 7TV and Kick chat sending).
  final String? userId;

  final bool isLive;
  final String? title;
  final String? category;
  final int? viewers;
  final String? thumbnailUrl;

  /// When the current stream started (for "live for 2h 14m").
  final DateTime? startedAt;

  // Kick only.
  final int? kickChannelId;
  final int? kickChatroomId;
  final String? playbackUrl;

  const ChannelInfo({
    required this.platform,
    required this.login,
    required this.displayName,
    this.avatarUrl,
    this.userId,
    this.isLive = false,
    this.title,
    this.category,
    this.viewers,
    this.thumbnailUrl,
    this.startedAt,
    this.kickChannelId,
    this.kickChatroomId,
    this.playbackUrl,
  });

  ChannelRef get ref => ChannelRef(platform, login);

  ChannelInfo copyWith({
    String? avatarUrl,
    bool? isLive,
    String? title,
    String? category,
    int? viewers,
    String? thumbnailUrl,
    DateTime? startedAt,
  }) =>
      ChannelInfo(
        platform: platform,
        login: login,
        displayName: displayName,
        avatarUrl: avatarUrl ?? this.avatarUrl,
        userId: userId,
        isLive: isLive ?? this.isLive,
        title: title ?? this.title,
        category: category ?? this.category,
        viewers: viewers ?? this.viewers,
        thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
        startedAt: startedAt ?? this.startedAt,
        kickChannelId: kickChannelId,
        kickChatroomId: kickChatroomId,
        playbackUrl: playbackUrl,
      );

  /// A placeholder used while the real info is loading or when it failed.
  factory ChannelInfo.placeholder(ChannelRef ref) => ChannelInfo(
        platform: ref.platform,
        login: ref.login,
        displayName: ref.login,
      );
}

String formatViewers(int? viewers) {
  if (viewers == null) return '';
  if (viewers >= 1000000) return '${(viewers / 1000000).toStringAsFixed(1)}M';
  if (viewers >= 10000) return '${(viewers / 1000).toStringAsFixed(0)}K';
  if (viewers >= 1000) return '${(viewers / 1000).toStringAsFixed(1)}K';
  return '$viewers';
}

/// Small helpers for reading loosely typed JSON.
String? jStr(Object? v) {
  if (v == null) return null;
  if (v is String) return v.isEmpty ? null : v;
  return v.toString();
}

/// Parses a time from the APIs (ISO, or Kick's "2024-01-01 12:00:00" in UTC).
DateTime? jTime(Object? v) {
  final t = jStr(v);
  if (t == null || t.isEmpty) return null;
  var text = t.contains('T') ? t : t.replaceFirst(' ', 'T');
  if (!RegExp(r'(Z|[+-]\d\d:?\d\d)$').hasMatch(text)) text = '${text}Z';
  return DateTime.tryParse(text)?.toLocal();
}

/// "2h 14m" / "45m" since [start].
String formatUptime(DateTime start) {
  final d = DateTime.now().difference(start);
  if (d.isNegative) return '0m';
  final h = d.inHours, m = d.inMinutes % 60;
  return h > 0 ? '${h}h ${m}m' : '${m}m';
}

num? jNum(Object? v) => v is num ? v : (v is String ? num.tryParse(v) : null);

int? jInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

Map<String, dynamic>? jMap(Object? v) =>
    v is Map ? v.cast<String, dynamic>() : null;

List<dynamic> jList(Object? v) => v is List ? v : const [];
