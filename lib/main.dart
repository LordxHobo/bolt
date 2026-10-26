import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/models.dart';
import 'core/services.dart';
import 'ui/channel_screen.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    final text = await rootBundle.loadString('assets/adblock/LICENSE-TwitchAdSolutions.txt');
    yield LicenseEntryWithLineBreaks(const ['TwitchAdSolutions (vaft, video-swap-new)'], text);
  });
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  // Draw the app right away; loading settings happens behind a splash so a
  // slow or broken storage call can never leave the screen blank.
  runApp(const RelayApp());
}

class RelayApp extends StatefulWidget {
  const RelayApp({super.key});

  @override
  State<RelayApp> createState() => _RelayAppState();
}

class _RelayAppState extends State<RelayApp> {
  late Future<void> _init = _start();

  Future<void> _start() => Services.init().timeout(const Duration(seconds: 15));

  final _navigator = GlobalKey<NavigatorState>();
  StreamSubscription<Uri>? _links;

  @override
  void initState() {
    super.initState();
    // relay://open/<twitch|kick>/<name>, e.g. from a live alert. Also gives
    // the link Relay was opened with.
    try {
      _links = AppLinks().uriLinkStream.listen(_openLink, onError: (Object e) {
        debugPrint('Link failed: $e');
      });
    } catch (e) {
      debugPrint('Links unavailable: $e');
    }
  }

  @override
  void dispose() {
    _links?.cancel();
    super.dispose();
  }

  Future<void> _openLink(Uri uri) async {
    if (uri.scheme != 'relay' || uri.host != 'open') return;
    final parts = uri.pathSegments.where((p) => p.isNotEmpty).toList();
    if (parts.length < 2 || !const ['twitch', 'kick'].contains(parts[0])) return;
    final channel = ChannelRef(StreamPlatformX.parse(parts[0]), parts[1]);
    try {
      await _init;
    } catch (_) {
      return;
    }
    for (var i = 0; i < 20 && _navigator.currentState == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final nav = _navigator.currentState;
    if (nav == null) return;
    // Replace whatever stream is open (or in the mini player).
    nav.popUntil((route) => route.isFirst);
    unawaited(nav.push(ChannelRoute(channel: channel)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF7C5CFF),
      brightness: Brightness.dark,
      surface: const Color(0xFF0E0E10),
    );
    return MaterialApp(
      navigatorKey: _navigator,
      title: 'Bolt',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFF0E0E10),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0E0E10),
          surfaceTintColor: Colors.transparent,
          centerTitle: false,
        ),
        dividerColor: Colors.white12,
      ),
      home: FutureBuilder<void>(
        future: _init,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const _Splash();
          }
          if (snap.hasError) {
            return _StartupError(
              error: snap.error!,
              onRetry: () => setState(() => _init = _start()),
              onContinue: () => setState(() => _init = Future.value()),
            );
          }
          return const HomeScreen();
        },
      ),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
}

class _StartupError extends StatelessWidget {
  const _StartupError({required this.error, required this.onRetry, required this.onContinue});

  final Object error;
  final VoidCallback onRetry;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Bolt could not start', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              const Text('Build $relayBuild'),
              const SizedBox(height: 12),
              SelectableText('$error'),
              const SizedBox(height: 24),
              FilledButton(onPressed: onRetry, child: const Text('Try again')),
              if (Services.settings.isLoaded) ...[
                const SizedBox(height: 8),
                OutlinedButton(onPressed: onContinue, child: const Text('Continue anyway')),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
