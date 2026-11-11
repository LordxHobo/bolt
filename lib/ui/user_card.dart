import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../chat/chat_controller.dart';
import '../chat/chat_models.dart';
import '../core/models.dart';
import '../core/net.dart';
import '../kick/kick_web.dart';
import '../twitch/twitch_api.dart';
import 'channel_screen.dart';
import 'chat_view.dart';
import 'widgets.dart';

/// A chatter's profile, opened by tapping one of their messages.
Future<void> showUserCard(
  BuildContext context, {
  required ChatController controller,
  required ChatMessage message,
  ValueChanged<String>? onMention,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        minChildSize: 0.35,
        maxChildSize: 0.95,
        builder: (context, scroll) => _UserCard(
          controller: controller,
          message: message,
          scroll: scroll,
          onMention: onMention,
        ),
      ),
    );

/// What the platform tells us about a chatter.
class _Profile {
  String? avatarUrl;
  String? bio;
  DateTime? createdAt;
  int? followers;
  DateTime? followingSince;
  int? subMonths;
  List<ChatBadge> badges = const [];
}

class _UserCard extends StatefulWidget {
  const _UserCard({
    required this.controller,
    required this.message,
    required this.scroll,
    this.onMention,
  });

  final ChatController controller;
  final ChatMessage message;
  final ScrollController scroll;
  final ValueChanged<String>? onMention;

  @override
  State<_UserCard> createState() => _UserCardState();
}

class _UserCardState extends State<_UserCard> {
  late final Future<_Profile> _profile = _load();

  ChannelInfo get _channel => widget.controller.channel;
  String get _login => widget.message.authorLogin;

  Future<_Profile> _load() async {
    final p = _Profile()..badges = widget.message.badges;
    try {
      if (_channel.platform == StreamPlatform.twitch) {
        await _loadTwitch(p);
      } else {
        await _loadKick(p);
      }
    } catch (e) {
      debugPrint('Profile failed: $e');
    }
    return p;
  }

  Future<void> _loadTwitch(_Profile p) async {
    final data = await TwitchGql.query(
      r'query($login: String) { user(login: $login) { profileImageURL(width: 150) createdAt description followers { totalCount } } }',
      {'login': _login},
    );
    final u = jMap(data['user']);
    p.avatarUrl = jStr(u?['profileImageURL']);
    p.createdAt = DateTime.tryParse(jStr(u?['createdAt']) ?? '')?.toLocal();
    p.bio = jStr(u?['description']);
    p.followers = jInt(jMap(u?['followers'])?['totalCount']);
    // Twitch doesn't always share this; fine without it.
    try {
      final f = await TwitchGql.query(
        r'query($login: String, $channel: String) { user(login: $login) { follow(targetLogin: $channel) { followedAt } } }',
        {'login': _login, 'channel': _channel.login},
      );
      p.followingSince = DateTime.tryParse(
        jStr(jMap(jMap(f['user'])?['follow'])?['followedAt']) ?? '',
      )?.toLocal();
    } catch (_) {}
  }

  Future<void> _loadKick(_Profile p) async {
    final res = await KickWeb.instance.get(
      'https://kick.com/api/v2/channels/${Uri.encodeComponent(_channel.login)}'
      '/users/${Uri.encodeComponent(_login)}',
    );
    final u = jMap(res.json);
    if (!res.ok || u == null) return;
    p.avatarUrl = jStr(u['profile_pic']);
    p.followingSince = DateTime.tryParse(jStr(u['following_since']) ?? '')?.toLocal();
    p.subMonths = jInt(u['subscribed_for']);
    final badges = [
      for (final b in jList(u['badges']))
        if (jMap(b) case final m?)
          if (jStr(m['type']) case final type?) ChatBadge(type, '', jStr(m['text']), jInt(m['count'])),
    ];
    if (badges.isNotEmpty) p.badges = badges;
  }

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  static String _date(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

  static String _since(DateTime d) {
    final now = DateTime.now();
    var months = (now.year - d.year) * 12 + now.month - d.month;
    if (now.day < d.day) months--;
    if (months >= 12) {
      final years = months ~/ 12;
      return '${_date(d)} ($years ${years == 1 ? 'year' : 'years'})';
    }
    if (months >= 1) return '${_date(d)} ($months ${months == 1 ? 'month' : 'months'})';
    final days = now.difference(d).inDays;
    return '${_date(d)} ($days ${days == 1 ? 'day' : 'days'})';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final m = widget.message;
    final nameColor = ChatLine.readable(m.authorColor, theme.colorScheme.primary);
    final recent = [
      for (final x in widget.controller.messages)
        if (x.authorLogin == m.authorLogin && x.systemText == null) x,
    ].take(30).toList();

    return FutureBuilder<_Profile>(
      future: _profile,
      builder: (context, snap) {
        final p = snap.data;
        final badges = p?.badges ?? m.badges;
        Widget info(IconData icon, String text) => Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Icon(icon, size: 16, color: muted),
                  const SizedBox(width: 8),
                  Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
                ],
              ),
            );
        return ListView(
          controller: widget.scroll,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            Row(
              children: [
                ClipOval(
                  child: SizedBox(
                    width: 56,
                    height: 56,
                    child: p?.avatarUrl == null
                        ? Container(
                            color: _channel.platform.color.withValues(alpha: 0.25),
                            alignment: Alignment.center,
                            child: Text(m.author.isEmpty ? '?' : m.author[0].toUpperCase(),
                                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                          )
                        : CachedNetworkImage(imageUrl: p!.avatarUrl!, fit: BoxFit.cover),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(m.author,
                          style: theme.textTheme.titleLarge
                              ?.copyWith(color: nameColor, fontWeight: FontWeight.w800)),
                      if (m.author.toLowerCase() != m.authorLogin.toLowerCase())
                        Text(m.authorLogin, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                    ],
                  ),
                ),
                if (snap.connectionState != ConnectionState.done)
                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
            if (badges.isNotEmpty) ...[
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final b in badges)
                    if (ChatLine.badgeWidget(b, widget.controller.badges, 20) case final w?)
                      Container(
                        padding: const EdgeInsets.fromLTRB(6, 4, 10, 4),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            w,
                            const SizedBox(width: 6),
                            Text(widget.controller.badges.lookFor(b)?.title ?? b.title ?? b.set,
                                style: theme.textTheme.bodySmall),
                          ],
                        ),
                      ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            if (p?.createdAt != null) info(Icons.cake_outlined, 'Account created ${_date(p!.createdAt!)}'),
            if (p?.followingSince != null)
              info(Icons.favorite_border_rounded, 'Following since ${_since(p!.followingSince!)}'),
            if ((p?.subMonths ?? 0) > 0)
              info(Icons.star_border_rounded,
                  'Subscribed for ${p!.subMonths} ${p.subMonths == 1 ? 'month' : 'months'}'),
            if (p?.followers != null) info(Icons.people_outline_rounded, '${formatViewers(p!.followers)} followers'),
            if ((p?.bio ?? '').trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(p!.bio!.trim(), style: theme.textTheme.bodySmall?.copyWith(color: muted)),
              ),
            const SizedBox(height: 14),
            Row(
              children: [
                if (widget.onMention != null)
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: () {
                        Navigator.of(context).pop();
                        widget.onMention!(m.author.toLowerCase() == m.authorLogin.toLowerCase()
                            ? m.author
                            : m.authorLogin);
                      },
                      icon: const Icon(Icons.alternate_email_rounded, size: 18),
                      label: const Text('Mention'),
                    ),
                  ),
                if (widget.onMention != null) const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      final nav = Navigator.of(context);
                      nav.pop();
                      // In place of the stream you're watching (not on top of it).
                      nav.pushReplacement(
                        ChannelRoute(channel: ChannelRef(_channel.platform, m.authorLogin)),
                      );
                    },
                    icon: const Icon(Icons.live_tv_rounded, size: 18),
                    label: const Text('Open channel'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Text('Recent messages here', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            if (recent.isEmpty)
              Text('None since you opened the chat.', style: theme.textTheme.bodySmall?.copyWith(color: muted)),
            for (final x in recent)
              ChatLine(message: x, badges: widget.controller.badges, showTimestamp: true),
          ],
        );
      },
    );
  }
}
