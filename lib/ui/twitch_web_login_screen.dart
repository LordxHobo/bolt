import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/silent_page.dart';
import '../core/services.dart';
import 'widgets.dart';

/// Signs in to Twitch on twitch.tv's own login page. That one login is used
/// for everything: watching (your subs and Turbo apply, so no ads there),
/// chat and your follow list.
class TwitchWebLoginScreen extends StatefulWidget {
  const TwitchWebLoginScreen({super.key});

  @override
  State<TwitchWebLoginScreen> createState() => _TwitchWebLoginScreenState();
}

class _TwitchWebLoginScreenState extends State<TwitchWebLoginScreen> {
  double _progress = 0;
  bool _busy = false;
  bool _done = false;

  static const _safariUserAgent =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 '
      '(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';

  Future<void> _check({bool manual = false}) async {
    if (_done || _busy) return;
    String? token;
    try {
      final cookie = await CookieManager.instance()
          .getCookie(url: WebUri('https://www.twitch.tv'), name: 'auth-token');
      token = cookie?.value?.toString();
    } catch (_) {}
    if (!mounted) return;
    if (token == null || token.isEmpty) {
      if (manual) showError(context, "You're not logged in yet. Log in on the page, then tap Done.");
      return;
    }
    setState(() => _busy = true);
    try {
      await Services.twitch.signInWithWebToken(token);
      _done = true;
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sign in to Twitch'),
        actions: [
          _busy
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : TextButton(onPressed: () => _check(manual: true), child: const Text('Done')),
        ],
        bottom: _progress < 1
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(value: _progress, minHeight: 2),
              )
            : null,
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: theme.colorScheme.surfaceContainer,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Text(
              'Log in with your Twitch account. Relay uses it to chat, show who you follow, and '
              "watch as you, so channels you're subscribed to play without ads.",
              style: theme.textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri('https://www.twitch.tv/login')),
              initialUserScripts: UnmodifiableListView([silentPageScript]),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                userAgent: _safariUserAgent,
                mediaPlaybackRequiresUserGesture: true,
                allowsPictureInPictureMediaPlayback: false,
              ),
              onProgressChanged: (controller, progress) {
                if (mounted) setState(() => _progress = progress / 100);
              },
              // Twitch leaves the login page once you're in.
              onLoadStop: (controller, url) => _check(),
            ),
          ),
        ],
      ),
    );
  }
}
