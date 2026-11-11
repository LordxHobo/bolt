import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/net.dart';

/// A 7TV badge: its picture and name.
class SevenTvBadge {
  final String name;
  final String url;
  const SevenTvBadge(this.name, this.url);
}

/// A 7TV name paint, ready to draw: a gradient (or a single color) for the
/// letters, plus optional glow/shadows.
class SevenTvPaint {
  final String name;
  final Gradient? gradient;
  final Color? color;

  /// A (usually animated) picture the letters are cut out of.
  final String? imageUrl;
  final List<Shadow> shadows;
  const SevenTvPaint(this.name, {this.gradient, this.color, this.imageUrl, this.shadows = const []});

  bool get drawable => gradient != null || color != null || imageUrl != null;
}

/// 7TV badges and name paints ("cosmetics") that chatters picked on 7TV.
///
/// Uses 7TV's API: all paints and badges are loaded once, and each new
/// chatter is looked up (in batches) to see which ones they have on.
class SevenTvCosmetics extends ChangeNotifier {
  SevenTvCosmetics._();
  static final instance = SevenTvCosmetics._();

  static const _gql = 'https://7tv.io/v4/gql';

  Map<String, SevenTvPaint> _paints = const {};
  Map<String, SevenTvBadge> _badges = const {};
  Future<void>? _catalog;

  /// platform:userId → (paint id, badge id); null = looked up, nothing on.
  final Map<String, (String?, String?)?> _users = {};
  final Set<String> _queued = {};
  Timer? _flush;

  static String _key(StreamPlatform p, String id) => '${p.name}:$id';

  SevenTvPaint? paintFor(StreamPlatform p, String? userId) {
    if (userId == null) return null;
    final id = _users[_key(p, userId)]?.$1;
    return id == null ? null : _paints[id];
  }

  SevenTvBadge? badgeFor(StreamPlatform p, String? userId) {
    if (userId == null) return null;
    final id = _users[_key(p, userId)]?.$2;
    return id == null ? null : _badges[id];
  }

  /// Asks 7TV about this chatter (once per app run), a batch at a time.
  void request(StreamPlatform p, String? userId) {
    if (userId == null || userId.isEmpty) return;
    final key = _key(p, userId);
    if (_users.containsKey(key) || !_queued.add(key)) return;
    _flush ??= Timer(const Duration(milliseconds: 600), _lookUp);
  }

  Future<Map<String, dynamic>> _query(String query) async {
    final res = await httpClient
        .post(Uri.parse(_gql), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'query': query}))
        .timeout(const Duration(seconds: 15));
    final json = jMap(decodeJson(res, '7TV'));
    final data = jMap(json?['data']);
    if (data == null) throw ApiException('7TV: ${json?['errors'] ?? 'no data'}');
    return data;
  }

  Future<void> _loadCatalog() => _catalog ??= () async {
        try {
          final data = await _query(
            'query { paints { paints { id name data { layers { opacity ty { __typename '
            '... on PaintLayerTypeSingleColor { color { hex } } '
            '... on PaintLayerTypeLinearGradient { angle repeating stops { at color { hex } } } '
            '... on PaintLayerTypeRadialGradient { repeating shape stops { at color { hex } } } '
            '... on PaintLayerTypeImage { images { url mime scale frameCount } } '
            '} } shadows { color { hex } offsetX offsetY blur } } } } '
            'badges { badges { id name description images { url mime scale } } } }',
          );
          _paints = {
            for (final p in jList(jMap(data['paints'])?['paints']))
              if (jMap(p) case final m?)
                if (jStr(m['id']) case final id?) id: _parsePaint(m),
          };
          _badges = {
            for (final b in jList(jMap(data['badges'])?['badges']))
              if (jMap(b) case final m?)
                if (jStr(m['id']) case final id?)
                  if (_badgeUrl(m) case final url?) id: SevenTvBadge(jStr(m['description']) ?? jStr(m['name']) ?? '7TV', url),
          };
        } catch (e) {
          debugPrint('7TV cosmetics catalog failed: $e');
          _catalog = null; // try again later
        }
      }();

  Future<void> _lookUp() async {
    _flush = null;
    await _loadCatalog();
    // Up to 40 chatters per request (7TV limits how big a request can be).
    final keys = _queued.take(40).toList();
    _queued.removeAll(keys);
    if (_queued.isNotEmpty) _flush = Timer(const Duration(milliseconds: 600), _lookUp);
    if (keys.isEmpty) return;
    final parts = <String>[];
    for (var i = 0; i < keys.length; i++) {
      final colon = keys[i].indexOf(':');
      final platform = keys[i].substring(0, colon) == 'kick' ? 'KICK' : 'TWITCH';
      final id = keys[i].substring(colon + 1).replaceAll('"', '');
      parts.add('u$i: userByConnection(platform: $platform, platformId: "$id") '
          '{ style { activePaintId activeBadgeId } }');
    }
    try {
      final data = jMap((await _query('query { users { ${parts.join(' ')} } }'))['users']);
      var changed = false;
      for (var i = 0; i < keys.length; i++) {
        final style = jMap(jMap(data?['u$i'])?['style']);
        final paint = jStr(style?['activePaintId']);
        final badge = jStr(style?['activeBadgeId']);
        _users[keys[i]] = (paint == null && badge == null) ? null : (paint, badge);
        if (paint != null || badge != null) changed = true;
      }
      if (changed) notifyListeners();
    } catch (e) {
      debugPrint('7TV user lookup failed: $e');
      // Don't ask again this run (avoids hammering 7TV when it's down).
      for (final k in keys) {
        _users[k] = null;
      }
    }
  }

  static String? _badgeUrl(Map<String, dynamic> m) {
    final images = [for (final i in jList(m['images'])) if (jMap(i) case final x?) x];
    // A 2x picture iOS can draw (no AVIF).
    images.sort((a, b) => ((jInt(a['scale']) ?? 1) - 2).abs().compareTo(((jInt(b['scale']) ?? 1) - 2).abs()));
    for (final pass in [
      (String mime) => mime.contains('png') || mime.contains('webp'),
      (String mime) => !mime.contains('avif'),
    ]) {
      for (final i in images) {
        if (pass(jStr(i['mime']) ?? '')) return jStr(i['url']);
      }
    }
    return null;
  }

  /// 7TV colors are "#RRGGBBAA".
  static Color? _color(Object? c) {
    final hex = jStr(jMap(c)?['hex'])?.replaceFirst('#', '');
    if (hex == null || hex.length != 8) return null;
    final v = int.tryParse(hex, radix: 16);
    if (v == null) return null;
    return Color(((v & 0xFF) << 24) | (v >> 8));
  }

  static SevenTvPaint _parsePaint(Map<String, dynamic> m) {
    final name = jStr(m['name']) ?? '';
    final data = jMap(m['data']);
    Gradient? gradient;
    Color? color;
    String? imageUrl;
    for (final l in jList(data?['layers'])) {
      final ty = jMap(jMap(l)?['ty']);
      if (ty == null) continue;
      final stopsRaw = [
        for (final s in jList(ty['stops']))
          if (jMap(s) case final st?)
            if (_color(st['color']) case final c?) ((jNum(st['at']) ?? 0).toDouble(), c),
      ];
      switch (jStr(ty['__typename'])) {
        case 'PaintLayerTypeLinearGradient' when stopsRaw.length >= 2:
          gradient = _linear((jNum(ty['angle']) ?? 90).toDouble(), ty['repeating'] == true, stopsRaw);
        case 'PaintLayerTypeRadialGradient' when stopsRaw.length >= 2:
          gradient = RadialGradient(
            colors: [for (final s in stopsRaw) s.$2],
            stops: [for (final s in stopsRaw) s.$1.clamp(0.0, 1.0)],
            radius: 0.8,
            tileMode: ty['repeating'] == true ? TileMode.repeated : TileMode.clamp,
          );
        case 'PaintLayerTypeSingleColor':
          color ??= _color(ty['color']);
        case 'PaintLayerTypeImage':
          imageUrl ??= _paintImageUrl(ty);
      }
    }
    final shadows = [
      for (final s in jList(data?['shadows']))
        if (jMap(s) case final sh?)
          if (_color(sh['color']) case final c?)
            Shadow(
              color: c,
              offset: Offset((jNum(sh['offsetX']) ?? 0).toDouble(), (jNum(sh['offsetY']) ?? 0).toDouble()),
              blurRadius: (jNum(sh['blur']) ?? 0).toDouble(),
            ),
    ];
    // Paints built on a picture often have a see-through color under it;
    // never draw a name in (nearly) invisible colors.
    if (color != null && color.a < 0.25) color = null;
    if (gradient != null && gradient.colors.every((c) => c.a < 0.25)) gradient = null;
    return SevenTvPaint(name, gradient: gradient, color: color, imageUrl: imageUrl, shadows: shadows);
  }

  /// The paint's picture in a format iOS can play (animated WebP or GIF,
  /// not AVIF), preferring the animated, 1x version.
  static String? _paintImageUrl(Map<String, dynamic> ty) {
    final images = [for (final i in jList(ty['images'])) if (jMap(i) case final x?) x];
    int rank(Map<String, dynamic> i) {
      final mime = jStr(i['mime']) ?? '';
      var r = 0;
      if (mime.contains('avif')) r += 100;
      if (!(mime.contains('webp') || mime.contains('gif'))) r += 10;
      if ((jInt(i['frameCount']) ?? 1) <= 1) r += 5;
      r += ((jInt(i['scale']) ?? 1) - 1).abs();
      return r;
    }

    images.sort((a, b) => rank(a).compareTo(rank(b)));
    for (final i in images) {
      if (!(jStr(i['mime']) ?? '').contains('avif')) return jStr(i['url']);
    }
    return null;
  }

  /// CSS-style angle (0 = upwards, 90 = to the right).
  static Gradient _linear(double angle, bool repeating, List<(double, Color)> stops) {
    final rad = angle * math.pi / 180;
    final dx = math.sin(rad), dy = -math.cos(rad);
    var scale = 1.0;
    if (repeating && stops.last.$1 > 0 && stops.last.$1 < 1) scale = stops.last.$1;
    final at = [for (final s in stops) (s.$1 / (repeating ? scale : 1)).clamp(0.0, 1.0)];
    return LinearGradient(
      begin: Alignment(-dx, -dy),
      end: Alignment(-dx + 2 * dx * scale, -dy + 2 * dy * scale),
      colors: [for (final s in stops) s.$2],
      stops: at,
      tileMode: repeating ? TileMode.repeated : TileMode.clamp,
    );
  }
}

/// A chatter's name drawn with their 7TV paint.
class PaintedName extends StatelessWidget {
  const PaintedName({super.key, required this.text, required this.paint, required this.style});

  final String text;
  final SevenTvPaint paint;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    if (paint.imageUrl != null) {
      return _ImagePaintedName(text: text, paint: paint, style: style);
    }
    final letters = paint.gradient == null
        ? Text(text, style: style.copyWith(color: paint.color))
        : ShaderMask(
            blendMode: BlendMode.srcIn,
            shaderCallback: (bounds) => paint.gradient!.createShader(bounds),
            child: Text(text, style: style.copyWith(color: Colors.white)),
          );
    if (paint.shadows.isEmpty) return letters;
    return Stack(
      children: [
        // The glow/shadow underneath, then the painted letters.
        Text(text, style: style.copyWith(color: Colors.transparent, shadows: paint.shadows)),
        letters,
      ],
    );
  }
}

/// A name cut out of the paint's picture, following its animation.
class _ImagePaintedName extends StatefulWidget {
  const _ImagePaintedName({required this.text, required this.paint, required this.style});

  final String text;
  final SevenTvPaint paint;
  final TextStyle style;

  @override
  State<_ImagePaintedName> createState() => _ImagePaintedNameState();
}

class _ImagePaintedNameState extends State<_ImagePaintedName> {
  ImageStream? _stream;
  late final _listener = ImageStreamListener(_onFrame, onError: (_, __) {});
  ui.Image? _frame;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(_ImagePaintedName old) {
    super.didUpdateWidget(old);
    if (old.paint.imageUrl != widget.paint.imageUrl) _resolve();
  }

  void _resolve() {
    final stream = NetworkImage(widget.paint.imageUrl!).resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) return;
    _stream?.removeListener(_listener);
    _stream = stream..addListener(_listener);
  }

  void _onFrame(ImageInfo info, bool _) {
    if (!mounted) return;
    setState(() => _frame = info.image);
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final frame = _frame;
    final style = widget.style;
    Widget letters;
    if (frame == null) {
      // Until the picture is in: the paint's colors, or the normal name.
      letters = widget.paint.gradient != null || widget.paint.color != null
          ? PaintedName(
              text: widget.text,
              paint: SevenTvPaint(widget.paint.name, gradient: widget.paint.gradient, color: widget.paint.color),
              style: style,
            )
          : Text(widget.text, style: style);
    } else {
      // The picture fills the height of the line and repeats sideways.
      final lineHeight = (style.fontSize ?? 14) * (style.height ?? 1.3);
      final scale = lineHeight / frame.height;
      final matrix = Matrix4.diagonal3Values(scale, scale, 1).storage;
      letters = Text(
        widget.text,
        // (copyWith drops the plain color when a foreground is given.)
        style: style.copyWith(
          foreground: Paint()..shader = ImageShader(frame, TileMode.repeated, TileMode.repeated, matrix),
        ),
      );
    }
    if (widget.paint.shadows.isEmpty) return letters;
    return Stack(
      children: [
        Text(widget.text, style: style.copyWith(color: Colors.transparent, shadows: widget.paint.shadows)),
        letters,
      ],
    );
  }
}
