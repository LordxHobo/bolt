import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/models.dart';
import '../core/net.dart';
import '../core/settings.dart';

class TwitchDeviceCode {
  final String deviceCode;
  final String userCode;
  final String verificationUri;
  final int interval;
  final int expiresIn;

  TwitchDeviceCode({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.interval,
    required this.expiresIn,
  });
}

/// Twitch login using the Device Code Grant flow. It works for "Public"
/// Twitch apps, so no client secret has to live inside the app.
class TwitchAuth extends ChangeNotifier {
  TwitchAuth(this.settings);

  final Settings settings;

  static const scopes = 'chat:read chat:edit user:read:follows';
  static const _storageKey = 'twitchAuth';

  String? accessToken;
  String? refreshToken;
  DateTime? expiresAt;
  String? login;
  String? userId;

  /// The app the token belongs to. Set for the twitch.tv website login
  /// (Twitch's own web client); null for the older developer-app login.
  String? clientId;

  bool get isLoggedIn => accessToken != null && login != null;

  /// Signed in through twitch.tv (one login for playback, chat and follows).
  bool get isWebLogin => accessToken != null && clientId != null && refreshToken == null;

  /// Token for requesting streams as you (only the twitch.tv login works for
  /// that), so your subscriptions and Turbo apply.
  String? get playbackToken => isWebLogin ? accessToken : null;

  /// Signs in with the twitch.tv website login (its "auth-token" cookie).
  Future<void> signInWithWebToken(String token) async {
    final res = await httpClient.get(
      Uri.parse('https://id.twitch.tv/oauth2/validate'),
      headers: {'Authorization': 'OAuth $token'},
    );
    if (res.statusCode != 200) {
      throw ApiException('Twitch did not accept the login (HTTP ${res.statusCode})');
    }
    final j = jMap(jsonDecode(res.body))!;
    accessToken = token;
    refreshToken = null;
    final expiresIn = jInt(j['expires_in']);
    expiresAt = expiresIn == null || expiresIn <= 0
        ? null
        : DateTime.now().add(Duration(seconds: expiresIn));
    login = jStr(j['login']);
    userId = jStr(j['user_id']);
    clientId = jStr(j['client_id']);
    await _save();
    notifyListeners();
  }

  Future<void> load() async {
    try {
      final raw = await secureStorage.read(key: _storageKey);
      if (raw == null) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      accessToken = j['access'] as String?;
      refreshToken = j['refresh'] as String?;
      final exp = j['exp'] as int?;
      expiresAt = exp == null ? null : DateTime.fromMillisecondsSinceEpoch(exp);
      login = j['login'] as String?;
      userId = j['userId'] as String?;
      clientId = j['clientId'] as String?;
    } catch (_) {
      // Corrupt storage: start logged out.
    }
  }

  Future<void> _save() async {
    if (accessToken == null) {
      await secureStorage.delete(key: _storageKey);
      return;
    }
    await secureStorage.write(
      key: _storageKey,
      value: jsonEncode({
        'access': accessToken,
        'refresh': refreshToken,
        'exp': expiresAt?.millisecondsSinceEpoch,
        'login': login,
        'userId': userId,
        'clientId': clientId,
      }),
    );
  }

  String _requireClientId() {
    final id = settings.twitchClientId;
    if (id.isEmpty) {
      throw ApiException(
          'Add your Twitch Client ID in Settings first (see the README).');
    }
    return id;
  }

  Future<TwitchDeviceCode> startDeviceFlow() async {
    final clientId = _requireClientId();
    final res = await httpClient.post(
      Uri.parse('https://id.twitch.tv/oauth2/device'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: formEncode({'client_id': clientId, 'scopes': scopes}),
    );
    final j = jMap(decodeJson(res, 'Starting Twitch login'))!;
    return TwitchDeviceCode(
      deviceCode: jStr(j['device_code'])!,
      userCode: jStr(j['user_code'])!,
      verificationUri: jStr(j['verification_uri']) ?? 'https://www.twitch.tv/activate',
      interval: jInt(j['interval']) ?? 5,
      expiresIn: jInt(j['expires_in']) ?? 1800,
    );
  }

  /// Polls until the user approves the code on twitch.tv/activate.
  /// Returns false when [isCancelled] becomes true or the code expires.
  Future<bool> waitForApproval(TwitchDeviceCode code,
      {required bool Function() isCancelled}) async {
    final clientId = _requireClientId();
    final deadline = DateTime.now().add(Duration(seconds: code.expiresIn));
    var interval = code.interval;
    while (!isCancelled() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(Duration(seconds: interval));
      if (isCancelled()) return false;
      final res = await httpClient.post(
        Uri.parse('https://id.twitch.tv/oauth2/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: formEncode({
          'client_id': clientId,
          'scopes': scopes,
          'device_code': code.deviceCode,
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        }),
      );
      if (res.statusCode == 200) {
        await _applyTokenResponse(jMap(jsonDecode(res.body))!);
        await _validate();
        notifyListeners();
        return true;
      }
      String message = '';
      try {
        message = jStr(jMap(jsonDecode(res.body))?['message']) ?? '';
      } catch (_) {}
      if (message == 'authorization_pending') continue;
      if (message == 'slow_down') {
        interval += 5;
        continue;
      }
      throw ApiException('Twitch login failed: ${message.isEmpty ? res.statusCode : message}');
    }
    return false;
  }

  Future<void> _applyTokenResponse(Map<String, dynamic> j) async {
    accessToken = jStr(j['access_token']);
    refreshToken = jStr(j['refresh_token']) ?? refreshToken;
    final expiresIn = jInt(j['expires_in']) ?? 14400;
    expiresAt = DateTime.now().add(Duration(seconds: expiresIn));
    await _save();
  }

  Future<void> _validate() async {
    final res = await httpClient.get(
      Uri.parse('https://id.twitch.tv/oauth2/validate'),
      headers: {'Authorization': 'OAuth $accessToken'},
    );
    if (res.statusCode != 200) {
      throw ApiException('Twitch token is not valid', status: res.statusCode);
    }
    final j = jMap(jsonDecode(res.body))!;
    login = jStr(j['login']);
    userId = jStr(j['user_id']);
    await _save();
  }

  /// Returns a usable access token, refreshing it when needed.
  /// Returns null (and logs out) when the session can't be recovered.
  Future<String?> validAccessToken() async {
    if (accessToken == null) return null;
    if (isWebLogin) {
      // twitch.tv logins last a long time and can't be refreshed; when one
      // stops working, requests fail and the user signs in again.
      final exp = expiresAt;
      if (exp != null && DateTime.now().isAfter(exp)) {
        await logout(revoke: false);
        return null;
      }
      return accessToken;
    }
    final exp = expiresAt;
    if (exp != null && DateTime.now().isBefore(exp.subtract(const Duration(minutes: 5)))) {
      return accessToken;
    }
    if (refreshToken == null || settings.twitchClientId.isEmpty) {
      await logout(revoke: false);
      return null;
    }
    try {
      final res = await httpClient.post(
        Uri.parse('https://id.twitch.tv/oauth2/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: formEncode({
          'client_id': settings.twitchClientId,
          'grant_type': 'refresh_token',
          'refresh_token': refreshToken!,
        }),
      );
      if (res.statusCode == 400 || res.statusCode == 401) {
        await logout(revoke: false);
        return null;
      }
      await _applyTokenResponse(jMap(decodeJson(res, 'Refreshing Twitch login'))!);
      notifyListeners();
      return accessToken;
    } catch (e) {
      debugPrint('Twitch refresh failed: $e');
      // Network trouble: keep the session, the old token may still work.
      return accessToken;
    }
  }

  Future<void> logout({bool revoke = true}) async {
    final token = accessToken;
    final web = isWebLogin;
    if (revoke && !web && token != null && settings.twitchClientId.isNotEmpty) {
      unawaited(httpClient
          .post(
            Uri.parse('https://id.twitch.tv/oauth2/revoke'),
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: formEncode({'client_id': settings.twitchClientId, 'token': token}),
          )
          .then((_) {}, onError: (_) {}));
    }
    accessToken = null;
    refreshToken = null;
    expiresAt = null;
    login = null;
    userId = null;
    clientId = null;
    await _save();
    if (web) {
      // Also sign out of the twitch.tv page so the next sign-in asks again.
      try {
        await CookieManager.instance().deleteCookies(url: WebUri('https://www.twitch.tv'));
        await CookieManager.instance().deleteCookies(url: WebUri('https://twitch.tv'));
      } catch (e) {
        debugPrint('Clearing twitch.tv cookies failed: $e');
      }
    }
    notifyListeners();
  }
}
