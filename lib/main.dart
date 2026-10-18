import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/models.dart';
import 'core/services.dart';
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

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF7C5CFF),
      brightness: Brightness.dark,
      surface: const Color(0xFF0E0E10),
    );
    return MaterialApp(
      title: 'Relay',
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
              Text('Relay could not start', style: Theme.of(context).textTheme.titleLarge),
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
