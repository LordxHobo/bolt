import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/net.dart';

/// Requests to Twitch's site API made from inside a hidden twitch.tv page.
///
/// Some of Twitch's site API (like your follow list) only answers requests
/// that carry a "Client-Integrity" token, which twitch.tv's own page can get
/// but a plain app request can't. Running the request inside the page (where
/// you're signed in through Relay's twitch.tv sign-in) gets it like the
/// website does. Same idea as KickWeb.
class TwitchWeb {
  TwitchWeb._();
  static final instance = TwitchWeb._();

  static const _webClientId = 'kimne78kx3ncx6brgo4mv6wki5h1ko';

  HeadlessInAppWebView? _headless;
  InAppWebViewController? _controller;
  Completer<void>? _ready;

  Future<void> _ensurePage() async {
    final existing = _ready;
    if (existing != null) {
      await existing.future.timeout(const Duration(seconds: 30), onTimeout: () {});
      return;
    }
    final ready = Completer<void>();
    _ready = ready;
    _headless = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri('https://www.twitch.tv/directory/following')),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 '
            '(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1',
        // This page only runs requests; it must never play anything.
        mediaPlaybackRequiresUserGesture: true,
        allowsInlineMediaPlayback: false,
        allowsPictureInPictureMediaPlayback: false,
        allowsAirPlayForMediaPlayback: false,
      ),
      onWebViewCreated: (controller) => _controller = controller,
      // Complete whichever load is pending (the first one, or a reload).
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
    // Give the page's own scripts a moment to set up (they protect the
    // integrity request).
    await Future<void>.delayed(const Duration(seconds: 2));
  }

  /// Logins of the channels the signed-in user follows.
  Future<List<String>> followedLogins({required String login, required String token}) async {
    String? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      await _ensurePage();
      final controller = _controller;
      if (controller == null) {
        lastError = 'twitch.tv did not load';
        continue;
      }
      try {
        final result = await controller.callAsyncJavaScript(
          functionBody: r'''
            const cookie = (name) => {
              const m = document.cookie.match(new RegExp('(?:^|; )' + name + '=([^;]+)'));
              return m ? decodeURIComponent(m[1]) : null;
            };
            const headers = {
              'Client-ID': clientId,
              'Authorization': 'OAuth ' + token,
              'Content-Type': 'text/plain;charset=UTF-8',
            };
            const device = cookie('unique_id');
            if (device) headers['X-Device-Id'] = device;
            let integrity = null;
            try {
              const r = await fetch('https://gql.twitch.tv/integrity', { method: 'POST', headers });
              const j = await r.json();
              integrity = j && j.token ? j.token : null;
            } catch (e) {}
            if (integrity) headers['Client-Integrity'] = integrity;

            const queries = [
              ['currentUser', 'query($after: Cursor) { currentUser { follows(first: 100, after: $after, order: DESC) { edges { cursor node { login } } pageInfo { hasNextPage } } } }'],
              ['user', 'query($login: String!, $after: Cursor) { user(login: $login, lookupType: ALL) { follows(first: 100, after: $after, order: DESC) { edges { cursor node { login } } pageInfo { hasNextPage } } } }'],
            ];
            let error = null;
            for (const [root, query] of queries) {
              const out = [];
              let after = null;
              let ok = true;
              for (let page = 0; page < 30; page++) {
                const r = await fetch('https://gql.twitch.tv/gql', {
                  method: 'POST', headers, body: JSON.stringify({ query, variables: { login, after } }),
                });
                const j = await r.json();
                const f = j && j.data && j.data[root] ? j.data[root].follows : null;
                if (!f) {
                  ok = false;
                  error = (j && j.errors ? j.errors.map((e) => e.message).join('; ') : 'HTTP ' + r.status);
                  break;
                }
                for (const e of f.edges || []) if (e && e.node && e.node.login) out.push(e.node.login);
                const last = (f.edges || []).slice(-1)[0];
                if (!f.pageInfo || !f.pageInfo.hasNextPage || !last) break;
                after = last.cursor;
              }
              if (ok) return { logins: out, integrity: !!integrity };
            }
            return { error: error, integrity: !!integrity };
          ''',
          arguments: {'clientId': _webClientId, 'token': token, 'login': login},
        );
        final value = result?.value;
        if (value is Map) {
          final logins = value['logins'];
          if (logins is List) return logins.map((e) => e.toString()).toList();
          lastError = '${value['error'] ?? 'no answer'}'
              '${value['integrity'] == true ? '' : ' (no integrity token)'}';
        } else if (result?.error != null) {
          lastError = result!.error;
        }
      } catch (e) {
        lastError = '$e';
        debugPrint('TwitchWeb follows failed: $e');
      }
      // Reload the page and try once more (e.g. its scripts weren't ready).
      try {
        final ready = Completer<void>();
        _ready = ready;
        await _controller?.reload();
        await ready.future.timeout(const Duration(seconds: 20), onTimeout: () {});
        await Future<void>.delayed(const Duration(seconds: 2));
      } catch (_) {}
    }
    throw ApiException('twitch.tv: ${lastError ?? 'no answer'}');
  }
}
