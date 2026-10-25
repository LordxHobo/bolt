import '../kick/kick_auth.dart';
import '../twitch/twitch_auth.dart';
import 'live_alerts.dart';
import 'settings.dart';

/// App-wide singletons. This is a single-user app, so plain globals keep
/// things simple.
class Services {
  static final settings = Settings();
  static final twitch = TwitchAuth(settings);
  static final kick = KickAuth(settings);

  static Future<void> init() async {
    await settings.load();
    await Future.wait([twitch.load(), kick.load()]);
    await _migrateTwitchWebLogin();
    LiveAlerts.start();
  }

  /// Earlier versions kept the twitch.tv login (used only for playback)
  /// separately. It now is the Twitch login, so move it over once.
  static Future<void> _migrateTwitchWebLogin() async {
    const oldKey = 'twitchWebAuthToken';
    try {
      final token = await secureStorage.read(key: oldKey);
      if (token == null) return;
      await secureStorage.delete(key: oldKey);
      if (!twitch.isWebLogin) {
        await twitch.signInWithWebToken(token).timeout(const Duration(seconds: 6));
      }
    } catch (_) {
      // Offline or expired: the user can sign in again in Settings.
    }
  }
}
