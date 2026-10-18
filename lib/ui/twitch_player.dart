import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/services.dart';
import '../twitch/adblock.dart';

/// Twitch's own web player in a WebView, with the TwitchAdSolutions script
/// injected at document start, exactly like a userscript manager does.
class TwitchPlayer extends StatefulWidget {
  const TwitchPlayer({super.key, required this.login});

  final String login;

  @override
  State<TwitchPlayer> createState() => TwitchPlayerState();
}

class TwitchPlayerState extends State<TwitchPlayer> {
  InAppWebViewController? _controller;
  String? _script;
  bool _scriptLoaded = false;

  @override
  void initState() {
    super.initState();
    AdBlockScripts.load(Services.settings).then((script) {
      if (!mounted) return;
      setState(() {
        _script = script;
        _scriptLoaded = true;
      });
    }, onError: (Object _) {
      if (!mounted) return;
      setState(() => _scriptLoaded = true);
    });
  }

  Uri get _playerUrl => Uri.https('player.twitch.tv', '/', {
        'channel': widget.login,
        'parent': 'twitch.tv',
        'muted': 'false',
        'autoplay': 'true',
      });

  void reload() => _controller?.reload();

  @override
  Widget build(BuildContext context) {
    if (!_scriptLoaded) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final script = _script;
    return ColoredBox(
      color: Colors.black,
      child: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri.uri(_playerUrl)),
        initialUserScripts: script == null
            ? null
            : UnmodifiableListView<UserScript>([
                UserScript(
                  groupName: 'adblock',
                  source: script,
                  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                  forMainFrameOnly: true,
                ),
              ]),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          mediaPlaybackRequiresUserGesture: false,
          allowsInlineMediaPlayback: true,
          allowsPictureInPictureMediaPlayback: true,
          allowsAirPlayForMediaPlayback: true,
          transparentBackground: true,
          supportZoom: false,
          disableContextMenu: true,
          disallowOverScroll: true,
          useShouldOverrideUrlLoading: true,
          iframeAllowFullscreen: true,
        ),
        onWebViewCreated: (controller) => _controller = controller,
        shouldOverrideUrlLoading: (controller, action) async {
          final url = action.request.url;
          if (action.isForMainFrame && url != null && url.host != 'player.twitch.tv') {
            // Links like the Twitch logo would navigate away from the player;
            // open them in the browser instead.
            if (url.scheme == 'http' || url.scheme == 'https') {
              await launchUrl(url, mode: LaunchMode.externalApplication);
            }
            return NavigationActionPolicy.CANCEL;
          }
          return NavigationActionPolicy.ALLOW;
        },
        onConsoleMessage: (controller, message) {
          // vaft logs "Blocking ads (...)" etc.; handy when debugging.
          debugPrint('[twitch-player] ${message.message}');
        },
      ),
    );
  }
}
