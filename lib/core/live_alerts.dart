import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'net.dart';
import 'services.dart';

/// Keeps the live-alerts checker (server/live-alerts) up to date with the
/// streamers you want alerts for. Sends the list whenever it changes.
class LiveAlerts {
  LiveAlerts._();

  static final status = ValueNotifier<String?>(null);
  static Timer? _debounce;
  static bool _started = false;

  static const _sentKey = 'alertsLastSent';

  static void start() {
    if (_started) return;
    _started = true;
    Services.settings.addListener(_schedule);
    _schedule();
  }

  static void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), () => sync());
  }

  static bool get isSetUp => Services.settings.alertsServer.isNotEmpty;

  static String _body() => jsonEncode({
        'channels': [for (final c in Services.settings.alertChannels) c.toJson()],
      });

  /// Sends the list to the checker if it changed (or always, with [force]).
  /// Returns an error message, or null when it worked.
  static Future<String?> sync({bool force = false}) async {
    final s = Services.settings;
    if (s.alertsServer.isEmpty) return 'Add your checker address first.';
    final body = _body();
    final sentFor = '${s.alertsServer}|${s.alertsTopic}|$body';
    if (!force && s.prefs.getString(_sentKey) == sentFor) return null;
    try {
      final res = await httpClient
          .put(Uri.parse('${s.alertsServer}/config/${s.alertsTopic}'),
              headers: {'Content-Type': 'application/json'}, body: body)
          .timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw ApiException('the checker answered HTTP ${res.statusCode}: ${_short(res.body)}');
      }
      await s.prefs.setString(_sentKey, sentFor);
      status.value = null;
      return null;
    } catch (e) {
      final message = "Couldn't update live alerts: $e";
      debugPrint(message);
      status.value = message;
      return message;
    }
  }

  /// Asks the checker to send a test notification.
  static Future<String?> sendTest() async {
    final s = Services.settings;
    if (s.alertsServer.isEmpty) return 'Add your checker address first.';
    final error = await sync(force: true);
    if (error != null) return error;
    try {
      final res = await httpClient
          .post(Uri.parse('${s.alertsServer}/test/${s.alertsTopic}'))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        return 'The checker answered HTTP ${res.statusCode}: ${_short(res.body)}';
      }
      return null;
    } catch (e) {
      return "Couldn't reach the checker: $e";
    }
  }

  static String _short(String s) => s.length > 200 ? '${s.substring(0, 200)}…' : s;
}
