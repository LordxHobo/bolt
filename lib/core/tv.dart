import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

import 'services.dart';

/// Whether Bolt shows its TV layout (Fire TV, Android TV): picked
/// automatically, or forced on/off in Settings → Home.
class TvMode {
  TvMode._();

  /// Use the TV layout. Set once at startup.
  static bool isTv = false;

  /// What automatic detection found.
  static bool detected = false;

  static Future<void> init() async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final info = await DeviceInfoPlugin().androidInfo;
        final features = info.systemFeatures;
        detected = features.contains('android.software.leanback') ||
            features.contains('amazon.hardware.fire_tv') ||
            info.model.toUpperCase().startsWith('AFT'); // Fire TV models: AFTMM, AFTKA...
      }
    } catch (e) {
      debugPrint('TV detection failed: $e');
    }
    isTv = switch (Services.settings.tvLayout) {
      'on' => true,
      'off' => false,
      _ => detected,
    };
  }
}
