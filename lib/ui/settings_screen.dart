import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/services.dart';
import '../core/settings.dart';
import '../twitch/adblock.dart';
import '../twitch/twitch_watch.dart';
import '../kick/kick_follows.dart';
import 'chat_filters_screen.dart';
import 'kick_web_login_screen.dart';
import 'live_alerts_screen.dart';
import 'twitch_web_login_screen.dart';
import 'widgets.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _settings = Services.settings;
  late final _customUrl = TextEditingController(text: _settings.customScriptUrl);
  final _updating = ValueNotifier<bool>(false);
  bool get _updatingScript => _updating.value;

  @override
  void dispose() {
    _customUrl.dispose();
    _updating.dispose();
    super.dispose();
  }

  Future<void> _signInTwitch() => Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const TwitchWebLoginScreen()),
      );

  Future<void> _signInKick() => Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const KickWebLoginScreen()),
      );

  Future<void> _signOutKick() async {
    await KickFollows.signOut();
    // Also end the older developer-app login, if there is one.
    if (Services.kick.isLoggedIn) await Services.kick.logout();
  }

  Future<void> _updateScript() async {
    final url = AdBlockScripts.urlFor(_settings);
    if (url == null) return;
    _updating.value = true;
    try {
      final script = await AdBlockScripts.download(_settings, url);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Script updated (version ${AdBlockScripts.versionOf(script) ?? 'unknown'})'),
      ));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      _updating.value = false;
    }
  }

  Listenable get _changes => Listenable.merge([_settings, Services.twitch, Services.kick, _updating]);

  /// Opens one category on its own page (kept up to date as settings change).
  void _open(String title, List<Widget> Function(BuildContext context) children) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (context) => ListenableBuilder(
        listenable: _changes,
        builder: (context, _) => Scaffold(
          appBar: AppBar(title: Text(title)),
          body: ListView(
            padding: const EdgeInsets.only(top: 8, bottom: 40),
            children: children(context),
          ),
        ),
      ),
    ));
  }

  List<Widget> _accounts(BuildContext context) {
    final twitch = Services.twitch;
    return [
      ListTile(
        leading: const _Logo(color: Color(0xFF9146FF), letter: 'T'),
        title: const Text('Twitch'),
        subtitle: Text(twitch.isWebLogin
            ? 'Signed in as ${twitch.login}'
            : twitch.isLoggedIn
                ? 'Signed in as ${twitch.login} (old login). Sign in again so your subs remove ads'
                : "Chat, your follows, and no ads on channels you're subscribed to"),
        trailing: twitch.isWebLogin
            ? TextButton(onPressed: () => twitch.logout(), child: const Text('Sign out'))
            : FilledButton(onPressed: _signInTwitch, child: const Text('Sign in')),
      ),
      ListTile(
        leading: const _Logo(color: Color(0xFF53FC18), letter: 'K', dark: true),
        title: const Text('Kick'),
        subtitle: Text(KickFollows.isSignedIn
            ? 'Signed in${KickFollows.username == null ? '' : ' as ${KickFollows.username}'}'
            : 'Chat and your follows'),
        trailing: KickFollows.isSignedIn
            ? TextButton(onPressed: _signOutKick, child: const Text('Sign out'))
            : FilledButton(onPressed: _signInKick, child: const Text('Sign in')),
      ),
    ];
  }

  List<Widget> _home(BuildContext context) => [
        SwitchListTile(
          title: const Text('Preview troubleshooting notes'),
          subtitle: const Text('In tile view, tiles without a preview say why'),
          value: _settings.previewNotes,
          onChanged: (v) => _settings.setPreviewNotes(v),
        ),
      ];

  List<Widget> _player(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return [
      SwitchListTile(
        title: const Text('Count me as a viewer (Twitch)'),
        subtitle: ValueListenableBuilder<String?>(
          valueListenable: TwitchWatchReporter.status,
          builder: (context, status, _) => Text(
            'Reports your watch time like Twitch\'s own player, so you earn channel points, '
            'watch streaks and Drops while watching in Bolt. Needs your Twitch sign-in.'
            '${status == null ? '' : '\nLast: $status'}',
          ),
        ),
        isThreeLine: true,
        value: _settings.countAsViewer,
        onChanged: (v) => _settings.setCountAsViewer(v),
      ),
      const Divider(height: 1),
      for (final mode in TwitchPlayerMode.values)
        ListTile(
          leading: Icon(
            _settings.twitchPlayer == mode
                ? Icons.radio_button_checked_rounded
                : Icons.radio_button_unchecked_rounded,
            color: _settings.twitchPlayer == mode ? theme.colorScheme.primary : null,
          ),
          title: Text(mode.label),
          subtitle: Text(mode.description),
          onTap: () => _settings.setTwitchPlayer(mode),
        ),
      if (defaultTargetPlatform == TargetPlatform.iOS) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text('iPhone player', style: theme.textTheme.titleSmall),
        ),
        for (final engine in PlayerEngine.values)
          ListTile(
            leading: Icon(
              _settings.playerEngine == engine
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              color: _settings.playerEngine == engine ? theme.colorScheme.primary : null,
            ),
            title: Text(engine.label),
            subtitle: Text(engine.description),
            onTap: () => _settings.setPlayerEngine(engine),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'This is the default. Any channel can use the other one: ⋮ on the channel.'
            '${_settings.playerEngineFor.isEmpty ? '' : ' Channels with their own choice: ${_settings.playerEngineFor.length}.'}',
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
      ],
      SwitchListTile(
        title: const Text('Low latency mode'),
        subtitle: const Text(
            'Starts streams close to live and quietly catches up if playback falls behind.'),
        value: _settings.lowLatency,
        onChanged: (v) => _settings.setLowLatency(v),
      ),
      SwitchListTile(
        title: const Text('Show latency'),
        subtitle: const Text('How many seconds behind live the stream is, shown on the video.'),
        value: _settings.showLatency,
        onChanged: (v) => _settings.setShowLatency(v),
      ),
    ];
  }

  List<Widget> _adBlocking(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final cachedVersion = AdBlockScripts.versionOf(AdBlockScripts.cachedFor(_settings));
    final items = <Widget>[
      if (_settings.twitchPlayer == TwitchPlayerMode.relay)
        SwitchListTile(
          title: const Text('Block Twitch ads'),
          subtitle: const Text(
              'During ad breaks Bolt plays an ad-free copy of the stream, the way '
              "TwitchAdSolutions' vaft does. If none is available, the video waits until the break ends."),
          value: _settings.relayAdBlock,
          onChanged: (v) => _settings.setRelayAdBlock(v),
        ),
      if (_settings.twitchPlayer == TwitchPlayerMode.web) ...[
        for (final option in AdBlockScript.values)
          ListTile(
            leading: Icon(
              _settings.adBlock == option
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              color: _settings.adBlock == option ? theme.colorScheme.primary : null,
            ),
            title: Text(option.label),
            subtitle: Text(option.description),
            onTap: () => _settings.setAdBlock(option),
          ),
        if (_settings.adBlock == AdBlockScript.custom)
          _field(_customUrl, 'Userscript URL',
              onSubmitted: (v) => _settings.setCustomScriptUrl(v)),
        if (_settings.adBlock == AdBlockScript.vaftFork ||
            _settings.adBlock == AdBlockScript.custom)
          ListTile(
            title: Text(cachedVersion == null
                ? 'Not downloaded yet'
                : 'Cached version $cachedVersion'),
            subtitle: const Text('The script refreshes itself in the background too.'),
            trailing: _updatingScript
                ? const SizedBox(
                    width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : TextButton(
                    onPressed: () async {
                      if (_settings.adBlock == AdBlockScript.custom) {
                        await _settings.setCustomScriptUrl(_customUrl.text);
                      }
                      await _updateScript();
                    },
                    child: const Text('Update now'),
                  ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Text(
            'Changes apply the next time you open a Twitch stream.',
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
      ],
    ];
    if (items.isEmpty) {
      items.add(Padding(
        padding: const EdgeInsets.all(16),
        child: Text('Nothing to set for this player.', style: theme.textTheme.bodySmall?.copyWith(color: muted)),
      ));
    }
    return items;
  }

  String _filterSummary() {
    final s = _settings;
    final parts = [
      if (s.hideBots) 'bots hidden',
      if (s.mutedUsers.isNotEmpty) '${s.mutedUsers.length} people hidden',
      if (s.mutedWords.isNotEmpty) '${s.mutedWords.length} words hidden',
      if (s.highlightWords.isNotEmpty) '${s.highlightWords.length} highlight words',
    ];
    return parts.isEmpty ? 'Hide bots, people or words; highlight keywords' : parts.join(' · ');
  }

  List<Widget> _chat(BuildContext context) => [
        ListTile(
          title: const Text('Text size'),
          subtitle: Slider(
            value: _settings.chatTextScale,
            min: 0.8,
            max: 1.6,
            divisions: 8,
            label: '${(_settings.chatTextScale * 100).round()}%',
            onChanged: (v) => _settings.setChatTextScale(v),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.filter_alt_outlined),
          title: const Text('Filters'),
          subtitle: Text(_filterSummary()),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const ChatFiltersScreen()),
          ),
        ),
        SwitchListTile(
          title: const Text('7TV name paints'),
          subtitle: const Text('Colored and gradient names people picked on 7TV'),
          value: _settings.showPaints,
          onChanged: (v) => _settings.setShowPaints(v),
        ),
        SwitchListTile(
          title: const Text('Show timestamps'),
          value: _settings.showTimestamps,
          onChanged: (v) => _settings.setShowTimestamps(v),
        ),
        SwitchListTile(
          title: const Text('Show chat in landscape'),
          subtitle: const Text('Toggle it anytime with the chat button on the video'),
          value: _settings.landscapeChat,
          onChanged: (v) => _settings.setLandscapeChat(v),
        ),
      ];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _changes,
      builder: (context, _) {
        final twitch = Services.twitch;
        final signedIn = [
          if (twitch.isLoggedIn) 'Twitch',
          if (KickFollows.isSignedIn) 'Kick',
        ];
        final iosEngine = defaultTargetPlatform == TargetPlatform.iOS ? ' · ${_settings.playerEngine.label}' : '';
        Widget category(IconData icon, String title, String subtitle, VoidCallback onTap) => ListTile(
              leading: Icon(icon),
              title: Text(title),
              subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: onTap,
            );
        return Scaffold(
          appBar: AppBar(title: const Text('Settings')),
          body: ListView(
            padding: const EdgeInsets.only(top: 8, bottom: 40),
            children: [
              category(Icons.person_outline_rounded, 'Accounts',
                  signedIn.isEmpty ? 'Sign in to Twitch and Kick' : 'Signed in: ${signedIn.join(', ')}',
                  () => _open('Accounts', _accounts)),
              category(Icons.play_circle_outline_rounded, 'Player',
                  '${_settings.twitchPlayer.label}$iosEngine', () => _open('Player', _player)),
              category(Icons.block_rounded, 'Twitch ad blocking',
                  _settings.twitchPlayer == TwitchPlayerMode.relay
                      ? (_settings.relayAdBlock ? 'On' : 'Off')
                      : _settings.adBlock.label,
                  () => _open('Twitch ad blocking', _adBlocking)),
              category(Icons.chat_bubble_outline_rounded, 'Chat', 'Filters, text size, timestamps, 7TV paints',
                  () => _open('Chat', _chat)),
              category(Icons.notifications_active_outlined, 'Live alerts',
                  _settings.alertsServer.isEmpty
                      ? 'Get notified when streamers go live'
                      : '${_settings.alertChannels.length} streamers',
                  () => Navigator.of(context).push(
                        MaterialPageRoute<void>(builder: (_) => const LiveAlertsScreen()),
                      )),
              category(Icons.home_outlined, 'Home', 'Tile view troubleshooting',
                  () => _open('Home', _home)),
              const SizedBox(height: 16),
              ListTile(
                title: const Text('Credits and licenses'),
                subtitle: const Text(
                    'Ad blocking: TwitchAdSolutions (MIT). Emotes: 7TV. Not affiliated with Twitch or Kick.\n'
                    'Build $relayBuild'),
                onTap: () => showLicensePage(context: context, applicationName: 'Bolt'),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _field(TextEditingController c, String label,
      {bool obscure = false, ValueChanged<String>? onSubmitted}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: TextField(
        controller: c,
        obscureText: obscure,
        autocorrect: false,
        enableSuggestions: false,
        onSubmitted: onSubmitted,
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo({required this.color, required this.letter, this.dark = false});

  final Color color;
  final String letter;
  final bool dark;

  @override
  Widget build(BuildContext context) => CircleAvatar(
        backgroundColor: color,
        radius: 18,
        child: Text(letter,
            style: TextStyle(
                color: dark ? Colors.black : Colors.white, fontWeight: FontWeight.w800)),
      );
}
