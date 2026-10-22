import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/net.dart';
import 'hls.dart';
import 'sources.dart';

/// What the relay is currently doing about ads.
enum AdState { none, blocking, waiting }

/// A tiny HTTP server on 127.0.0.1 that the video player streams from.
///
/// For every playlist request it fetches the real playlist, keeps only the
/// segments worth playing (no ads, optionally Twitch's early "prefetch"
/// segments so playback starts closer to live) and serves a clean playlist.
/// Video segments are passed through too, so Relay knows exactly which part
/// of the stream the player has downloaded (that's what the latency readout
/// is based on).
class LiveProxy {
  LiveProxy(this.source, {this.lowLatency = true, this.proxySegments = true});

  final StreamSource source;
  final bool lowLatency;

  /// Route video segments through the relay too (needed for [latencyFor]).
  final bool proxySegments;

  HttpServer? _server;
  List<HlsVariant> _variants = [];
  final Map<int, Stitcher> _stitchers = {};
  final Map<int, Future<void>> _locks = {};
  int _generation = 0;
  bool _closed = false;

  final HttpClient _http = HttpClient()
    ..userAgent = browserUserAgent
    ..connectionTimeout = const Duration(seconds: 10);

  /// The newest segment the current player finished downloading.
  StitchedSegment? _lastFetched;
  int _segRequests = 0;
  int _segCompleted = 0;

  /// Recent estimates of "stream time at player position 0" (microseconds
  /// since epoch), see [latencyFor].
  final List<int> _anchors = [];

  /// Index of the forced quality, or null for automatic.
  int? selectedVariant;

  /// Server clock minus device clock.
  Duration serverOffset = Duration.zero;

  /// Ad handling state, for the player overlay.
  final adState = ValueNotifier<AdState>(AdState.none);

  List<HlsVariant> get variants => List.unmodifiable(_variants);

  /// The variant being played: the chosen one, or the best available.
  int get playingVariant => selectedVariant ?? bestVariantIndex(_variants);

  static int bestVariantIndex(List<HlsVariant> variants) {
    var best = 0;
    for (var i = 1; i < variants.length; i++) {
      final a = variants[i], b = variants[best];
      final byPixels = a.pixels.compareTo(b.pixels);
      final byFps = (a.frameRate ?? 0).compareTo(b.frameRate ?? 0);
      final byBandwidth = a.bandwidth.compareTo(b.bandwidth);
      if (byPixels > 0 || (byPixels == 0 && (byFps > 0 || (byFps == 0 && byBandwidth > 0)))) {
        best = i;
      }
    }
    return best;
  }

  /// Starts the server and loads the stream. Returns the URL to play.
  Future<Uri> start() async {
    final master = await source.loadMaster();
    _variants = master.variants;
    serverOffset = master.serverOffset ?? Duration.zero;
    if (_server == null) {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen(_handle, onError: (Object e) => debugPrint('LiveProxy server error: $e'));
      _server = server;
    }
    return playUrl();
  }

  /// URL of the master playlist; changes when the quality choice changes so
  /// the player can't serve a stale copy.
  Uri playUrl() {
    _generation++;
    // A fresh timeline for the new player instance.
    _stitchers.clear();
    _edgeAges.clear();
    _lastFetched = null;
    _anchors.clear();
    _segRequests = 0;
    _segCompleted = 0;
    return Uri.parse('http://127.0.0.1:${_server!.port}/m/$_generation.m3u8');
  }

  /// "Seconds behind live" for a player at [position] whose buffer reaches
  /// [bufferedEnd] (null if the player doesn't report its buffer).
  ///
  /// The buffer ends at the end of the newest downloaded segment, plus
  /// whatever part of the next one has arrived so far (at the live edge one
  /// is almost always arriving). So "end of the newest finished segment minus
  /// bufferedEnd" is never later than the stream time at player position 0,
  /// and equals it whenever nothing extra has arrived. The latest of the
  /// recent estimates is used. This works however the player numbers its
  /// timeline (AVPlayer and ExoPlayer differ).
  double? latencyFor(Duration position, Duration? bufferedEnd) {
    final seg = _lastFetched;
    final pdt = seg?.pdt;
    if (seg == null || pdt == null) return null;
    final end = pdt.add(Duration(microseconds: (seg.duration * 1000000).round()));
    final reference = bufferedEnd ?? position;
    _anchors.add(end.microsecondsSinceEpoch - reference.inMicroseconds);
    if (_anchors.length > 20) _anchors.removeAt(0);
    final anchor = _anchors.reduce((a, b) => a > b ? a : b);
    final playhead = anchor + position.inMicroseconds;
    final now = DateTime.now().toUtc().add(serverOffset).microsecondsSinceEpoch;
    final seconds = (now - playhead) / 1000000;
    if (seconds < 0 || seconds > 120) return null;
    return seconds;
  }

  /// The raw numbers behind the latency readout, for troubleshooting.
  String debugInfo(Duration position, Duration? bufferedEnd, double speed) {
    String sec(num v) => v.toStringAsFixed(1);
    final now = DateTime.now().toUtc().add(serverOffset);
    String age(StitchedSegment? s) {
      final pdt = s?.pdt;
      if (s == null || pdt == null) return '-';
      final end = pdt.add(Duration(microseconds: (s.duration * 1000000).round()));
      return '#${s.seq} ${sec(now.difference(end).inMilliseconds / 1000)}s';
    }
    final newest = _stitchers[playingVariant]?.last;
    return 'pos ${sec(position.inMilliseconds / 1000)} · '
        'buf ${bufferedEnd == null ? '-' : sec(bufferedEnd.inMilliseconds / 1000)} · '
        '${speed}x\n'
        'got ${age(_lastFetched)} · newest ${age(newest)}\n'
        'segments $_segCompleted/$_segRequests · '
        'newest video ${edgeLag?.toStringAsFixed(1) ?? '-'}s old';
  }

  Future<void> close() async {
    _closed = true;
    adState.dispose();
    _http.close(force: true);
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final path = request.uri.path;
      if (path.startsWith('/s/')) {
        await _segment(request);
        return;
      }
      String? body;
      if (path.startsWith('/m/')) {
        body = renderMaster(
          _variants,
          (i) => 'http://127.0.0.1:${_server!.port}/v/$i.m3u8',
          // One quality at a time: switching between separately stitched
          // playlists could skip or repeat video.
          only: playingVariant,
        );
      } else if (path.startsWith('/v/')) {
        final index = int.tryParse(path.substring(3).split('.').first);
        if (index != null && index >= 0 && index < _variants.length) {
          body = await _serialized(index, () => _variantPlaylist(index));
        }
      }
      if (body == null) {
        request.response.statusCode = HttpStatus.notFound;
      } else {
        request.response.headers
          ..set(HttpHeaders.contentTypeHeader, 'application/vnd.apple.mpegurl')
          ..set(HttpHeaders.cacheControlHeader, 'no-cache, no-store');
        request.response.write(body);
      }
    } catch (e) {
      debugPrint('LiveProxy request failed: $e');
      request.response.statusCode = e is StreamOfflineException ? HttpStatus.notFound : HttpStatus.badGateway;
    }
    await request.response.close();
  }

  /// Passes one video segment from the CDN to the player.
  /// Path: /s/<generation>/<variant>/<seq>.<ext>
  Future<void> _segment(HttpRequest request) async {
    final response = request.response;
    final parts = request.uri.pathSegments;
    final gen = parts.length == 4 ? int.tryParse(parts[1]) : null;
    final index = parts.length == 4 ? int.tryParse(parts[2]) : null;
    final seq = parts.length == 4 ? int.tryParse(parts[3].split('.').first) : null;
    final seg = (gen == _generation && index != null && seq != null)
        ? _stitchers[index]?.bySeq(seq)
        : null;
    if (seg == null || gen == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    // Players download segments in order, so asking for this one means the
    // previous one is complete (in case we never saw it finish).
    final previous = _stitchers[index]?.bySeq(seg.seq - 1);
    if (previous != null) _markFetched(gen, previous);
    _segRequests++;
    var complete = false;
    try {
      final upstream = await _http.getUrl(seg.uri);
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) upstream.headers.set(HttpHeaders.rangeHeader, range);
      final res = await upstream.close();
      response.statusCode = res.statusCode;
      final type = res.headers.value(HttpHeaders.contentTypeHeader);
      response.headers.set(HttpHeaders.contentTypeHeader,
          type ?? (seg.uri.path.endsWith('.ts') ? 'video/mp2t' : 'application/octet-stream'));
      if (res.contentLength >= 0) response.contentLength = res.contentLength;
      final contentRange = res.headers.value(HttpHeaders.contentRangeHeader);
      if (contentRange != null) response.headers.set(HttpHeaders.contentRangeHeader, contentRange);
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      // Stream it through as it arrives; prefetch segments are still being
      // produced while the player downloads them.
      await response.addStream(res);
      complete = res.statusCode == HttpStatus.ok || res.statusCode == HttpStatus.partialContent;
      await response.close();
    } catch (e) {
      debugPrint('LiveProxy segment failed: $e');
      try {
        response.statusCode = HttpStatus.badGateway;
        await response.close();
      } catch (_) {}
    }
    if (complete) {
      _segCompleted++;
      _markFetched(gen, seg);
    }
  }

  void _markFetched(int gen, StitchedSegment seg) {
    if (gen != _generation) return;
    final last = _lastFetched;
    if (last == null || seg.seq > last.seq) _lastFetched = seg;
  }

  /// Runs requests for the same variant one at a time.
  Future<String> _serialized(int index, Future<String> Function() task) {
    final previous = _locks[index] ?? Future.value();
    final result = previous.then((_) => task());
    _locks[index] = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<String> _variantPlaylist(int index) async {
    final stitcher = _stitchers.putIfAbsent(index, () => Stitcher(window: lowLatency ? 6 : 10));
    // At startup there may be nothing playable yet (e.g. a pre-roll ad with no
    // ad-free backup). Keep the player waiting a little rather than handing
    // it an empty playlist.
    for (var attempt = 0; attempt < 8 && !_closed; attempt++) {
      await _update(index, stitcher);
      if (!stitcher.isEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    }
    if (!proxySegments) return stitcher.render();
    final gen = _generation;
    final port = _server!.port;
    return stitcher.render(uriFor: (s) {
      final name = s.uri.pathSegments.isEmpty ? '' : s.uri.pathSegments.last;
      final dot = name.lastIndexOf('.');
      final ext = dot < 0 ? '.ts' : name.substring(dot);
      return Uri.parse('http://127.0.0.1:$port/s/$gen/$index/${s.seq}$ext');
    });
  }

  Future<void> _update(int index, Stitcher stitcher) async {
    final variant = _variants[index];
    HlsMediaPlaylist playlist;
    try {
      playlist = await source.loadVariant(variant);
    } catch (e) {
      // Playlist links expire: reload the master once and map to the same quality.
      debugPrint('LiveProxy: variant fetch failed ($e), reloading master');
      final master = await source.loadMaster();
      final match = closestVariant(master.variants, variant);
      if (match == null) rethrow;
      _variants = [
        for (final v in _variants) closestVariant(master.variants, v) ?? v,
      ];
      playlist = await source.loadVariant(match);
    }

    final hasAds = source.blocksAds && playlist.segments.any(source.isAd);
    final candidates = <Candidate>[];
    for (final s in playlist.segments) {
      if (source.blocksAds && source.isAd(s)) continue;
      candidates.add(_candidate(s, 'main'));
    }

    if (hasAds) {
      final backup = await source.loadBackup(variant);
      if (backup != null) {
        for (final s in backup.playlist.segments) {
          if (!source.isAd(s)) candidates.add(_candidate(s, backup.source));
        }
        _setAdState(AdState.blocking);
      } else {
        // No ad-free copy anywhere: play the break as Twitch sends it rather
        // than freezing until it's over.
        candidates
          ..clear()
          ..addAll([
            for (final s in playlist.segments) _candidate(s, source.isAd(s) ? 'ad' : 'main'),
          ]);
        _setAdState(AdState.waiting);
      }
      // Put backup segments in time order with the main ones.
      candidates.sort((a, b) {
        final pa = a.pdt, pb = b.pdt;
        if (pa == null || pb == null) return 0;
        return pa.compareTo(pb);
      });
    } else {
      _setAdState(AdState.none);
    }

    // Prefetch: Twitch lists the next segments before they're complete. Giving
    // them to the player lets it start right at the live edge. Skipped during
    // ads, when the upcoming segments could be ads.
    if (lowLatency && !hasAds && playlist.segments.isNotEmpty && playlist.prefetch.isNotEmpty) {
      final last = playlist.segments.last;
      var pdt = last.programDateTime;
      // Only the first one: it's the segment being recorded right now. The
      // next one doesn't exist yet, and listing it makes the player start
      // on video that hasn't been made, so it stalls right after starting.
      for (final uri in playlist.prefetch.take(1)) {
        pdt = pdt?.add(Duration(microseconds: (last.duration * 1000000).round()));
        candidates.add(Candidate(
          uri: uri,
          duration: last.duration,
          pdt: pdt,
          map: last.map,
          source: 'main',
          prefetch: true,
        ));
      }
    }

    // On the very first fetch only keep the newest segments, so the player
    // starts near live instead of at the start of a long playlist.
    if (stitcher.isEmpty && candidates.length > stitcher.window) {
      candidates.removeRange(0, candidates.length - stitcher.window);
    }
    stitcher.add(candidates);
    if (index == playingVariant) _sampleEdge(stitcher);
  }

  /// How old the newest video in the playlist is, sampled at each refresh.
  final List<double> _edgeAges = [];

  void _sampleEdge(Stitcher stitcher) {
    final last = stitcher.last;
    final pdt = last?.pdt;
    if (last == null || pdt == null) return;
    final end = pdt.add(Duration(microseconds: (last.duration * 1000000).round()));
    final now = DateTime.now().toUtc().add(serverOffset);
    _edgeAges.add(now.difference(end).inMilliseconds / 1000);
    if (_edgeAges.length > 15) _edgeAges.removeAt(0);
  }

  /// How far behind live the newest available video is (worst recent case).
  /// Low-latency Twitch streams are ~0 s (Twitch hands out the segment being
  /// recorded); streams without that (Twitch "normal latency", Kick) lag
  /// several seconds, and the player can't get closer than this.
  double? get edgeLag {
    if (_edgeAges.length < 3) return null;
    return _edgeAges.reduce((a, b) => a > b ? a : b);
  }

  void _setAdState(AdState state) {
    if (!_closed) adState.value = state;
  }

  Candidate _candidate(HlsSegment s, String sourceName) => Candidate(
        uri: s.uri,
        duration: s.duration,
        pdt: s.programDateTime,
        map: s.map,
        source: sourceName,
        discontinuity: s.discontinuity,
      );
}
