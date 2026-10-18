import 'dart:async';

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
import 'kick_player.dart';
import 'twitch_player.dart';
import 'widgets.dart';

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
  final _twitchKey = GlobalKey<TwitchPlayerState>();
  final _kickKey = GlobalKey<KickPlayerState>();

  ChannelInfo? _info;
  bool _loaded = false;
  String? _error;
  ChatController? _chat;
  Timer? _infoTimer;
  bool? _wasLandscape;
  late bool _showChatLandscape = Services.settings.landscapeChat;

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

  void _reloadPlayer() {
    if (ref.platform == StreamPlatform.twitch) {
      _twitchKey.currentState?.reload();
    } else {
      _kickKey.currentState?.reload();
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

  Widget _player() {
    if (ref.platform == StreamPlatform.twitch) {
      return TwitchPlayer(key: _twitchKey, login: ref.login);
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
    return KickPlayer(key: _kickKey, playbackUrl: info.playbackUrl, isLive: info.isLive);
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
    final landscape = MediaQuery.of(context).orientation == Orientation.landscape;
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
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          AspectRatio(aspectRatio: 16 / 9, child: _player()),
          _Header(
            channel: ref,
            info: _info,
            onBack: () => Navigator.of(context).pop(),
            onReload: _reloadPlayer,
            onOpenInBrowser: _openInBrowser,
          ),
          const Divider(height: 1),
          Expanded(
            child: ColoredBox(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: _chatArea(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _landscape() {
    return Row(
      children: [
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(child: _player()),
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
                  onTap: () => setState(() => _showChatLandscape = !_showChatLandscape),
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
