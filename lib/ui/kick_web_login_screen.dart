import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/silent_page.dart';
import '../kick/kick_follows.dart';
import 'widgets.dart';

/// Shows kick.com so you can sign in with your Kick account; Relay then reads
/// your follow list with that login. Returns true when it worked.
class KickWebLoginScreen extends StatefulWidget {
  const KickWebLoginScreen({super.key});

  @override
  State<KickWebLoginScreen> createState() => _KickWebLoginScreenState();
}

class _KickWebLoginScreenState extends State<KickWebLoginScreen> {
  double _progress = 0;
  bool _checking = false;

  Future<void> _done() async {
    setState(() => _checking = true);
    final ok = await KickFollows.confirmSignIn();
    if (!mounted) return;
    setState(() => _checking = false);
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      showError(context,
          "Relay couldn't read your follows yet. Make sure you're logged in on the page, then tap Done again.");
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sign in to kick.com'),
        actions: [
          _checking
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : TextButton(onPressed: _done, child: const Text('Done')),
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
              'Log in with your Kick account below, then tap Done. Relay only uses this to see who you follow.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri('https://kick.com/')),
              initialUserScripts: UnmodifiableListView([silentPageScript]),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                mediaPlaybackRequiresUserGesture: true,
                allowsPictureInPictureMediaPlayback: false,
              ),
              onProgressChanged: (controller, progress) {
                if (mounted) setState(() => _progress = progress / 100);
              },
            ),
          ),
        ],
      ),
    );
  }
}
