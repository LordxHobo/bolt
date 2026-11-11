import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/models.dart';
import '../core/silent_page.dart';
import 'twitch_api.dart';

/// One extension a Twitch channel has turned on.
class ChannelExtension {
  final String id;
  final String name;
  final String version;

  /// panel, video_overlay or component.
  final String anchor;

  const ChannelExtension({required this.id, required this.name, required this.version, required this.anchor});

  String get kind => switch (anchor) {
        'video_overlay' => 'Overlay',
        'component' => 'Component',
        _ => 'Panel',
      };

  /// Twitch's own pop-out page for it: it runs the extension the way the
  /// website does, signed in as you (the twitch.tv cookies are shared).
  WebUri popoutUrl(String login) =>
      WebUri('https://www.twitch.tv/popout/$login/extensions/$id-$version/$anchor');
}

/// Desktop browser: twitch.tv sends phones to its mobile site, which has no
/// extensions.
const desktopUserAgent =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';

InAppWebViewSettings extensionWebSettings() => InAppWebViewSettings(
      javaScriptEnabled: true,
      userAgent: desktopUserAgent,
      preferredContentMode: UserPreferredContentMode.DESKTOP,
      mediaPlaybackRequiresUserGesture: true,
      allowsInlineMediaPlayback: true,
      allowsPictureInPictureMediaPlayback: false,
      allowsAirPlayForMediaPlayback: false,
      thirdPartyCookiesEnabled: true,
      sharedCookiesEnabled: true,
      supportMultipleWindows: false,
    );

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
}

/// Extensions kept running out of sight while you watch, so ones that track
/// watching (card drops and the like) see you as there. Stopped when you
/// leave the channel.
class ExtensionKeeper extends ChangeNotifier {
  ExtensionKeeper._();
  static final instance = ExtensionKeeper._();

  final Map<String, HeadlessInAppWebView> _running = {};

  static String _key(String login, ChannelExtension e) => '$login/${e.id}';

  bool isRunning(String login, ChannelExtension e) => _running.containsKey(_key(login, e));

  int runningFor(String login) => _running.keys.where((k) => k.startsWith('$login/')).length;

  Future<void> start(String login, ChannelExtension e) async {
    final key = _key(login, e);
    if (_running.containsKey(key)) return;
    final view = HeadlessInAppWebView(
      initialSize: const Size(400, 700),
      initialUrlRequest: URLRequest(url: e.popoutUrl(login)),
      initialUserScripts: UnmodifiableListView([silentPageScript]),
      initialSettings: extensionWebSettings(),
      onReceivedError: (_, req, err) {
        if (req.isForMainFrame ?? false) debugPrint('Extension ${e.name}: ${err.description}');
      },
    );
    _running[key] = view;
    notifyListeners();
    try {
      await view.run();
    } catch (err) {
      debugPrint('Extension ${e.name} failed to start: $err');
      _running.remove(key);
      notifyListeners();
    }
  }

  Future<void> stop(String login, ChannelExtension e) async {
    final view = _running.remove(_key(login, e));
    notifyListeners();
    await view?.dispose();
  }

  Future<void> stopChannel(String login) async {
    final keys = _running.keys.where((k) => k.startsWith('$login/')).toList();
    if (keys.isEmpty) return;
    for (final k in keys) {
      await _running.remove(k)?.dispose();
    }
    notifyListeners();
  }
}
