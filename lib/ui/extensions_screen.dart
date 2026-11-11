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
                      'Experimental. Extensions open in Twitch\'s own pop-out page, signed in as you. '
                      'Turn on "Keep running" for ones that reward watching (like card drops): it stays open '
                      'out of sight until you leave this channel.',
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
                      subtitle: Text(keeper.isRunning(login, e) ? '${e.kind} · running' : e.kind),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) => _ExtensionPage(login: login, extension: e),
                      )),
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Switch(
                            value: keeper.isRunning(login, e),
                            onChanged: (on) => on ? keeper.start(login, e) : keeper.stop(login, e),
                          ),
                        ],
                      ),
                    ),
                  if (items.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                      child: Text('Switch = keep running while you watch. Tap to open.',
                          style: theme.textTheme.labelSmall?.copyWith(color: Colors.white60)),
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

  @override
  Widget build(BuildContext context) {
    final keeper = ExtensionKeeper.instance;
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
          ListenableBuilder(
            listenable: keeper,
            builder: (context, _) => SwitchListTile(
              dense: true,
              title: const Text('Keep running while I watch'),
              value: keeper.isRunning(widget.login, widget.extension),
              onChanged: (on) =>
                  on ? keeper.start(widget.login, widget.extension) : keeper.stop(widget.login, widget.extension),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: widget.extension.popoutUrl(widget.login)),
              initialSettings: extensionWebSettings(),
              onWebViewCreated: (c) => _web = c,
              onProgressChanged: (_, p) {
                if (mounted) setState(() => _progress = p / 100);
              },
            ),
          ),
        ],
      ),
    );
  }
}
