import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Native HLS player for Kick (ExoPlayer on Android, AVPlayer on iOS).
class KickPlayer extends StatefulWidget {
  const KickPlayer({super.key, required this.playbackUrl, required this.isLive});

  final String? playbackUrl;
  final bool isLive;

  @override
  State<KickPlayer> createState() => KickPlayerState();
}

class KickPlayerState extends State<KickPlayer> {
  VideoPlayerController? _controller;
  String? _error;
  bool _showControls = true;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(KickPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playbackUrl != widget.playbackUrl ||
        (!oldWidget.isLive && widget.isLive)) {
      reload();
    }
  }

  Future<void> _start() async {
    final url = widget.playbackUrl;
    if (url == null || !widget.isLive) return;
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(url),
      formatHint: VideoFormat.hls,
      videoPlayerOptions: VideoPlayerOptions(allowBackgroundPlayback: false),
    );
    _controller = controller;
    controller.addListener(_onPlayerChanged);
    try {
      await controller.initialize();
      if (!mounted || _controller != controller) return;
      await controller.play();
      _scheduleHide();
    } catch (e) {
      if (!mounted || _controller != controller) return;
      setState(() => _error = 'Could not start the stream.');
    }
    if (mounted) setState(() {});
  }

  void _onPlayerChanged() {
    final c = _controller;
    if (c == null || !mounted) return;
    if (c.value.hasError && _error == null) {
      setState(() => _error = c.value.errorDescription ?? 'Playback error');
    } else {
      setState(() {});
    }
  }

  Future<void> reload() async {
    final old = _controller;
    _controller = null;
    setState(() => _error = null);
    old?.removeListener(_onPlayerChanged);
    await old?.dispose();
    await _start();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller?.removeListener(_onPlayerChanged);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    Widget child;
    if (!widget.isLive) {
      child = const _Message(icon: Icons.videocam_off_outlined, text: 'Offline');
    } else if (_error != null) {
      child = _Message(
        icon: Icons.error_outline,
        text: _error!,
        action: TextButton(onPressed: reload, child: const Text('Retry')),
      );
    } else if (c == null || !c.value.isInitialized) {
      child = const Center(child: CircularProgressIndicator());
    } else {
      final aspect = c.value.aspectRatio > 0 ? c.value.aspectRatio : 16 / 9;
      child = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleControls,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(child: AspectRatio(aspectRatio: aspect, child: VideoPlayer(c))),
            if (c.value.isBuffering)
              const Center(child: CircularProgressIndicator()),
            AnimatedOpacity(
              opacity: _showControls ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !_showControls,
                child: _Controls(controller: c, onReload: reload),
              ),
            ),
          ],
        ),
      );
    }
    return ColoredBox(color: Colors.black, child: child);
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.controller, required this.onReload});

  final VideoPlayerController controller;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    final playing = controller.value.isPlaying;
    final muted = controller.value.volume == 0;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black54, Colors.transparent, Colors.black54],
        ),
      ),
      child: Stack(
        children: [
          Center(
            child: IconButton(
              iconSize: 56,
              color: Colors.white,
              icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
              onPressed: () => playing ? controller.pause() : controller.play(),
            ),
          ),
          Positioned(
            left: 8,
            bottom: 4,
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE91916),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text('LIVE',
                      style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                ),
              ],
            ),
          ),
          Positioned(
            right: 4,
            bottom: 0,
            child: Row(
              children: [
                IconButton(
                  color: Colors.white,
                  tooltip: 'Jump to live',
                  icon: const Icon(Icons.refresh_rounded),
                  onPressed: onReload,
                ),
                IconButton(
                  color: Colors.white,
                  tooltip: muted ? 'Unmute' : 'Mute',
                  icon: Icon(muted ? Icons.volume_off_rounded : Icons.volume_up_rounded),
                  onPressed: () => controller.setVolume(muted ? 1 : 0),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white54, size: 40),
          const SizedBox(height: 8),
          Text(text, style: const TextStyle(color: Colors.white70), textAlign: TextAlign.center),
          if (action != null) action!,
        ],
      ),
    );
  }
}
