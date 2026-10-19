import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// Secure storage (Keychain / Android Keystore) with a time limit on every
/// call. Some Android emulators fake the Keystore badly and a call can hang
/// forever; this way the app keeps working and only the saved logins are lost.
class SecureStore {
  const SecureStore();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _timeout = Duration(seconds: 4);

  Future<String?> read({required String key}) async {
    try {
      return await _storage.read(key: key).timeout(_timeout);
    } catch (e) {
      debugPrint('Secure storage read "$key" failed: $e');
      return null;
    }
  }

  Future<void> write({required String key, required String? value}) async {
    try {
      await _storage.write(key: key, value: value).timeout(_timeout);
    } catch (e) {
      debugPrint('Secure storage write "$key" failed: $e');
    }
  }

  Future<void> delete({required String key}) async {
    try {
      await _storage.delete(key: key).timeout(_timeout);
    } catch (e) {
      debugPrint('Secure storage delete "$key" failed: $e');
    }
  }
}

const secureStorage = SecureStore();

/// Which TwitchAdSolutions-style script is injected into the Twitch player.
enum AdBlockScript {
  vaft('vaft (bundled)', 'TwitchAdSolutions vaft 37.0.0, shipped with the app.'),
  vaftFork('vaft fork (online)',
      'Community-maintained fork of vaft, downloaded from GitHub and cached.'),
  videoSwapNew('video-swap-new (bundled)',
      'TwitchAdSolutions video-swap-new 1.55, shipped with the app.'),
  custom('Custom URL', 'Any userscript URL, downloaded and cached.'),
  off('Off', 'No ad blocking.');

  const AdBlockScript(this.label, this.description);
  final String label;
  final String description;
}

/// Which player Relay uses for Twitch.
enum TwitchPlayerMode {
  relay('Relay player', 'Recommended. Native playback, close to live, ads removed by Relay.'),
  web('Twitch web player', "Twitch's own player in a web view, with the script below.");

  const TwitchPlayerMode(this.label, this.description);
  final String label;
  final String description;
}

/// The home screen views from the menu.
enum HomeView { favorites, following, kick, twitch }

class Settings extends ChangeNotifier {
  late SharedPreferences _prefs;

  static const defaultKickRedirect = 'http://localhost/auth/callback';

  String twitchClientId = '';
  String kickClientId = '';
  String kickClientSecret = '';
  String kickRedirectUri = defaultKickRedirect;

  AdBlockScript adBlock = AdBlockScript.vaft;
  String customScriptUrl = '';

  TwitchPlayerMode twitchPlayer = TwitchPlayerMode.relay;
  bool relayAdBlock = true;
  bool lowLatency = true;
  bool showLatency = true;

  HomeView homeView = HomeView.following;

  double chatTextScale = 1.0;
  bool showTimestamps = false;
  bool landscapeChat = true;

  List<ChannelRef> favorites = [];

  /// True once the basic (non-secure) settings are available.
  bool isLoaded = false;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    isLoaded = true;
    twitchClientId = _prefs.getString('twitchClientId') ?? '';
    kickClientId = _prefs.getString('kickClientId') ?? '';
    kickRedirectUri = _prefs.getString('kickRedirectUri') ?? defaultKickRedirect;
    try {
      kickClientSecret = await secureStorage.read(key: 'kickClientSecret') ?? '';
    } catch (_) {
      kickClientSecret = '';
    }
    final adName = _prefs.getString('adBlock');
    adBlock = AdBlockScript.values.firstWhere((a) => a.name == adName,
        orElse: () => AdBlockScript.vaft);
    customScriptUrl = _prefs.getString('customScriptUrl') ?? '';
    final playerName = _prefs.getString('twitchPlayer');
    twitchPlayer = TwitchPlayerMode.values.firstWhere((m) => m.name == playerName,
        orElse: () => TwitchPlayerMode.relay);
    relayAdBlock = _prefs.getBool('relayAdBlock') ?? true;
    lowLatency = _prefs.getBool('lowLatency') ?? true;
    showLatency = _prefs.getBool('showLatency') ?? true;
    final viewName = _prefs.getString('homeView');
    homeView = HomeView.values.firstWhere((v) => v.name == viewName,
        orElse: () => HomeView.following);
    chatTextScale = _prefs.getDouble('chatTextScale') ?? 1.0;
    showTimestamps = _prefs.getBool('showTimestamps') ?? false;
    landscapeChat = _prefs.getBool('landscapeChat') ?? true;
    final favJson = _prefs.getString('favorites');
    if (favJson != null) {
      try {
        favorites = (jsonDecode(favJson) as List)
            .map((e) => ChannelRef.fromJson((e as Map).cast<String, dynamic>()))
            .toList();
      } catch (_) {
        favorites = [];
      }
    }
  }

  SharedPreferences get prefs => _prefs;

  /// For state stored directly in [prefs] by other parts of the app.
  void notifyChanged() => notifyListeners();

  Future<void> setTwitchClientId(String v) async {
    twitchClientId = v.trim();
    await _prefs.setString('twitchClientId', twitchClientId);
    notifyListeners();
  }

  Future<void> setKickCredentials({
    required String clientId,
    required String clientSecret,
    required String redirectUri,
  }) async {
    kickClientId = clientId.trim();
    kickClientSecret = clientSecret.trim();
    kickRedirectUri =
        redirectUri.trim().isEmpty ? defaultKickRedirect : redirectUri.trim();
    await _prefs.setString('kickClientId', kickClientId);
    await _prefs.setString('kickRedirectUri', kickRedirectUri);
    await secureStorage.write(key: 'kickClientSecret', value: kickClientSecret);
    notifyListeners();
  }

  Future<void> setAdBlock(AdBlockScript v) async {
    adBlock = v;
    await _prefs.setString('adBlock', v.name);
    notifyListeners();
  }

  Future<void> setCustomScriptUrl(String v) async {
    customScriptUrl = v.trim();
    await _prefs.setString('customScriptUrl', customScriptUrl);
    notifyListeners();
  }

  Future<void> setTwitchPlayer(TwitchPlayerMode v) async {
    twitchPlayer = v;
    await _prefs.setString('twitchPlayer', v.name);
    notifyListeners();
  }

  Future<void> setRelayAdBlock(bool v) async {
    relayAdBlock = v;
    await _prefs.setBool('relayAdBlock', v);
    notifyListeners();
  }

  Future<void> setLowLatency(bool v) async {
    lowLatency = v;
    await _prefs.setBool('lowLatency', v);
    notifyListeners();
  }

  Future<void> setShowLatency(bool v) async {
    showLatency = v;
    await _prefs.setBool('showLatency', v);
    notifyListeners();
  }

  Future<void> setHomeView(HomeView v) async {
    homeView = v;
    await _prefs.setString('homeView', v.name);
    notifyListeners();
  }

  Future<void> setChatTextScale(double v) async {
    chatTextScale = v;
    await _prefs.setDouble('chatTextScale', v);
    notifyListeners();
  }

  Future<void> setShowTimestamps(bool v) async {
    showTimestamps = v;
    await _prefs.setBool('showTimestamps', v);
    notifyListeners();
  }

  Future<void> setLandscapeChat(bool v) async {
    landscapeChat = v;
    await _prefs.setBool('landscapeChat', v);
    notifyListeners();
  }

  bool isFavorite(ChannelRef ref) => favorites.contains(ref);

  Future<void> toggleFavorite(ChannelRef ref) async {
    if (favorites.contains(ref)) {
      favorites = [...favorites]..remove(ref);
    } else {
      favorites = [...favorites, ref];
    }
    await _prefs.setString(
        'favorites', jsonEncode(favorites.map((f) => f.toJson()).toList()));
    notifyListeners();
  }
}
