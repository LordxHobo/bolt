import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../chat/chat_replay.dart';
import '../core/models.dart';
import '../core/net.dart';
import '../core/services.dart';
import '../core/videos_api.dart';
import 'chat_view.dart' show ChatLine;
import 'videos_screen.dart' show formatAgo, formatDuration;

/// Plays a past broadcast or clip, with its chat alongside when there is one.
class VodPlayerScreen extends StatefulWidget {
  const VodPlayerScreen({super.key, required this.info, required this.video});

  final ChannelInfo info;
  final VideoItem video;

  @override
  State<VodPlayerScreen> createState() => _VodPlayerScreenState();
}

class _VodPlayerScreenState extends State<VodPlayerScreen> {
  VideoPlayerController? _c;
  String? _error;
  late final ChatReplay? _replay =
      widget.video.isClip ? null : ChatReplay(widget.info, widget.video);

  bool _showControls = true;
  bool _chatOpen = true;
  Timer? _hideTimer;
  double? _dragging; // seconds, while moving the slider

  static const _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _start();
  }

  Future<void> _start() async {
    try {
      final url = await VideosApi.playUrl(widget.video);
      final c = VideoPlayerController.networkUrl(url, httpHeaders: {'User-Agent': browserUserAgent});
      _c = c;
      c.addListener(_onTick);
      await c.initialize();
      if (!mounted) return;
      await c.play();
      setState(() {});
      _scheduleHide();
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiException ? e.message : "Couldn't play this video.");
    }
  }

  void _onTick() {
    final c = _c;
    if (c == null || !mounted) return;
    _replay?.seek(c.value.position);
    setState(() {});
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _c?.removeListener(_onTick);
    _c?.dispose();
    _replay?.dispose();
    SystemChrome.setPreferredOrientations(const []);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && (_c?.value.isPlaying ?? false)) setState(() => _showControls = false);
    });
  }

  void _poke() {
    setState(() => _showControls = true);
    _scheduleHide();
  }

  void _skip(int seconds) {
    final c = _c;
    if (c == null) return;
    final d = c.value.duration;
    var p = c.value.position + Duration(seconds: seconds);
    if (p < Duration.zero) p = Duration.zero;
    if (p > d) p = d;
    c.seekTo(p);
    _poke();
  }

  Future<void> _toggleFullscreen() async {
    if (MediaQuery.of(context).orientation == Orientation.landscape) {
      await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      Timer(const Duration(seconds: 2), () => SystemChrome.setPreferredOrientations(const []));
    } else {
      await SystemChrome.setPreferredOrientations(
          [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    }
    _poke();
  }

  Future<void> _pickSpeed() async {
    final c = _c;
    if (c == null) return;
    final picked = await showModalBottomSheet<double>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('Playback speed')),
            for (final s in _speeds)
              ListTile(
                title: Text(s == 1.0 ? 'Normal' : '${s}x'),
                trailing: c.value.playbackSpeed == s ? const Icon(Icons.check_rounded) : null,
                onTap: () => Navigator.pop(context, s),
              ),
          ],
        ),
      ),
    );
    if (picked != null) await c.setPlaybackSpeed(picked);
  }

  @override
  Widget build(BuildContext context) {
    final landscape = MediaQuery.of(context).orientation == Orientation.landscape;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SystemChrome.setEnabledSystemUIMode(landscape ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
    });
    final video = _videoArea(landscape);
    if (landscape) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Row(
          children: [
            Expanded(child: video),
            if (_chatOpen && _replay != null)
              SizedBox(
                width: 320,
                child: SafeArea(
                  left: false,
                  child: ColoredBox(color: Theme.of(context).scaffoldBackgroundColor, child: _chat()),
                ),
              ),
          ],
        ),
      );
    }
    return Scaffold(
      body: Column(
        children: [
          ColoredBox(
            color: Colors.black,
            child: SafeArea(bottom: false, child: AspectRatio(aspectRatio: 16 / 9, child: video)),
          ),
          _details(),
          const Divider(height: 1),
          Expanded(child: _replay == null ? const SizedBox.shrink() : _chat()),
        ],
      ),
    );
  }

  Widget _details() {
    final theme = Theme.of(context);
    final v = widget.video;
    final meta = [
      widget.info.displayName,
      if (v.category != null) v.category!,
      if (v.createdAt != null) formatAgo(v.createdAt!),
      if (v.views != null) '${formatViewers(v.views)} views',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 12, 8),
      child: Row(
        children: [
          IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: () => Navigator.pop(context)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(v.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                Text(meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chat() {
    final r = _replay!;
    return ListenableBuilder(
      listenable: r,
      builder: (context, _) {
        final theme = Theme.of(context);
        if (!r.supported || r.unavailable != null) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(r.unavailable ?? 'No chat replay for this video.',
                  textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
            ),
          );
        }
        if (r.shown.isEmpty) {
          return Center(
            child: Text(r.loading ? 'Loading chat…' : 'No messages yet at this point.',
                style: theme.textTheme.bodySmall),
          );
        }
        return ListView.builder(
          reverse: true,
          padding: const EdgeInsets.symmetric(vertical: 6),
          itemCount: r.shown.length,
          itemBuilder: (context, i) => ChatLine(
            message: r.shown[i],
            badges: r.badges,
            scale: Services.settings.chatTextScale,
          ),
        );
      },
    );
  }

  Widget _videoArea(bool landscape) {
    final c = _c;
    final ready = c != null && c.value.isInitialized;
    return LayoutBuilder(builder: (context, box) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (_showControls) {
          _hideTimer?.cancel();
          setState(() => _showControls = false);
        } else {
          _poke();
        }
      },
      onDoubleTapDown: (d) => _skip(d.localPosition.dx < box.maxWidth / 2 ? -10 : 10),
      onDoubleTap: () {},
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: Colors.black,
            child: Center(
              child: _error != null
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
                    )
                  : !ready
                      ? const CircularProgressIndicator()
                      : AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c)),
            ),
          ),
          if (ready && c.value.isBuffering) const Center(child: CircularProgressIndicator()),
          if (_showControls || _error != null)
            AnimatedOpacity(
              opacity: 1,
              duration: const Duration(milliseconds: 150),
              child: _controls(c, ready, landscape),
            ),
        ],
      ),
    ));
  }

  Widget _controls(VideoPlayerController? c, bool ready, bool landscape) {
    final v = c?.value;
    final duration = v?.duration ?? Duration.zero;
    final position = _dragging != null ? Duration(milliseconds: (_dragging! * 1000).round()) : (v?.position ?? Duration.zero);
    final max = duration.inMilliseconds / 1000.0;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black54, Colors.transparent, Colors.transparent, Colors.black87],
          stops: [0, 0.25, 0.6, 1],
        ),
      ),
      child: SafeArea(
        right: !(landscape && _chatOpen && _replay != null),
        child: Stack(
          children: [
            if (landscape)
              Positioned(
                left: 4,
                top: 4,
                right: 60,
                child: Row(
                  children: [
                    IconButton(
                      color: Colors.white,
                      icon: const Icon(Icons.arrow_back_rounded),
                      onPressed: _toggleFullscreen,
                    ),
                    Expanded(
                      child: Text(widget.video.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ),
            if (landscape && _replay != null)
              Positioned(
                right: 4,
                top: 4,
                child: IconButton(
                  color: Colors.white,
                  tooltip: _chatOpen ? 'Hide chat' : 'Show chat',
                  icon: Icon(_chatOpen ? Icons.speaker_notes_off_outlined : Icons.chat_outlined),
                  onPressed: () => setState(() => _chatOpen = !_chatOpen),
                ),
              ),
            if (ready)
              Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      iconSize: 34,
                      color: Colors.white,
                      icon: const Icon(Icons.replay_10_rounded),
                      onPressed: () => _skip(-10),
                    ),
                    const SizedBox(width: 18),
                    IconButton(
                      iconSize: 52,
                      color: Colors.white,
                      icon: Icon(v!.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
                      onPressed: () {
                        v.isPlaying ? c!.pause() : c!.play();
                        _poke();
                      },
                    ),
                    const SizedBox(width: 18),
                    IconButton(
                      iconSize: 34,
                      color: Colors.white,
                      icon: const Icon(Icons.forward_10_rounded),
                      onPressed: () => _skip(10),
                    ),
                  ],
                ),
              ),
            if (ready)
              Positioned(
                left: 8,
                right: 8,
                bottom: 0,
                child: Row(
                  children: [
                    Text(formatDuration(position), style: const TextStyle(color: Colors.white, fontSize: 12)),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                          overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                        ),
                        child: Slider(
                          min: 0,
                          max: max <= 0 ? 1 : max,
                          value: (position.inMilliseconds / 1000.0).clamp(0, max <= 0 ? 1 : max).toDouble(),
                          onChangeStart: (x) {
                            _hideTimer?.cancel();
                            setState(() => _dragging = x);
                          },
                          onChanged: (x) => setState(() => _dragging = x),
                          onChangeEnd: (x) async {
                            await c!.seekTo(Duration(milliseconds: (x * 1000).round()));
                            if (mounted) setState(() => _dragging = null);
                            _scheduleHide();
                          },
                        ),
                      ),
                    ),
                    Text(formatDuration(duration), style: const TextStyle(color: Colors.white, fontSize: 12)),
                    TextButton(
                      onPressed: _pickSpeed,
                      style: TextButton.styleFrom(foregroundColor: Colors.white, minimumSize: const Size(40, 36)),
                      child: Text(v!.playbackSpeed == 1.0 ? '1x' : '${v.playbackSpeed}x'),
                    ),
                    IconButton(
                      color: Colors.white,
                      icon: Icon(landscape ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded),
                      onPressed: _toggleFullscreen,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
