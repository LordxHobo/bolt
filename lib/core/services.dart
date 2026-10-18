import '../kick/kick_auth.dart';
import '../twitch/twitch_auth.dart';
import 'settings.dart';

/// App-wide singletons. This is a single-user app, so plain globals keep
/// things simple.
class Services {
  static final settings = Settings();
  static final twitch = TwitchAuth(settings);
  static final kick = KickAuth(settings);

  static Future<void> init() async {
    await settings.load();
    await twitch.load();
    await kick.load();
  }
}
