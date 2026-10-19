import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../core/services.dart';
import '../player/live_proxy.dart';
import '../player/sources.dart';

/// Native live player (AVPlayer on iOS, ExoPlayer on Android) fed through
/// Relay's local stream relay, for both Twitch and Kick.
class LivePlayer extends StatefulWidget {
  const LivePlayer({
    super.key,
    required this.createSource,
    required this.sourceKey,
    this.isLive = true,
  });

  /// Builds the stream source; called again on every reload.
  final StreamSource Function() createSource;

  /// Changes when a different stream should be played.
  final String sourceKey;
  final bool isLive;

  @override
  State<LivePlayer> createState() => LivePlayerState();
}

class LivePlayerState extends State<LivePlayer> {
  LiveProxy? _proxy;
  VideoPlayerController? _controller;
  String? _error;
  bool _offline = false;
  bool _starting = false;
  bool _showControls = true;
  Timer? _hideTimer;
  Timer? _latencyTimer;
  double? _latency;
  final List<double> _recent = [];
  double _speed = 1.0;
  int _session = 0;
  int _farBehind = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(LivePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sourceKey != widget.sourceKey || (!oldWidget.isLive && widget.isLive)) {
      // A different stream or setting: rebuild the relay from scratch.
      reload(keepQuality: false);
    }
  }

  @override
  void dispose() {
    _session++;
    _hideTimer?.cancel();
    _latencyTimer?.cancel();
    _controller?.removeListener(_onPlayerChanged);
    _controller?.dispose();
    _proxy?.close();
    super.dispose();
  }

  bool get _lowLatency => Services.settings.lowLatency;

  Future<void> _start() async {
    if (!widget.isLive) return;
    final session = ++_session;
    setState(() {
      _starting = true;
      _error = null;
      _offline = false;
      _latency = null;
      _recent.clear();
      _speed = 1.0;
      _farBehind = 0;
    });
    try {
      var proxy = _proxy;
      Uri url;
      if (proxy == null) {
        proxy = LiveProxy(widget.createSource(), lowLatency: _lowLatency);
        _proxy = proxy;
        url = await proxy.start();
      } else {
        url = proxy.playUrl();
      }
      if (session != _session || !mounted) return;
      final controller = VideoPlayerController.networkUrl(
        url,
        formatHint: VideoFormat.hls,
        videoPlayerOptions: VideoPlayerOptions(allowBackgroundPlayback: false),
      );
      _controller = controller;
      controller.addListener(_onPlayerChanged);
      await controller.initialize();
      if (session != _session || !mounted) return;
      await controller.play();
      _scheduleHide();
      _latencyTimer?.cancel();
      _latencyTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    } on StreamOfflineException {
      if (session == _session && mounted) setState(() => _offline = true);
    } catch (e) {
      debugPrint('LivePlayer start failed: $e');
      if (session == _session && mounted) setState(() => _error = 'Could not start the stream.');
    } finally {
      if (session == _session && mounted) setState(() => _starting = false);
    }
  }

  /// Restarts playback at the live edge (also used by "Reload player").
  Future<void> reload({bool keepQuality = true}) async {
    _latencyTimer?.cancel();
    final old = _controller;
    _controller = null;
    old?.removeListener(_onPlayerChanged);
    await old?.dispose();
    if (!keepQuality) {
      await _proxy?.close();
      _proxy = null;
    }
    if (mounted) await _start();
  }

  Future<void> _selectQuality(int? index) async {
    final proxy = _proxy;
    if (proxy == null) return;
    proxy.selectedVariant = index;
    await reload();
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

  /// Measures latency once a second and nudges playback speed to catch up.
  void _tick() {
    final c = _controller;
    final proxy = _proxy;
    if (c == null || proxy == null || !c.value.isInitialized || !c.value.isPlaying) return;
    final position = c.value.position;
    Duration? bufferedEnd;
    for (final r in c.value.buffered) {
      if (bufferedEnd == null || r.end > bufferedEnd) bufferedEnd = r.end;
    }
    final reading = proxy.latencyFor(position, bufferedEnd);
    if (reading == null) return;
    _recent.add(reading);
    if (_recent.length > 3) _recent.removeAt(0);
    final latency = _recent.reduce((a, b) => a + b) / _recent.length;
    if (mounted) setState(() => _latency = latency);

    if (!_lowLatency || proxy.adState.value != AdState.none) {
      _setSpeed(1.0);
      return;
    }
    // Seconds of video downloaded but not played yet. Speeding up only helps
    // while there's some to eat into; at the live edge it would just stall.
    final ahead = bufferedEnd == null ? 0.0 : (bufferedEnd - position).inMilliseconds / 1000;
    const target = 3.5;
    _farBehind = latency > 30 ? _farBehind + 1 : 0;
    if (_farBehind >= 5) {
      // Way behind for a while (e.g. after a long stall): jump back to live.
      _farBehind = 0;
      reload();
    } else if (ahead < 1.0 || latency <= target + 0.3) {
      _setSpeed(1.0);
    } else if (latency > target + 4) {
      _setSpeed(1.25);
    } else if (latency > target + 1.5) {
      _setSpeed(1.1);
    }
  }

  void _setSpeed(double speed) {
    if (speed == _speed) return;
    _speed = speed;
    _controller?.setPlaybackSpeed(speed);
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

  Future<void> _showQualityMenu() async {
    final proxy = _proxy;
    if (proxy == null) return;
    final variants = proxy.variants;
    final current = proxy.selectedVariant;
    final best = LiveProxy.bestVariantIndex(variants);
    final order = List.generate(variants.length, (i) => i)
      ..sort((a, b) => variants[b].pixels != variants[a].pixels
          ? variants[b].pixels.compareTo(variants[a].pixels)
          : (variants[b].frameRate ?? 0).compareTo(variants[a].frameRate ?? 0));
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text('Best (${variants[best].label})'),
              trailing: current == null ? const Icon(Icons.check_rounded) : null,
              onTap: () => Navigator.pop(context, -1),
            ),
            for (final i in order)
              ListTile(
                title: Text(variants[i].label),
                trailing: current == i ? const Icon(Icons.check_rounded) : null,
                onTap: () => Navigator.pop(context, i),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await _selectQuality(picked < 0 ? null : picked);
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    Widget child;
    if (!widget.isLive || _offline) {
      child = const _Message(icon: Icons.videocam_off_outlined, text: 'Offline');
    } else if (_error != null) {
      child = _Message(
        icon: Icons.error_outline,
        text: _error!,
        action: TextButton(onPressed: () => reload(keepQuality: false), child: const Text('Retry')),
      );
    } else if (c == null || !c.value.isInitialized || _starting) {
      child = const Center(child: CircularProgressIndicator());
    } else {
      final aspect = c.value.aspectRatio > 0 ? c.value.aspectRatio : 16 / 9;
      final proxy = _proxy;
      child = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleControls,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(child: AspectRatio(aspectRatio: aspect, child: VideoPlayer(c))),
            if (c.value.isBuffering) const Center(child: CircularProgressIndicator()),
            if (proxy != null)
              ValueListenableBuilder<AdState>(
                valueListenable: proxy.adState,
                builder: (context, state, _) => switch (state) {
                  AdState.none => const SizedBox.shrink(),
                  AdState.blocking => const Positioned(
                      top: 8,
                      left: 8,
                      child: _Chip(text: 'Blocking ads', icon: Icons.shield_outlined),
                    ),
                  AdState.waiting => const Positioned(
                      top: 8,
                      left: 8,
                      child: _Chip(text: 'Ad break, waiting for the stream', icon: Icons.hourglass_top_rounded),
                    ),
                },
              ),
            if (Services.settings.showLatency && _latency != null)
              Positioned(
                top: 8,
                right: 8,
                child: _Chip(text: '${_latency!.toStringAsFixed(1)}s behind live'),
              ),
            AnimatedOpacity(
              opacity: _showControls ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !_showControls,
                child: _Controls(
                  controller: c,
                  qualityLabel: proxy == null || proxy.variants.isEmpty
                      ? null
                      : proxy.variants[proxy.playingVariant].label,
                  onQuality: _showQualityMenu,
                  onReload: reload,
                ),
              ),
            ),
          ],
        ),
      );
    }
    return ColoredBox(color: Colors.black, child: child);
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, this.icon});

  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: Colors.white70),
            const SizedBox(width: 4),
          ],
          Text(text, style: const TextStyle(color: Colors.white, fontSize: 12)),
        ],
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.controller,
    required this.qualityLabel,
    required this.onQuality,
    required this.onReload,
  });

  final VideoPlayerController controller;
  final String? qualityLabel;
  final VoidCallback onQuality;
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
          colors: [Colors.black45, Colors.transparent, Colors.black54],
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
            bottom: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFFE91916),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text('LIVE',
                  style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
            ),
          ),
          Positioned(
            right: 4,
            bottom: 0,
            child: Row(
              children: [
                if (qualityLabel != null)
                  TextButton(
                    onPressed: onQuality,
                    style: TextButton.styleFrom(foregroundColor: Colors.white),
                    child: Text(qualityLabel!, style: const TextStyle(fontSize: 12)),
                  ),
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
