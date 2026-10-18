import 'dart:async';

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/services.dart';
import '../kick/kick_api.dart';
import '../twitch/twitch_api.dart';
import 'channel_screen.dart';
import 'settings_screen.dart';
import 'widgets.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final Map<String, ChannelInfo> _favoriteInfo = {};
  List<ChannelInfo> _followedLive = [];
  bool _loading = false;
  String? _followError;
  Timer? _autoRefresh;
  List<ChannelRef> _lastFavorites = [];
  String? _lastTwitchLogin;

  @override
  void initState() {
    super.initState();
    _lastFavorites = Services.settings.favorites;
    _lastTwitchLogin = Services.twitch.login;
    Services.settings.addListener(_onSettingsChanged);
    Services.twitch.addListener(_onSettingsChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    _autoRefresh = Timer.periodic(const Duration(minutes: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _autoRefresh?.cancel();
    Services.settings.removeListener(_onSettingsChanged);
    Services.twitch.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onSettingsChanged() {
    final favorites = Services.settings.favorites;
    final login = Services.twitch.login;
    if (!identical(favorites, _lastFavorites) || login != _lastTwitchLogin) {
      _lastFavorites = favorites;
      _lastTwitchLogin = login;
      _refresh();
    } else if (mounted) {
      setState(() {});
    }
  }

  bool _refreshAgain = false;

  Future<void> _refresh() async {
    if (!mounted) return;
    if (_loading) {
      _refreshAgain = true;
      return;
    }
    setState(() => _loading = true);
    final favorites = Services.settings.favorites;
    final twitchLogins = favorites
        .where((f) => f.platform == StreamPlatform.twitch)
        .map((f) => f.login)
        .toList();
    final kickSlugs = favorites
        .where((f) => f.platform == StreamPlatform.kick)
        .map((f) => f.login)
        .toList();

    final tasks = <Future<void>>[];

    tasks.add(() async {
      try {
        final infos = await TwitchGql.getChannels(twitchLogins);
        for (final i in infos) {
          _favoriteInfo[i.ref.key] = i;
        }
      } catch (e) {
        debugPrint('Twitch favorites failed: $e');
      }
    }());

    for (final slug in kickSlugs) {
      tasks.add(() async {
        try {
          final info = await KickApi.getChannel(slug);
          if (info != null) _favoriteInfo[ChannelRef(StreamPlatform.kick, slug).key] = info;
        } catch (e) {
          debugPrint('Kick favorite $slug failed: $e');
        }
      }());
    }

    if (Services.twitch.isLoggedIn && Services.settings.twitchClientId.isNotEmpty) {
      tasks.add(() async {
        try {
          final token = await Services.twitch.validAccessToken();
          final userId = Services.twitch.userId;
          if (token == null || userId == null) {
            _followedLive = [];
            return;
          }
          final followed = await TwitchHelix.getFollowedLive(
            clientId: Services.settings.twitchClientId,
            accessToken: token,
            userId: userId,
          );
          // Helix doesn't include avatars; fetch them in one GQL request.
          try {
            final profiles = await TwitchGql.getChannels(
                followed.map((f) => f.login).toList());
            final avatars = {for (final p in profiles) p.login: p.avatarUrl};
            _followedLive = [
              for (final f in followed) f.copyWith(avatarUrl: avatars[f.login]),
            ];
          } catch (_) {
            _followedLive = followed;
          }
          _followError = null;
        } catch (e) {
          _followError = 'Could not load followed channels: $e';
        }
      }());
    } else {
      _followedLive = [];
      _followError = null;
    }

    await Future.wait(tasks);
    if (!mounted) return;
    setState(() => _loading = false);
    if (_refreshAgain) {
      _refreshAgain = false;
      unawaited(_refresh());
    }
  }

  void _open(ChannelRef ref, [ChannelInfo? info]) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChannelScreen(channel: ref, initialInfo: info),
    ));
  }

  Future<void> _toggleFavorite(ChannelRef ref) async {
    final wasFavorite = Services.settings.isFavorite(ref);
    await Services.settings.toggleFavorite(ref);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(wasFavorite
            ? 'Removed ${ref.login} from favorites'
            : 'Added ${ref.login} to favorites'),
      ));
  }

  Future<void> _showOpenDialog() async {
    final result = await showModalBottomSheet<(ChannelRef, bool)>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _OpenChannelSheet(),
    );
    if (result == null || !mounted) return;
    final (ref, favorite) = result;
    if (favorite) {
      if (!Services.settings.isFavorite(ref)) await Services.settings.toggleFavorite(ref);
    } else {
      _open(ref);
    }
  }

  @override
  Widget build(BuildContext context) {
    final favorites = Services.settings.favorites;
    final favoriteKeys = favorites.map((f) => f.key).toSet();

    // Merge favorites and Twitch follows, de-duplicated.
    final live = <String, ChannelInfo>{};
    for (final f in favorites) {
      final info = _favoriteInfo[f.key];
      if (info != null && info.isLive) live[f.key] = info;
    }
    for (final info in _followedLive) {
      final existing = live[info.ref.key];
      // Keep the favorite entry, but take the fresher numbers from Helix.
      live[info.ref.key] = existing == null
          ? info
          : existing.copyWith(
              isLive: true,
              title: info.title,
              category: info.category,
              viewers: info.viewers,
              thumbnailUrl: info.thumbnailUrl,
            );
    }
    final liveList = live.values.toList()
      ..sort((a, b) => (b.viewers ?? 0).compareTo(a.viewers ?? 0));
    final offline = favorites
        .where((f) => !live.containsKey(f.key))
        .map((f) => _favoriteInfo[f.key] ?? ChannelInfo.placeholder(f))
        .toList()
      ..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));

    final empty = liveList.isEmpty && offline.isEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Duplex', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
        bottom: _loading
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showOpenDialog,
        icon: const Icon(Icons.add),
        label: const Text('Channel'),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: empty
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  if (_followError != null) _ErrorLine(_followError!),
                  const _EmptyState(),
                ],
              )
            : ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(bottom: 96),
                children: [
                  if (_followError != null) _ErrorLine(_followError!),
                  if (liveList.isNotEmpty) SectionHeader('Live · ${liveList.length}'),
                  for (final info in liveList)
                    ChannelTile(
                      info: info,
                      isFavorite: favoriteKeys.contains(info.ref.key),
                      onTap: () => _open(info.ref, info),
                      onLongPress: () => _toggleFavorite(info.ref),
                    ),
                  if (offline.isNotEmpty) const SectionHeader('Offline'),
                  for (final info in offline)
                    ChannelTile(
                      info: info,
                      isFavorite: true,
                      loading: _loading && !_favoriteInfo.containsKey(info.ref.key),
                      onTap: () => _open(info.ref, info),
                      onLongPress: () => _toggleFavorite(info.ref),
                    ),
                ],
              ),
      ),
    );
  }
}

class _ErrorLine extends StatelessWidget {
  const _ErrorLine(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6);
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 96, 32, 32),
      child: Column(
        children: [
          Icon(Icons.live_tv_rounded, size: 56, color: muted),
          const SizedBox(height: 16),
          Text('No channels yet', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Tap “Channel” to open a Twitch or Kick channel or add it to your '
            'favorites. Log in to Twitch in Settings to see who you follow.\n\n'
            'Long-press any channel to add or remove it from favorites.',
            textAlign: TextAlign.center,
            style: TextStyle(color: muted),
          ),
        ],
      ),
    );
  }
}

class _OpenChannelSheet extends StatefulWidget {
  const _OpenChannelSheet();

  @override
  State<_OpenChannelSheet> createState() => _OpenChannelSheetState();
}

class _OpenChannelSheetState extends State<_OpenChannelSheet> {
  final _controller = TextEditingController();
  StreamPlatform _platform = StreamPlatform.twitch;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit(bool favorite) {
    final raw = _controller.text.trim();
    if (raw.isEmpty) return;
    var platform = _platform;
    // Pasted links pick the platform automatically.
    if (raw.contains('kick.com')) platform = StreamPlatform.kick;
    if (raw.contains('twitch.tv')) platform = StreamPlatform.twitch;
    Navigator.of(context).pop((ChannelRef(platform, raw), favorite));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<StreamPlatform>(
            segments: const [
              ButtonSegment(value: StreamPlatform.twitch, label: Text('Twitch')),
              ButtonSegment(value: StreamPlatform.kick, label: Text('Kick')),
            ],
            selected: {_platform},
            onSelectionChanged: (s) => setState(() => _platform = s.first),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            autocorrect: false,
            textInputAction: TextInputAction.go,
            decoration: const InputDecoration(
              labelText: 'Channel name or link',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _submit(false),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _submit(true),
                  icon: const Icon(Icons.star_outline_rounded),
                  label: const Text('Favorite'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _submit(false),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Watch'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
