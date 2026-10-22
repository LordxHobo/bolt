import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:relay_native_player/relay_native_player.dart';
import 'package:video_player/video_player.dart';

/// The video part of the live player. On iPhone it's Relay's own AVPlayer
/// view (picture-in-picture when you swipe home, exact stream time for the
/// latency readout); on Android it's the video_player plugin (ExoPlayer).
abstract class LiveVideo extends ChangeNotifier {
  static LiveVideo create(Uri url, {double? liveOffset}) =>
      defaultTargetPlatform == TargetPlatform.iOS
          ? _NativeLiveVideo(url, liveOffset: liveOffset)
          : _PluginLiveVideo(url);

  Future<void> initialize();
  Future<void> play();
  Future<void> pause();
  Future<void> setSpeed(double speed);
  Future<void> setMuted(bool muted);

  /// Jumps [by] forward (within what's already loaded).
  Future<void> seekForward(Duration by);

  /// What the lock screen / Control Center show (iPhone only).
  Future<void> setNowPlaying({String? title, String? artist, String? artworkUrl}) async {}

  /// Paused from the lock screen, Control Center or Relay's own button.
  bool get pausedByUser => false;

  /// Moves the video into picture-in-picture (iPhone only).
  Future<void> startPip() async {}

  /// Whether [startPip] can work right now, and a short status for the
  /// details line.
  bool get pipAvailable => false;
  String? get pipStatus => null;

  bool get isInitialized;
  bool get isPlaying;
  bool get isBuffering;
  bool get isMuted;
  String? get error;
  double get aspectRatio;
  Duration get position;
  Duration? get bufferedEnd;

  /// The stream's real time at the playhead, when the player knows it.
  DateTime? get playheadDate;

  /// The speed the player is actually playing at, when it reports it.
  double? get rate => null;

  Widget buildView();

  Future<void> close();
}

class _PluginLiveVideo extends LiveVideo {
  _PluginLiveVideo(Uri url)
      : _c = VideoPlayerController.networkUrl(
          url,
          formatHint: VideoFormat.hls,
          videoPlayerOptions: VideoPlayerOptions(allowBackgroundPlayback: false),
        ) {
    _c.addListener(notifyListeners);
  }

  final VideoPlayerController _c;

  @override
  Future<void> initialize() => _c.initialize();
  @override
  Future<void> play() => _c.play();
  @override
  Future<void> pause() => _c.pause();
  @override
  Future<void> setSpeed(double speed) => _c.setPlaybackSpeed(speed);
  @override
  Future<void> setMuted(bool muted) => _c.setVolume(muted ? 0 : 1);
  @override
  Future<void> seekForward(Duration by) => _c.seekTo(_c.value.position + by);

  @override
  bool get isInitialized => _c.value.isInitialized;
  @override
  bool get isPlaying => _c.value.isPlaying;
  @override
  bool get isBuffering => _c.value.isBuffering;
  @override
  bool get isMuted => _c.value.volume == 0;
  @override
  String? get error => _c.value.hasError ? (_c.value.errorDescription ?? 'Playback error') : null;
  @override
  double get aspectRatio => _c.value.aspectRatio;
  @override
  Duration get position => _c.value.position;
  @override
  Duration? get bufferedEnd {
    Duration? end;
    for (final r in _c.value.buffered) {
      if (end == null || r.end > end) end = r.end;
    }
    return end;
  }

  @override
  DateTime? get playheadDate => null;

  @override
  Widget buildView() => Center(
        child: AspectRatio(
          aspectRatio: aspectRatio > 0 ? aspectRatio : 16 / 9,
          child: VideoPlayer(_c),
        ),
      );

  @override
  Future<void> close() async {
    _c.removeListener(notifyListeners);
    await _c.dispose();
  }
}

class _NativeLiveVideo extends LiveVideo {
  _NativeLiveVideo(this.url, {this.liveOffset});

  static const _channel = MethodChannel(relayNativePlayerChannel);

  final Uri url;
  final double? liveOffset;
  int? _id;
  Timer? _poll;
  bool _closed = false;

  bool _initialized = false;
  bool _playing = false;
  bool _buffering = false;
  bool _muted = false;
  String? _error;
  double _aspect = 16 / 9;
  Duration _position = Duration.zero;
  Duration? _bufferedEnd;
  DateTime? _date;
  double? _rate;
  bool _pausedByUser = false;
  bool _pipPossible = false;
  String? _pipStatus;

  @override
  Future<void> initialize() async {
    final id = await _channel.invokeMethod<int>('create', {
      'url': url.toString(),
      if (liveOffset != null) 'liveOffset': liveOffset,
    });
    if (id == null) throw StateError('Could not create the player');
    _id = id;
    // Wait until AVPlayer has loaded the stream (or failed).
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    while (!_closed) {
      await _refresh();
      if (_error != null) throw StateError(_error!);
      if (_initialized) break;
      if (DateTime.now().isAfter(deadline)) throw TimeoutException('The stream took too long to load');
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    _poll = Timer.periodic(const Duration(milliseconds: 500), (_) => _refresh());
  }

  Future<void> _refresh() async {
    final id = _id;
    if (id == null || _closed) return;
    Map<Object?, Object?>? s;
    try {
      s = await _channel.invokeMapMethod<Object?, Object?>('state', {'id': id});
    } catch (e) {
      debugPrint('Native player state failed: $e');
      return;
    }
    if (s == null || _closed) return;
    int? ms(Object? v) => v is num ? v.toInt() : null;
    _initialized = _initialized || s['status'] == 'ready';
    _error = s['status'] == 'failed' ? (s['error'] as String? ?? 'Playback error') : null;
    _playing = s['playing'] == true;
    _buffering = s['buffering'] == true;
    _muted = s['muted'] == true;
    final w = s['width'], h = s['height'];
    if (w is num && h is num && w > 0 && h > 0) _aspect = w / h;
    final pos = ms(s['position']);
    if (pos != null) _position = Duration(milliseconds: pos);
    final buf = ms(s['bufferedEnd']);
    _bufferedEnd = buf == null ? null : Duration(milliseconds: buf);
    final date = s['date'];
    _date = date is num ? DateTime.fromMillisecondsSinceEpoch(date.round(), isUtc: true) : null;
    final rate = s['rate'];
    _rate = rate is num ? rate.toDouble() : null;
    _pipPossible = s['pipPossible'] == true;
    _pausedByUser = s['pausedByUser'] == true;
    String yn(Object? v) => v == true ? 'yes' : 'no';
    _pipStatus = 'PiP supported ${yn(s['pipSupported'])} · possible ${yn(s['pipPossible'])} · '
        'auto ${yn(s['pipAuto'])} · active ${yn(s['pip'])}';
    notifyListeners();
  }

  Future<void> _call(String method, [Map<String, Object?> extra = const {}]) async {
    final id = _id;
    if (id == null || _closed) return;
    await _channel.invokeMethod<void>(method, {'id': id, ...extra});
    await _refresh();
  }

  @override
  Future<void> play() => _call('play');
  @override
  Future<void> pause() => _call('pause');
  @override
  Future<void> setSpeed(double speed) => _call('setRate', {'rate': speed});
  @override
  Future<void> setMuted(bool muted) => _call('setMuted', {'muted': muted});
  @override
  Future<void> startPip() => _call('startPip');
  @override
  Future<void> setNowPlaying({String? title, String? artist, String? artworkUrl}) =>
      _call('setNowPlaying', {'title': title, 'artist': artist, 'artwork': artworkUrl});
  @override
  bool get pausedByUser => _pausedByUser;
  @override
  Future<void> seekForward(Duration by) =>
      _call('seekBy', {'seconds': by.inMilliseconds / 1000});
  @override
  bool get pipAvailable => _pipPossible;
  @override
  String? get pipStatus => _pipStatus;

  @override
  bool get isInitialized => _initialized;
  @override
  bool get isPlaying => _playing;
  @override
  bool get isBuffering => _buffering;
  @override
  bool get isMuted => _muted;
  @override
  String? get error => _error;
  @override
  double get aspectRatio => _aspect;
  @override
  Duration get position => _position;
  @override
  Duration? get bufferedEnd => _bufferedEnd;
  @override
  DateTime? get playheadDate => _date;
  @override
  double? get rate => _rate;

  @override
  Widget buildView() {
    final id = _id;
    if (id == null) return const SizedBox.shrink();
    // Taps go to Relay's own controls on top, not the native view.
    return IgnorePointer(
      child: UiKitView(
        key: ValueKey('relay-native-player-$id'),
        viewType: relayNativePlayerViewType,
        creationParams: {'id': id},
        creationParamsCodec: const StandardMessageCodec(),
      ),
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _poll?.cancel();
    final id = _id;
    if (id != null) {
      try {
        await _channel.invokeMethod<void>('dispose', {'id': id});
      } catch (_) {}
    }
  }
}
