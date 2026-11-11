import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../chat/chat_controller.dart';
import '../chat/chat_models.dart';
import '../core/services.dart';

/// The emote picker: every emote you can use here, searchable, with your
/// recent ones first. Tapping one calls [onPick]; the picker stays open so
/// you can add several.
Future<void> showEmotePicker(
  BuildContext context, {
  required ChatController controller,
  required ValueChanged<String> onPick,
}) {
  controller.loadPlatformEmotes();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      builder: (context, scroll) => ListenableBuilder(
        listenable: Listenable.merge([controller, Services.settings]),
        builder: (context, _) => _Picker(controller: controller, scroll: scroll, onPick: onPick),
      ),
    ),
  );
}

class _Picker extends StatefulWidget {
  const _Picker({required this.controller, required this.scroll, required this.onPick});

  final ChatController controller;
  final ScrollController scroll;
  final ValueChanged<String> onPick;

  @override
  State<_Picker> createState() => _PickerState();
}

class _PickerState extends State<_Picker> {
  String _query = '';

  List<(String, List<Emote>)> _sections() {
    final c = widget.controller;
    final recent = [
      for (final name in Services.settings.recentEmotes)
        if (c.emoteNamed(name) case final e?) e,
    ];
    List<Emote> sorted(Iterable<Emote> list) =>
        list.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final all = <(String, List<Emote>)>[
      if (recent.isNotEmpty) ('Recent', recent),
      if (c.sevenTvChannel.isNotEmpty) ('7TV · this channel', sorted(c.sevenTvChannel.values)),
      ...c.platformEmotes,
      if (c.sevenTvGlobal.isNotEmpty) ('7TV · global', sorted(c.sevenTvGlobal.values)),
    ];
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return all;
    // Searching: one list, names starting with the text first.
    final seen = <String>{};
    final starts = <Emote>[], contains = <Emote>[];
    for (final (_, list) in all) {
      for (final e in list) {
        final n = e.name.toLowerCase();
        if (!n.contains(q) || !seen.add(e.name)) continue;
        (n.startsWith(q) ? starts : contains).add(e);
      }
    }
    return [('Results', [...starts, ...contains])];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final sections = _sections();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: TextField(
            autofocus: false,
            onChanged: (v) => setState(() => _query = v),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Search emotes',
              prefixIcon: const Icon(Icons.search_rounded),
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerHighest,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
            ),
          ),
        ),
        Expanded(
          child: CustomScrollView(
            controller: widget.scroll,
            slivers: [
              if (sections.every((s) => s.$2.isEmpty))
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_query.isEmpty ? 'Loading emotes…' : 'No emotes match "$_query".',
                        textAlign: TextAlign.center, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                  ),
                ),
              for (final (title, list) in sections)
                if (list.isNotEmpty) ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
                      child: Text(title, style: theme.textTheme.labelMedium?.copyWith(color: muted)),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    sliver: SliverGrid(
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 52,
                        mainAxisSpacing: 4,
                        crossAxisSpacing: 4,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (context, i) {
                          final e = list[i];
                          return Tooltip(
                            message: e.name,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: () {
                                widget.onPick(e.name);
                                Services.settings.useEmote(e.name);
                              },
                              child: Padding(
                                padding: const EdgeInsets.all(5),
                                child: CachedNetworkImage(
                                  imageUrl: e.url,
                                  fit: BoxFit.contain,
                                  fadeInDuration: Duration.zero,
                                  errorWidget: (_, __, ___) => Center(
                                    child: Text(e.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 9)),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                        childCount: list.length,
                      ),
                    ),
                  ),
                ],
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ),
        ),
      ],
    );
  }
}
