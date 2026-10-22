import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../chat/chat_controller.dart';
import '../core/models.dart';
import '../core/services.dart';
import '../kick/kick_api.dart';
import '../twitch/twitch_api.dart';
import 'chat_view.dart';
import 'home_screen.dart';
import '../core/settings.dart';
import '../player/sources.dart';
import 'live_player.dart';
import 'twitch_player.dart';
import 'widgets.dart';

/// The route channels open in. It can close without the slide-out animation,
/// for closing the mini player: the home list it leaves you on is already
/// on screen.
class ChannelRoute extends MaterialPageRoute<void> {
  ChannelRoute({required ChannelRef channel, ChannelInfo? info})
      : super(builder: (_) => ChannelScreen(channel: channel, initialInfo: info));

  bool _instant = false;

  @override
  Duration get reverseTransitionDuration =>
      _instant ? Duration.zero : super.reverseTransitionDuration;

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    // Closing from the mini player: no slide at all.
    if (_instant) return child;
    return super.buildTransitions(context, animation, secondaryAnimation, child);
  }

  void popInstantly(BuildContext context) {
    _instant = true;
    controller?.reverseDuration = Duration.zero;
    // Rebuild the transition without the slide before closing.
    changedInternalState();
    Navigator.of(context).pop();
  }
}

class ChannelScreen extends StatefulWidget {
  const ChannelScreen({super.key, required this.channel, this.initialInfo});

  final ChannelRef channel;
  final ChannelInfo? initialInfo;

  @override
  State<ChannelScreen> createState() => _ChannelScreenState();
}

class _ChannelScreenState extends State<ChannelScreen> {
  // Global keys let the players survive the portrait <-> landscape re-layout
  // without reloading the stream.
  final _webKey = GlobalKey<TwitchPlayerState>();
  final _liveKey = GlobalKey<LivePlayerState>();

  ChannelInfo? _info;
  bool _loaded = false;

  /// True once the channel lookup succeeded (so `isLive` can be trusted).
  bool _lookupOk = false;
  String? _error;
  ChatController? _chat;
  Timer? _infoTimer;
  bool? _wasLandscape;
  late bool _showChatLandscape = Services.settings.landscapeChat;

  // Mini player: swipe the video down to shrink it into a corner with the
  // home list underneath. The player widget stays the same, so the stream
  // keeps playing without reloading.
  bool _mini = false;
  _Corner _corner = _Corner.bottomRight;
  Offset? _dragTopLeft;
  double _swipe = 0;

  ChannelRef get ref => widget.channel;

  @override
  void initState() {
    super.initState();
    _info = widget.initialInfo;
    WakelockPlus.enable();
    _load();
    _infoTimer = Timer.periodic(const Duration(seconds: 60), (_) => _load(quiet: true));
  }

  @override
  void dispose() {
    _infoTimer?.cancel();
    _chat?.dispose();
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    // Undo the full screen button's forced rotation.
    SystemChrome.setPreferredOrientations(const []);
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    try {
      final info = ref.platform == StreamPlatform.twitch
          ? await TwitchGql.getChannel(ref.login)
          : await KickApi.getChannel(ref.login);
      if (!mounted) return;
      if (info == null) {
        if (!quiet) setState(() => _error = 'Channel “${ref.login}” was not found on ${ref.platform.label}.');
        return;
      }
      setState(() {
        _info = info;
        _loaded = true;
        _lookupOk = true;
        _error = null;
      });
      if (_chat == null) {
        final chat = ChatController(info);
        _chat = chat;
        unawaited(chat.start());
      }
    } catch (e) {
      if (!mounted || quiet) return;
      if (ref.platform == StreamPlatform.twitch && _chat == null) {
        // Twitch chat only needs the channel name, so keep going without the
        // lookup (the player doesn't need it either).
        final info = _info ?? ChannelInfo.placeholder(ref);
        final chat = ChatController(info);
        setState(() {
          _info = info;
          _loaded = true;
          _chat = chat;
        });
        unawaited(chat.start());
        return;
      }
      setState(() => _error = e.toString());
    }
  }

  bool get _useWebPlayer =>
      ref.platform == StreamPlatform.twitch &&
      Services.settings.twitchPlayer == TwitchPlayerMode.web;

  void _reloadPlayer() {
    if (_useWebPlayer) {
      _webKey.currentState?.reload();
    } else {
      _liveKey.currentState?.reload();
    }
  }

  Future<void> _openInBrowser() async {
    final url = ref.platform == StreamPlatform.twitch
        ? Uri.https('www.twitch.tv', '/${ref.login}')
        : Uri.https('kick.com', '/${ref.login}');
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }

  void _syncSystemUi(bool landscape) {
    if (_wasLandscape == landscape) return;
    _wasLandscape = landscape;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SystemChrome.setEnabledSystemUIMode(
          landscape ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
    });
  }

  void _toggleLandscapeChat() => setState(() => _showChatLandscape = !_showChatLandscape);

  Widget _player({VoidCallback? onDoubleTap, double latencyRightInset = 8, bool compact = false}) {
    if (_useWebPlayer) {
      return TwitchPlayer(key: _webKey, login: ref.login);
    }
    if (ref.platform == StreamPlatform.twitch) {
      final blockAds = Services.settings.relayAdBlock;
      return LivePlayer(
        key: _liveKey,
        sourceKey: 'twitch:${ref.login}:$blockAds:${Services.settings.lowLatency}',
        // Only trust "offline" when the lookup actually succeeded; the player
        // finds out by itself otherwise.
        isLive: !_lookupOk || (_info?.isLive ?? true),
        onDoubleTap: onDoubleTap,
        latencyRightInset: latencyRightInset,
        compact: compact,
        mediaTitle: _info?.title,
        mediaArtist: _info?.displayName ?? ref.login,
        mediaArtwork: _info?.avatarUrl,
        createSource: () => TwitchSource(ref.login, blockAds: blockAds),
      );
    }
    final info = _info;
    if (!_loaded || info == null) {
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: _error == null
              ? const CircularProgressIndicator()
              : const Icon(Icons.error_outline, color: Colors.white54, size: 40),
        ),
      );
    }
    final playbackUrl = info.playbackUrl;
    return LivePlayer(
      key: _liveKey,
      sourceKey: 'kick:${playbackUrl ?? ''}:${Services.settings.lowLatency}',
      isLive: info.isLive && playbackUrl != null,
      onDoubleTap: onDoubleTap,
      latencyRightInset: latencyRightInset,
      compact: compact,
      mediaTitle: info.title,
      mediaArtist: info.displayName,
      mediaArtwork: info.avatarUrl,
      createSource: () => KickSource(playbackUrl!),
    );
  }

  Widget _chatArea() {
    final chat = _chat;
    if (chat != null) return ChatView(controller: chat, platform: ref.platform);
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton.tonal(
                onPressed: () {
                  setState(() => _error = null);
                  _load();
                },
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }
    return const Center(child: CircularProgressIndicator());
  }

  @override
  Widget build(BuildContext context) {
    final landscape = MediaQuery.of(context).orientation == Orientation.landscape && !_mini;
    _syncSystemUi(landscape);
    return ListenableBuilder(
      listenable: Services.settings,
      builder: (context, _) => Scaffold(
        backgroundColor: Colors.black,
        body: landscape ? _landscape() : _portrait(),
      ),
    );
  }

  Widget _portrait() {
    return LayoutBuilder(builder: (context, box) {
      final pad = MediaQuery.paddingOf(context);
      final screen = box.biggest;
      final full = Rect.fromLTWH(0, pad.top, screen.width, screen.width * 9 / 16);
      final rect = _mini ? _miniRect(screen, pad) : full;
      return Stack(
        children: [
          Positioned.fill(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: _mini
                  ? HomeScreen(key: const ValueKey('home'), onOpenChannel: _openFromMini)
                  : _channelContent(key: const ValueKey('channel'), playerBottom: full.bottom),
            ),
          ),
          AnimatedPositioned(
            duration: _dragTopLeft != null ? Duration.zero : const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            left: rect.left,
            top: rect.top,
            width: rect.width,
            height: rect.height,
            child: _playerFrame(screen, pad),
          ),
        ],
      );
    });
  }

  /// Header and chat under the full-width player.
  Widget _channelContent({Key? key, required double playerBottom}) {
    return ColoredBox(
      key: key,
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Column(
        children: [
          Container(height: playerBottom, color: Colors.black),
          _Header(
            channel: ref,
            info: _info,
            onBack: () => Navigator.of(context).pop(),
            onReload: _reloadPlayer,
            onOpenInBrowser: _openInBrowser,
          ),
          const Divider(height: 1),
          Expanded(child: _chatArea()),
        ],
      ),
    );
  }

  /// The video, full width or as the mini player.
  Widget _playerFrame(Size screen, EdgeInsets pad) {
    final mini = _mini;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      // Full size: swipe down to shrink.
      onVerticalDragStart: mini ? null : (_) => _swipe = 0,
      onVerticalDragUpdate: mini ? null : (d) => _swipe += d.delta.dy,
      onVerticalDragEnd: mini
          ? null
          : (d) {
              if (_swipe > 60 || (d.primaryVelocity ?? 0) > 500) {
                setState(() => _mini = true);
              }
              _swipe = 0;
            },
      // Mini: tap to open again, drag to any corner.
      onTap: mini ? () => setState(() => _mini = false) : null,
      onPanStart: mini
          ? (_) => setState(() => _dragTopLeft = _cornerRect(_corner, screen, pad).topLeft)
          : null,
      onPanUpdate: mini
          ? (d) => setState(() => _dragTopLeft = (_dragTopLeft ?? Offset.zero) + d.delta)
          : null,
      onPanEnd: mini ? (d) => _snapToCorner(d.velocity.pixelsPerSecond, screen) : null,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(mini ? 12 : 0),
          boxShadow: mini ? const [BoxShadow(color: Colors.black54, blurRadius: 16)] : null,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(mini ? 12 : 0),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: Colors.black, child: IgnorePointer(ignoring: mini, child: _player(compact: mini))),
              if (mini)
                Positioned(
                  top: 4,
                  right: 4,
                  child: _OverlayButton(icon: Icons.close_rounded, onTap: _closeMini),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Size _miniSize(Size screen) {
    final w = math.min(screen.width * 0.5, 280.0);
    return Size(w, w * 9 / 16);
  }

  Rect _cornerRect(_Corner corner, Size screen, EdgeInsets pad) {
    final size = _miniSize(screen);
    const margin = 12.0;
    final left = corner == _Corner.topLeft || corner == _Corner.bottomLeft
        ? margin
        : screen.width - size.width - margin;
    // Bottom corners stay clear of the "+ Channel" button.
    final top = corner == _Corner.topLeft || corner == _Corner.topRight
        ? pad.top + margin
        : screen.height - pad.bottom - size.height - 88;
    return Rect.fromLTWH(left, top, size.width, size.height);
  }

  Rect _miniRect(Size screen, EdgeInsets pad) {
    final drag = _dragTopLeft;
    if (drag != null) return drag & _miniSize(screen);
    return _cornerRect(_corner, screen, pad);
  }

  /// Lets go of the mini player: it glides to the nearest corner (a flick
  /// counts towards the direction it was thrown).
  void _snapToCorner(Offset velocity, Size screen) {
    final drag = _dragTopLeft;
    if (drag == null) return;
    final size = _miniSize(screen);
    final center = drag + Offset(size.width / 2, size.height / 2) + velocity * 0.15;
    final left = center.dx < screen.width / 2;
    final top = center.dy < screen.height / 2;
    setState(() {
      _corner = top
          ? (left ? _Corner.topLeft : _Corner.topRight)
          : (left ? _Corner.bottomLeft : _Corner.bottomRight);
      _dragTopLeft = null;
    });
  }

  /// Closes the stream from the mini player straight onto the home list
  /// (which is what's already showing), without the slide animation.
  void _closeMini() {
    final route = ModalRoute.of(context);
    if (route is ChannelRoute) {
      route.popInstantly(context);
    } else {
      Navigator.of(context).pop();
    }
  }

  /// A channel picked from the list under the mini player.
  void _openFromMini(ChannelRef channel, ChannelInfo? info) {
    if (channel == ref) {
      setState(() => _mini = false);
      return;
    }
    Navigator.of(context).pushReplacement(ChannelRoute(channel: channel, info: info));
  }

  Widget _landscape() {
    return Row(
      children: [
        Expanded(
          child: Stack(
            children: [
              // Double-tap the video to show or hide chat.
              // The chat button sits top right (36 px at 8 px from the
              // edge), so the latency readout goes just left of it.
              Positioned.fill(
                child: _player(onDoubleTap: _toggleLandscapeChat, latencyRightInset: 52),
              ),
              Positioned(
                top: 8,
                left: 8,
                child: _OverlayButton(
                  icon: Icons.arrow_back_rounded,
                  onTap: () => Navigator.of(context).pop(),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: _OverlayButton(
                  icon: _showChatLandscape ? Icons.chat_rounded : Icons.chat_outlined,
                  onTap: _toggleLandscapeChat,
                ),
              ),
            ],
          ),
        ),
        if (_showChatLandscape)
          SizedBox(
            width: 330,
            child: SafeArea(
              left: false,
              child: ColoredBox(
                color: Theme.of(context).scaffoldBackgroundColor,
                child: _chatArea(),
              ),
            ),
          ),
      ],
    );
  }
}

enum _Corner { topLeft, topRight, bottomLeft, bottomRight }

class _OverlayButton extends StatelessWidget {
  const _OverlayButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black45,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.channel,
    required this.info,
    required this.onBack,
    required this.onReload,
    required this.onOpenInBrowser,
  });

  final ChannelRef channel;
  final ChannelInfo? info;
  final VoidCallback onBack;
  final VoidCallback onReload;
  final VoidCallback onOpenInBrowser;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final i = info ?? ChannelInfo.placeholder(channel);
    final favorite = Services.settings.isFavorite(channel);
    final details = <String>[
      if (i.isLive && i.category != null) i.category!,
      if (i.isLive && i.viewers != null) '${formatViewers(i.viewers)} watching',
      if (!i.isLive && info != null) 'Offline',
    ].join(' · ');
    return Container(
      color: theme.scaffoldBackgroundColor,
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
      child: Row(
        children: [
          IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: onBack),
          ChannelAvatar(info: i, size: 34),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(i.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                    ),
                    const SizedBox(width: 6),
                    PlatformBadge(i.platform, compact: true),
                  ],
                ),
                if (i.title != null && i.isLive)
                  Text(i.title!,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                if (details.isNotEmpty)
                  Text(details,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
              ],
            ),
          ),
          IconButton(
            tooltip: favorite ? 'Remove from favorites' : 'Add to favorites',
            icon: Icon(favorite ? Icons.star_rounded : Icons.star_outline_rounded,
                color: favorite ? Colors.amber.shade400 : null),
            onPressed: () => Services.settings.toggleFavorite(channel),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'reload') onReload();
              if (v == 'browser') onOpenInBrowser();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'reload', child: Text('Reload player')),
              PopupMenuItem(value: 'browser', child: Text('Open in browser')),
            ],
          ),
        ],
      ),
    );
  }
}
