/// Field API auth helpers — Firebase ID token required (`Authorization: Bearer`).
///
/// UID / role / status for authorization must come from the verified Firebase
/// session on the server — never from request body fields.

import 'package:flutter/foundation.dart' show kIsWeb;

import 'native_auth_service.dart';
import 'platform/browser_bridge.dart';

/// Firebase ID token — live JS auth on web, Firebase Auth on native APK/iOS.
Future<String?> firebaseIdToken({bool forceRefresh = false}) async {
  if (!kIsWeb) {
    return NativeAuthService.instance.getIdToken(forceRefresh: forceRefresh);
  }

  final live = await browserFirebaseIdToken(forceRefresh: forceRefresh);
  if (live != null && live.isNotEmpty) return live;

  final stored = browserGetItem('firebaseIdToken');
  if (stored == null || stored.isEmpty) return null;

  final at = int.tryParse(browserGetItem('firebaseIdTokenAt') ?? '') ?? 0;
  final ageMs = DateTime.now().millisecondsSinceEpoch - at;
  if (at == 0 || ageMs < 50 * 60 * 1000) return stored;
  return null;
}

Future<String?> waitForFirebaseIdToken({
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final token = await firebaseIdToken();
    if (token != null && token.isNotEmpty) return token;
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  return firebaseIdToken(forceRefresh: true);
}

Future<Map<String, String>> fieldApiHeaders({
  bool forceRefreshToken = false,
}) async {
  final headers = <String, String>{
    'Content-Type': 'application/json',
  };
  final token = forceRefreshToken
      ? await firebaseIdToken(forceRefresh: true)
      : await firebaseIdToken();
  if (token != null && token.isNotEmpty) {
    headers['Authorization'] = 'Bearer $token';
  }
  return headers;
}

Future<bool> canAuthenticateFieldApi() async {
  final token = await firebaseIdToken();
  if (token != null && token.isNotEmpty) return true;
  if (kIsWeb) {
    final waited = await waitForFirebaseIdToken(
      timeout: const Duration(seconds: 8),
    );
    if (waited != null && waited.isNotEmpty) return true;
  }
  return false;
}

Future<T> withFieldAuthRetry<T>({
  required Future<T> Function(Map<String, String> headers) send,
  required int Function(T response) statusCode,
}) async {
  var headers = await fieldApiHeaders();
  var response = await send(headers);
  if (statusCode(response) == 401 && headers.containsKey('Authorization')) {
    headers = await fieldApiHeaders(forceRefreshToken: true);
    response = await send(headers);
  }
  return response;
}

({double lat, double lon})? readBrowserLocationBridge() {
  return browserReadLocationBridge();
}
