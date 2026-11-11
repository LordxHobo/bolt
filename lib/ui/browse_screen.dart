import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/browse_api.dart';
import '../core/models.dart';
import '../core/services.dart';
import 'home_screen.dart' show LiveTile;
import 'widgets.dart';

/// Browse and search Twitch and Kick: top streams, categories, and search
/// for any streamer or category.
class BrowseScreen extends StatefulWidget {
  const BrowseScreen({super.key, required this.onOpen});

  final void Function(ChannelInfo) onOpen;

  @override
  State<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends State<BrowseScreen> {
  StreamPlatform _platform = StreamPlatform.twitch;
  final _search = TextEditingController();
  Timer? _debounce;
  String _query = '';

  late Future<(List<ChannelInfo>, List<BrowseCategory>)> _top = _loadTop();
  Future<(List<ChannelInfo>, List<BrowseCategory>)>? _results;

  Future<(List<ChannelInfo>, List<BrowseCategory>)> _loadTop() async {
    final p = _platform;
    final results = await Future.wait<Object>([
      BrowseApi.topStreams(p).catchError((Object e) => <ChannelInfo>[]),
      BrowseApi.topCategories(p).catchError((Object e) => <BrowseCategory>[]),
    ]);
    return (results[0] as List<ChannelInfo>, results[1] as List<BrowseCategory>);
  }

  void _setPlatform(StreamPlatform p) {
    if (p == _platform) return;
    setState(() {
      _platform = p;
      _top = _loadTop();
      if (_query.isNotEmpty) _results = BrowseApi.search(p, _query);
    });
  }

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      setState(() {
        _query = v.trim();
        _results = _query.isEmpty ? null : BrowseApi.search(_platform, _query);
      });
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _openCategory(BrowseCategory c) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _CategoryScreen(category: c, onOpen: widget.onOpen),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Browse'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(104),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Column(
              children: [
                SegmentedButton<StreamPlatform>(
                  segments: [
                    for (final p in StreamPlatform.values)
                      ButtonSegment(value: p, label: Text(p.label), icon: PlatformBadge(p, compact: true)),
                  ],
                  selected: {_platform},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) => _setPlatform(s.first),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _search,
                  onChanged: _onSearch,
                  autocorrect: false,
                  textInputAction: TextInputAction.search,
                  onTapOutside: (_) => FocusScope.of(context).unfocus(),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Search ${_platform.label} streamers and categories',
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () {
                              _search.clear();
                              _onSearch('');
                            },
                          ),
                    filled: true,
                    fillColor: theme.colorScheme.surfaceContainerHighest,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      body: _results != null ? _searchResults() : _topView(),
    );
  }

  Widget _topView() => FutureBuilder(
        future: _top,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final (streams, categories) = snap.data ?? (const <ChannelInfo>[], const <BrowseCategory>[]);
          return RefreshIndicator(
            onRefresh: () async {
              setState(() => _top = _loadTop());
              await _top;
            },
            child: ListView(
              padding: const EdgeInsets.only(bottom: 40),
              children: [
                if (categories.isNotEmpty) ...[
                  const SectionHeader('Top categories'),
                  SizedBox(
                    height: 190,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemCount: categories.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 10),
                      itemBuilder: (context, i) => _CategoryCard(category: categories[i], onTap: _openCategory),
                    ),
                  ),
                ],
                const SectionHeader('Live now'),
                if (streams.isEmpty)
                  _empty(context, "Couldn't load ${_platform.label}'s top streams. Pull down to try again."),
                _StreamGrid(streams: streams, onOpen: widget.onOpen),
              ],
            ),
          );
        },
      );

  Widget _searchResults() => FutureBuilder(
        future: _results,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final (channels, categories) = snap.data ?? (const <ChannelInfo>[], const <BrowseCategory>[]);
          if (channels.isEmpty && categories.isEmpty) {
            return _empty(context, 'Nothing found for "$_query" on ${_platform.label}.');
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 40),
            children: [
              if (channels.isNotEmpty) const SectionHeader('Streamers'),
              for (final c in channels.take(25))
                ChannelTile(info: c, onTap: () => widget.onOpen(c)),
              if (categories.isNotEmpty) const SectionHeader('Categories'),
              for (final c in categories.take(15))
                ListTile(
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: SizedBox(
                      width: 36,
                      height: 48,
                      child: c.imageUrl == null
                          ? const ColoredBox(color: Colors.white10)
                          : CachedNetworkImage(imageUrl: c.imageUrl!, fit: BoxFit.cover),
                    ),
                  ),
                  title: Text(c.name),
                  subtitle: c.viewers == null ? null : Text('${formatViewers(c.viewers)} watching'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => _openCategory(c),
                ),
            ],
          );
        },
      );

  static Widget _empty(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.all(24),
        child: Text(text,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6))),
      );
}

class _CategoryCard extends StatelessWidget {
  const _CategoryCard({required this.category, required this.onTap});

  final BrowseCategory category;
  final void Function(BrowseCategory) onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => onTap(category),
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 104,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: AspectRatio(
                aspectRatio: 3 / 4,
                child: category.imageUrl == null
                    ? ColoredBox(
                        color: category.platform.color.withValues(alpha: 0.2),
                        child: const Icon(Icons.sports_esports_outlined),
                      )
                    : CachedNetworkImage(imageUrl: category.imageUrl!, fit: BoxFit.cover),
              ),
            ),
            const SizedBox(height: 4),
            Text(category.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700)),
            if (category.viewers != null)
              Text('${formatViewers(category.viewers)} watching',
                  maxLines: 1, style: theme.textTheme.labelSmall?.copyWith(color: Colors.white60)),
          ],
        ),
      ),
    );
  }
}

/// Live streams as tiles, two per row on a phone.
class _StreamGrid extends StatelessWidget {
  const _StreamGrid({required this.streams, required this.onOpen});

  final List<ChannelInfo> streams;
  final void Function(ChannelInfo) onOpen;

  @override
  Widget build(BuildContext context) {
    final bucket = DateTime.now().millisecondsSinceEpoch ~/ (5 * 60 * 1000);
    return LayoutBuilder(builder: (context, box) {
      final columns = math.max(2, (box.maxWidth / 260).floor());
      const gap = 10.0;
      final width = (box.maxWidth - 24 - gap * (columns - 1)) / columns;
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Wrap(
          spacing: gap,
          runSpacing: 14,
          children: [
            for (final s in streams)
              SizedBox(
                width: width,
                child: LiveTile(
                  info: s,
                  alsoOn: null,
                  isFavorite: Services.settings.isFavorite(s.ref),
                  bucket: bucket,
                  onTap: () => onOpen(s),
                  onLongPress: () => Services.settings.toggleFavorite(s.ref),
                ),
              ),
          ],
        ),
      );
    });
  }
}

/// One category's live streams.
class _CategoryScreen extends StatefulWidget {
  const _CategoryScreen({required this.category, required this.onOpen});

  final BrowseCategory category;
  final void Function(ChannelInfo) onOpen;

  @override
  State<_CategoryScreen> createState() => _CategoryScreenState();
}

class _CategoryScreenState extends State<_CategoryScreen> {
  late Future<List<ChannelInfo>> _streams = BrowseApi.topStreams(widget.category.platform, category: widget.category.key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.category.name)),
      body: FutureBuilder<List<ChannelInfo>>(
        future: _streams,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final streams = snap.data ?? const [];
          return RefreshIndicator(
            onRefresh: () async {
              setState(() => _streams =
                  BrowseApi.topStreams(widget.category.platform, category: widget.category.key));
              await _streams;
            },
            child: ListView(
              padding: const EdgeInsets.only(top: 8, bottom: 40),
              children: [
                if (snap.hasError || streams.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      snap.hasError ? "Couldn't load this category: ${snap.error}" : 'Nobody is live here right now.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                _StreamGrid(streams: streams, onOpen: widget.onOpen),
              ],
            ),
          );
        },
      ),
    );
  }
}
