import 'dart:convert';

import 'package:http/http.dart' as http;

/// Browser-like user agent. Twitch and Kick both treat obviously non-browser
/// clients with suspicion.
const browserUserAgent =
    'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36';

final httpClient = http.Client();

class ApiException implements Exception {
  final String message;
  final int? status;
  ApiException(this.message, {this.status});
  @override
  String toString() => message;
}

/// Decodes a JSON body, or throws an [ApiException] with a readable message.
dynamic decodeJson(http.Response res, String what) {
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw ApiException('$what failed (HTTP ${res.statusCode})',
        status: res.statusCode);
  }
  try {
    return jsonDecode(utf8.decode(res.bodyBytes));
  } catch (_) {
    throw ApiException('$what returned an unexpected response');
  }
}

/// Encodes form fields as application/x-www-form-urlencoded.
String formEncode(Map<String, String> fields) => fields.entries
    .map((e) =>
        '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
    .join('&');
