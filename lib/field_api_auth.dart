import 'package:flutter/foundation.dart' show kIsWeb;

import 'native_auth_service.dart';
import 'platform/browser_bridge.dart';

/// Field API auth helpers (Phase 1 dual auth).
///
/// Preferred: Firebase ID token → `Authorization: Bearer <token>`.
/// Migration fallback: optional shared `API_KEY` as `x-api-key`.
///
/// Logged-in clients do not need the API key for routes that accept Bearer.
/// Keep passing [apiKey] during migration so older server builds and key-only
/// fallbacks still work. Do not remove dart-define `API_KEY` yet.
///
/// UID / role / status for authorization must come from the verified Firebase
/// session on the server — never from request body fields.

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

/// Build headers: Bearer when signed in; optional API key as migration fallback.
Future<Map<String, String>> fieldApiHeaders({
  String apiKey = '',
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
  if (apiKey.isNotEmpty) {
    headers['x-api-key'] = apiKey;
  }
  return headers;
}

/// True if we can authenticate via Firebase session and/or API key fallback.
Future<bool> canAuthenticateFieldApi({String apiKey = ''}) async {
  final token = await firebaseIdToken();
  if (token != null && token.isNotEmpty) return true;
  if (kIsWeb) {
    final waited = await waitForFirebaseIdToken(
      timeout: const Duration(seconds: 8),
    );
    if (waited != null && waited.isNotEmpty) return true;
  }
  return apiKey.isNotEmpty;
}

/// Run an authenticated request; on HTTP 401, force-refresh the ID token once
/// and retry. Offline outbox callers should use this so expired tokens recover
/// without a full re-login when Firebase Auth can still refresh.
Future<T> withFieldAuthRetry<T>({
  String apiKey = '',
  required Future<T> Function(Map<String, String> headers) send,
  required int Function(T response) statusCode,
}) async {
  var headers = await fieldApiHeaders(apiKey: apiKey);
  var response = await send(headers);
  if (statusCode(response) == 401 && headers.containsKey('Authorization')) {
    headers = await fieldApiHeaders(apiKey: apiKey, forceRefreshToken: true);
    response = await send(headers);
  }
  return response;
}

({double lat, double lon})? readBrowserLocationBridge() {
  return browserReadLocationBridge();
}
