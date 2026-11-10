import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/net.dart';
import '../core/silent_page.dart';

class KickResponse {
  final int status;
  final String body;
  const KickResponse(this.status, this.body);

  bool get ok => status >= 200 && status < 300;

  dynamic get json {
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }
}

/// Requests to kick.com's own (website) API.
///
/// Those endpoints sit behind Cloudflare, which often rejects plain HTTP
/// clients. We try a normal request first; if Cloudflare blocks it, we run the
/// request inside a hidden WebView that has kick.com open, so it goes out as
/// a real browser request.
class KickWeb {
  KickWeb._();
  static final instance = KickWeb._();

  bool _useWebView = false;
  HeadlessInAppWebView? _headless;
  InAppWebViewController? _controller;
  Completer<void>? _ready;

  Future<KickResponse> get(String url) => request(url);

  Future<KickResponse> post(String url, Object body) =>
      request(url, method: 'POST', jsonBody: body);

  Future<KickResponse> request(String url,
      {String method = 'GET', Object? jsonBody}) async {
    if (!_useWebView) {
      try {
        final res = await _native(url, method, jsonBody);
        if (!_blocked(res)) return res;
        debugPrint('Kick API blocked natively (${res.status}); switching to WebView');
      } catch (e) {
        debugPrint('Kick native request failed: $e; trying WebView');
      }
      _useWebView = true;
    }
    return _viaWebView(url, method, jsonBody);
  }

  static bool _blocked(KickResponse r) {
    if (r.status == 403 || r.status == 429 || r.status == 503) return true;
    final t = r.body.trimLeft();
    return r.ok && (t.startsWith('<') || t.isEmpty);
  }

  Future<KickResponse> _native(String url, String method, Object? jsonBody) async {
    final headers = {
      'User-Agent': browserUserAgent,
      'Accept': 'application/json',
      'Accept-Language': 'en-US,en;q=0.9',
      'Referer': 'https://kick.com/',
      'Origin': 'https://kick.com',
      if (jsonBody != null) 'Content-Type': 'application/json',
    };
    final uri = Uri.parse(url);
    final res = method == 'POST'
        ? await httpClient
            .post(uri, headers: headers, body: jsonEncode(jsonBody))
            .timeout(const Duration(seconds: 15))
        : await httpClient.get(uri, headers: headers).timeout(const Duration(seconds: 15));
    return KickResponse(res.statusCode, utf8.decode(res.bodyBytes, allowMalformed: true));
  }

  Future<void> _ensureWebView() async {
    final existing = _ready;
    if (existing != null) {
      await existing.future.timeout(const Duration(seconds: 30), onTimeout: () {});
      return;
    }
    final ready = Completer<void>();
    _ready = ready;
    _headless = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri('https://kick.com/')),
      initialUserScripts: UnmodifiableListView([silentPageScript]),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        // This page only runs requests; it must never play kick.com's
        // featured stream (which could also take over picture-in-picture
        // from Relay's player).
        mediaPlaybackRequiresUserGesture: true,
        allowsInlineMediaPlayback: true, // never full screen over Relay
        allowsPictureInPictureMediaPlayback: false,
        allowsAirPlayForMediaPlayback: false,
      ),
      onWebViewCreated: (controller) => _controller = controller,
      // Complete whichever load is pending (the first one, or a reloadPage()).
      onLoadStop: (controller, url) {
        _controller = controller;
        final pending = _ready;
        if (pending != null && !pending.isCompleted) pending.complete();
      },
      onReceivedError: (controller, request, error) {
        final pending = _ready;
        if (request.isForMainFrame == true && pending != null && !pending.isCompleted) {
          pending.complete();
        }
      },
    );
    await _headless!.run();
    await ready.future.timeout(const Duration(seconds: 30), onTimeout: () {});
  }

  /// Kick's picture server (images.kick.com) refuses apps with HTTP 403,
  /// so stream previews are downloaded from inside the kick.com page, like
  /// the website loads them. Kept for 5 minutes.
  final Map<String, Future<Uint8List?>> _images = {};

  Future<Uint8List?> image(String url) {
    final bucket = DateTime.now().millisecondsSinceEpoch ~/ (5 * 60 * 1000);
    final key = '$url#$bucket';
    if (_images.length > 200) _images.clear();
    return _images[key] ??= _image(url).then((bytes) {
      if (bytes == null) _images.remove(key); // try again next time
      return bytes;
    });
  }

  Future<Uint8List?> _image(String url) async {
    await _ensureWebView();
    final controller = _controller;
    if (controller == null) return null;
    try {
      final result = await controller.callAsyncJavaScript(
        functionBody: r'''
          const toDataUrl = (blob) => new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onload = () => resolve(reader.result);
            reader.onerror = reject;
            reader.readAsDataURL(blob);
          });
          // 1. A normal download, as the website would.
          try {
            const r = await fetch(url, { credentials: 'omit' });
            if (r.ok) return { data: await toDataUrl(await r.blob()) };
          } catch (e) {}
          // 2. As a picture on the page, copied off a canvas.
          const img = new Image();
          img.crossOrigin = 'anonymous';
          await new Promise((resolve, reject) => {
            img.onload = resolve;
            img.onerror = () => reject(new Error('picture did not load'));
            img.src = url;
          });
          const c = document.createElement('canvas');
          c.width = img.naturalWidth;
          c.height = img.naturalHeight;
          c.getContext('2d').drawImage(img, 0, 0);
          return { data: c.toDataURL('image/jpeg', 0.8) };
        ''',
        arguments: {'url': url},
      );
      final value = result?.value;
      final data = value is Map ? value['data']?.toString() : null;
      if (data == null) {
        debugPrint('Kick preview in page failed: ${result?.error}');
        return _imageWithPageIdentity(url, controller);
      }
      final comma = data.indexOf(',');
      return base64Decode(comma >= 0 ? data.substring(comma + 1) : data);
    } catch (e) {
      debugPrint('Kick preview failed: $e');
      return null;
    }
  }

  /// Downloads [url] directly, but as the kick.com page: its exact browser
  /// name and its Cloudflare cookies.
  Future<Uint8List?> _imageWithPageIdentity(String url, InAppWebViewController controller) async {
    try {
      final ua = (await controller.evaluateJavascript(source: 'navigator.userAgent'))?.toString();
      final cookies = await CookieManager.instance().getCookies(url: WebUri('https://kick.com/'));
      final cookie = cookies.map((c) => '${c.name}=${c.value}').join('; ');
      final res = await httpClient.get(Uri.parse(url), headers: {
        'User-Agent': (ua == null || ua.isEmpty) ? browserUserAgent : ua,
        'Referer': 'https://kick.com/',
        'Accept': 'image/webp,image/avif,image/*,*/*;q=0.8',
        if (cookie.isNotEmpty) 'Cookie': cookie,
      }).timeout(const Duration(seconds: 15));
      if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) return res.bodyBytes;
      debugPrint('Kick preview direct: HTTP ${res.statusCode}');
    } catch (e) {
      debugPrint('Kick preview direct failed: $e');
    }
    return null;
  }

  /// Reloads the hidden kick.com page, e.g. after signing in, so it picks up
  /// the new login cookies.
  Future<void> reloadPage() async {
    final controller = _controller;
    if (controller == null) return;
    final ready = Completer<void>();
    _ready = ready;
    await controller.reload();
    await ready.future.timeout(const Duration(seconds: 20), onTimeout: () {});
  }

  /// GET [url] as the signed-in kick.com user (website login, not the
  /// developer-app login). Always runs inside the kick.com page so the
  /// session cookie applies; the site also expects it as a Bearer token.
  Future<KickResponse> getSignedIn(String url) => requestSignedIn(url);

  /// Like [getSignedIn], for any method (e.g. POST to send a chat message).
  Future<KickResponse> requestSignedIn(String url, {String method = 'GET', Object? jsonBody}) async {
    KickResponse last = const KickResponse(0, '');
    for (var attempt = 0; attempt < 3; attempt++) {
      await _ensureWebView();
      final controller = _controller;
      if (controller == null) {
        await Future<void>.delayed(const Duration(seconds: 2));
        continue;
      }
      try {
        final result = await controller.callAsyncJavaScript(
          functionBody: '''
            const m = document.cookie.match(/(?:^|; )session_token=([^;]+)/);
            const x = document.cookie.match(/(?:^|; )XSRF-TOKEN=([^;]+)/);
            const headers = { 'Accept': 'application/json' };
            if (m) headers['Authorization'] = 'Bearer ' + decodeURIComponent(m[1]);
            if (x) headers['X-XSRF-TOKEN'] = decodeURIComponent(x[1]);
            const opts = { method: method, headers: headers, credentials: 'include' };
            if (body !== null) {
              headers['Content-Type'] = 'application/json';
              opts.body = body;
            }
            const r = await fetch(url, opts);
            return { status: r.status, body: await r.text(), signedIn: !!m };
          ''',
          arguments: {
            'url': url,
            'method': method,
            'body': jsonBody == null ? null : jsonEncode(jsonBody),
          },
        );
        final value = result?.value;
        if (value is Map) {
          last = KickResponse(
            (value['status'] as num?)?.toInt() ?? 0,
            value['body']?.toString() ?? '',
          );
          if (!_blocked(last) || last.status == 401) return last;
        }
      } catch (e) {
        debugPrint('Kick signed-in fetch threw: $e');
      }
      await Future<void>.delayed(Duration(seconds: 2 + attempt * 2));
    }
    return last;
  }

  Future<KickResponse> _viaWebView(String url, String method, Object? jsonBody) async {
    KickResponse last = const KickResponse(0, '');
    for (var attempt = 0; attempt < 4; attempt++) {
      await _ensureWebView();
      final controller = _controller;
      if (controller == null) {
        await Future<void>.delayed(const Duration(seconds: 2));
        continue;
      }
      try {
        final result = await controller.callAsyncJavaScript(
          functionBody: '''
            const opts = { method: method, headers: { 'Accept': 'application/json' } };
            if (body !== null) {
              opts.headers['Content-Type'] = 'application/json';
              opts.body = body;
            }
            const r = await fetch(url, opts);
            return { status: r.status, body: await r.text() };
          ''',
          arguments: {
            'url': url,
            'method': method,
            'body': jsonBody == null ? null : jsonEncode(jsonBody),
          },
        );
        final value = result?.value;
        if (value is Map) {
          last = KickResponse(
            (value['status'] as num?)?.toInt() ?? 0,
            value['body']?.toString() ?? '',
          );
          // A Cloudflare challenge may still be running; give it time.
          if (!_blocked(last)) return last;
        } else if (result?.error != null) {
          debugPrint('Kick WebView fetch error: ${result!.error}');
        }
      } catch (e) {
        debugPrint('Kick WebView fetch threw: $e');
      }
      await Future<void>.delayed(Duration(seconds: 2 + attempt * 2));
    }
    if (last.status == 0) {
      throw ApiException('Could not reach Kick. Check your connection and try again.');
    }
    return last;
  }
}
