import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/models.dart';
import 'twitch_api.dart';

/// One extension a Twitch channel has turned on.
class ChannelExtension {
  final String id;
  final String name;
  final String version;

  /// panel, video_overlay or component.
  final String anchor;

  const ChannelExtension({required this.id, required this.name, required this.version, required this.anchor});

  bool get isPanel => anchor == 'panel';

  String get kind => switch (anchor) {
        'video_overlay' => 'Overlay',
        'component' => 'Component',
        _ => 'Panel',
      };

  /// Twitch's own pop-out page for it (works for panels).
  WebUri popoutUrl(String login) =>
      WebUri('https://www.twitch.tv/popout/$login/extensions/$id-$version/$anchor');
}

/// The channel's full desktop page: overlays and components only run on top
/// of the website's own player.
WebUri channelPageUrl(String login) => WebUri('https://www.twitch.tv/$login');

/// Desktop browser: twitch.tv sends phones to its mobile site, which has no
/// extensions.
const desktopUserAgent =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';

/// On twitch.tv: start the website's player muted at the lowest quality
/// (it only has to be there for the extensions), and get past the
/// "intended for certain audiences" screen.
final _quietPlayerScript = UserScript(
  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
  source: r'''
(function () {
  if (location.hostname !== 'www.twitch.tv' || window.__boltQuiet) return;
  window.__boltQuiet = true;
  try {
    localStorage.setItem('video-muted', '{"default":true}');
    localStorage.setItem('video-quality', '{"default":"160p30"}');
    localStorage.setItem('volume', '0');
  } catch (e) {}
  setInterval(function () {
    document.querySelectorAll(
      '[data-a-target="content-classification-gate-overlay-start-watching-button"],' +
      '[data-a-target="player-overlay-mature-accept"]'
    ).forEach(function (b) { try { b.click(); } catch (e) {} });
    document.querySelectorAll('video').forEach(function (v) { v.muted = true; });
  }, 2000);
})();
''',
);

InAppWebViewSettings extensionWebSettings() => InAppWebViewSettings(
      javaScriptEnabled: true,
      userAgent: desktopUserAgent,
      preferredContentMode: UserPreferredContentMode.DESKTOP,
      // The website's player has to be allowed to start (muted) by itself.
      mediaPlaybackRequiresUserGesture: false,
      allowsInlineMediaPlayback: true,
      allowsPictureInPictureMediaPlayback: false,
      allowsAirPlayForMediaPlayback: false,
      thirdPartyCookiesEnabled: true,
      sharedCookiesEnabled: true,
      supportMultipleWindows: false,
    );

UnmodifiableListView<UserScript> extensionUserScripts() => UnmodifiableListView([_quietPlayerScript]);

/// Looks at a twitch.tv page: signed in? extensions on it? player playing?
const _probeJs = r'''
(function () {
  var frames = document.querySelectorAll('iframe[src*="ext-twitch.tv"]').length;
  var v = document.querySelector('video');
  return JSON.stringify({
    signedIn: document.cookie.indexOf('login=') !== -1,
    frames: frames,
    video: v ? (v.paused ? 'paused' : 'playing') : 'none'
  });
})();
''';

class TwitchExtensions {
  TwitchExtensions._();

  static Future<List<ChannelExtension>> forChannel(String login) async {
    final data = await TwitchGql.query(
      r'query($login: String) { user(login: $login) { channel { selfInstalledExtensions { installation { '
      'extension { id name version } activationConfig { anchor state } } } } } }',
      {'login': login},
    );
    final out = <ChannelExtension>[];
    final seen = <String>{};
    for (final e in jList(jMap(jMap(data['user'])?['channel'])?['selfInstalledExtensions'])) {
      final inst = jMap(jMap(e)?['installation']);
      final ext = jMap(inst?['extension']);
      final cfg = jMap(inst?['activationConfig']);
      final id = jStr(ext?['id']), version = jStr(ext?['version']);
      if (id == null || version == null) continue;
      final state = jStr(cfg?['state'])?.toUpperCase();
      if (state != null && state != 'ACTIVE') continue;
      if (!seen.add(id)) continue;
      out.add(ChannelExtension(
        id: id,
        name: jStr(ext?['name']) ?? 'Extension',
        version: version,
        anchor: (jStr(cfg?['anchor']) ?? 'panel').toLowerCase(),
      ));
    }
    return out;
  }

  /// A readable line about a twitch.tv page, from [_probeJs].
  static Future<String?> probe(InAppWebViewController c) async {
    try {
      final raw = await c.evaluateJavascript(source: _probeJs);
      final j = jMap(raw is String ? _decode(raw) : raw);
      if (j == null) return null;
      final frames = jInt(j['frames']) ?? 0;
      return [
        j['signedIn'] == true ? 'Signed in' : 'NOT signed in',
        frames == 0 ? 'no extensions on the page yet' : '$frames extension${frames == 1 ? '' : 's'} on the page',
        switch (jStr(j['video'])) {
          'playing' => 'player running (muted)',
          'paused' => 'player paused',
          _ => 'no player',
        },
      ].join(' · ');
    } catch (_) {
      return null;
    }
  }

  static Object? _decode(String s) {
    try {
      return jsonDecode(s);
    } catch (_) {
      return null;
    }
  }
}

class _Hidden {
  _Hidden(this.view);
  final HeadlessInAppWebView view;
  InAppWebViewController? controller;
  String status = 'Starting…';
  Timer? probe;
}

/// Keeps a channel's extensions running out of sight while you watch, so
/// ones that track watching (card drops and the like) see you as there:
/// the channel's desktop page, muted at the lowest quality. Stopped when
/// you leave the channel.
class ExtensionKeeper extends ChangeNotifier {
  ExtensionKeeper._();
  static final instance = ExtensionKeeper._();

  final Map<String, _Hidden> _pages = {};

  bool isRunning(String login) => _pages.containsKey(login);

  String? status(String login) => _pages[login]?.status;

  void _set(String login, _Hidden h, String status) {
    if (_pages[login] != h) return;
    h.status = status;
    notifyListeners();
  }

  Future<void> start(String login) async {
    if (_pages.containsKey(login)) return;
    late final _Hidden h;
    final view = HeadlessInAppWebView(
      initialSize: const Size(1280, 800),
      initialUrlRequest: URLRequest(url: channelPageUrl(login)),
      initialUserScripts: extensionUserScripts(),
      initialSettings: extensionWebSettings(),
      onWebViewCreated: (c) => h.controller = c,
      onLoadStart: (_, __) => _set(login, h, 'Loading twitch.tv…'),
      onLoadStop: (c, __) async {
        h.controller = c;
        _set(login, h, 'Loaded, waiting for extensions…');
        h.probe?.cancel();
        Future<void> check() async {
          final line = await TwitchExtensions.probe(c);
          if (line != null) _set(login, h, line);
        }

        h.probe = Timer.periodic(const Duration(seconds: 15), (_) => check());
        Timer(const Duration(seconds: 5), check);
      },
      onReceivedError: (_, req, err) {
        if (req.isForMainFrame ?? false) _set(login, h, 'Error: ${err.description}');
      },
    );
    h = _Hidden(view);
    _pages[login] = h;
    notifyListeners();
    try {
      await view.run();
    } catch (err) {
      debugPrint('Hidden extension page failed: $err');
      _set(login, h, 'Could not start: $err');
    }
  }

  Future<void> stop(String login) async {
    final h = _pages.remove(login);
    notifyListeners();
    h?.probe?.cancel();
    await h?.view.dispose();
  }

  /// What the hidden page looks like right now (a PNG).
  Future<Uint8List?> peek(String login) async {
    try {
      return await _pages[login]?.controller?.takeScreenshot();
    } catch (_) {
      return null;
    }
  }
}
