import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/net.dart';

/// Requests to Twitch's site API made from inside a hidden twitch.tv page.
///
/// Twitch's own site API is what knows your full follow list, but it only
/// answers requests the way twitch.tv's page makes them (with its security
/// token, current query format, etc.). So Relay opens your Following page
/// invisibly (you're signed in through Relay's twitch.tv sign-in), watches
/// the request that page makes for your follows, and repeats exactly that
/// request to page through the whole list. Same idea as KickWeb.
class TwitchWeb {
  TwitchWeb._();
  static final instance = TwitchWeb._();

  static const _webClientId = 'kimne78kx3ncx6brgo4mv6wki5h1ko';
  static const _followingPage = 'https://www.twitch.tv/directory/following/channels';

  /// Records the page's own requests to Twitch's site API whose answers
  /// contain a follow list (request body, headers and answer).
  static const _recorder = r'''
(function () {
  if (window.__relayRecorder) return;
  window.__relayRecorder = true;
  window.__relayFollows = [];
  const original = window.fetch;
  window.__relayFetch = original;
  window.fetch = async function (input, init) {
    const response = await original.apply(this, arguments);
    try {
      const url = typeof input === 'string' ? input : (input && input.url) || '';
      if (url.indexOf('gql.twitch.tv/gql') >= 0 && init && typeof init.body === 'string') {
        const body = init.body;
        let headers = init.headers || {};
        if (headers instanceof Headers) headers = Object.fromEntries(headers.entries());
        response.clone().text().then(function (text) {
          if (text.indexOf('"follows"') >= 0) {
            window.__relayFollows.push({ body: body, headers: headers, text: text });
          }
        });
      }
    } catch (e) {}
    return response;
  };
  // Also requests made the older way (XMLHttpRequest).
  const open = XMLHttpRequest.prototype.open;
  const setHeader = XMLHttpRequest.prototype.setRequestHeader;
  const sendXhr = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (method, url) {
    this.__relayUrl = String(url || '');
    this.__relayHeaders = {};
    return open.apply(this, arguments);
  };
  XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
    if (this.__relayHeaders) this.__relayHeaders[name] = value;
    return setHeader.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function (body) {
    const xhr = this;
    if (xhr.__relayUrl && xhr.__relayUrl.indexOf('gql.twitch.tv/gql') >= 0 && typeof body === 'string') {
      xhr.addEventListener('load', function () {
        try {
          const text = xhr.responseText || '';
          if (text.indexOf('"follows"') >= 0) {
            window.__relayFollows.push({ body: body, headers: xhr.__relayHeaders, text: text });
          }
        } catch (e) {}
      });
    }
    return sendXhr.apply(this, arguments);
  };
})();
''';

  HeadlessInAppWebView? _headless;
  InAppWebViewController? _controller;
  Completer<void>? _ready;

  Future<void> _openFollowingPage() async {
    if (_headless != null && _controller != null) {
      // Reload so the page asks for the follow list again.
      final ready = Completer<void>();
      _ready = ready;
      await _controller!.loadUrl(urlRequest: URLRequest(url: WebUri(_followingPage)));
      await ready.future.timeout(const Duration(seconds: 30), onTimeout: () {});
      return;
    }
    final ready = Completer<void>();
    _ready = ready;
    _headless = HeadlessInAppWebView(
      // A real desktop-sized window, so the list's "load more when the
      // bottom comes into view" works while scrolling it.
      initialSize: const Size(1280, 1600),
      initialUrlRequest: URLRequest(url: WebUri(_followingPage)),
      initialUserScripts: UnmodifiableListView([
        UserScript(source: _recorder, injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START),
      ]),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        // Desktop site: with an iPhone identity twitch.tv sends the mobile
        // site, which loads the follow list differently.
        userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 '
            '(KHTML, like Gecko) Version/18.0 Safari/605.1.15',
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
  }

  /// Logins of the channels the signed-in user follows. When the full list
  /// can't be had, falls back to the ones live right now ([liveOnly] true).
  Future<({List<String> logins, bool liveOnly})> followedLogins({
    required String login,
    required String token,
  }) async {
    String? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      await _openFollowingPage();
      final controller = _controller;
      if (controller == null) {
        lastError = 'twitch.tv did not load';
        continue;
      }
      try {
        final result = await controller.callAsyncJavaScript(
          functionBody: r'''
            const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
            const send = window.__relayFetch || fetch;
            const findFollows = (o, depth) => {
              if (!o || typeof o !== 'object' || depth > 8) return null;
              if (o.follows && Array.isArray(o.follows.edges)) return o.follows;
              for (const k in o) {
                const r = findFollows(o[k], depth + 1);
                if (r) return r;
              }
              return null;
            };
            const loginsOf = (follows) =>
              (follows.edges || []).map((e) => e && e.node && e.node.login).filter(Boolean);

            // 1. Wait for the page's own follow-list request, then repeat it
            //    page by page.
            let seen = null;
            for (let i = 0; i < 40 && !seen; i++) {
              const list = window.__relayFollows || [];
              if (list.length) seen = list[list.length - 1];
              else await sleep(500);
            }
            let replayError = seen ? null : 'the Following page never asked for your follows';
            const all = new Set();
            const collect = () => {
              for (const rec of window.__relayFollows || []) {
                try {
                  const answer = JSON.parse(rec.text);
                  for (const a of Array.isArray(answer) ? answer : [answer]) {
                    const f = findFollows(a && a.data, 0);
                    if (f) for (const l of loginsOf(f)) all.add(l);
                  }
                } catch (e) {}
              }
            };
            if (seen) {
              // a) Repeat the page's request with the next-page marker.
              try {
                const body = JSON.parse(seen.body);
                const answer = JSON.parse(seen.text);
                const ops = Array.isArray(body) ? body : [body];
                const answers = Array.isArray(answer) ? answer : [answer];
                const index = answers.findIndex((a) => findFollows(a && a.data, 0));
                if (index >= 0) {
                  const op = ops[index];
                  let follows = findFollows(answers[index].data, 0);
                  for (let page = 0; page < 40 && follows; page++) {
                    const last = (follows.edges || []).slice(-1)[0];
                    const more = follows.pageInfo ? follows.pageInfo.hasNextPage : !!(last && last.cursor);
                    if (!more || !last || !last.cursor) break;
                    const vars = Object.assign({}, op.variables || {});
                    if ('after' in vars) vars.after = last.cursor; else vars.cursor = last.cursor;
                    const next = Object.assign({}, op, { variables: vars });
                    const r = await send('https://gql.twitch.tv/gql', {
                      method: 'POST', headers: seen.headers,
                      body: JSON.stringify(Array.isArray(body) ? [next] : next),
                    });
                    const j = await r.json();
                    const a = Array.isArray(j) ? j[0] : j;
                    follows = findFollows(a && a.data, 0);
                    if (follows) for (const l of loginsOf(follows)) all.add(l);
                  }
                }
              } catch (e) {
                replayError = String(e && e.message || e);
              }

              // b) Scroll the page's own list to the bottom over and over, so
              //    Twitch loads every next batch itself (recorded as it comes).
              let records = (window.__relayFollows || []).length;
              let quiet = 0;
              for (let i = 0; i < 80 && quiet < 4; i++) {
                window.scrollTo(0, document.body.scrollHeight);
                for (const el of document.querySelectorAll('*')) {
                  if (el.scrollHeight > el.clientHeight + 50) {
                    const style = getComputedStyle(el);
                    if (/(auto|scroll)/.test(style.overflowY)) el.scrollTop = el.scrollHeight;
                  }
                }
                await sleep(1200);
                const now = (window.__relayFollows || []).length;
                if (now > records) { records = now; quiet = 0; } else { quiet++; }
              }
              collect();
              if (all.size) return { logins: Array.from(all) };
            }

            // 2. At least the channels live right now (a simpler request).
            const headers = { 'Client-ID': clientId, 'Authorization': 'OAuth ' + token,
                              'Content-Type': 'text/plain;charset=UTF-8' };
            const m = document.cookie.match(/(?:^|; )unique_id=([^;]+)/);
            if (m) headers['X-Device-Id'] = decodeURIComponent(m[1]);
            if (seen && seen.headers) {
              for (const k of Object.keys(seen.headers)) {
                if (/integrity|device|session/i.test(k)) headers[k] = seen.headers[k];
              }
            }
            const r = await send('https://gql.twitch.tv/gql', {
              method: 'POST', headers,
              body: JSON.stringify({ query: 'query { currentUser { followedLiveUsers(first: 100) { edges { node { login } } } } }' }),
            });
            const j = await r.json();
            const live = j && j.data && j.data.currentUser && j.data.currentUser.followedLiveUsers;
            if (live) {
              return { logins: (live.edges || []).map((e) => e.node && e.node.login).filter(Boolean),
                       liveOnly: true, error: replayError };
            }
            return { error: replayError + '; live list: ' +
                     (j && j.errors ? j.errors.map((e) => e.message).join('; ') : 'HTTP ' + r.status) };
          ''',
          arguments: {'clientId': _webClientId, 'token': token, 'login': login},
        );
        final value = result?.value;
        if (value is Map) {
          final logins = value['logins'];
          if (logins is List) {
            if (value['error'] != null) debugPrint('TwitchWeb: ${value['error']}');
            return (
              logins: logins.map((e) => e.toString()).toList(),
              liveOnly: value['liveOnly'] == true,
            );
          }
          lastError = '${value['error'] ?? 'no answer'}';
        } else if (result?.error != null) {
          lastError = result!.error;
        }
      } catch (e) {
        lastError = '$e';
        debugPrint('TwitchWeb follows failed: $e');
      }
    }
    throw ApiException('twitch.tv: ${lastError ?? 'no answer'}');
  }
}
