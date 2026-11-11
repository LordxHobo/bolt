import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/videos_api.dart';
import 'vod_player_screen.dart';

/// A channel's past broadcasts and clips.
class VideosScreen extends StatefulWidget {
  const VideosScreen({super.key, required this.info});

  final ChannelInfo info;

  @override
  State<VideosScreen> createState() => _VideosScreenState();
}

class _VideosScreenState extends State<VideosScreen> {
  late Future<List<VideoItem>> _vods = VideosApi.vods(widget.info.ref);
  ClipPeriod _period = ClipPeriod.week;
  late Future<List<VideoItem>> _clips = VideosApi.clips(widget.info.ref, _period);

  void _open(VideoItem v) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => VodPlayerScreen(info: widget.info, video: v),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.info.displayName),
          bottom: const TabBar(tabs: [Tab(text: 'Past broadcasts'), Tab(text: 'Clips')]),
        ),
        body: TabBarView(
          children: [
            _VideoList(
              future: _vods,
              empty: '${widget.info.displayName} has no past broadcasts saved.',
              onRefresh: () async {
                setState(() => _vods = VideosApi.vods(widget.info.ref));
                await _vods;
              },
              onOpen: _open,
            ),
            _VideoList(
              future: _clips,
              empty: 'No clips from this period.',
              header: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final p in ClipPeriod.values)
                      ChoiceChip(
                        label: Text(switch (p) {
                          ClipPeriod.week => 'This week',
                          ClipPeriod.month => 'This month',
                          ClipPeriod.all => 'All time',
                        }),
                        selected: _period == p,
                        onSelected: (_) => setState(() {
                          _period = p;
                          _clips = VideosApi.clips(widget.info.ref, p);
                        }),
                      ),
                  ],
                ),
              ),
              onRefresh: () async {
                setState(() => _clips = VideosApi.clips(widget.info.ref, _period));
                await _clips;
              },
              onOpen: _open,
            ),
          ],
        ),
      ),
    );
  }
}

class _VideoList extends StatelessWidget {
  const _VideoList({
    required this.future,
    required this.empty,
    required this.onRefresh,
    required this.onOpen,
    this.header,
  });

  final Future<List<VideoItem>> future;
  final String empty;
  final Future<void> Function() onRefresh;
  final void Function(VideoItem) onOpen;
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<VideoItem>>(
      future: future,
      builder: (context, snap) {
        final loading = snap.connectionState != ConnectionState.done;
        final items = snap.data ?? const <VideoItem>[];
        return RefreshIndicator(
          onRefresh: onRefresh,
          child: ListView(
            padding: const EdgeInsets.only(bottom: 40),
            children: [
              if (header != null) header!,
              if (loading)
                const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
              else if (snap.hasError || items.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    snap.hasError ? "Couldn't load these: ${snap.error}" : empty,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                )
              else
                LayoutBuilder(builder: (context, box) {
                  final columns = math.max(1, (box.maxWidth / 340).floor());
                  const gap = 10.0;
                  final width = (box.maxWidth - 24 - gap * (columns - 1)) / columns;
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                    child: Wrap(
                      spacing: gap,
                      runSpacing: 14,
                      children: [
                        for (final v in items)
                          SizedBox(width: width, child: _VideoTile(video: v, onTap: () => onOpen(v))),
                      ],
                    ),
                  );
                }),
            ],
          ),
        );
      },
    );
  }
}

String formatDuration(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

String formatAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inDays >= 365) return '${d.inDays ~/ 365}y ago';
  if (d.inDays >= 30) return '${d.inDays ~/ 30}mo ago';
  if (d.inDays >= 1) return d.inDays == 1 ? 'Yesterday' : '${d.inDays} days ago';
  if (d.inHours >= 1) return '${d.inHours}h ago';
  return '${math.max(1, d.inMinutes)}m ago';
}

class _VideoTile extends StatelessWidget {
  const _VideoTile({required this.video, required this.onTap});

  final VideoItem video;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = video;
    final meta = [
      if (v.createdAt != null) formatAgo(v.createdAt!),
      if (v.views != null) '${formatViewers(v.views)} views',
      if (v.isClip && v.creator != null) 'clipped by ${v.creator}',
    ].join(' · ');
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (v.thumbnailUrl == null)
                    ColoredBox(
                      color: v.platform.color.withValues(alpha: 0.15),
                      child: Icon(v.isClip ? Icons.movie_outlined : Icons.video_library_outlined),
                    )
                  else
                    CachedNetworkImage(
                      imageUrl: v.thumbnailUrl!,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => ColoredBox(color: v.platform.color.withValues(alpha: 0.15)),
                    ),
                  if (v.duration != null)
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(4)),
                        child: Text(formatDuration(v.duration!),
                            style: theme.textTheme.labelSmall?.copyWith(color: Colors.white)),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(v.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          if (v.category != null)
            Text(v.category!,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
          if (meta.isNotEmpty)
            Text(meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(color: Colors.white60)),
        ],
      ),
    );
  }
}
