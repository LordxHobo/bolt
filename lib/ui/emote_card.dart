import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chat/chat_models.dart';
import '../core/models.dart';
import '../twitch/twitch_api.dart';

/// What an emote is called and where it comes from.
Future<void> showEmoteCard(BuildContext context, Emote emote, {List<Emote> overlays = const []}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => _EmoteCard(emote: emote, overlays: overlays),
  );
}

/// Twitch emote details, looked up once per emote.
class _TwitchEmoteInfo {
  final String? type;
  final String? ownerLogin;
  final String? ownerName;
  const _TwitchEmoteInfo(this.type, this.ownerLogin, this.ownerName);

  static final _cache = <String, Future<_TwitchEmoteInfo?>>{};

  static Future<_TwitchEmoteInfo?> lookup(String id) => _cache[id] ??= () async {
        try {
          final data = await TwitchGql.query(
            r'query($id: ID!) { emote(id: $id) { type owner { login displayName } } }',
            {'id': id},
          );
          final e = jMap(data['emote']);
          if (e == null) return null;
          final owner = jMap(e['owner']);
          return _TwitchEmoteInfo(jStr(e['type']), jStr(owner?['login']), jStr(owner?['displayName']));
        } catch (_) {
          _cache.remove(id);
          return null;
        }
      }();

  bool get isGlobal => switch (type) {
        'GLOBALS' || 'SMILIES' || 'TWO_FACTOR' => true,
        _ => ownerLogin == 'twitch',
      };

  String get kind => switch (type) {
        'SUBSCRIPTIONS' => 'Subscriber emote',
        'FOLLOWER' => 'Follower emote',
        'BITS_BADGE_TIERS' => 'Bits reward emote',
        'CHANNEL_POINTS' => 'Channel points emote',
        'PRIME' => 'Prime Gaming emote',
        'TURBO' => 'Turbo emote',
        'HYPE_TRAIN' => 'Hype Train emote',
        'LIMITED_TIME' => 'Limited-time emote',
        'MEGA_COMMERCE' => 'Event emote',
        _ => isGlobal ? 'Global emote' : 'Channel emote',
      };
}

class _EmoteCard extends StatefulWidget {
  const _EmoteCard({required this.emote, required this.overlays});

  final Emote emote;
  final List<Emote> overlays;

  @override
  State<_EmoteCard> createState() => _EmoteCardState();
}

class _EmoteCardState extends State<_EmoteCard> {
  late Emote _emote = widget.emote;
  Future<_TwitchEmoteInfo?>? _twitch;

  @override
  void initState() {
    super.initState();
    _lookup();
  }

  void _lookup() {
    final id = _emote.resolvedId;
    _twitch = _emote.source == EmoteSource.twitch && id != null ? _TwitchEmoteInfo.lookup(id) : null;
  }

  /// A sharper picture for the card.
  static String _bigUrl(Emote e) => switch (e.source) {
        EmoteSource.twitch => e.url.replaceFirst(RegExp(r'/(1|2)\.0$'), '/3.0'),
        EmoteSource.sevenTv => e.url.replaceFirst(RegExp(r'/[12]x\.(webp|gif|png)$'), '/4x.webp'),
        EmoteSource.bttv => e.url.replaceFirst('/2x.webp', '/3x.webp'),
        _ => e.url,
      };

  String? _scope(Emote e) => switch (e.isGlobal) {
        true => 'Global emote',
        false => 'Channel emote',
        null => null,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = _emote;
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final all = [widget.emote, ...widget.overlays];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 112,
              child: CachedNetworkImage(
                imageUrl: _bigUrl(e),
                fit: BoxFit.contain,
                errorWidget: (_, __, ___) => CachedNetworkImage(imageUrl: e.url, fit: BoxFit.contain),
              ),
            ),
            const SizedBox(height: 12),
            SelectableText(e.name,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            FutureBuilder<_TwitchEmoteInfo?>(
              future: _twitch,
              builder: (context, snap) {
                final t = snap.data;
                final chips = <String>[
                  e.source.label,
                  if (e.source == EmoteSource.twitch)
                    t?.kind ?? (snap.connectionState == ConnectionState.waiting ? '…' : 'Emote')
                  else if (_scope(e) case final s?)
                    s,
                  if (e.zeroWidth) 'Zero-width',
                ];
                final by = e.source == EmoteSource.twitch
                    ? (t != null && !t.isGlobal && t.ownerName != null ? 'From ${t.ownerName}' : null)
                    : (e.creator != null && e.creator!.isNotEmpty ? 'By ${e.creator}' : null);
                return Column(
                  children: [
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final c in chips)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: c == chips.first
                                  ? _color(e.source).withValues(alpha: 0.22)
                                  : theme.colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(c, style: theme.textTheme.labelMedium),
                          ),
                      ],
                    ),
                    if (by != null) ...[
                      const SizedBox(height: 8),
                      Text(by, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                    ],
                  ],
                );
              },
            ),
            if (all.length > 1) ...[
              const SizedBox(height: 14),
              Text('Stacked in this message', style: theme.textTheme.labelSmall?.copyWith(color: muted)),
              const SizedBox(height: 6),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 6,
                children: [
                  for (final o in all)
                    ChoiceChip(
                      avatar: CachedNetworkImage(imageUrl: o.url, height: 20, fit: BoxFit.contain),
                      label: Text(o.name),
                      selected: identical(o, e),
                      showCheckmark: false,
                      onSelected: (_) => setState(() {
                        _emote = o;
                        _lookup();
                      }),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 14),
            OutlinedButton.icon(
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: const Text('Copy name'),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: e.name));
                final messenger = ScaffoldMessenger.of(context);
                Navigator.pop(context);
                messenger.showSnackBar(SnackBar(content: Text('Copied ${e.name}')));
              },
            ),
          ],
        ),
      ),
    );
  }

  static Color _color(EmoteSource s) => switch (s) {
        EmoteSource.twitch => const Color(0xFF9146FF),
        EmoteSource.kick => const Color(0xFF53FC18),
        EmoteSource.sevenTv => const Color(0xFF29B6F6),
        EmoteSource.bttv => const Color(0xFFD50014),
        EmoteSource.ffz => const Color(0xFF7F8C8D),
      };
}
