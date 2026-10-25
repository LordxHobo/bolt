import 'dart:convert';
import 'dart:math';

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

/// Which video player Relay uses on iPhone (Android always uses ExoPlayer).
enum PlayerEngine {
  apple('Apple player', 'Most reliable. Plays each piece of video once it has fully downloaded.'),
  ivs('IVS player (lower latency)',
      "The player the Twitch app uses. Plays video while it's still downloading, so it "
      'gets closer to live, especially on streams that send long pieces.');

  const PlayerEngine(this.label, this.description);
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

  /// Default iPhone player, and per-channel choices ("twitch:login" -> name).
  PlayerEngine playerEngine = PlayerEngine.apple;
  Map<String, PlayerEngine> playerEngineFor = {};

  double chatTextScale = 1.0;
  bool showTimestamps = false;
  bool landscapeChat = true;

  List<ChannelRef> favorites = [];

  /// Live alerts (see server/live-alerts): the checker's address, Relay's
  /// private ntfy topic, and per-streamer choices that differ from the
  /// default (favorites on, everyone else off).
  String alertsServer = '';
  String alertsTopic = '';
  Map<String, bool> alertChoices = {};

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
    final engineName = _prefs.getString('playerEngine');
    playerEngine = PlayerEngine.values.firstWhere((e) => e.name == engineName,
        orElse: () => PlayerEngine.apple);
    try {
      final raw = jsonDecode(_prefs.getString('playerEngineFor') ?? '{}') as Map<String, dynamic>;
      playerEngineFor = {
        for (final e in raw.entries)
          for (final engine in PlayerEngine.values)
            if (engine.name == e.value) e.key: engine,
      };
    } catch (_) {
      playerEngineFor = {};
    }
    final viewName = _prefs.getString('homeView');
    homeView = HomeView.values.firstWhere((v) => v.name == viewName,
        orElse: () => HomeView.following);
    chatTextScale = _prefs.getDouble('chatTextScale') ?? 1.0;
    showTimestamps = _prefs.getBool('showTimestamps') ?? false;
    landscapeChat = _prefs.getBool('landscapeChat') ?? true;
    alertsServer = _prefs.getString('alertsServer') ?? '';
    alertsTopic = _prefs.getString('alertsTopic') ?? '';
    if (alertsTopic.isEmpty) {
      const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
      final rnd = Random.secure();
      alertsTopic = 'relay-${List.generate(20, (_) => chars[rnd.nextInt(chars.length)]).join()}';
      await _prefs.setString('alertsTopic', alertsTopic);
    }
    try {
      final raw = jsonDecode(_prefs.getString('alertChoices') ?? '{}') as Map<String, dynamic>;
      alertChoices = {for (final e in raw.entries) if (e.value is bool) e.key: e.value as bool};
    } catch (_) {
      alertChoices = {};
    }
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

  Future<void> setPlayerEngine(PlayerEngine v) async {
    playerEngine = v;
    await _prefs.setString('playerEngine', v.name);
    notifyListeners();
  }

  /// The player for [channel]: its own choice, or the default.
  PlayerEngine engineFor(ChannelRef channel) => playerEngineFor[channel.key] ?? playerEngine;

  /// Remembers a player for one channel (null: back to the default).
  Future<void> setEngineFor(ChannelRef channel, PlayerEngine? engine) async {
    if (engine == null || engine == playerEngine) {
      playerEngineFor.remove(channel.key);
    } else {
      playerEngineFor[channel.key] = engine;
    }
    await _prefs.setString(
      'playerEngineFor',
      jsonEncode({for (final e in playerEngineFor.entries) e.key: e.value.name}),
    );
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

  /// Whether [ref] sends a live alert: your choice, or on for favorites.
  bool alertsFor(ChannelRef ref) => alertChoices[ref.key] ?? isFavorite(ref);

  Future<void> setAlertsFor(ChannelRef ref, bool on) async {
    alertChoices = {...alertChoices};
    if (on == isFavorite(ref)) {
      alertChoices.remove(ref.key);
    } else {
      alertChoices[ref.key] = on;
    }
    await _prefs.setString('alertChoices', jsonEncode(alertChoices));
    notifyListeners();
  }

  /// Every streamer that currently sends alerts.
  List<ChannelRef> get alertChannels {
    final out = <ChannelRef>[
      for (final f in favorites)
        if (alertsFor(f)) f,
    ];
    for (final e in alertChoices.entries) {
      if (!e.value) continue;
      final i = e.key.indexOf(':');
      if (i <= 0) continue;
      final ref = ChannelRef(StreamPlatformX.parse(e.key.substring(0, i)), e.key.substring(i + 1));
      if (!out.contains(ref)) out.add(ref);
    }
    return out;
  }

  Future<void> setAlertsServer(String v) async {
    var url = v.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.isNotEmpty && !url.contains('://')) url = 'https://$url';
    alertsServer = url;
    await _prefs.setString('alertsServer', url);
    notifyListeners();
  }
}
