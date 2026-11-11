import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/net.dart';
import '../core/services.dart';
import '../core/settings.dart';
import '../kick/kick_api.dart';
import '../kick/kick_follows.dart';
import '../kick/kick_web.dart';
import '../twitch/twitch_api.dart';
import '../twitch/twitch_web.dart';
import 'browse_screen.dart';
import 'channel_screen.dart';
import 'settings_screen.dart';
import 'widgets.dart';

extension on HomeView {
  String get label => switch (this) {
        HomeView.favorites => 'Favorites',
        HomeView.following => 'Following',
        HomeView.kick => 'Kick',
        HomeView.twitch => 'Twitch',
      };
}

/// One row on the home screen. [other] is set when the same streamer is
/// followed on both platforms (a multistream); [primary] is the one that
/// opens on tap.
class _Entry {
  _Entry(this.primary, [this.other]);
  final ChannelInfo primary;
  final ChannelInfo? other;

  bool isFavorite(Settings s) =>
      s.isFavorite(primary.ref) || (other != null && s.isFavorite(other!.ref));
}

/// Lowercase letters and digits only, so "some_name" on Twitch matches
/// "some-name" on Kick.
String _matchKey(String login) => login.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// Live favorites (most viewers first), other live channels (most viewers
/// first), offline favorites, then everyone else, alphabetically.
void _sortEntries(List<_Entry> list, Settings s) {
  int rank(_Entry e) => e.primary.isLive ? (e.isFavorite(s) ? 0 : 1) : (e.isFavorite(s) ? 2 : 3);
  list.sort((a, b) {
    final r = rank(a).compareTo(rank(b));
    if (r != 0) return r;
    if (a.primary.isLive) {
      final v = (b.primary.viewers ?? 0).compareTo(a.primary.viewers ?? 0);
      if (v != 0) return v;
    }
    return a.primary.displayName.toLowerCase().compareTo(b.primary.displayName.toLowerCase());
  });
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.onOpenChannel});

  /// Set when the home list is shown under the mini player: opening a
  /// channel then switches the mini player's stream instead of stacking a
  /// second player.
  final void Function(ChannelRef channel, ChannelInfo? info)? onOpenChannel;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _menu = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  late HomeView _view = Services.settings.homeView;
  StreamPlatform? _followFilter;

  final Map<String, ChannelInfo> _favoriteInfo = {};
  bool _favoritesLoaded = false;

  List<ChannelInfo> _twitchFollows = [];
  bool _twitchLoaded = false;
  String? _twitchError;

  /// Twitch only gave the channels live right now, not the full list.
  bool _twitchLiveOnly = false;

  List<ChannelInfo> _kickFollows = [];
  bool _kickLoaded = false;
  String? _kickError;
  bool _kickExpired = false;

  bool _loading = false;
  bool _refreshAgain = false;
  bool _refreshAgainFull = false;
  Timer? _autoRefresh;

  List<ChannelRef> _lastFavorites = [];
  String? _lastTwitchLogin;
  bool _lastKickSignedIn = false;

  @override
  void initState() {
    super.initState();
    _lastFavorites = Services.settings.favorites;
    _lastTwitchLogin = Services.twitch.login;
    _lastKickSignedIn = KickFollows.isSignedIn;
    Services.settings.addListener(_onChanged);
    Services.twitch.addListener(_onChanged);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    _autoRefresh = Timer.periodic(_liveCheckEvery, (_) => _refresh());
  }

  @override
  void dispose() {
    _autoRefresh?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _menu.dispose();
    Services.settings.removeListener(_onChanged);
    Services.twitch.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    // The list picked under the mini player (another copy of this screen)
    // applies here too, so closing the mini player lands on the same list.
    final view = Services.settings.homeView;
    if (view != _view && mounted) setState(() => _view = view);
    final favorites = Services.settings.favorites;
    final login = Services.twitch.login;
    final kickSignedIn = KickFollows.isSignedIn;
    if (!identical(favorites, _lastFavorites) ||
        login != _lastTwitchLogin ||
        kickSignedIn != _lastKickSignedIn) {
      _lastFavorites = favorites;
      _lastTwitchLogin = login;
      _lastKickSignedIn = kickSignedIn;
      _refresh();
    } else if (mounted) {
      setState(() {});
    }
  }

  // ---------------------------------------------------------------- loading

  /// Live status is cheap to check (one lookup per 100 channels), so it runs
  /// often. Your full Twitch follow list is slow to get (it comes through a
  /// hidden twitch.tv page), so Relay keeps the last one it got, shows that
  /// straight away, and only fetches it again now and then in the background.
  static const _liveCheckEvery = Duration(seconds: 45);
  static const _followListMaxAge = Duration(minutes: 30);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back in the app: check who's live right away.
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh({bool full = false}) async {
    if (!mounted) return;
    if (_loading) {
      _refreshAgain = true;
      _refreshAgainFull = _refreshAgainFull || full;
      return;
    }
    setState(() => _loading = true);
    // Each part shows as soon as it's ready; favorites don't wait for the
    // follow lists.
    void show(void _) {
      if (mounted) setState(() {});
    }

    await Future.wait([
      _loadFavorites().then(show),
      _loadTwitchFollows(full: full).then(show),
      _loadKickFollows().then(show),
    ]);
    if (!mounted) return;
    setState(() => _loading = false);
    if (_refreshAgain) {
      final again = _refreshAgainFull;
      _refreshAgain = false;
      _refreshAgainFull = false;
      unawaited(_refresh(full: again));
    }
  }

  Future<void> _loadFavorites() async {
    final favorites = Services.settings.favorites;
    final twitchLogins = [
      for (final f in favorites)
        if (f.platform == StreamPlatform.twitch) f.login,
    ];
    final kickSlugs = [
      for (final f in favorites)
        if (f.platform == StreamPlatform.kick) f.login,
    ];
    final tasks = <Future<void>>[
      () async {
        try {
          for (final i in await TwitchGql.getChannels(twitchLogins)) {
            _favoriteInfo[i.ref.key] = i;
          }
        } catch (e) {
          debugPrint('Twitch favorites failed: $e');
        }
      }(),
      for (final slug in kickSlugs)
        () async {
          try {
            final info = await KickApi.getChannel(slug);
            if (info != null) _favoriteInfo[ChannelRef(StreamPlatform.kick, slug).key] = info;
          } catch (e) {
            debugPrint('Kick favorite $slug failed: $e');
          }
        }(),
    ];
    await Future.wait(tasks);
    _favoritesLoaded = true;
  }

  // The last full Twitch follow list (saved, so it's there at app start).
  List<String>? _twitchLogins;
  DateTime? _twitchListAt;
  String? _twitchListOwner;
  Future<void>? _twitchListJob;
  bool _twitchRetryScheduled = false;
  int _twitchRetries = 0;

  static const _twitchListKey = 'twitchFollowList';

  void _restoreTwitchList(String me) {
    if (_twitchListOwner == me) return;
    _twitchListOwner = me;
    _twitchLogins = null;
    _twitchListAt = null;
    try {
      final raw = Services.settings.prefs.getString(_twitchListKey);
      if (raw == null) return;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      if (m['login'] != me) return;
      _twitchLogins = (m['logins'] as List).map((e) => e.toString()).toList();
      final at = m['at'];
      if (at is int) _twitchListAt = DateTime.fromMillisecondsSinceEpoch(at);
    } catch (_) {}
  }

  void _saveTwitchList(String me) {
    unawaited(Services.settings.prefs.setString(
      _twitchListKey,
      jsonEncode({'login': me, 'at': _twitchListAt?.millisecondsSinceEpoch, 'logins': _twitchLogins}),
    ));
  }

  Future<void> _loadTwitchFollows({bool full = false}) async {
    final twitch = Services.twitch;
    // twitch.tv login: Twitch's own web client; older login: your dev app.
    final clientId = twitch.clientId ?? Services.settings.twitchClientId;
    final me = twitch.login;
    if (!twitch.isLoggedIn || clientId.isEmpty || me == null) {
      _twitchFollows = [];
      _twitchError = null;
      _twitchLoaded = true;
      return;
    }
    _restoreTwitchList(me);
    final known = _twitchLogins;
    if (known != null && known.isNotEmpty) {
      // Live status for the list we already know.
      try {
        _twitchFollows = await TwitchGql.getChannels(known);
        _twitchError = null;
      } catch (e) {
        _twitchError = 'Could not check who is live: $e';
      }
      _twitchLoaded = true;
    }
    final at = _twitchListAt;
    final stale = at == null || DateTime.now().difference(at) > _followListMaxAge;
    if (!full && !stale && known != null && known.isNotEmpty) return;

    final job = _twitchListJob ??= _fetchTwitchList(clientId, me).whenComplete(() => _twitchListJob = null);
    if (full || known == null || known.isEmpty) {
      // Pull to refresh, or nothing to show yet: wait for it.
      await job;
    } else {
      // Live status is already showing; the list updates when it arrives.
      unawaited(job.then((_) {
        if (mounted) setState(() {});
      }));
    }
  }

  Future<void> _fetchTwitchList(String clientId, String me) async {
    final twitch = Services.twitch;
    final known = _twitchLogins;
    try {
      final token = await twitch.validAccessToken();
      final userId = twitch.userId;
      if (token == null || userId == null) {
        _twitchFollows = [];
        _twitchError = 'Your Twitch sign-in has expired. Sign in again in Settings.';
        return;
      }
      List<String> logins;
      var liveOnly = false;
      try {
        logins = await TwitchHelix.getFollowedLogins(
          clientId: clientId,
          accessToken: token,
          userId: userId,
        );
      } catch (e) {
        // Helix can refuse the twitch.tv login; Twitch's own site API won't.
        if (!twitch.isWebLogin) rethrow;
        debugPrint('Helix follows failed ($e), asking through twitch.tv');
        try {
          // Through a hidden twitch.tv page, which can pass Twitch's
          // integrity check like the website does.
          final result = await TwitchWeb.instance.followedLogins(login: me, token: token);
          logins = result.logins;
          liveOnly = result.liveOnly;
        } catch (e2) {
          try {
            logins = await TwitchGql.getFollowedLogins(login: me, token: token);
          } catch (e3) {
            throw ApiException('$e2 (also: $e3; $e)');
          }
        }
      }
      if (twitch.login != me) return; // signed into another account meanwhile
      if (liveOnly) {
        if (known != null && known.isNotEmpty) {
          // Keep the full list from before (plus anyone new who's live); try
          // the full list again in a few minutes.
          _twitchLogins = {...known, ...logins}.toList();
          _twitchListAt = DateTime.now().subtract(_followListMaxAge - const Duration(minutes: 3));
          _twitchLiveOnly = false;
        } else {
          // First time and twitch.tv wasn't ready yet: show who's live and
          // try for the full list again shortly, so no manual refresh.
          _twitchLogins = logins;
          _twitchListAt = null;
          _twitchLiveOnly = true;
          if (!_twitchRetryScheduled && _twitchRetries < 3) {
            _twitchRetryScheduled = true;
            _twitchRetries++;
            Timer(const Duration(seconds: 8), () {
              _twitchRetryScheduled = false;
              if (mounted) _refresh(full: true);
            });
          }
        }
      } else {
        _twitchLogins = logins;
        _twitchListAt = DateTime.now();
        _twitchLiveOnly = false;
        _twitchRetries = 0;
      }
      _saveTwitchList(me);
      // Helix only lists names; one GQL lookup per 100 adds live status,
      // viewers and avatars.
      _twitchFollows = await TwitchGql.getChannels(_twitchLogins!);
      _twitchError = null;
    } catch (e) {
      if (known != null && known.isNotEmpty) {
        // Still showing the list from before; try again next time.
        debugPrint('Twitch follow list refresh failed: $e');
      } else {
        _twitchError = 'Could not load your Twitch follows: $e';
      }
    } finally {
      _twitchLoaded = true;
    }
  }

  Future<void> _loadKickFollows() async {
    if (!KickFollows.isSignedIn) {
      _kickFollows = [];
      _kickError = null;
      _kickLoaded = true;
      return;
    }
    try {
      _kickFollows = await _withKickPreviews(await KickFollows.load());
      _kickError = null;
      _kickExpired = false;
    } on KickSignedOutException {
      _kickFollows = [];
      _kickError = null;
      _kickExpired = true;
    } catch (e) {
      _kickError = 'Could not load your Kick follows: $e';
    }
    _kickLoaded = true;
  }

  /// Kick's follow list usually leaves out the stream preview, so for live
  /// channels it's looked up from the channel itself (kept 5 minutes).
  final Map<String, ({String? url, DateTime? startedAt, DateTime at})> _kickPreviews = {};

  Future<List<ChannelInfo>> _withKickPreviews(List<ChannelInfo> list) async {
    final now = DateTime.now();
    // The follow list's own preview address points at an old recording
    // picture that doesn't load, so every live channel is looked up.
    final need = [
      for (final c in list)
        if (c.isLive &&
            (_kickPreviews[c.login] == null ||
                now.difference(_kickPreviews[c.login]!.at) > const Duration(minutes: 5)))
          c.login,
    ];
    // A few at a time, so the hidden kick.com page isn't flooded.
    for (var i = 0; i < need.length; i += 4) {
      await Future.wait([
        for (final slug in need.skip(i).take(4))
          () async {
            try {
              final live = await KickApi.getLivePreview(slug);
              _kickPreviews[slug] = (url: live.url, startedAt: live.startedAt, at: now);
            } catch (e) {
              debugPrint('Kick preview for $slug failed: $e');
            }
          }(),
      ]);
    }
    return [
      for (final c in list)
        if (c.isLive && _kickPreviews[c.login] != null)
          c.copyWith(
            thumbnailUrl: _kickPreviews[c.login]!.url,
            startedAt: _kickPreviews[c.login]!.startedAt,
          )
        else
          c,
    ];
  }

  // ---------------------------------------------------------------- actions

  void _toggleMenu() {
    if (_menu.isDismissed || _menu.status == AnimationStatus.reverse) {
      _menu.forward();
    } else {
      _menu.reverse();
    }
  }

  void _select(HomeView view) {
    _menu.reverse();
    if (view == _view) return;
    setState(() => _view = view);
    Services.settings.setHomeView(view);
  }

  void _open(ChannelInfo info) {
    final open = widget.onOpenChannel;
    if (open != null) return open(info.ref, info);
    Navigator.of(context).push(ChannelRoute(channel: info.ref, info: info));
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

  void _longPress(_Entry e) {
    final other = e.other;
    if (other == null) {
      _toggleFavorite(e.primary.ref);
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) {
        final both = [e.primary, other];
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final i in both)
                ListTile(
                  leading: PlatformBadge(i.platform),
                  title: Text('Watch on ${i.platform.label}'),
                  subtitle: Text(i.isLive
                      ? '${formatViewers(i.viewers)} viewers'
                      : 'Offline'),
                  onTap: () {
                    Navigator.of(sheet).pop();
                    _open(i);
                  },
                ),
              const Divider(height: 8),
              for (final i in both)
                ListTile(
                  leading: Icon(
                    Services.settings.isFavorite(i.ref)
                        ? Icons.star_rounded
                        : Icons.star_outline_rounded,
                    color: Colors.amber.shade400,
                  ),
                  title: Text(Services.settings.isFavorite(i.ref)
                      ? 'Remove from favorites on ${i.platform.label}'
                      : 'Favorite on ${i.platform.label}'),
                  onTap: () {
                    Navigator.of(sheet).pop();
                    _toggleFavorite(i.ref);
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
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
    } else if (widget.onOpenChannel != null) {
      widget.onOpenChannel!(ref, null);
    } else {
      Navigator.of(context).push(ChannelRoute(channel: ref));
    }
  }

  // ---------------------------------------------------------------- lists

  List<_Entry> _favoriteEntries() {
    final follows = {for (final i in [..._twitchFollows, ..._kickFollows]) i.ref.key: i};
    final list = [
      for (final f in Services.settings.favorites)
        _Entry(follows[f.key] ?? _favoriteInfo[f.key] ?? ChannelInfo.placeholder(f)),
    ];
    _sortEntries(list, Services.settings);
    return list;
  }

  List<_Entry> _platformEntries(List<ChannelInfo> follows) {
    final list = [for (final i in follows) _Entry(i)];
    _sortEntries(list, Services.settings);
    return list;
  }

  List<_Entry> _followingEntries() {
    if (_followFilter == StreamPlatform.twitch) return _platformEntries(_twitchFollows);
    if (_followFilter == StreamPlatform.kick) return _platformEntries(_kickFollows);
    // Same streamer on both platforms: one row, opening whichever side has
    // more viewers (or is live).
    final kickByKey = <String, ChannelInfo>{};
    for (final k in _kickFollows) {
      kickByKey.putIfAbsent(_matchKey(k.login), () => k);
    }
    final used = <String>{};
    final list = <_Entry>[];
    for (final t in _twitchFollows) {
      final key = _matchKey(t.login);
      final k = used.contains(key) ? null : kickByKey[key];
      if (k == null) {
        list.add(_Entry(t));
        continue;
      }
      used.add(key);
      final kickFirst = k.isLive != t.isLive
          ? k.isLive
          : (k.viewers ?? 0) > (t.viewers ?? 0);
      list.add(kickFirst ? _Entry(k, t) : _Entry(t, k));
    }
    for (final k in _kickFollows) {
      if (!used.contains(_matchKey(k.login))) list.add(_Entry(k));
    }
    _sortEntries(list, Services.settings);
    return list;
  }

  // ---------------------------------------------------------------- notices

  String? get _twitchNotice {
    if (!Services.twitch.isLoggedIn) return 'Sign in to Twitch in Settings to see who you follow there.';
    if (_twitchError == null && _twitchLiveOnly) {
      return 'Showing only Twitch channels that are live right now: Twitch didn\'t give the full follow list.';
    }
    return _twitchError;
  }

  String? get _kickNotice {
    if (_kickError != null) return _kickError;
    if (!KickFollows.isSignedIn) {
      return _kickExpired
          ? 'Your Kick sign-in has expired. Sign in again in Settings.'
          : 'Sign in to Kick in Settings to see who you follow there.';
    }
    return null;
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showOpenDialog,
        icon: const Icon(Icons.add),
        label: const Text('Channel'),
      ),
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Bolt',
                        style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                  ),
                  IconButton(
                    tooltip: 'Browse and search',
                    icon: const Icon(Icons.search_rounded),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => BrowseScreen(onOpen: _open)),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Settings',
                    icon: const Icon(Icons.settings_outlined),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SettingsScreen()),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 0, 16, 4),
              child: Row(
                children: [
                  InkWell(
                    onTap: _toggleMenu,
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AnimatedIcon(
                            icon: AnimatedIcons.menu_close,
                            progress: _menu,
                            semanticLabel: 'Menu',
                          ),
                          const SizedBox(width: 10),
                          Text(_view.label,
                              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: Services.settings.homeTiles ? 'Show as list' : 'Show as tiles',
                    icon: Icon(Services.settings.homeTiles
                        ? Icons.view_agenda_outlined
                        : Icons.grid_view_rounded),
                    onPressed: () async {
                      await Services.settings.setHomeTiles(!Services.settings.homeTiles);
                      if (mounted) setState(() {});
                    },
                  ),
                ],
              ),
            ),
            if (_view == HomeView.following)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Row(
                  children: [
                    for (final f in <StreamPlatform?>[null, StreamPlatform.twitch, StreamPlatform.kick])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(f?.label ?? 'All'),
                          selected: _followFilter == f,
                          onSelected: (_) => setState(() => _followFilter = f),
                        ),
                      ),
                  ],
                ),
              ),
            SizedBox(
              height: 2,
              child: _loading ? const LinearProgressIndicator(minHeight: 2) : null,
            ),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(child: _buildList()),
                  _buildMenu(theme),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMenu(ThemeData theme) {
    return AnimatedBuilder(
      animation: _menu,
      builder: (context, _) {
        if (_menu.isDismissed) return const SizedBox.shrink();
        final t = Curves.easeOut.transform(_menu.value);
        return Positioned.fill(
          child: Stack(
            children: [
              // Tapping anywhere outside the menu closes it.
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _menu.reverse,
                  child: ColoredBox(color: Colors.black.withValues(alpha: 0.35 * t)),
                ),
              ),
              Positioned(
                left: 12,
                top: 4,
                child: Opacity(
                  opacity: t,
                  child: Transform.translate(
                    offset: Offset(0, -8 * (1 - t)),
                    child: Transform.scale(
                      scale: 0.94 + 0.06 * t,
                      alignment: Alignment.topLeft,
                      child: _menuCard(theme),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _menuCard(ThemeData theme) {
    Widget leading(HomeView v) => switch (v) {
          HomeView.favorites => Icon(Icons.star_rounded, color: Colors.amber.shade400),
          HomeView.following => const Icon(Icons.favorite_rounded, color: Color(0xFFFF4D6D)),
          HomeView.kick => const _PlatformMark(StreamPlatform.kick),
          HomeView.twitch => const _PlatformMark(StreamPlatform.twitch),
        };
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      elevation: 8,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicWidth(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final v in HomeView.values)
                InkWell(
                  onTap: () => _select(v),
                  child: Container(
                    color: v == _view ? theme.colorScheme.onSurface.withValues(alpha: 0.08) : null,
                    padding: const EdgeInsets.fromLTRB(16, 12, 28, 12),
                    child: Row(
                      children: [
                        SizedBox(width: 24, child: Center(child: leading(v))),
                        const SizedBox(width: 14),
                        Text(v.label,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: v == _view ? FontWeight.w800 : FontWeight.w600,
                            )),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildList() {
    final settings = Services.settings;
    late final List<_Entry> entries;
    final notices = <String>[];
    var loaded = true;
    String emptyText = '';

    switch (_view) {
      case HomeView.favorites:
        entries = _favoriteEntries();
        loaded = _favoritesLoaded || entries.isEmpty;
        emptyText = 'No favorites yet.\n\nLong-press any channel to favorite it, '
            'or tap “Channel” to add one by name.';
      case HomeView.twitch:
        entries = _platformEntries(_twitchFollows);
        loaded = _twitchLoaded;
        if (_twitchNotice != null) notices.add(_twitchNotice!);
        emptyText = Services.twitch.isLoggedIn ? 'You don’t follow anyone on Twitch yet.' : '';
      case HomeView.kick:
        entries = _platformEntries(_kickFollows);
        loaded = _kickLoaded;
        if (_kickNotice != null) notices.add(_kickNotice!);
        emptyText = KickFollows.isSignedIn ? 'You don’t follow anyone on Kick yet.' : '';
      case HomeView.following:
        entries = _followingEntries();
        if (_followFilter != StreamPlatform.kick) {
          loaded = loaded && _twitchLoaded;
          if (_twitchNotice != null) notices.add(_twitchNotice!);
        }
        if (_followFilter != StreamPlatform.twitch) {
          loaded = loaded && _kickLoaded;
          if (_kickNotice != null) notices.add(_kickNotice!);
        }
        emptyText = notices.isEmpty ? 'No followed channels yet.' : '';
    }

    final liveCount = entries.where((e) => e.primary.isLive).length;
    final firstOffline = entries.indexWhere((e) => !e.primary.isLive);

    return RefreshIndicator(
      onRefresh: () => _refresh(full: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          for (final n in notices) _Notice(n),
          if (entries.isEmpty && !loaded)
            const Padding(
              padding: EdgeInsets.only(top: 80),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (entries.isEmpty && emptyText.isNotEmpty)
            _EmptyState(emptyText),
          if (liveCount > 0) SectionHeader('Live · $liveCount'),
          if (settings.homeTiles && liveCount > 0)
            _LiveTiles(
              entries: entries.where((e) => e.primary.isLive).toList(),
              settings: settings,
              onOpen: _open,
              onLongPress: _longPress,
            ),
          for (var i = settings.homeTiles ? math.max(firstOffline, 0) : 0;
              i < entries.length && !(settings.homeTiles && firstOffline < 0);
              i++) ...[
            if (i == firstOffline) const SectionHeader('Offline'),
            ChannelTile(
              info: entries[i].primary,
              alsoOn: entries[i].other?.platform,
              isFavorite: entries[i].isFavorite(settings),
              loading: _loading &&
                  _view == HomeView.favorites &&
                  !_favoriteInfo.containsKey(entries[i].primary.ref.key),
              onTap: () => _open(entries[i].primary),
              onLongPress: () => _longPress(entries[i]),
            ),
          ],
        ],
      ),
    );
  }
}

/// Live channels as tiles with the stream's preview picture.
class _LiveTiles extends StatelessWidget {
  const _LiveTiles({
    required this.entries,
    required this.settings,
    required this.onOpen,
    required this.onLongPress,
  });

  final List<_Entry> entries;
  final Settings settings;
  final void Function(ChannelInfo) onOpen;
  final void Function(_Entry) onLongPress;

  @override
  Widget build(BuildContext context) {
    // Twitch and Kick refresh the preview every few minutes at the same
    // address; this makes the picture refresh too (every 5 minutes).
    final bucket = DateTime.now().millisecondsSinceEpoch ~/ (5 * 60 * 1000);
    return LayoutBuilder(builder: (context, box) {
      // Two per row on a phone, more on wider screens.
      final columns = math.max(2, (box.maxWidth / 260).floor());
      const gap = 10.0;
      final width = (box.maxWidth - 24 - gap * (columns - 1)) / columns;
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Wrap(
          spacing: gap,
          runSpacing: 14,
          children: [
            for (final e in entries)
              SizedBox(
                width: width,
                child: LiveTile(
                  info: e.primary,
                  alsoOn: e.other?.platform,
                  isFavorite: e.isFavorite(settings),
                  bucket: bucket,
                  onTap: () => onOpen(e.primary),
                  onLongPress: () => onLongPress(e),
                ),
              ),
          ],
        ),
      );
    });
  }
}

class LiveTile extends StatelessWidget {
  const LiveTile({
    required this.info,
    required this.alsoOn,
    required this.isFavorite,
    required this.bucket,
    required this.onTap,
    required this.onLongPress,
  });

  final ChannelInfo info;
  final StreamPlatform? alsoOn;
  final bool isFavorite;
  final int bucket;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  String? get _thumb {
    final url = info.thumbnailUrl;
    if (url == null || url.isEmpty) return null;
    // Kick's preview addresses are signed/unique already; adding to them can
    // break them. Twitch's stay the same, so a time marker refreshes them.
    // (A #fragment isn't sent to the server, but still makes the picture
    // refresh every 5 minutes.)
    if (info.platform == StreamPlatform.kick) return '$url#t=$bucket';
    return '$url${url.contains('?') ? '&' : '?'}t=$bucket';
  }

  /// A tiny note on the placeholder saying why there's no preview (helps
  /// tell a missing address apart from a picture that wouldn't load).
  static Widget _withNote(Widget placeholder, String note) => !Services.settings.previewNotes
      ? placeholder
      : Stack(
        fit: StackFit.expand,
        children: [
          placeholder,
          Positioned(
            right: 6,
            bottom: 28, // above the viewer count
            left: 6,
            child: Text(note,
                textAlign: TextAlign.right,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 9, color: Colors.white70)),
          ),
        ],
      );

  static String _shortError(Object error) {
    final text = '$error';
    final code = RegExp(r'statusCode: (\d+)').firstMatch(text)?.group(1);
    if (code != null) return 'preview HTTP $code';
    return text.length > 60 ? '${text.substring(0, 60)}…' : text;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final thumb = _thumb;
    final placeholder = Container(
      color: info.platform.color.withValues(alpha: 0.18),
      alignment: Alignment.center,
      child: ChannelAvatar(info: info, size: 40),
    );
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (thumb == null)
                    _withNote(placeholder, 'no preview from ${info.platform.label}')
                  else if (info.platform == StreamPlatform.kick)
                    // Kick refuses apps; the picture comes through kick.com.
                    FutureBuilder<Uint8List?>(
                      future: KickWeb.instance.image(info.thumbnailUrl!),
                      builder: (context, snap) {
                        final bytes = snap.data;
                        if (bytes != null) {
                          return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
                        }
                        if (snap.connectionState != ConnectionState.done) return placeholder;
                        return _withNote(placeholder,
                            KickWeb.instance.imageNotes[info.thumbnailUrl!] ?? 'preview blocked by Kick');
                      },
                    )
                  else
                    Image.network(
                      thumb,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      loadingBuilder: (context, child, progress) =>
                          progress == null ? child : placeholder,
                      errorBuilder: (context, error, _) {
                        debugPrint('Preview for ${info.login} failed: $error ($thumb)');
                        return _withNote(placeholder, _shortError(error));
                      },
                    ),
                  Positioned(
                    left: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE91916),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text('LIVE',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Colors.white)),
                    ),
                  ),
                  Positioned(
                    right: 6,
                    top: 6,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        PlatformBadge(info.platform, compact: true),
                        if (alsoOn != null) ...[
                          const SizedBox(width: 3),
                          PlatformBadge(alsoOn!, compact: true),
                        ],
                      ],
                    ),
                  ),
                  if (info.viewers != null)
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.65),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text('${formatViewers(info.viewers)} watching',
                            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.white)),
                      ),
                    ),
                  // How long they've been live.
                  if (info.startedAt != null)
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.65),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(formatUptime(info.startedAt!),
                            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.white)),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              ChannelAvatar(info: info, size: 20),
              const SizedBox(width: 6),
              Expanded(
                child: Text(info.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
              ),
              if (isFavorite) Icon(Icons.star_rounded, size: 15, color: Colors.amber.shade400),
            ],
          ),
          if ((info.title ?? '').isNotEmpty)
            Text(info.title!,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
          if ((info.category ?? '').isNotEmpty)
            Text(info.category!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: muted)),
        ],
      ),
    );
  }
}

class _PlatformMark extends StatelessWidget {
  const _PlatformMark(this.platform);
  final StreamPlatform platform;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 22,
        height: 22,
        child: Image.asset(PlatformBadge.assetFor(platform), semanticLabel: platform.label),
      );
}

class _Notice extends StatelessWidget {
  const _Notice(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, size: 18, color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6);
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 80, 32, 32),
      child: Column(
        children: [
          Icon(Icons.live_tv_rounded, size: 56, color: muted),
          const SizedBox(height: 16),
          Text(text, textAlign: TextAlign.center, style: TextStyle(color: muted)),
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
