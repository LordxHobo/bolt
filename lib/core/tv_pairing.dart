import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;

import '../kick/kick_follows.dart';
import 'models.dart';
import 'net.dart';
import 'services.dart';

/// Copies your Twitch and Kick sign-ins from Bolt on your phone to Bolt on
/// your TV, straight over your home Wi-Fi (no server in between).
///
/// The TV listens on [port] and shows a short code (and a QR code holding
/// its address and the code). The phone encrypts the sign-ins with a key
/// made from the code, so only that TV can read them, and the code itself
/// never travels over the network.
class TvPairing {
  TvPairing._();

  static const port = 47851;

  // No 0/O or 1/I: easy to read off a TV and type on a phone.
  static const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  /// Kick's anti-bot cookies belong to the browser that got them; the TV
  /// gets its own.
  static const _skipCookies = {'cf_clearance', '__cf_bm', '_cfuvid', '__cflb'};

  static String newCode() {
    final r = Random.secure();
    return List.generate(8, (_) => _alphabet[r.nextInt(_alphabet.length)]).join();
  }

  /// "ABCD-EFGH" as typed or scanned → "ABCDEFGH".
  static String normalizeCode(String s) => s.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  static String showCode(String code) =>
      code.length == 8 ? '${code.substring(0, 4)}-${code.substring(4)}' : code;

  static SecretKey _key(String code) =>
      SecretKey(hash.sha256.convert(utf8.encode('bolt-pair:${normalizeCode(code)}')).bytes);

  static final _aes = AesGcm.with256bits();

  /// Only addresses on your own network (a QR code can't send your sign-ins
  /// out to the internet).
  static bool isLocalAddress(String host) {
    final ip = InternetAddress.tryParse(host);
    if (ip == null || ip.type != InternetAddressType.IPv4) return false;
    final b = ip.rawAddress;
    return b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168) ||
        (b[0] == 169 && b[1] == 254);
  }

  /// This device's address on the home network.
  static Future<String?> localAddress() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final i in interfaces) {
        for (final a in i.addresses) {
          if (!a.isLoopback && isLocalAddress(a.address)) return a.address;
        }
      }
    } catch (e) {
      debugPrint('No local address: $e');
    }
    return null;
  }

  // ------------------------------------------------------------ phone side

  /// What there is to send: your Twitch name (twitch.tv login), and
  /// whether you're signed in to Kick.
  static ({String? twitch, bool kick}) available() => (
        twitch: Services.twitch.isWebLogin ? Services.twitch.login : null,
        kick: KickFollows.isSignedIn,
      );

  static Future<Map<String, dynamic>> _collect() async {
    final out = <String, dynamic>{'v': 1};
    final twitch = Services.twitch;
    if (twitch.isWebLogin && twitch.accessToken != null) {
      out['twitch'] = {'token': twitch.accessToken, 'login': twitch.login};
    }
    if (KickFollows.isSignedIn) {
      final cookies = await CookieManager.instance().getCookies(url: WebUri('https://kick.com/'));
      out['kick'] = {
        'username': KickFollows.username,
        'cookies': [
          for (final c in cookies)
            if (!_skipCookies.contains(c.name))
              {
                'name': c.name,
                'value': '${c.value}',
                if (c.domain != null) 'domain': c.domain,
                if (c.path != null) 'path': c.path,
                if (c.expiresDate != null) 'expires': c.expiresDate,
                if (c.isHttpOnly != null) 'httpOnly': c.isHttpOnly,
              },
        ],
      };
    }
    return out;
  }

  /// Sends your sign-ins to the TV at [host] showing [code].
  static Future<String> send(String host, String code) async {
    // Commas count as dots (some number pads only have a comma).
    host = host.trim().replaceAll(',', '.').replaceAll(' ', '');
    if (host.contains(':')) host = host.split(':').first;
    if (!isLocalAddress(host)) {
      throw ApiException('That isn\'t an address on your home network ($host).');
    }
    final payload = await _collect();
    if (!payload.containsKey('twitch') && !payload.containsKey('kick')) {
      throw ApiException('Sign in to Twitch or Kick on this phone first.');
    }
    final box = await _aes.encrypt(utf8.encode(jsonEncode(payload)), secretKey: _key(code));
    final http.Response res;
    try {
      res = await httpClient
          .post(
            Uri.parse('http://$host:$port/pair'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'n': base64Encode(box.nonce),
              'c': base64Encode(box.cipherText),
              'm': base64Encode(box.mac.bytes),
            }),
          )
          .timeout(const Duration(seconds: 25));
    } on TimeoutException {
      throw ApiException("The TV didn't answer. Is it on the sign-in screen, on the same Wi-Fi?");
    } on SocketException {
      throw ApiException("Couldn't reach the TV at $host. Is it on the sign-in screen, on the same Wi-Fi? "
          '(On iPhone, Bolt also needs Local Network access: Settings → Bolt.)');
    }
    final j = jMap(jsonDecode(utf8.decode(res.bodyBytes)));
    if (res.statusCode == 403) throw ApiException('Wrong code. Check the code on the TV and try again.');
    if (res.statusCode != 200) {
      throw ApiException(jStr(j?['error']) ?? 'The TV said no (HTTP ${res.statusCode}).');
    }
    return jStr(j?['summary']) ?? 'Signed in on the TV.';
  }

  // ------------------------------------------------------------ TV side

  /// Applies sign-ins sent from a phone; returns what happened.
  static Future<String> _apply(Map<String, dynamic> p) async {
    final done = <String>[];
    final failed = <String>[];
    final t = jMap(p['twitch']);
    final token = jStr(t?['token']);
    if (token != null) {
      try {
        await Services.twitch.signInWithWebToken(token);
        // The hidden twitch.tv page (your follow list) signs in with the
        // website's own cookie.
        final cm = CookieManager.instance();
        await cm.setCookie(
          url: WebUri('https://www.twitch.tv'),
          name: 'auth-token',
          value: token,
          domain: '.twitch.tv',
          isSecure: true,
        );
        if (Services.twitch.login != null) {
          await cm.setCookie(
            url: WebUri('https://www.twitch.tv'),
            name: 'login',
            value: Services.twitch.login!,
            domain: '.twitch.tv',
            isSecure: true,
          );
        }
        done.add('Twitch as ${Services.twitch.login}');
      } catch (e) {
        failed.add('Twitch ($e)');
      }
    }
    final k = jMap(p['kick']);
    final cookies = jList(k?['cookies']);
    if (cookies.isNotEmpty) {
      try {
        final cm = CookieManager.instance();
        for (final raw in cookies) {
          final c = jMap(raw);
          final name = jStr(c?['name']), value = jStr(c?['value']);
          if (name == null || value == null || _skipCookies.contains(name)) continue;
          await cm.setCookie(
            url: WebUri('https://kick.com'),
            name: name,
            value: value,
            domain: jStr(c?['domain']) ?? '.kick.com',
            path: jStr(c?['path']) ?? '/',
            expiresDate: jInt(c?['expires']),
            isSecure: true,
            isHttpOnly: c?['httpOnly'] == true ? true : null,
          );
        }
        if (await KickFollows.confirmSignIn()) {
          done.add('Kick${KickFollows.username == null ? '' : ' as ${KickFollows.username}'}');
        } else {
          failed.add('Kick (Kick didn\'t accept the sign-in on the TV; sign in on the phone again, then resend)');
        }
      } catch (e) {
        failed.add('Kick ($e)');
      }
    }
    if (done.isEmpty && failed.isEmpty) return 'Nothing to sign in with was sent.';
    return [
      if (done.isNotEmpty) 'Signed in to ${done.join(' and ')}.',
      if (failed.isNotEmpty) 'Didn\'t work: ${failed.join('; ')}.',
    ].join(' ');
  }
}

/// The TV waiting for a phone to send its sign-ins.
class TvPairServer extends ChangeNotifier {
  TvPairServer();

  final String code = TvPairing.newCode();
  String? address;

  /// What to show: null while waiting.
  String? result;
  String? error;
  bool busy = false;

  HttpServer? _server;
  int _wrongTries = 0;
  Timer? _expire;

  /// relay://pair?h=<address>&c=<code>, for the QR code.
  String? get link => address == null ? null : 'relay://pair?h=$address&c=$code';

  Future<void> start() async {
    address = await TvPairing.localAddress();
    if (address == null) {
      error = "This TV doesn't seem to be on a network.";
      notifyListeners();
      return;
    }
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, TvPairing.port, shared: true);
    } catch (e) {
      error = "Couldn't get ready for your phone: $e";
      notifyListeners();
      return;
    }
    _server!.listen(_handle, onError: (Object e) => debugPrint('Pair server: $e'));
    // Ten minutes, then the code stops working.
    _expire = Timer(const Duration(minutes: 10), () {
      error = 'This code expired. Go back and open this screen again for a new one.';
      stop();
      notifyListeners();
    });
    notifyListeners();
  }

  Future<void> _handle(HttpRequest req) async {
    Future<void> reply(int status, Map<String, Object?> body) async {
      req.response.statusCode = status;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(body));
      await req.response.close();
    }

    try {
      if (req.method != 'POST' || req.uri.path != '/pair') {
        return await reply(404, {'error': 'not found'});
      }
      if (busy || result != null) return await reply(409, {'error': 'The TV is already signed in from a phone.'});
      final bytes = <int>[];
      await for (final chunk in req) {
        bytes.addAll(chunk);
        if (bytes.length > 256 * 1024) return await reply(413, {'error': 'too big'});
      }
      final j = jMap(jsonDecode(utf8.decode(bytes)));
      final box = SecretBox(
        base64Decode(jStr(j?['c']) ?? ''),
        nonce: base64Decode(jStr(j?['n']) ?? ''),
        mac: Mac(base64Decode(jStr(j?['m']) ?? '')),
      );
      List<int> clear;
      try {
        clear = await TvPairing._aes.decrypt(box, secretKey: TvPairing._key(code));
      } catch (_) {
        // Wrong code (or not from Bolt). A few tries, then stop listening.
        _wrongTries++;
        if (_wrongTries >= 5) {
          error = 'Too many wrong codes. Go back and open this screen again for a new one.';
          notifyListeners();
          await reply(403, {'error': 'wrong code'});
          await stop();
          return;
        }
        return await reply(403, {'error': 'wrong code'});
      }
      busy = true;
      notifyListeners();
      final summary = await TvPairing._apply(jMap(jsonDecode(utf8.decode(clear))) ?? const {});
      result = summary;
      busy = false;
      notifyListeners();
      await reply(200, {'ok': true, 'summary': summary});
      await stop();
    } catch (e) {
      busy = false;
      notifyListeners();
      try {
        await reply(400, {'error': '$e'});
      } catch (_) {}
    }
  }

  Future<void> stop() async {
    _expire?.cancel();
    final s = _server;
    _server = null;
    await s?.close(force: true);
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
