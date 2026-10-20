import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/models.dart';
import '../core/services.dart';
import '../core/settings.dart';
import '../twitch/adblock.dart';
import '../twitch/twitch_auth.dart';
import '../kick/kick_follows.dart';
import 'kick_login_screen.dart';
import 'kick_web_login_screen.dart';
import 'twitch_web_login_screen.dart';
import '../twitch/twitch_web_auth.dart';
import 'widgets.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _settings = Services.settings;
  late final _twitchId = TextEditingController(text: _settings.twitchClientId);
  late final _kickId = TextEditingController(text: _settings.kickClientId);
  late final _kickSecret = TextEditingController(text: _settings.kickClientSecret);
  late final _kickRedirect = TextEditingController(text: _settings.kickRedirectUri);
  late final _customUrl = TextEditingController(text: _settings.customScriptUrl);
  bool _updatingScript = false;

  @override
  void dispose() {
    _twitchId.dispose();
    _kickId.dispose();
    _kickSecret.dispose();
    _kickRedirect.dispose();
    _customUrl.dispose();
    super.dispose();
  }

  Future<void> _saveCredentials() async {
    await _settings.setTwitchClientId(_twitchId.text);
    await _settings.setKickCredentials(
      clientId: _kickId.text,
      clientSecret: _kickSecret.text,
      redirectUri: _kickRedirect.text,
    );
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Saved')));
  }

  Future<void> _loginTwitch() async {
    await _saveCredentials();
    if (!mounted) return;
    if (_settings.twitchClientId.isEmpty) {
      showError(context, 'Enter your Twitch Client ID first.');
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _TwitchLoginDialog(),
    );
  }

  Future<void> _loginKick() async {
    await _saveCredentials();
    if (!mounted) return;
    if (!Services.kick.isConfigured) {
      showError(context, 'Enter your Kick Client ID and Client Secret first.');
      return;
    }
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const KickLoginScreen()),
    );
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
        final kick = Services.kick;
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
                subtitle: Text(twitch.isLoggedIn
                    ? 'Logged in as ${twitch.login}'
                    : 'Log in to chat and see who you follow'),
                trailing: twitch.isLoggedIn
                    ? TextButton(onPressed: () => twitch.logout(), child: const Text('Log out'))
                    : FilledButton(onPressed: _loginTwitch, child: const Text('Log in')),
              ),
              ListTile(
                leading: const _Logo(color: Color(0xFF53FC18), letter: 'K', dark: true),
                title: const Text('Kick'),
                subtitle: Text(kick.isLoggedIn
                    ? 'Logged in${kick.username == null ? '' : ' as ${kick.username}'}'
                    : 'Log in to chat'),
                trailing: kick.isLoggedIn
                    ? TextButton(onPressed: () => kick.logout(), child: const Text('Log out'))
                    : FilledButton(onPressed: _loginKick, child: const Text('Log in')),
              ),
              ListTile(
                leading: const _Logo(color: Color(0xFF9146FF), letter: 'T'),
                title: const Text('twitch.tv (for playback)'),
                subtitle: Text(TwitchWebAuth.isSignedIn
                    ? "Signed in. Streams are requested as you, so your subs and Turbo apply"
                    : "Sign in so channels you're subscribed to play without ads"),
                isThreeLine: true,
                trailing: TwitchWebAuth.isSignedIn
                    ? TextButton(onPressed: TwitchWebAuth.signOut, child: const Text('Sign out'))
                    : FilledButton(
                        onPressed: () => Navigator.of(context).push<bool>(
                          MaterialPageRoute(builder: (_) => const TwitchWebLoginScreen()),
                        ),
                        child: const Text('Sign in'),
                      ),
              ),
              ListTile(
                leading: const _Logo(color: Color(0xFF53FC18), letter: 'K', dark: true),
                title: const Text('kick.com (follow list)'),
                subtitle: Text(KickFollows.isSignedIn
                    ? 'Signed in. Your Kick follows show on the home screen'
                    : 'Sign in on kick.com to see who you follow. Uses an unofficial endpoint, so it may break'),
                isThreeLine: !KickFollows.isSignedIn,
                trailing: KickFollows.isSignedIn
                    ? TextButton(onPressed: KickFollows.signOut, child: const Text('Sign out'))
                    : FilledButton(
                        onPressed: () => Navigator.of(context).push<bool>(
                          MaterialPageRoute(builder: (_) => const KickWebLoginScreen()),
                        ),
                        child: const Text('Sign in'),
                      ),
              ),
              const SectionHeader('Developer apps'),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'Logging in needs your own (free) developer apps. '
                  'Twitch: dev.twitch.tv/console, client type “Public”. '
                  'Kick: kick.com/settings/developer, with the redirect URL below. '
                  'Watching and reading chat work without them.',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ),
              _field(_twitchId, 'Twitch Client ID'),
              _field(_kickId, 'Kick Client ID'),
              _field(_kickSecret, 'Kick Client Secret', obscure: true),
              _field(_kickRedirect, 'Kick Redirect URL'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonal(onPressed: _saveCredentials, child: const Text('Save')),
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
                      'During ad breaks Relay plays an ad-free copy of the stream, the way '
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
                onTap: () => showLicensePage(context: context, applicationName: 'Relay'),
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

class _TwitchLoginDialog extends StatefulWidget {
  const _TwitchLoginDialog();

  @override
  State<_TwitchLoginDialog> createState() => _TwitchLoginDialogState();
}

class _TwitchLoginDialogState extends State<_TwitchLoginDialog> {
  TwitchDeviceCode? _code;
  String? _error;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _cancelled = true;
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final code = await Services.twitch.startDeviceFlow();
      if (!mounted) return;
      setState(() => _code = code);
      final ok = await Services.twitch.waitForApproval(code, isCancelled: () => _cancelled);
      if (!mounted) return;
      if (ok) {
        Navigator.of(context).pop();
      } else {
        setState(() => _error = 'The code expired. Close this and try again.');
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final code = _code;
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Log in to Twitch'),
      content: _error != null
          ? Text(_error!)
          : code == null
              ? const SizedBox(height: 80, child: Center(child: CircularProgressIndicator()))
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Open the activation page and enter this code:'),
                    const SizedBox(height: 16),
                    SelectableText(
                      code.userCode,
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: 4,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: () => Clipboard.setData(ClipboardData(text: code.userCode)),
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      label: const Text('Copy code'),
                    ),
                    const SizedBox(height: 8),
                    const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    Text('Waiting for you to approve…', style: theme.textTheme.bodySmall),
                  ],
                ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        if (code != null && _error == null)
          FilledButton(
            onPressed: () => launchUrl(Uri.parse(code.verificationUri),
                mode: LaunchMode.externalApplication),
            child: const Text('Open twitch.tv/activate'),
          ),
      ],
    );
  }
}
