import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/models.dart';
import '../core/services.dart';
import '../twitch/twitch_extensions.dart';
import 'twitch_web_login_screen.dart';

/// A Twitch channel's extensions (experimental).
class ExtensionsScreen extends StatefulWidget {
  const ExtensionsScreen({super.key, required this.info});

  final ChannelInfo info;

  @override
  State<ExtensionsScreen> createState() => _ExtensionsScreenState();
}

class _ExtensionsScreenState extends State<ExtensionsScreen> {
  late Future<List<ChannelExtension>> _list = TwitchExtensions.forChannel(widget.info.login);

  Future<void> _peek() async {
    final png = await ExtensionKeeper.instance.peek(widget.info.login);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hidden page right now'),
        contentPadding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
        content: png == null
            ? const Text("Couldn't take a picture of it (it may still be loading).")
            : InteractiveViewer(maxScale: 5, child: Image.memory(png)),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final keeper = ExtensionKeeper.instance;
    final login = widget.info.login;
    return Scaffold(
      appBar: AppBar(title: const Text('Extensions')),
      body: ListenableBuilder(
        listenable: Listenable.merge([keeper, Services.twitch]),
        builder: (context, _) => FutureBuilder<List<ChannelExtension>>(
          future: _list,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final items = snap.data ?? const <ChannelExtension>[];
            final running = keeper.isRunning(login);
            return RefreshIndicator(
              onRefresh: () async {
                setState(() => _list = TwitchExtensions.forChannel(login));
                await _list;
              },
              child: ListView(
                padding: const EdgeInsets.only(bottom: 40),
                children: [
                  Container(
                    margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      'Experimental. "Keep running" opens this channel\'s twitch.tv page out of sight '
                      '(muted, lowest quality), so extensions that reward watching, like card drops, '
                      'see you there. It closes when you leave the channel and uses a little extra data.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  if (!Services.twitch.isWebLogin)
                    ListTile(
                      leading: const Icon(Icons.login_rounded),
                      title: const Text('Sign in to Twitch'),
                      subtitle: const Text('Extensions need to know who you are'),
                      onTap: () => Navigator.of(context)
                          .push(MaterialPageRoute<void>(builder: (_) => const TwitchWebLoginScreen())),
                    ),
                  SwitchListTile(
                    title: const Text('Keep running while I watch'),
                    subtitle: running ? Text(keeper.status(login) ?? '') : null,
                    value: running,
                    onChanged: (on) => on ? keeper.start(login) : keeper.stop(login),
                  ),
                  if (running)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: TextButton.icon(
                          onPressed: _peek,
                          icon: const Icon(Icons.visibility_outlined),
                          label: const Text('Peek at the hidden page'),
                        ),
                      ),
                    ),
                  const Divider(),
                  if (snap.hasError)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text("Couldn't load this channel's extensions: ${snap.error}",
                          textAlign: TextAlign.center),
                    )
                  else if (items.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('This channel has no extensions turned on.', textAlign: TextAlign.center),
                    ),
                  for (final e in items)
                    ListTile(
                      leading: const Icon(Icons.extension_outlined),
                      title: Text(e.name),
                      subtitle: Text(e.kind),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) => _ExtensionPage(login: login, extension: e),
                      )),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ExtensionPage extends StatefulWidget {
  const _ExtensionPage({required this.login, required this.extension});

  final String login;
  final ChannelExtension extension;

  @override
  State<_ExtensionPage> createState() => _ExtensionPageState();
}

class _ExtensionPageState extends State<_ExtensionPage> {
  InAppWebViewController? _web;
  double _progress = 0;
  String? _status;
  int _load = 0;

  /// Scrolls the page to this extension once Twitch has put it there
  /// (panels sit under the video, so they're otherwise off screen).
  Future<void> _findExtension(InAppWebViewController c) async {
    final load = ++_load;
    final id = widget.extension.id;
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!mounted || load != _load) return;
      try {
        final found = await c.evaluateJavascript(
          source: "(function () { var f = document.querySelector('iframe[src*=\"$id\"]'); "
              "if (!f) return false; f.scrollIntoView({block: 'center'}); return true; })();",
        );
        if (found == true) break;
      } catch (_) {}
    }
    if (!mounted || load != _load) return;
    final line = await TwitchExtensions.probe(c);
    if (mounted && line != null) setState(() => _status = line);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.extension.name),
        actions: [
          IconButton(icon: const Icon(Icons.refresh_rounded), onPressed: () => _web?.reload()),
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
            child: Text(
              _status ??
                  (widget.extension.isPanel
                      ? 'Panels sit under the video; the page scrolls to it once it loads. Pinch to zoom.'
                      : '${widget.extension.kind}s show on the video. Pinch to zoom.'),
              style: theme.textTheme.labelSmall?.copyWith(color: Colors.white60),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: channelPageUrl(widget.login)),
              initialUserScripts: extensionUserScripts(),
              initialSettings: extensionWebSettings(),
              onWebViewCreated: (c) => _web = c,
              onProgressChanged: (_, p) {
                if (mounted) setState(() => _progress = p / 100);
              },
              onLoadStop: (c, _) => _findExtension(c),
              onReceivedError: (_, req, err) {
                if ((req.isForMainFrame ?? false) && mounted) setState(() => _status = 'Error: ${err.description}');
              },
            ),
          ),
        ],
      ),
    );
  }
}
