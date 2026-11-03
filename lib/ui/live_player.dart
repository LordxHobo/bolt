import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/services.dart';
import '../player/live_proxy.dart';
import '../player/live_video.dart';
import '../player/sources.dart';

/// Native live player (AVPlayer on iOS, ExoPlayer on Android) fed through
/// Relay's local stream relay, for both Twitch and Kick.
class LivePlayer extends StatefulWidget {
  const LivePlayer({
    super.key,
    required this.createSource,
    required this.sourceKey,
    this.isLive = true,
    this.onDoubleTap,
    this.latencyRightInset = 8,
    this.compact = false,
    this.mediaTitle,
    this.mediaArtist,
    this.mediaArtwork,
    this.ivs = false,
  });

  /// Builds the stream source; called again on every reload.
  final StreamSource Function() createSource;

  /// Changes when a different stream should be played.
  final String sourceKey;
  final bool isLive;

  /// Double-tapping the video (used in full screen to show/hide chat).
  final VoidCallback? onDoubleTap;

  /// Distance of the latency readout from the right edge (full screen moves
  /// it left of the chat button).
  final double latencyRightInset;

  /// Mini player: just the video, no controls or labels.
  final bool compact;

  /// Shown on the lock screen and in Control Center: stream title, streamer
  /// and their picture.
  final String? mediaTitle;
  final String? mediaArtist;
  final String? mediaArtwork;

  /// Use the IVS player (iPhone). Part of [sourceKey], so a change restarts.
  final bool ivs;

  @override
  State<LivePlayer> createState() => LivePlayerState();
}

class LivePlayerState extends State<LivePlayer> with WidgetsBindingObserver {
  LiveProxy? _proxy;
  LiveVideo? _controller;
  Timer? _orientationReset;
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
  bool _details = false;
  String? _detailText;

  /// False after you press pause, so returning to Relay doesn't undo it.
  bool _wantPlaying = true;

  /// Seconds the player has been stuck waiting for video.
  int _stalledFor = 0;

  /// Where the playhead was at the last check, to tell whether the video is
  /// really moving. The player sometimes says it's waiting for video while
  /// it's actually still playing; trusting that made Bolt restart a stream
  /// that was playing fine (and land further behind).
  Duration? _lastPosition;
  DateTime? _lastDate;

  /// When the current playback started; catch-up waits a moment after.
  DateTime _startedAt = DateTime.now();

  /// The latency catch-up aims for on this stream (shown in the details).
  double? _target;

  /// Catch-up: readings in a row that were too far behind, and the last jump.
  int _behindFor = 0;
  DateTime _lastJump = DateTime.fromMillisecondsSinceEpoch(0);

  /// Extra seconds added to the target on this stream after the player ran
  /// out of video. Aiming as close as the stream allows can be too close for
  /// your connection: the player runs dry, falls back to 7-8 s, catches up,
  /// and runs dry again. Each time that happens the target moves back a bit,
  /// and after a long stretch without trouble it tries a little closer again.
  double _extra = 0;
  bool _stalled = false;
  DateTime _lastStall = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastEase = DateTime.fromMillisecondsSinceEpoch(0);
  static const _maxExtra = 5.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // iOS pauses the video when Relay goes to the background without
    // picture-in-picture; carry on when you come back.
    final c = _controller;
    // Not if it was paused from the lock screen or Control Center.
    if (state == AppLifecycleState.resumed && c != null && _wantPlaying && !c.isPlaying &&
        !c.pausedByUser) {
      c.play();
    }
  }

  void _playPause() {
    final c = _controller;
    if (c == null) return;
    _wantPlaying = !c.isPlaying;
    _wantPlaying ? c.play() : c.pause();
  }

  @override
  void didUpdateWidget(LivePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sourceKey != widget.sourceKey || (!oldWidget.isLive && widget.isLive)) {
      // A different stream or setting: rebuild the relay from scratch, and
      // start learning that stream's comfortable latency afresh.
      _extra = 0;
      reload(keepQuality: false);
    } else if (oldWidget.mediaTitle != widget.mediaTitle ||
        oldWidget.mediaArtist != widget.mediaArtist ||
        oldWidget.mediaArtwork != widget.mediaArtwork) {
      _pushNowPlaying();
    }
  }

  void _pushNowPlaying() {
    _controller?.setNowPlaying(
      title: widget.mediaTitle,
      artist: widget.mediaArtist,
      artworkUrl: widget.mediaArtwork,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session++;
    _hideTimer?.cancel();
    _latencyTimer?.cancel();
    _orientationReset?.cancel();
    _controller?.removeListener(_onPlayerChanged);
    _controller?.close();
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
      _stalledFor = 0;
      _detailText = null;
    });
    try {
      var proxy = _proxy;
      Uri url;
      if (proxy == null) {
        proxy = LiveProxy(
          widget.createSource(),
          lowLatency: _lowLatency,
          // The iPhone player reports the stream time itself, so it can load
          // video straight from Twitch/Kick; Android's needs the relay to
          // see what it downloads.
          proxySegments: defaultTargetPlatform != TargetPlatform.iOS,
          prefetchAsTags: widget.ivs && defaultTargetPlatform == TargetPlatform.iOS,
        );
        _proxy = proxy;
        url = await proxy.start();
      } else {
        url = proxy.playUrl();
      }
      if (session != _session || !mounted) return;
      // Start ~4 s from the end of the playlist (the last listed segment is
      // still being recorded); catch-up then closes in once there's buffer.
      final controller = LiveVideo.create(
        url,
        liveOffset: _lowLatency ? 4.0 : null,
        ivs: widget.ivs,
      );
      _startedAt = DateTime.now();
      _wantPlaying = true;
      _controller = controller;
      controller.addListener(_onPlayerChanged);
      await controller.initialize();
      if (session != _session || !mounted) return;
      await controller.play();
      _pushNowPlaying();
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
    await old?.close();
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
    final error = c.error;
    if (error != null && _error == null) {
      setState(() => _error = error);
    } else {
      setState(() {});
    }
  }

  /// Measures latency once a second and nudges playback speed to catch up.
  void _tick() {
    final c = _controller;
    final proxy = _proxy;
    if (c == null || proxy == null || !c.isInitialized) return;
    // Did the picture move since the last check (about a second ago)?
    final pos = c.position;
    final when = c.playheadDate;
    final lastPos = _lastPosition;
    final lastDate = _lastDate;
    final moved = (lastPos != null && (pos - lastPos).inMilliseconds.abs() > 300) ||
        (when != null && lastDate != null && when.difference(lastDate).inMilliseconds.abs() > 300);
    _lastPosition = pos;
    _lastDate = when;
    if (!c.isPlaying && !moved) {
      // Waiting for video (or paused): never stay sped up, or the player can
      // wait forever at the live edge.
      _setSpeed(1.0);
      if (c.isBuffering && _wantPlaying) {
        if (!_stalled) {
          _stalled = true;
          _onRanDry(proxy);
        }
        _stalledFor++;
        final inApp = WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
        // Not during ad breaks: a restart would only fetch a new pre-roll ad.
        final adFree = proxy.adState.value == AdState.none;
        if (_stalledFor >= 10 && inApp && adFree) {
          // Stuck for 10 s: restart at the live edge (not while in
          // picture-in-picture, which a restart would close).
          _stalledFor = 0;
          reload();
        }
      } else {
        _stalledFor = 0;
      }
      return;
    }
    _stalledFor = 0;
    _stalled = false;
    final position = c.position;
    final bufferedEnd = c.bufferedEnd;
    // The iPhone player knows the exact stream time on screen; otherwise
    // estimate it from what the player downloaded.
    final date = c.playheadDate;
    double? reading;
    final measured = c.liveLatency;
    if (measured != null) {
      reading = measured;
    } else if (date != null) {
      final now = DateTime.now().toUtc().add(proxy.serverOffset);
      final seconds = now.difference(date).inMilliseconds / 1000;
      if (seconds >= 0 && seconds < 120) reading = seconds;
    } else {
      reading = proxy.latencyFor(position, bufferedEnd);
    }
    if (_details && mounted) {
      var text = proxy.debugInfo(position, bufferedEnd, _speed);
      final buffered = bufferedEnd == null ? null : (bufferedEnd - position).inMilliseconds / 1000;
      if (measured != null) {
        text += '\nIVS: ${measured.toStringAsFixed(1)}s behind · '
            'buffered ${buffered?.toStringAsFixed(1) ?? '-'}s';
      }
      if (date != null) {
        text += '\nAVPlayer: ${reading?.toStringAsFixed(1) ?? '-'}s behind · '
            'buffer ahead ${buffered?.toStringAsFixed(1) ?? '-'}s · '
            'playing at ${c.rate?.toStringAsFixed(2) ?? '-'}x';
      }
      final target = _target;
      if (target != null) {
        text += '\naiming for ${target.toStringAsFixed(1)}s behind'
            '${_extra > 0 ? ' (+${_extra.toStringAsFixed(1)}s after running dry)' : ''}';
      }
      final pip = c.pipStatus;
      if (pip != null) text += '\n$pip';
      setState(() => _detailText = text);
    }
    if (reading == null) return;
    _recent.add(reading);
    if (_recent.length > 3) _recent.removeAt(0);
    final latency = _recent.reduce((a, b) => a + b) / _recent.length;
    if (mounted) setState(() => _latency = latency);

    if (!_lowLatency || proxy.adState.value != AdState.none) {
      if (!c.managesLatency) _setSpeed(1.0);
      return;
    }
    final ivs = c.managesLatency;
    // Catch up by jumping forward through video that's already loaded, not
    // by playing faster: at 1.1-1.25x a 60 fps stream drops frames and looks
    // choppy. Playback always stays at normal speed.
    if (!ivs) _setSpeed(1.0);
    var ahead = bufferedEnd == null ? 0.0 : (bufferedEnd - position).inMilliseconds / 1000;
    // (IVS may report how much is buffered rather than up to where.)
    if (ivs && bufferedEnd != null && bufferedEnd < position) {
      ahead = bufferedEnd.inMilliseconds / 1000;
    }
    // How close this stream allows: ~3 s when Twitch hands out the segment
    // being recorded; otherwise just behind the newest video available, with
    // room for the next segment to arrive (aiming closer only makes the
    // player run dry and buffer).
    // The IVS player plays the segment still being recorded, so it can sit
    // at ~3 s on low-latency streams; Apple's needs finished segments.
    final edge = proxy.edgeLag;
    final base = ivs || edge == null ? 3.0 : (edge + 2.5).clamp(3.0, 20.0);
    // After 5 minutes without running dry, try half a second closer again
    // (at most once every 5 minutes).
    final now = DateTime.now();
    if (_extra > 0 &&
        now.difference(_lastStall) > const Duration(minutes: 5) &&
        now.difference(_lastEase) > const Duration(minutes: 5)) {
      _extra = (_extra - 0.5).clamp(0.0, _maxExtra);
      _lastEase = now;
    }
    final target = base + _extra;
    _target = target;
    final settling = DateTime.now().difference(_startedAt) < const Duration(seconds: 10);
    final behind = latency - target;
    final minBehind = ivs ? 1.0 : 1.5;
    final keep = ivs ? 1.0 : 1.5;
    if (!settling && behind > minBehind && ahead > keep + 1.0 && latency < 60) {
      _behindFor++;
      final sinceJump = DateTime.now().difference(_lastJump);
      // Behind for a few readings in a row, and not right after a jump.
      if (_behindFor >= 3 && sinceJump > const Duration(seconds: 15)) {
        // Keep some video loaded after the jump.
        final jump = behind < ahead - keep ? behind : ahead - keep;
        if (jump > 0.8) {
          _lastJump = DateTime.now();
          _recent.clear();
          c.seekForward(Duration(milliseconds: (jump * 1000).round()));
        }
        _behindFor = 0;
      }
    } else {
      _behindFor = 0;
    }
  }

  /// The player stopped to wait for video while it should be playing.
  void _onRanDry(LiveProxy proxy) {
    final now = DateTime.now();
    // Not right after starting (it's still filling up) or during ads.
    if (now.difference(_startedAt) < const Duration(seconds: 10)) return;
    if (proxy.adState.value != AdState.none) return;
    // Only when catch-up had brought it close: then the target was too
    // ambitious for this stream and connection.
    final target = _target;
    final latency = _latency;
    if (target != null && latency != null && latency > target + 3) return;
    _extra = (_extra + 0.75).clamp(0.0, _maxExtra);
    _lastStall = now;
    _lastEase = now;
  }

  void _setSpeed(double speed) {
    final c = _controller;
    // Also resend when the player isn't actually at that speed (it can drop
    // back to 1x by itself when its buffer runs dry).
    final actual = c?.rate;
    final inSync = actual == null || actual == 0 || (actual - speed).abs() < 0.01;
    if (speed == _speed && inSync) return;
    _speed = speed;
    c?.setSpeed(speed);
  }

  /// Turns the screen sideways (or back) from the button, which also works
  /// with the iPhone's rotation lock on.
  Future<void> _toggleFullscreen() async {
    _orientationReset?.cancel();
    if (MediaQuery.of(context).orientation == Orientation.landscape) {
      await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      // Afterwards let the phone rotate on its own again (if rotation lock
      // is off).
      _orientationReset = Timer(const Duration(seconds: 2), () {
        SystemChrome.setPreferredOrientations(const []);
      });
    } else {
      await SystemChrome.setPreferredOrientations(
          [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    }
    _scheduleHide();
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
    } else if (c == null || !c.isInitialized || _starting) {
      child = const Center(child: CircularProgressIndicator());
    } else {
      final proxy = _proxy;
      child = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleControls,
        onDoubleTap: widget.onDoubleTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            c.buildView(),
            if (c.isBuffering) const Center(child: CircularProgressIndicator()),
            if (proxy != null && !widget.compact)
              ValueListenableBuilder<AdState>(
                valueListenable: proxy.adState,
                builder: (context, state, _) => switch (state) {
                  AdState.none => const SizedBox.shrink(),
                  // Bottom left, above LIVE: the top corners hold the back
                  // and chat buttons in full screen.
                  AdState.blocking => const Positioned(
                      bottom: 44,
                      left: 8,
                      child: _Chip(text: 'Blocking ads', icon: Icons.shield_outlined),
                    ),
                  AdState.waiting => const Positioned(
                      bottom: 44,
                      left: 8,
                      child: _Chip(text: 'Ad break (no ad-free copy available)', icon: Icons.campaign_outlined),
                    ),
                },
              ),
            if (!widget.compact)
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
                  fullscreen: MediaQuery.of(context).orientation == Orientation.landscape,
                  onFullscreen: _toggleFullscreen,
                  onPlayPause: _playPause,
                  onPip: defaultTargetPlatform == TargetPlatform.iOS ? c.startPip : null,
                ),
              ),
            ),
            if (Services.settings.showLatency && !widget.compact)
              Positioned(
                top: 14,
                right: widget.latencyRightInset,
                child: GestureDetector(
                  // Tap the readout for the raw numbers behind it.
                  onTap: () => setState(() => _details = !_details),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      _Chip(text: _latency == null
                          ? 'Measuring latency…'
                          : '${_latency!.toStringAsFixed(1)}s behind live'),
                      if (_details && _detailText != null) ...[
                        const SizedBox(height: 4),
                        _Chip(text: _detailText!),
                      ],
                    ],
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
    required this.fullscreen,
    required this.onFullscreen,
    required this.onPlayPause,
    this.onPip,
  });

  final LiveVideo controller;
  final String? qualityLabel;
  final VoidCallback onQuality;
  final VoidCallback onReload;
  final bool fullscreen;
  final VoidCallback onFullscreen;
  final VoidCallback onPlayPause;
  final VoidCallback? onPip;

  @override
  Widget build(BuildContext context) {
    final playing = controller.isPlaying;
    final muted = controller.isMuted;
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
              onPressed: onPlayPause,
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
                  onPressed: () => controller.setMuted(!muted),
                ),
                if (onPip != null)
                  IconButton(
                    color: Colors.white,
                    tooltip: 'Picture in picture',
                    icon: const Icon(Icons.picture_in_picture_alt_rounded),
                    onPressed: onPip,
                  ),
                IconButton(
                  color: Colors.white,
                  tooltip: fullscreen ? 'Exit full screen' : 'Full screen',
                  icon: Icon(fullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded),
                  onPressed: onFullscreen,
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
