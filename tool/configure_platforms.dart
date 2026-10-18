// Applies the few native settings Duplex needs on top of the android/ and ios/
// folders that `flutter create` generates. Safe to run more than once.
//
//   flutter create --platforms=android,ios --org io.github.duplexapp --project-name duplex .
//   dart run tool/configure_platforms.dart
import 'dart:io';

const appName = 'Duplex';

void main() {
  _android();
  _ios();
  stdout.writeln('Platform configuration done.');
}

void _android() {
  final manifest = File('android/app/src/main/AndroidManifest.xml');
  if (!manifest.existsSync()) {
    stderr.writeln('android/ not found - run flutter create first.');
    return;
  }
  var s = manifest.readAsStringSync();
  if (!s.contains('android.permission.INTERNET')) {
    s = s.replaceFirst(
      '<application',
      '<uses-permission android:name="android.permission.INTERNET"/>\n    <application',
    );
  }
  s = s.replaceFirst(RegExp(r'android:label="[^"]*"'), 'android:label="$appName"');
  manifest.writeAsStringSync(s);
  stdout.writeln('Patched ${manifest.path}');

  // flutter_inappwebview needs minSdk 19+, video_player 21+; Flutter's default
  // is already higher, but older templates hard-code a lower number.
  for (final name in ['android/app/build.gradle.kts', 'android/app/build.gradle']) {
    final gradle = File(name);
    if (!gradle.existsSync()) continue;
    var g = gradle.readAsStringSync();
    g = g.replaceAllMapped(RegExp(r'minSdk(Version)?\s*=?\s*(\d+)'), (m) {
      final v = int.parse(m.group(2)!);
      return v < 24 ? m.group(0)!.replaceFirst(m.group(2)!, '24') : m.group(0)!;
    });
    gradle.writeAsStringSync(g);
  }
}

void _ios() {
  final plist = File('ios/Runner/Info.plist');
  if (!plist.existsSync()) {
    stderr.writeln('ios/ not found - run flutter create first.');
    return;
  }
  var s = plist.readAsStringSync();
  s = s.replaceFirstMapped(
    RegExp(r'(<key>CFBundleDisplayName</key>\s*<string>)[^<]*(</string>)'),
    (m) => '${m.group(1)}$appName${m.group(2)}',
  );
  plist.writeAsStringSync(s);
  stdout.writeln('Patched ${plist.path}');
}
