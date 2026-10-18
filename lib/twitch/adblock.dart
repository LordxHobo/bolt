import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/net.dart';
import '../core/settings.dart';

/// Loads the TwitchAdSolutions userscript that gets injected into the
/// Twitch player at document start (the same way a userscript manager would).
class AdBlockScripts {
  static const vaftAsset = 'assets/adblock/vaft.user.js';
  static const videoSwapAsset = 'assets/adblock/video-swap-new.user.js';
  static const vaftForkUrl =
      'https://raw.githubusercontent.com/0rpi/twitch-adblock-userscript/main/twitch-adblock.user.js';

  static String? urlFor(Settings s) => switch (s.adBlock) {
        AdBlockScript.vaftFork => vaftForkUrl,
        AdBlockScript.custom => s.customScriptUrl.isEmpty ? null : s.customScriptUrl,
        _ => null,
      };

  static String _cacheKey(String url) => 'script:$url';

  /// The script source to inject, or null when ad blocking is off.
  static Future<String?> load(Settings s) async {
    switch (s.adBlock) {
      case AdBlockScript.off:
        return null;
      case AdBlockScript.vaft:
        return rootBundle.loadString(vaftAsset);
      case AdBlockScript.videoSwapNew:
        return rootBundle.loadString(videoSwapAsset);
      case AdBlockScript.vaftFork:
      case AdBlockScript.custom:
        final url = urlFor(s);
        if (url == null) return rootBundle.loadString(vaftAsset);
        final cached = s.prefs.getString(_cacheKey(url));
        if (cached != null) {
          // Refresh in the background for next time.
          download(s, url).catchError((Object _) => '');
          return cached;
        }
        try {
          return await download(s, url);
        } catch (e) {
          debugPrint('Ad-block script download failed, using bundled vaft: $e');
          return rootBundle.loadString(vaftAsset);
        }
    }
  }

  /// Downloads and caches a script. Throws when it doesn't look like JS.
  static Future<String> download(Settings s, String url) async {
    final res = await httpClient.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      throw ApiException('Download failed (HTTP ${res.statusCode})');
    }
    final body = utf8.decode(res.bodyBytes, allowMalformed: true);
    if (!body.contains('==UserScript==') && !body.contains('function')) {
      throw ApiException('That URL is not a userscript');
    }
    await s.prefs.setString(_cacheKey(url), body);
    return body;
  }

  /// Reads `@version` from a userscript header, for display in Settings.
  static String? versionOf(String? script) {
    if (script == null) return null;
    final m = RegExp(r'@version\s+(\S+)').firstMatch(script);
    return m?.group(1);
  }

  static String? cachedFor(Settings s) {
    final url = urlFor(s);
    return url == null ? null : s.prefs.getString(_cacheKey(url));
  }
}
