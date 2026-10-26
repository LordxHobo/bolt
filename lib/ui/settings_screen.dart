import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/services.dart';
import '../core/settings.dart';
import '../twitch/adblock.dart';
import '../kick/kick_follows.dart';
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
  bool _updatingScript = false;

  @override
  void dispose() {
    _customUrl.dispose();
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
    setState(() => _updatingScript = true);
    try {
      final script = await AdBlockScripts.download(_settings, url);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Script updated (version ${AdBlockScripts.versionOf(script) ?? 'unknown'})'),
      ));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _updatingScript = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_settings, Services.twitch, Services.kick]),
      builder: (context, _) {
        final twitch = Services.twitch;
        final theme = Theme.of(context);
        final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
        final cachedVersion = AdBlockScripts.versionOf(AdBlockScripts.cachedFor(_settings));
        return Scaffold(
          appBar: AppBar(title: const Text('Settings')),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 40),
            children: [
              const SectionHeader('Accounts'),
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
              const SectionHeader('Notifications'),
              ListTile(
                leading: const Icon(Icons.notifications_active_outlined),
                title: const Text('Live alerts'),
                subtitle: Text(_settings.alertsServer.isEmpty
                    ? 'Get notified when streamers go live'
                    : '${_settings.alertChannels.length} streamers'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const LiveAlertsScreen()),
                ),
              ),
              const SectionHeader('Player'),
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
              const SectionHeader('Twitch ad blocking'),
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
              const SectionHeader('Chat'),
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
              const SectionHeader('About'),
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
