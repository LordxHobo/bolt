import 'package:flutter_test/flutter_test.dart';
import 'package:relay/player/hls.dart';

void main() {
  final base = Uri.parse('https://video.example/hls/index.m3u8');

  test('master playlist: variants, names and server time', () {
    const text = '''
#EXTM3U
#EXT-X-TWITCH-INFO:NODE="x",SERVER-TIME="1700000000.50",USER-IP="1.2.3.4"
#EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="chunked",NAME="1080p60 (source)",AUTOSELECT=YES,DEFAULT=YES
#EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080,CODECS="avc1.64002A,mp4a.40.2",VIDEO="chunked",FRAME-RATE=60.000
https://cdn.example/chunked/index.m3u8
#EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="720p60",NAME="720p60",AUTOSELECT=YES,DEFAULT=YES
#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720,CODECS="avc1.4D401F,mp4a.40.2",VIDEO="720p60",FRAME-RATE=60.000
720p60/index.m3u8
''';
    final m = parseMasterPlaylist(text, base);
    expect(m.variants.length, 2);
    expect(m.variants[0].name, '1080p60 (source)');
    expect(m.variants[0].codecs, 'avc1.64002A,mp4a.40.2');
    expect(m.variants[0].height, 1080);
    expect(m.variants[1].uri.toString(), 'https://video.example/hls/720p60/index.m3u8');
    expect(m.serverTime!.millisecondsSinceEpoch, 1700000000500);
  });

  test('media playlist: ads, prefetch and program date time', () {
    const text = '''
#EXTM3U
#EXT-X-TARGETDURATION:6
#EXT-X-MEDIA-SEQUENCE:100
#EXT-X-PROGRAM-DATE-TIME:2024-01-01T00:00:00.000Z
#EXTINF:2.000,live
a.ts
#EXT-X-PROGRAM-DATE-TIME:2024-01-01T00:00:02.000Z
#EXTINF:2.000,Amazon|stitched-ad
ad.ts
#EXT-X-TWITCH-PREFETCH:https://cdn.example/next.ts
''';
    final p = parseMediaPlaylist(text, base);
    expect(p.targetDuration, 6);
    expect(p.segments.length, 2);
    expect(p.segments[0].title, 'live');
    expect(p.segments[0].uri.toString(), 'https://video.example/hls/a.ts');
    expect(p.segments[1].programDateTime, DateTime.utc(2024, 1, 1, 0, 0, 2));
    expect(p.prefetch.single.toString(), 'https://cdn.example/next.ts');
    expect(p.hasAdMarkers, isTrue);
  });

  group('Stitcher', () {
    final t0 = DateTime.utc(2024, 1, 1);
    Candidate seg(int i, {String source = 'main', bool prefetch = false, String? name}) => Candidate(
          uri: Uri.parse('https://cdn.example/${name ?? '$source$i'}.ts'),
          duration: 2,
          pdt: t0.add(Duration(seconds: i * 2)),
          source: source,
          prefetch: prefetch,
        );

    test('keeps sequence numbers stable and skips repeats', () {
      final s = Stitcher(window: 3);
      expect(s.add([seg(0), seg(1), seg(2)]), 3);
      expect(s.add([seg(1), seg(2), seg(3)]), 1);
      expect(s.segments.map((e) => e.seq), [1, 2, 3]);
      expect(s.render(), contains('#EXT-X-MEDIA-SEQUENCE:1'));
      expect(s.render(), contains('#EXT-X-TARGETDURATION:2'));
    });

    test('drops the real copy of a segment already served as prefetch', () {
      final s = Stitcher();
      s.add([seg(0), seg(1, prefetch: true, name: 'pf1')]);
      expect(s.add([seg(1)]), 0);
      expect(s.add([seg(2)]), 1);
    });

    test('marks a gap (dropped ads) and a source change as discontinuities', () {
      final s = Stitcher(window: 10);
      s.add([seg(0), seg(1), seg(5)]);
      expect(s.segments[2].discontinuity, isTrue);
      s.add([seg(6, source: 'embed')]);
      expect(s.segments[3].discontinuity, isTrue);
      expect('#EXT-X-DISCONTINUITY\n'.allMatches(s.render()).length, 2);
    });

    test('counts discontinuities that leave the window', () {
      final s = Stitcher(window: 2);
      s.add([seg(0), seg(5), seg(6), seg(7)]);
      expect(s.render(), contains('#EXT-X-DISCONTINUITY-SEQUENCE:1'));
    });

    test('finds served segments and rewrites their URIs', () {
      final s = Stitcher(window: 2);
      s.add([seg(0), seg(1), seg(2)]);
      expect(s.bySeq(0)!.uri.toString(), 'https://cdn.example/main0.ts');
      expect(s.bySeq(9), isNull);
      final text = s.render(uriFor: (e) => Uri.parse('http://127.0.0.1:1/s/${e.seq}.ts'));
      expect(text, contains('http://127.0.0.1:1/s/2.ts'));
      expect(text, isNot(contains('cdn.example')));
    });

    test('writes segments still being recorded as prefetch tags', () {
      final s = Stitcher(window: 6);
      s.add([seg(0), seg(1), seg(2, name: 'pf2', prefetch: true)]);
      final pf = Uri.parse('https://cdn.example/pf2.ts');
      final text = s.render(prefetchTags: {pf}, prefetchTag: '#EXT-X-TWITCH-PREFETCH:');
      expect(text, contains('#EXT-X-TWITCH-PREFETCH:https://cdn.example/pf2.ts'));
      expect('#EXTINF'.allMatches(text).length, 2);
      // Once it's finished (no longer listed as prefetch) it's a normal segment.
      final later = s.render(prefetchTags: const {});
      expect('#EXTINF'.allMatches(later).length, 3);
      expect(later, isNot(contains('PREFETCH')));
    });

    test('maps player position to stream time', () {
      final s = Stitcher(window: 2);
      s.add([seg(0), seg(1), seg(5), seg(6)]);
      // Player timeline: 0-2 seg0, 2-4 seg1, 4-6 seg5 (stream time 10s).
      expect(s.pdtAt(5), t0.add(const Duration(seconds: 11)));
      expect(s.windowStartTimeline, 4);
    });
  });
}
