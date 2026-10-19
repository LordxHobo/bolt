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
  LiveProxy(this.source, {this.lowLatency = true});

  final StreamSource source;
  final bool lowLatency;

  HttpServer? _server;
  List<HlsVariant> _variants = [];
  final Map<int, Stitcher> _stitchers = {};
  final Map<int, Future<void>> _locks = {};
  int _generation = 0;
  bool _closed = false;

  final HttpClient _http = HttpClient()
    ..userAgent = browserUserAgent
    ..connectionTimeout = const Duration(seconds: 10);

  /// Segment downloads in progress, per player generation.
  final Map<int, int> _downloading = {};

  /// The newest segment the current player finished downloading.
  StitchedSegment? _lastFetched;

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
    _lastFetched = null;
    return Uri.parse('http://127.0.0.1:${_server!.port}/m/$_generation.m3u8');
  }

  /// "Seconds behind live" for a player at [position] whose buffer reaches
  /// [bufferedEnd].
  ///
  /// The end of the newest downloaded segment is the end of the buffer, and
  /// its timestamp is known, so: latency = age of that segment's end + how
  /// much buffer is still ahead of the playhead. This doesn't depend on how
  /// the player numbers its timeline (AVPlayer and ExoPlayer differ).
  double? latencyFor(Duration position, Duration bufferedEnd) {
    // While a segment is still arriving the buffer end is in between.
    if ((_downloading[_generation] ?? 0) > 0) return null;
    final seg = _lastFetched;
    final pdt = seg?.pdt;
    if (seg == null || pdt == null) return null;
    final ahead = (bufferedEnd - position).inMilliseconds / 1000;
    if (ahead < -0.5 || ahead > 120) return null;
    final edge = pdt.add(Duration(microseconds: (seg.duration * 1000000).round()));
    final now = DateTime.now().toUtc().add(serverOffset);
    final seconds = now.difference(edge).inMilliseconds / 1000 + (ahead < 0 ? 0 : ahead);
    if (seconds < 0 || seconds > 120) return null;
    return seconds;
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
    _downloading[gen] = (_downloading[gen] ?? 0) + 1;
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
      await res.pipe(response);
      complete = res.statusCode == HttpStatus.ok || res.statusCode == HttpStatus.partialContent;
    } catch (e) {
      debugPrint('LiveProxy segment failed: $e');
      try {
        response.statusCode = HttpStatus.badGateway;
        await response.close();
      } catch (_) {}
    } finally {
      _downloading[gen] = (_downloading[gen] ?? 1) - 1;
    }
    if (complete && gen == _generation) {
      final last = _lastFetched;
      if (last == null || seg.seq > last.seq) _lastFetched = seg;
    }
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
      for (final uri in playlist.prefetch) {
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
