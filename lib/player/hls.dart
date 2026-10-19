// Minimal HLS playlist parsing and re-writing for Relay's local stream relay.
//
// The relay sits between the video player and Twitch/Kick: it fetches the real
// playlists, keeps only the segments it wants (no ads, closer to live) and
// serves a clean, standards-compliant playlist to the player.

/// Parses an HLS attribute list like `BANDWIDTH=1,RESOLUTION=1920x1080,CODECS="a,b"`.
Map<String, String> parseHlsAttributes(String input) {
  final out = <String, String>{};
  var i = 0;
  while (i < input.length) {
    final eq = input.indexOf('=', i);
    if (eq < 0) break;
    final key = input.substring(i, eq).trim();
    var j = eq + 1;
    String value;
    if (j < input.length && input[j] == '"') {
      final end = input.indexOf('"', j + 1);
      if (end < 0) {
        value = input.substring(j + 1);
        j = input.length;
      } else {
        value = input.substring(j + 1, end);
        j = end + 1;
      }
    } else {
      final comma = input.indexOf(',', j);
      value = comma < 0 ? input.substring(j) : input.substring(j, comma);
      j = comma < 0 ? input.length : comma;
    }
    if (key.isNotEmpty) out[key] = value;
    // Skip the comma separating attributes.
    while (j < input.length && (input[j] == ',' || input[j] == ' ')) {
      j++;
    }
    i = j;
  }
  return out;
}

Uri _resolve(Uri base, String ref) => base.resolve(ref.trim());

class HlsVariant {
  HlsVariant({required this.uri, required this.attributes, this.name});

  final Uri uri;
  final Map<String, String> attributes;

  /// Human-readable name from EXT-X-MEDIA (Twitch: "1080p60 (source)").
  final String? name;

  int get bandwidth => int.tryParse(attributes['BANDWIDTH'] ?? '') ?? 0;
  String get codecs => attributes['CODECS'] ?? '';
  String? get resolution => attributes['RESOLUTION'];

  int? get width => int.tryParse(resolution?.split('x').first ?? '');
  int? get height {
    final parts = resolution?.split('x');
    return parts == null || parts.length < 2 ? null : int.tryParse(parts[1]);
  }

  double? get frameRate => double.tryParse(attributes['FRAME-RATE'] ?? '');

  bool get isAudioOnly =>
      resolution == null &&
      codecs.isNotEmpty &&
      !codecs.contains('avc') &&
      !codecs.contains('hvc') &&
      !codecs.contains('hev') &&
      !codecs.contains('av01');

  String get label {
    final n = name;
    if (n != null && n.isNotEmpty && n.toLowerCase() != 'chunked') return n;
    final h = height;
    if (h == null) return '${(bandwidth / 1000).round()} kbps';
    final fps = frameRate;
    return fps != null && fps > 31 ? '${h}p${fps.round()}' : '${h}p';
  }

  int get pixels => (width ?? 0) * (height ?? 0);
}

class HlsMaster {
  HlsMaster(this.variants, {this.serverTime});

  final List<HlsVariant> variants;

  /// Server clock from Twitch's SERVER-TIME, if present.
  final DateTime? serverTime;
}

HlsMaster parseMasterPlaylist(String text, Uri base) {
  final lines = text.replaceAll('\r', '').split('\n');
  final mediaNames = <String, String>{};
  DateTime? serverTime;
  for (final line in lines) {
    if (line.startsWith('#EXT-X-MEDIA:')) {
      final a = parseHlsAttributes(line.substring('#EXT-X-MEDIA:'.length));
      final group = a['GROUP-ID'];
      final name = a['NAME'];
      if (group != null && name != null && a['TYPE'] == 'VIDEO') mediaNames[group] = name;
    } else if (line.startsWith('#EXT-X-TWITCH-INFO:')) {
      final a = parseHlsAttributes(line.substring('#EXT-X-TWITCH-INFO:'.length));
      serverTime ??= _parseEpochSeconds(a['SERVER-TIME']);
    } else if (line.startsWith('#EXT-X-SESSION-DATA:')) {
      final a = parseHlsAttributes(line.substring('#EXT-X-SESSION-DATA:'.length));
      if (a['DATA-ID'] == 'SERVER-TIME') serverTime ??= _parseEpochSeconds(a['VALUE']);
    }
  }
  final variants = <HlsVariant>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
    final attrs = parseHlsAttributes(line.substring('#EXT-X-STREAM-INF:'.length));
    // The URI is the next non-empty, non-comment line.
    var j = i + 1;
    while (j < lines.length && (lines[j].trim().isEmpty || lines[j].startsWith('#'))) {
      if (lines[j].startsWith('#EXT-X-STREAM-INF:')) break;
      j++;
    }
    if (j >= lines.length || lines[j].startsWith('#')) continue;
    final group = attrs['VIDEO'];
    variants.add(HlsVariant(
      uri: _resolve(base, lines[j]),
      attributes: attrs,
      name: group == null ? null : mediaNames[group],
    ));
  }
  return HlsMaster(variants, serverTime: serverTime);
}

DateTime? _parseEpochSeconds(String? v) {
  final secs = double.tryParse(v ?? '');
  if (secs == null) return null;
  return DateTime.fromMillisecondsSinceEpoch((secs * 1000).round(), isUtc: true);
}

class HlsSegment {
  HlsSegment({
    required this.uri,
    required this.duration,
    this.title = '',
    this.programDateTime,
    this.map,
    this.discontinuity = false,
  });

  final Uri uri;
  final double duration;
  final String title;
  final DateTime? programDateTime;
  final Uri? map;
  final bool discontinuity;
}

class HlsMediaPlaylist {
  HlsMediaPlaylist({
    required this.segments,
    required this.prefetch,
    required this.targetDuration,
    required this.hasAdMarkers,
    required this.ended,
  });

  final List<HlsSegment> segments;

  /// Upcoming segments announced early (Twitch's low-latency prefetch).
  final List<Uri> prefetch;
  final int targetDuration;

  /// Twitch marks ad breaks with "stitched" dateranges.
  final bool hasAdMarkers;
  final bool ended;
}

HlsMediaPlaylist parseMediaPlaylist(String text, Uri base) {
  final lines = text.replaceAll('\r', '').split('\n');
  final segments = <HlsSegment>[];
  final prefetch = <Uri>[];
  var target = 0;
  double? pendingDuration;
  var pendingTitle = '';
  DateTime? pendingPdt;
  Uri? currentMap;
  var pendingDiscontinuity = false;
  var ended = false;
  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#EXTINF:')) {
      final body = line.substring('#EXTINF:'.length);
      final comma = body.indexOf(',');
      pendingDuration = double.tryParse(comma < 0 ? body : body.substring(0, comma));
      pendingTitle = comma < 0 ? '' : body.substring(comma + 1);
    } else if (line.startsWith('#EXT-X-PROGRAM-DATE-TIME:')) {
      pendingPdt = DateTime.tryParse(line.substring('#EXT-X-PROGRAM-DATE-TIME:'.length))?.toUtc();
    } else if (line.startsWith('#EXT-X-TARGETDURATION:')) {
      target = int.tryParse(line.substring('#EXT-X-TARGETDURATION:'.length)) ?? 0;
    } else if (line.startsWith('#EXT-X-MAP:')) {
      final uri = parseHlsAttributes(line.substring('#EXT-X-MAP:'.length))['URI'];
      currentMap = uri == null ? null : _resolve(base, uri);
    } else if (line == '#EXT-X-DISCONTINUITY') {
      pendingDiscontinuity = true;
    } else if (line == '#EXT-X-ENDLIST') {
      ended = true;
    } else if (line.startsWith('#EXT-X-TWITCH-PREFETCH:')) {
      prefetch.add(_resolve(base, line.substring('#EXT-X-TWITCH-PREFETCH:'.length)));
    } else if (line.startsWith('#EXT-X-PREFETCH:')) {
      prefetch.add(_resolve(base, line.substring('#EXT-X-PREFETCH:'.length)));
    } else if (!line.startsWith('#')) {
      final d = pendingDuration;
      if (d != null) {
        segments.add(HlsSegment(
          uri: _resolve(base, line),
          duration: d,
          title: pendingTitle,
          programDateTime: pendingPdt,
          map: currentMap,
          discontinuity: pendingDiscontinuity,
        ));
      }
      pendingDuration = null;
      pendingTitle = '';
      pendingPdt = null;
      pendingDiscontinuity = false;
    }
  }
  return HlsMediaPlaylist(
    segments: segments,
    prefetch: prefetch,
    targetDuration: target,
    hasAdMarkers: text.contains('stitched'),
    ended: ended,
  );
}

/// A segment offered to the [Stitcher].
class Candidate {
  Candidate({
    required this.uri,
    required this.duration,
    required this.source,
    this.pdt,
    this.map,
    this.discontinuity = false,
    this.prefetch = false,
  });

  final Uri uri;
  final double duration;
  final DateTime? pdt;
  final Uri? map;

  /// Which stream the segment came from ("primary", "embed", ...). A change
  /// of source gets a discontinuity tag so the player resets its timestamps.
  final String source;
  final bool discontinuity;
  final bool prefetch;
}

class StitchedSegment {
  StitchedSegment({
    required this.seq,
    required this.uri,
    required this.duration,
    required this.source,
    required this.timelineStart,
    this.pdt,
    this.map,
    this.discontinuity = false,
    this.prefetch = false,
  });

  final int seq;
  final Uri uri;
  final double duration;
  final DateTime? pdt;
  final Uri? map;
  final String source;
  final bool discontinuity;
  final bool prefetch;

  /// Seconds from the start of the first segment ever served, i.e. where this
  /// segment sits on the player's timeline.
  final double timelineStart;
}

/// Builds one continuous, ever-growing live playlist out of segments that may
/// come from different upstream playlists (main stream, ad-free backups,
/// prefetch). Sequence numbers are assigned once and never change, which is
/// what players need to follow a live stream.
class Stitcher {
  Stitcher({this.window = 6});

  /// How many segments the rendered playlist contains.
  final int window;

  final List<StitchedSegment> _segments = [];
  final List<Uri> _recentUris = [];
  int _nextSeq = 0;
  int _discontinuitySeq = 0;
  StitchedSegment? _last;
  double _timelineEnd = 0;

  /// Recent segments (including ones that left the window), to map a player
  /// position back to the stream's real time.
  final List<StitchedSegment> _history = [];

  List<StitchedSegment> get segments => List.unmodifiable(_segments);
  bool get isEmpty => _segments.isEmpty;
  StitchedSegment? get last => _last;

  /// Adds [candidates] (in playback order) that are newer than what was
  /// already served. Returns how many were added.
  int add(Iterable<Candidate> candidates) {
    var added = 0;
    for (final c in candidates) {
      if (_recentUris.contains(c.uri)) continue;
      final last = _last;
      var discontinuity = c.discontinuity;
      if (last != null) {
        final lastPdt = last.pdt;
        final pdt = c.pdt;
        if (lastPdt != null && pdt != null) {
          final lastEnd = lastPdt.add(_seconds(last.duration));
          // Already covered (same moment from another source, or the real
          // version of a prefetched segment).
          if (!pdt.isAfter(lastEnd.subtract(_seconds(c.duration * 0.5)))) continue;
          // A hole (e.g. ad segments we dropped): tell the player.
          if (pdt.difference(lastEnd) > _seconds(c.duration * 1.5)) discontinuity = true;
        }
        if (c.source != last.source) discontinuity = true;
      }
      final seg = StitchedSegment(
        seq: _nextSeq++,
        uri: c.uri,
        duration: c.duration,
        pdt: c.pdt,
        map: c.map,
        source: c.source,
        discontinuity: discontinuity && last != null,
        prefetch: c.prefetch,
        timelineStart: _timelineEnd,
      );
      _timelineEnd += c.duration;
      _segments.add(seg);
      _history.add(seg);
      if (_history.length > 300) _history.removeAt(0);
      _last = seg;
      _recentUris.add(c.uri);
      if (_recentUris.length > 60) _recentUris.removeAt(0);
      added++;
    }
    while (_segments.length > window) {
      final removed = _segments.removeAt(0);
      if (removed.discontinuity) _discontinuitySeq++;
    }
    return added;
  }

  /// Player-timeline position (seconds) where the rendered playlist starts.
  double? get windowStartTimeline => _segments.isEmpty ? null : _segments.first.timelineStart;

  /// The stream's real time at player-timeline position [t] (seconds).
  DateTime? pdtAt(double t) {
    for (var i = _history.length - 1; i >= 0; i--) {
      final h = _history[i];
      if (h.timelineStart <= t) {
        final pdt = h.pdt;
        if (pdt == null) return null;
        return pdt.add(_seconds(t - h.timelineStart));
      }
    }
    return null;
  }

  /// A recently served segment by its sequence number.
  StitchedSegment? bySeq(int seq) {
    for (var i = _history.length - 1; i >= 0; i--) {
      final h = _history[i];
      if (h.seq == seq) return h;
      if (h.seq < seq) break;
    }
    return null;
  }

  /// The playlist text. [uriFor] can point segments somewhere else (Relay
  /// routes them through its local relay to see what the player downloads).
  String render({Uri Function(StitchedSegment segment)? uriFor}) {
    final b = StringBuffer()
      ..writeln('#EXTM3U')
      ..writeln('#EXT-X-VERSION:6');
    var maxDur = 1.0;
    for (final s in _segments) {
      if (s.duration > maxDur) maxDur = s.duration;
    }
    b
      ..writeln('#EXT-X-TARGETDURATION:${maxDur.ceil()}')
      ..writeln('#EXT-X-MEDIA-SEQUENCE:${_segments.isEmpty ? _nextSeq : _segments.first.seq}')
      ..writeln('#EXT-X-DISCONTINUITY-SEQUENCE:$_discontinuitySeq');
    StitchedSegment? prev;
    for (final s in _segments) {
      if (s.discontinuity) b.writeln('#EXT-X-DISCONTINUITY');
      final map = s.map;
      if (map != null && (prev == null || s.discontinuity || prev.map != map)) {
        b.writeln('#EXT-X-MAP:URI="$map"');
      }
      final pdt = s.pdt;
      if (pdt != null) b.writeln('#EXT-X-PROGRAM-DATE-TIME:${pdt.toUtc().toIso8601String()}');
      b
        ..writeln('#EXTINF:${s.duration.toStringAsFixed(3)},')
        ..writeln((uriFor == null ? s.uri : uriFor(s)).toString());
      prev = s;
    }
    return b.toString();
  }
}

Duration _seconds(double s) => Duration(microseconds: (s * 1000000).round());

/// Rewrites a master playlist so every variant points at the local relay.
/// Audio-only variants are left out; [only] keeps a single variant (for a
/// fixed quality choice).
String renderMaster(List<HlsVariant> variants, String Function(int index) variantUrl, {int? only}) {
  final b = StringBuffer()
    ..writeln('#EXTM3U')
    ..writeln('#EXT-X-VERSION:6')
    ..writeln('#EXT-X-INDEPENDENT-SEGMENTS');
  for (var i = 0; i < variants.length; i++) {
    if (only != null && i != only) continue;
    final v = variants[i];
    // Keep only standard attributes the player needs; Twitch/IVS add their
    // own (some quoted) that we'd otherwise have to re-quote correctly.
    const keep = ['BANDWIDTH', 'AVERAGE-BANDWIDTH', 'CODECS', 'RESOLUTION', 'FRAME-RATE'];
    final attrText = [
      for (final k in keep)
        if (v.attributes[k] != null) k == 'CODECS' ? '$k="${v.attributes[k]}"' : '$k=${v.attributes[k]}',
    ].join(',');
    b
      ..writeln('#EXT-X-STREAM-INF:$attrText')
      ..writeln(variantUrl(i));
  }
  return b.toString();
}
