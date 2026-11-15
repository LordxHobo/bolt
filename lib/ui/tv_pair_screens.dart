import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/tv_pairing.dart';
import 'tv_widgets.dart';
import 'widgets.dart';

/// TV: shows a QR code and a code for Bolt on your phone, and signs in with
/// what the phone sends.
class TvSignInScreen extends StatefulWidget {
  const TvSignInScreen({super.key});

  @override
  State<TvSignInScreen> createState() => _TvSignInScreenState();
}

class _TvSignInScreenState extends State<TvSignInScreen> {
  final _server = TvPairServer();

  @override
  void initState() {
    super.initState();
    _server.start();
  }

  @override
  void dispose() {
    _server.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.7);
    return Scaffold(
      body: ListenableBuilder(
        listenable: _server,
        builder: (context, _) {
          final s = _server;
          final link = s.link;
          final Widget side;
          if (s.result != null) {
            side = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Done', style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 12),
                Text(s.result!, style: theme.textTheme.titleMedium),
                const SizedBox(height: 24),
                TvButton(
                  autofocus: true,
                  icon: Icons.check_rounded,
                  label: 'Back to Bolt',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            );
          } else {
            side = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Sign in from your phone',
                    style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 16),
                if (s.error != null)
                  Text(s.error!, style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.error))
                else ...[
                  Text('1. Make sure your phone is on the same Wi-Fi as this TV.', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text('2. Point your phone\'s camera at the QR code and open it in Bolt.',
                      style: theme.textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text('3. Tap Send. The TV signs in to the same Twitch and Kick accounts.',
                      style: theme.textTheme.titleMedium),
                  const SizedBox(height: 20),
                  Text('No camera? In Bolt on your phone: Settings → Accounts → Send sign-ins to a TV, and enter:',
                      style: theme.textTheme.bodyMedium?.copyWith(color: muted)),
                  const SizedBox(height: 8),
                  if (s.address != null)
                    Text('TV address  ${s.address}',
                        style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                  Text('Code  ${TvPairing.showCode(s.code)}',
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w800, letterSpacing: 2)),
                  const SizedBox(height: 16),
                  if (s.busy)
                    const Row(children: [
                      SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                      SizedBox(width: 10),
                      Text('Signing in…'),
                    ])
                  else
                    Text('Waiting for your phone… (the code works for 10 minutes)',
                        style: theme.textTheme.bodyMedium?.copyWith(color: muted)),
                ],
                const SizedBox(height: 24),
                TvButton(
                  autofocus: true,
                  icon: Icons.arrow_back_rounded,
                  label: 'Back',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            );
          }
          return Padding(
            padding: const EdgeInsets.all(40),
            child: Row(
              children: [
                if (link != null && s.result == null && s.error == null) ...[
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                    child: QrImageView(data: link, size: 240, backgroundColor: Colors.white),
                  ),
                  const SizedBox(width: 40),
                ],
                Expanded(child: SingleChildScrollView(child: side)),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Phone: sends your sign-ins to Bolt on a TV. Opened from the TV's QR code
/// (address and code filled in) or from Settings → Accounts.
class SendToTvScreen extends StatefulWidget {
  const SendToTvScreen({super.key, this.host, this.code});

  final String? host;
  final String? code;

  @override
  State<SendToTvScreen> createState() => _SendToTvScreenState();
}

class _SendToTvScreenState extends State<SendToTvScreen> {
  late final _host = TextEditingController(text: widget.host ?? '');
  late final _code = TextEditingController(text: widget.code == null ? '' : TvPairing.showCode(widget.code!));
  bool _sending = false;
  String? _done;

  @override
  void dispose() {
    _host.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending) return;
    FocusScope.of(context).unfocus();
    setState(() => _sending = true);
    try {
      final summary = await TvPairing.send(_host.text, _code.text);
      if (mounted) setState(() => _done = summary);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final have = TvPairing.available();
    final fromQr = widget.host != null && widget.code != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Send sign-ins to a TV')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_done != null) ...[
            const Icon(Icons.check_circle_rounded, size: 48, color: Colors.greenAccent),
            const SizedBox(height: 12),
            Text('The TV says:', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(_done!, style: theme.textTheme.bodyLarge),
            const SizedBox(height: 20),
            FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
          ] else ...[
            Text(
              fromQr
                  ? 'Send your sign-ins to the TV at ${widget.host}?'
                  : 'On the TV, open Bolt → Sign in from phone. Enter the address and code it shows.',
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 12),
            Text(
              [
                have.twitch != null ? '• Twitch: ${have.twitch}' : '• Twitch: not signed in on this phone (with twitch.tv)',
                have.kick ? '• Kick: yes' : '• Kick: not signed in on this phone',
              ].join('\n'),
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
            ),
            const SizedBox(height: 16),
            if (!fromQr) ...[
              TextField(
                controller: _host,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'TV address',
                  hintText: '192.168.1.23',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _code,
                autocorrect: false,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Code',
                  hintText: 'ABCD-EFGH',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _send(),
              ),
              const SizedBox(height: 16),
            ],
            FilledButton.icon(
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send_rounded),
              label: Text(_sending ? 'Sending…' : 'Send'),
            ),
            const SizedBox(height: 16),
            Text(
              'Goes straight to the TV over your Wi-Fi, encrypted with the TV\'s code. '
              'Nothing passes through a server. On iPhone, allow Local Network access if asked.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ],
        ],
      ),
    );
  }
}
