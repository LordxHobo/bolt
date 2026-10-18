import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../core/net.dart';
import '../core/settings.dart';

class KickPkceRequest {
  final Uri authorizeUrl;
  final String state;
  final String verifier;
  KickPkceRequest(this.authorizeUrl, this.state, this.verifier);
}

/// Kick login through the official OAuth 2.1 + PKCE flow (id.kick.com),
/// used for sending chat messages via api.kick.com.
class KickAuth extends ChangeNotifier {
  KickAuth(this.settings);

  final Settings settings;

  static const scopes = 'user:read chat:write';
  static const _storageKey = 'kickAuth';

  String? accessToken;
  String? refreshToken;
  DateTime? expiresAt;
  String? username;
  String? userId;

  bool get isLoggedIn => accessToken != null;

  bool get isConfigured =>
      settings.kickClientId.isNotEmpty && settings.kickClientSecret.isNotEmpty;

  Future<void> load() async {
    try {
      final raw = await secureStorage.read(key: _storageKey);
      if (raw == null) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      accessToken = j['access'] as String?;
      refreshToken = j['refresh'] as String?;
      final exp = j['exp'] as int?;
      expiresAt = exp == null ? null : DateTime.fromMillisecondsSinceEpoch(exp);
      username = j['username'] as String?;
      userId = j['userId'] as String?;
    } catch (_) {}
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
        'username': username,
        'userId': userId,
      }),
    );
  }

  static String _randomString(int length) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final r = Random.secure();
    return List.generate(length, (_) => chars[r.nextInt(chars.length)]).join();
  }

  KickPkceRequest buildAuthorizeRequest() {
    if (!isConfigured) {
      throw ApiException('Add your Kick Client ID and Secret in Settings first (see the README).');
    }
    final verifier = _randomString(64);
    final challenge = base64UrlEncode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
    final state = _randomString(24);
    final url = Uri.https('id.kick.com', '/oauth/authorize', {
      'response_type': 'code',
      'client_id': settings.kickClientId,
      'redirect_uri': settings.kickRedirectUri,
      'scope': scopes,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      'state': state,
    });
    return KickPkceRequest(url, state, verifier);
  }

  /// Exchanges the code from the redirect for tokens.
  Future<void> completeLogin(KickPkceRequest request, Uri redirect) async {
    final error = redirect.queryParameters['error'];
    if (error != null) throw ApiException('Kick login was cancelled ($error)');
    if (redirect.queryParameters['state'] != request.state) {
      throw ApiException('Kick login failed (state mismatch). Try again.');
    }
    final code = redirect.queryParameters['code'];
    if (code == null) throw ApiException('Kick login failed (no code returned)');
    final res = await httpClient.post(
      Uri.parse('https://id.kick.com/oauth/token'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: formEncode({
        'grant_type': 'authorization_code',
        'client_id': settings.kickClientId,
        'client_secret': settings.kickClientSecret,
        'redirect_uri': settings.kickRedirectUri,
        'code_verifier': request.verifier,
        'code': code,
      }),
    );
    _applyTokens(jMap(decodeJson(res, 'Kick login'))!);
    await _loadUser();
    await _save();
    notifyListeners();
  }

  void _applyTokens(Map<String, dynamic> j) {
    accessToken = jStr(j['access_token']);
    refreshToken = jStr(j['refresh_token']) ?? refreshToken;
    final expiresIn = jInt(j['expires_in']) ?? 3600;
    expiresAt = DateTime.now().add(Duration(seconds: expiresIn));
  }

  Future<void> _loadUser() async {
    try {
      final res = await httpClient.get(
        Uri.parse('https://api.kick.com/public/v1/users'),
        headers: {'Authorization': 'Bearer $accessToken', 'Accept': 'application/json'},
      );
      final j = jMap(decodeJson(res, 'Kick profile'));
      final list = jList(j?['data']);
      final first = list.isEmpty ? null : jMap(list.first);
      username = jStr(first?['name']);
      userId = jStr(first?['user_id']);
    } catch (e) {
      debugPrint('Kick profile failed: $e');
    }
  }

  Future<String?> validAccessToken() async {
    if (accessToken == null) return null;
    final exp = expiresAt;
    if (exp != null && DateTime.now().isBefore(exp.subtract(const Duration(minutes: 2)))) {
      return accessToken;
    }
    if (refreshToken == null || !isConfigured) return accessToken;
    try {
      final res = await httpClient.post(
        Uri.parse('https://id.kick.com/oauth/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: formEncode({
          'grant_type': 'refresh_token',
          'client_id': settings.kickClientId,
          'client_secret': settings.kickClientSecret,
          'refresh_token': refreshToken!,
        }),
      );
      if (res.statusCode == 400 || res.statusCode == 401) {
        await logout();
        return null;
      }
      _applyTokens(jMap(decodeJson(res, 'Refreshing Kick login'))!);
      await _save();
      notifyListeners();
    } catch (e) {
      debugPrint('Kick refresh failed: $e');
    }
    return accessToken;
  }

  /// Sends a chat message as the logged-in user.
  Future<void> sendChat({required int broadcasterUserId, required String content}) async {
    final token = await validAccessToken();
    if (token == null) throw ApiException('Log in to Kick in Settings to chat.');
    final res = await httpClient.post(
      Uri.parse('https://api.kick.com/public/v1/chat'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      body: jsonEncode({
        'broadcaster_user_id': broadcasterUserId,
        'content': content,
        'type': 'user',
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      String detail = '';
      try {
        detail = jStr(jMap(jsonDecode(res.body))?['message']) ?? '';
      } catch (_) {}
      throw ApiException('Kick refused the message (HTTP ${res.statusCode}'
          '${detail.isEmpty ? '' : ': $detail'})');
    }
  }

  Future<void> logout() async {
    final token = accessToken;
    if (token != null) {
      httpClient
          .post(Uri.parse('https://id.kick.com/oauth/revoke?token=${Uri.encodeQueryComponent(token)}&token_hint_type=access_token'),
              headers: {'Content-Type': 'application/x-www-form-urlencoded'})
          .then((_) {}, onError: (_) {});
    }
    accessToken = null;
    refreshToken = null;
    expiresAt = null;
    username = null;
    userId = null;
    await _save();
    notifyListeners();
  }
}
