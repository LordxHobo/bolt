// Applies the few native settings Relay needs on top of the android/ and ios/
// folders that `flutter create` generates. Safe to run more than once.
//
//   flutter create --platforms=android,ios --org io.github.relayapp --project-name relay .
//   dart run tool/configure_platforms.dart
import 'dart:io';

const appName = 'Relay';

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
  // The player streams from Relay's own relay at http://127.0.0.1, which
  // Android blocks by default (no HTTPS on the phone's loopback).
  if (!s.contains('usesCleartextTraffic')) {
    s = s.replaceFirst('<application', '<application\n        android:usesCleartextTraffic="true"');
  }
  // Use the older Skia renderer on Android. Impeller (the default) shows a
  // blank screen on some emulators such as BlueStacks. Ignored if unsupported.
  if (!s.contains('EnableImpeller')) {
    s = s.replaceFirstMapped(
      RegExp(r'<application[^>]*>'),
      (m) => '${m.group(0)}\n        <meta-data android:name="io.flutter.embedding.android.EnableImpeller" android:value="false" />',
    );
  }
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
    // Make sure the release build reads proguard-rules.pro (written below).
    // Flutter usually adds it already; listing it twice is harmless.
    if (!g.contains('proguard-rules.pro')) {
      final kts = name.endsWith('.kts');
      g = g.replaceFirstMapped(
        RegExp(r'signingConfig\s*=?\s*signingConfigs\.getByName\("debug"\)'),
        (m) => kts
            ? '${m.group(0)}\n            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")'
            : "${m.group(0)}\n            proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), 'proguard-rules.pro'",
      );
    }
    gradle.writeAsStringSync(g);
  }

  // R8 (the release-build optimizer) has broken plugin code at runtime, e.g.
  // "NoSuchMethodError ... SharedPreferencesApiRegistrar.getAll". Keep plugin
  // classes as they are and skip the optimization pass; the size cost is small.
  final rules = File('android/app/proguard-rules.pro');
  const relayRules = '''
# --- Relay ---
-dontoptimize
-keep class io.flutter.plugins.** { *; }
-keep class dev.flutter.pigeon.** { *; }
-keep class com.pichillilorenzo.** { *; }
-keep class com.it_nomads.fluttersecurestorage.** { *; }
-keep class dev.fluttercommunity.plus.** { *; }
''';
  final existing = rules.existsSync() ? rules.readAsStringSync() : '';
  if (!existing.contains('# --- Relay ---')) {
    rules.writeAsStringSync('$existing\n$relayRules');
    stdout.writeln('Wrote ${rules.path}');
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
  // Allow the video player to load from Relay's local relay (http://127.0.0.1).
  if (!s.contains('NSAppTransportSecurity')) {
    s = s.replaceFirst(
      RegExp(r'</dict>\s*</plist>\s*$'),
      '\t<key>NSAppTransportSecurity</key>\n'
      '\t<dict>\n'
      '\t\t<key>NSAllowsLocalNetworking</key>\n'
      '\t\t<true/>\n'
      '\t\t<key>NSAllowsArbitraryLoadsForMedia</key>\n'
      '\t\t<true/>\n'
      '\t</dict>\n'
      '</dict>\n</plist>\n',
    );
  }
  // Keep playing (and allow picture-in-picture) when Relay is in the
  // background.
  if (!s.contains('UIBackgroundModes')) {
    s = s.replaceFirst(
      RegExp(r'</dict>\s*</plist>\s*$'),
      '\t<key>UIBackgroundModes</key>\n'
      '\t<array>\n'
      '\t\t<string>audio</string>\n'
      '\t</array>\n'
      '</dict>\n</plist>\n',
    );
  }
  plist.writeAsStringSync(s);
  stdout.writeln('Patched ${plist.path}');

  // The Amazon IVS player needs iOS 14. CocoaPods takes the app's minimum
  // iOS version from the Xcode project when the Podfile doesn't set one.
  final project = File('ios/Runner.xcodeproj/project.pbxproj');
  if (project.existsSync()) {
    final p = project.readAsStringSync().replaceAllMapped(
      RegExp(r'IPHONEOS_DEPLOYMENT_TARGET = (\d+)\.(\d+);'),
      (m) => int.parse(m.group(1)!) < 14 ? 'IPHONEOS_DEPLOYMENT_TARGET = 14.0;' : m.group(0)!,
    );
    project.writeAsStringSync(p);
    stdout.writeln('Patched ${project.path} (iOS 14 minimum)');
  }
}
