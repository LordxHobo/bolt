import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/services.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    final text = await rootBundle.loadString('assets/adblock/LICENSE-TwitchAdSolutions.txt');
    yield LicenseEntryWithLineBreaks(const ['TwitchAdSolutions (vaft, video-swap-new)'], text);
  });
  await Services.init();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  runApp(const RelayApp());
}

class RelayApp extends StatelessWidget {
  const RelayApp({super.key});

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
      home: const HomeScreen(),
    );
  }
}
