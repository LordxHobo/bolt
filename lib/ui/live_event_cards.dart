import 'dart:async';

import 'package:flutter/material.dart';

import '../chat/chat_controller.dart';
import '../chat/chat_models.dart';
import '../core/models.dart';
import 'channel_screen.dart';

/// Above chat: a raid you can join, and the current poll or prediction with
/// live results. Each can be put away with ✕ (until something new happens).
class LiveEventCards extends StatefulWidget {
  const LiveEventCards({super.key, required this.controller});

  final ChatController controller;

  @override
  State<LiveEventCards> createState() => _LiveEventCardsState();
}

class _LiveEventCardsState extends State<LiveEventCards> {
  final _dismissed = <String>{};
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Countdowns.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      final c = widget.controller;
      if (mounted && (c.poll != null || c.prediction != null)) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  static String _left(DateTime? until) {
    if (until == null) return '';
    final d = until.difference(DateTime.now());
    if (d.isNegative) return '';
    final m = d.inMinutes, s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  void _joinRaid(ChatRaid raid) {
    Navigator.of(context).pushReplacement(
      ChannelRoute(channel: ChannelRef(widget.controller.channel.platform, raid.targetLogin)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final raid = c.raid;
    final poll = c.poll;
    final prediction = c.prediction;
    final cards = <Widget>[
      if (raid != null && !_dismissed.contains('raid:${raid.targetLogin}'))
        _card(
          context,
          icon: Icons.rocket_launch_rounded,
          color: const Color(0xFFE91916),
          title: raid.started ? 'Raiding ${raid.targetName}' : 'Getting ready to raid ${raid.targetName}',
          subtitle: raid.viewers == null ? null : '${formatViewers(raid.viewers)} viewers',
          onClose: () => setState(() => _dismissed.add('raid:${raid.targetLogin}')),
          action: FilledButton(
            style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: () => _joinRaid(raid),
            child: const Text('Join raid'),
          ),
        ),
      if (poll != null && !_dismissed.contains('poll:${poll.id}'))
        _card(
          context,
          icon: Icons.poll_outlined,
          color: c.channel.platform.color,
          title: poll.title,
          subtitle: poll.ended
              ? 'Final results · ${poll.totalVotes} votes'
              : '${poll.totalVotes} votes${_left(poll.endsAt).isEmpty ? '' : ' · ends in ${_left(poll.endsAt)}'}',
          onClose: () => setState(() => _dismissed.add('poll:${poll.id}')),
          body: Column(
            children: [
              for (final (title, votes) in poll.options)
                _bar(context, title, poll.totalVotes == 0 ? 0 : votes / poll.totalVotes, '$votes',
                    c.channel.platform.color,
                    winner: poll.ended && votes > 0 && votes == poll.options.map((o) => o.$2).reduce((a, b) => a > b ? a : b)),
            ],
          ),
        ),
      if (prediction != null && !_dismissed.contains('prediction:${prediction.id}'))
        _predictionCard(context, prediction),
    ];
    if (cards.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
      child: Column(children: cards),
    );
  }

  Widget _predictionCard(BuildContext context, ChatPrediction p) {
    final total = p.outcomes.fold<int>(0, (a, o) => a + o.points);
    const colors = [Color(0xFF387AFF), Color(0xFFF5009B), Color(0xFF00B5AD), Color(0xFFF5A524)];
    String status;
    if (p.isOpen) {
      final left = _left(p.locksAt);
      status = left.isEmpty ? 'Open' : 'Open · locks in $left';
    } else if (p.status == 'LOCKED') {
      status = 'Locked, waiting for the result';
    } else if (p.isOver && p.winnerId != null) {
      final winner = p.outcomes.where((o) => o.id == p.winnerId).map((o) => o.title).firstOrNull;
      status = winner == null ? 'Result is in' : 'Winner: $winner';
    } else if (p.isOver) {
      status = 'Canceled';
    } else {
      status = p.status.toLowerCase();
    }
    return _card(
      context,
      icon: Icons.casino_outlined,
      color: const Color(0xFF387AFF),
      title: p.title,
      subtitle: status,
      onClose: () => setState(() => _dismissed.add('prediction:${p.id}')),
      body: Column(
        children: [
          for (var i = 0; i < p.outcomes.length; i++)
            _bar(
              context,
              p.outcomes[i].title,
              total == 0 ? 0 : p.outcomes[i].points / total,
              '${formatViewers(p.outcomes[i].points)} · ${p.outcomes[i].users} people',
              colors[i % colors.length],
              winner: p.winnerId != null && p.outcomes[i].id == p.winnerId,
            ),
        ],
      ),
    );
  }

  Widget _bar(BuildContext context, String title, double share, String detail, Color color, {bool winner = false}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: share.clamp(0.0, 1.0),
                  heightFactor: 1,
                  child: ColoredBox(color: color.withValues(alpha: winner ? 0.55 : 0.3)),
                ),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: winner ? color : Colors.white12),
            ),
            child: Row(
              children: [
                if (winner) const Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.emoji_events_rounded, size: 14)),
                Expanded(
                  child: Text(title,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
                ),
                Text('${(share * 100).round()}%  ', style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700)),
                Text(detail, style: theme.textTheme.labelSmall?.copyWith(color: Colors.white60)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String title,
    String? subtitle,
    Widget? body,
    Widget? action,
    required VoidCallback onClose,
  }) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
                    if (subtitle != null)
                      Text(subtitle, style: theme.textTheme.labelSmall?.copyWith(color: Colors.white60)),
                  ],
                ),
              ),
              if (action != null) action,
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Hide',
                icon: const Icon(Icons.close_rounded, size: 18),
                onPressed: onClose,
              ),
            ],
          ),
          if (body != null) Padding(padding: const EdgeInsets.only(right: 6), child: body),
        ],
      ),
    );
  }
}
