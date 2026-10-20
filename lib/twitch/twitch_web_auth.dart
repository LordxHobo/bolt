import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/services.dart';
import '../core/settings.dart';

/// Your twitch.tv website login, used only to request streams as you.
///
/// Twitch decides per viewer whether to show ads. Asking for the stream with
/// your own login means channels you're subscribed to (or everything, with
/// Turbo) come without ads, exactly like on twitch.tv. This is separate from
/// the developer-app login used for chat and follows.
class TwitchWebAuth {
  static const _key = 'twitchWebAuthToken';
  static String? _token;

  static String? get token => _token;
  static bool get isSignedIn => _token != null;

  static Future<void> load() async {
    try {
      _token = await secureStorage.read(key: _key);
    } catch (e) {
      debugPrint('Reading twitch.tv login failed: $e');
    }
  }

  /// Picks up the login after signing in on the twitch.tv page.
  static Future<bool> captureFromCookies() async {
    try {
      final cookie = await CookieManager.instance()
          .getCookie(url: WebUri('https://www.twitch.tv'), name: 'auth-token');
      final value = cookie?.value?.toString();
      if (value == null || value.isEmpty) return false;
      _token = value;
      await secureStorage.write(key: _key, value: value);
      Services.settings.notifyChanged();
      return true;
    } catch (e) {
      debugPrint('Reading twitch.tv cookie failed: $e');
      return false;
    }
  }

  /// Twitch rejected the login (expired or signed out elsewhere).
  static Future<void> invalidate() async {
    _token = null;
    await secureStorage.delete(key: _key);
    Services.settings.notifyChanged();
  }

  static Future<void> signOut() async {
    await invalidate();
    try {
      await CookieManager.instance().deleteCookies(url: WebUri('https://www.twitch.tv'));
      await CookieManager.instance().deleteCookies(url: WebUri('https://twitch.tv'));
    } catch (e) {
      debugPrint('Clearing twitch.tv cookies failed: $e');
    }
  }
}
