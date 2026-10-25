import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/live_alerts.dart';
import '../core/models.dart';
import '../core/services.dart';
import 'widgets.dart';

/// Settings → Live alerts: connect the checker and pick who alerts you.
class LiveAlertsScreen extends StatefulWidget {
  const LiveAlertsScreen({super.key});

  @override
  State<LiveAlertsScreen> createState() => _LiveAlertsScreenState();
}

class _LiveAlertsScreenState extends State<LiveAlertsScreen> {
  final _settings = Services.settings;
  late final _server = TextEditingController(text: _settings.alertsServer);
  bool _testing = false;

  @override
  void dispose() {
    _server.dispose();
    super.dispose();
  }

  Future<void> _saveServer() async {
    if (_server.text.trim() == _settings.alertsServer) return;
    await _settings.setAlertsServer(_server.text);
    _server.text = _settings.alertsServer;
  }

  Future<void> _test() async {
    FocusScope.of(context).unfocus();
    await _saveServer();
    setState(() => _testing = true);
    final error = await LiveAlerts.sendTest();
    if (!mounted) return;
    setState(() => _testing = false);
    if (error != null) {
      showError(context, error);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Test sent. It should show up in a few seconds.'),
      ));
    }
  }

  void _copyTopic() {
    Clipboard.setData(ClipboardData(text: _settings.alertsTopic));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Copied'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return ListenableBuilder(
      listenable: _settings,
      builder: (context, _) {
        final favorites = _settings.favorites;
        final others = [
          for (final c in _settings.alertChannels)
            if (!_settings.isFavorite(c)) c,
        ];
        return Scaffold(
          appBar: AppBar(title: const Text('Live alerts')),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 40),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(
                  'Get a notification when a streamer goes live. A small free checker on '
                  'Cloudflare looks every minute and notifies you through the Bark app; '
                  'tapping the notification opens the stream in Relay. Setup steps are in '
                  'server/live-alerts/README.md in your Relay repository.',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ),
              const SectionHeader('Your private key'),
              ListTile(
                title: SelectableText(_settings.alertsTopic),
                subtitle: const Text('Keeps your list private on the checker. Only needed in the ntfy app if you use ntfy instead of Bark'),
                trailing: TextButton(onPressed: _copyTopic, child: const Text('Copy')),
              ),
              const SectionHeader('Checker address'),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: TextField(
                  controller: _server,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    hintText: 'https://relay-alerts.your-name.workers.dev',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _saveServer(),
                  onTapOutside: (_) {
                    FocusScope.of(context).unfocus();
                    _saveServer();
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonalIcon(
                    onPressed: _testing ? null : _test,
                    icon: _testing
                        ? const SizedBox(
                            width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.notifications_active_outlined),
                    label: const Text('Send test alert'),
                  ),
                ),
              ),
              ValueListenableBuilder<String?>(
                valueListenable: LiveAlerts.status,
                builder: (context, error, _) => error == null
                    ? const SizedBox(height: 8)
                    : Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                        child: Text(error,
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
                      ),
              ),
              const SectionHeader('Favorites'),
              if (favorites.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Text('Favorites alert you by default. You have none yet.',
                      style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                ),
              for (final c in favorites) _tile(c),
              if (others.isNotEmpty) ...[
                const SectionHeader('Others'),
                for (final c in others) _tile(c),
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text(
                  'Turn alerts on or off for any streamer with the bell on their channel page.',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _tile(ChannelRef c) => SwitchListTile(
        secondary: PlatformBadge(c.platform),
        title: Text(c.login),
        value: _settings.alertsFor(c),
        onChanged: (on) => _settings.setAlertsFor(c, on),
      );
}
