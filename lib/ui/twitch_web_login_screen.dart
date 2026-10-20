import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../twitch/twitch_web_auth.dart';
import 'widgets.dart';

/// Shows twitch.tv's login page. Once you're logged in, Relay keeps the
/// login so streams are requested as you (no ads where you're subscribed).
class TwitchWebLoginScreen extends StatefulWidget {
  const TwitchWebLoginScreen({super.key});

  @override
  State<TwitchWebLoginScreen> createState() => _TwitchWebLoginScreenState();
}

class _TwitchWebLoginScreenState extends State<TwitchWebLoginScreen> {
  double _progress = 0;
  bool _done = false;

  static const _safariUserAgent =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 '
      '(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';

  Future<void> _check({bool manual = false}) async {
    if (_done) return;
    final ok = await TwitchWebAuth.captureFromCookies();
    if (!mounted) return;
    if (ok) {
      _done = true;
      Navigator.of(context).pop(true);
    } else if (manual) {
      showError(context, "You're not logged in yet. Log in on the page, then tap Done.");
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sign in to twitch.tv'),
        actions: [TextButton(onPressed: () => _check(manual: true), child: const Text('Done'))],
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
              'Log in with your Twitch account. Relay then asks for streams as you, so '
              "channels you're subscribed to play without ads (and everything does with Turbo).",
              style: theme.textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri('https://www.twitch.tv/login')),
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
