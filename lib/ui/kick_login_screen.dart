import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/services.dart';
import '../kick/kick_auth.dart';
import 'widgets.dart';

/// Shows Kick's login/consent page and catches the redirect back to the
/// app's redirect URI (it never has to actually load).
class KickLoginScreen extends StatefulWidget {
  const KickLoginScreen({super.key});

  @override
  State<KickLoginScreen> createState() => _KickLoginScreenState();
}

class _KickLoginScreenState extends State<KickLoginScreen> {
  late final KickPkceRequest _request = Services.kick.buildAuthorizeRequest();
  bool _handled = false;
  bool _exchanging = false;
  double _progress = 0;

  bool _isRedirect(Uri? url) {
    if (url == null) return false;
    final redirect = Uri.parse(Services.settings.kickRedirectUri);
    return url.host == redirect.host &&
        url.path == redirect.path &&
        (url.queryParameters.containsKey('code') || url.queryParameters.containsKey('error'));
  }

  Future<void> _handleRedirect(Uri url) async {
    if (_handled) return;
    _handled = true;
    setState(() => _exchanging = true);
    try {
      await Services.kick.completeLogin(_request, url);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      showError(context, e);
      Navigator.of(context).pop(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Log in to Kick'),
        bottom: _progress < 1 && !_exchanging
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(value: _progress, minHeight: 2),
              )
            : null,
      ),
      body: _exchanging
          ? const Center(child: CircularProgressIndicator())
          : InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri.uri(_request.authorizeUrl)),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                useShouldOverrideUrlLoading: true,
              ),
              shouldOverrideUrlLoading: (controller, action) async {
                final url = action.request.url;
                if (_isRedirect(url)) {
                  _handleRedirect(url!);
                  return NavigationActionPolicy.CANCEL;
                }
                return NavigationActionPolicy.ALLOW;
              },
              onLoadStart: (controller, url) {
                if (_isRedirect(url)) {
                  controller.stopLoading();
                  _handleRedirect(url!);
                }
              },
              onProgressChanged: (controller, progress) {
                if (mounted) setState(() => _progress = progress / 100);
              },
            ),
    );
  }
}
