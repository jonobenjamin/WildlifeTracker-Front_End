import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;

import 'tree_service.dart';
import 'road_service.dart';
import 'tracking_service.dart';
import 'field_api_auth.dart';
import 'platform/browser_bridge.dart';
import 'recent_sightings_service.dart';

/// Persistent local storage for offline-first PWA use (Hive → IndexedDB on web).
class LocalStorageService {
  static const String offlineBoxName = 'offlineData';
  static const String userBoxName = 'userData';
  static const String mapCacheBoxName = 'mapCache';

  static const List<String> mapAssetKeys = [
    'Consession_boundary.geojson',
    'KPR_roads.geojson',
    'Camps.geojson',
  ];

  static Box get offlineBox => Hive.box(offlineBoxName);
  static Box get userBox => Hive.box(userBoxName);
  static Box get mapCacheBox => Hive.box(mapCacheBoxName);

  static Future<void> init() async {
    await Hive.initFlutter();
    await Hive.openBox(offlineBoxName);
    await Hive.openBox(userBoxName);
    await Hive.openBox(mapCacheBoxName);
    await TreeService.openBox();
    await RoadService.openBox();
    await RecentSightingsService.openBox();
    await TrackingService.instance.init();

    if (kIsWeb) {
      await _requestPersistentStorage();
      // Sync is manual only — user presses "Sync data" in the Outbox.
    }

    // Warm map asset cache from bundled assets on every launch.
    await warmMapAssetCache();
  }

  static Future<void> _requestPersistentStorage() async {
    await browserRequestPersistentStorage();
  }

  static String newLocalId() {
    return '${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(99999)}';
  }

  /// Save any observation/tracking record locally first (offline-first).
  static Future<String> saveRecord(Map<String, dynamic> data) async {
    final id = (data['localId'] as String?)?.isNotEmpty == true
        ? data['localId'] as String
        : newLocalId();
    final record = Map<String, dynamic>.from(data);
    record['localId'] = id;
    record['synced'] = record['synced'] == true;
    record['savedAt'] = record['savedAt'] ?? DateTime.now().toIso8601String();
    await offlineBox.put(id, record);
    return id;
  }

  static List<Map<String, dynamic>> getAllRecords() {
    return offlineBox.values
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  static List<Map<String, dynamic>> getRecentSightings({int limit = 10}) {
    final sightings = getAllRecords()
        .where((r) => r['category'] == 'Sighting')
        .toList();
    sightings.sort((a, b) {
      final ta = a['timestamp']?.toString() ?? a['savedAt']?.toString() ?? '';
      final tb = b['timestamp']?.toString() ?? b['savedAt']?.toString() ?? '';
      return tb.compareTo(ta);
    });
    if (sightings.length <= limit) return sightings;
    return sightings.sublist(0, limit);
  }

  static int get unsyncedCount =>
      getAllRecords().where((r) => r['synced'] != true).length;

  static String getCurrentUserName() {
    try {
      final name = browserGetItem('authenticatedUserName');
      if (name != null && name.isNotEmpty) return name;
    } catch (_) {}
    return userBox.get('selectedUser')?.toString() ?? 'Unknown User';
  }

  /// Copy bundled GeoJSON into Hive so map layers survive iOS hard-close.
  static Future<void> warmMapAssetCache() async {
    for (final assetKey in mapAssetKeys) {
      try {
        if (mapCacheBox.get(assetKey) != null) continue;
        final raw = await rootBundle.loadString('assets/$assetKey');
        await mapCacheBox.put(assetKey, raw);
      } catch (e) {
        debugPrint('Map cache warm failed for $assetKey: $e');
      }
    }
  }

  static Future<String?> loadMapAsset(String assetKey) async {
    final cached = mapCacheBox.get(assetKey);
    if (cached is String && cached.isNotEmpty) return cached;

    try {
      final raw = await rootBundle.loadString('assets/$assetKey');
      await mapCacheBox.put(assetKey, raw);
      return raw;
    } catch (e) {
      debugPrint('Map asset load failed for $assetKey: $e');
      return null;
    }
  }

  static Future<Map<String, dynamic>?> loadMapJson(String assetKey) async {
    final raw = await loadMapAsset(assetKey);
    if (raw == null) return null;
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  static bool get isOnline => browserIsOnline();


  /// Manual sync — called only from the Outbox "Sync data" button.
  /// Returns a report of what actually uploaded (do NOT treat as always-success).
  static Future<SyncReport> syncEverything({
    required String apiBaseUrl,
    required String apiKey,
  }) async {
    if (!isOnline) {
      return const SyncReport(
        succeeded: 0,
        failed: 0,
        remaining: 0,
        sampleError: 'Offline',
      );
    }
    if (!await canAuthenticateFieldApi(apiKey: apiKey)) {
      return const SyncReport(
        succeeded: 0,
        failed: 0,
        remaining: 0,
        sampleError: 'Not signed in — refresh and log in again',
      );
    }

    final obs = await syncAll(apiBaseUrl: apiBaseUrl, apiKey: apiKey);
    final trees = await TreeService.syncTrees(
      apiBaseUrl: apiBaseUrl,
      apiKey: apiKey,
    );
    final roads = await RoadService.syncRoads(
      apiBaseUrl: apiBaseUrl,
      apiKey: apiKey,
    );

    final remaining =
        unsyncedCount + TreeService.unsyncedCount + RoadService.unsyncedCount;
    return SyncReport(
      succeeded: obs.succeeded + trees.succeeded + roads.succeeded,
      failed: obs.failed + trees.failed + roads.failed,
      remaining: remaining,
      sampleError: obs.sampleError ?? trees.sampleError ?? roads.sampleError,
    );
  }

  /// @deprecated Use [syncEverything] from the Outbox only.
  static Future<bool> trySyncIfOnline({
    String apiBaseUrl = const String.fromEnvironment(
      'API_BASE_URL',
      defaultValue: 'https://khwaiprivate.okavangowater.com',
    ),
    String apiKey = const String.fromEnvironment('API_KEY'),
  }) async {
    final report = await syncEverything(
      apiBaseUrl: apiBaseUrl,
      apiKey: apiKey,
    );
    return report.allOk;
  }

  /// Upload unsynced records; keep local copies and mark synced (do NOT delete).
  static Future<SyncReport> syncAll({
    required String apiBaseUrl,
    required String apiKey,
  }) async {
    if (!await canAuthenticateFieldApi(apiKey: apiKey)) {
      return const SyncReport(
        succeeded: 0,
        failed: 0,
        remaining: 0,
        sampleError: 'Not signed in — refresh and log in again',
      );
    }

    final unsyncedKeys = offlineBox.keys.where((key) {
      final item = offlineBox.get(key);
      if (item is! Map) return false;
      return item['synced'] != true;
    }).toList();

    if (unsyncedKeys.isEmpty) {
      return const SyncReport(succeeded: 0, failed: 0, remaining: 0);
    }

    var succeeded = 0;
    var failed = 0;
    String? sampleError;
    var headers = await fieldApiHeaders(apiKey: apiKey);

    for (final key in unsyncedKeys) {
      final raw = offlineBox.get(key);
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);

      try {
        var result = await _uploadItem(
          item: item,
          apiBaseUrl: apiBaseUrl,
          headers: headers,
        );
        // Expired Firebase ID token — refresh once and retry this item.
        if (!result.ok &&
            (result.error?.contains('HTTP 401') ?? false) &&
            headers.containsKey('Authorization')) {
          headers = await fieldApiHeaders(apiKey: apiKey, forceRefreshToken: true);
          result = await _uploadItem(
            item: item,
            apiBaseUrl: apiBaseUrl,
            headers: headers,
          );
        }
        if (result.ok) {
          item['synced'] = true;
          item['syncedAt'] = DateTime.now().toIso8601String();
          await offlineBox.put(key, item);
          succeeded++;
        } else {
          failed++;
          sampleError ??= result.error;
          debugPrint('Sync failed for $key: ${result.error}');
        }
      } catch (e) {
        failed++;
        sampleError ??= e.toString();
        debugPrint('Sync failed for $key: $e');
      }
    }

    final remaining = offlineBox.keys.where((key) {
      final item = offlineBox.get(key);
      return item is Map && item['synced'] != true;
    }).length;

    return SyncReport(
      succeeded: succeeded,
      failed: failed,
      remaining: remaining,
      sampleError: sampleError,
    );
  }

  static Future<_UploadResult> _uploadItem({
    required Map<String, dynamic> item,
    required String apiBaseUrl,
    required Map<String, String> headers,
  }) async {
    if (item['category'] == 'Tracking') {
      final trackingType = (item['trackingType'] ?? 'patrol').toString().toLowerCase();
      final trackingData = {
        'startTime': item['startTime'],
        'endTime': item['endTime'],
        'trackingType': trackingType,
        'vehicle': item['vehicle'],
        'user': item['user'] ?? 'Unknown User',
        'totalTimeSeconds': item['totalTimeSeconds'],
        'distanceMeters': item['distanceMeters'],
        'geoJson': item['geoJson'],
      };
      final response = await http
          .post(
            Uri.parse('$apiBaseUrl/api/tracking'),
            headers: headers,
            body: jsonEncode(trackingData),
          )
          .timeout(const Duration(seconds: 15));
      return _uploadResultFromResponse(response, label: 'tracking');
    }

    final uploadData = <String, dynamic>{
      'category': item['category'],
      'timestamp': item['timestamp'] ?? DateTime.now().toIso8601String(),
      'user': item['user'] ?? 'Unknown User',
    };

    if (item['category'] == 'Sighting') {
      uploadData['animal'] = item['animal'];
      if (item['vulture_species'] != null) uploadData['vulture_species'] = item['vulture_species'];
      if (item['pride'] != null) uploadData['pride'] = item['pride'];
      if (item['leopard'] != null) uploadData['leopard'] = item['leopard'];
      if (item['activity'] != null) uploadData['activity'] = item['activity'];
      if (item['age'] != null) uploadData['age'] = item['age'];
      if (item['vulture_tagged'] != null) uploadData['vulture_tagged'] = item['vulture_tagged'];
      if (item['species_count'] != null) uploadData['species_count'] = item['species_count'];
    } else if (item['category'] == 'Incident') {
      uploadData['incident_type'] = item['incident_type'];
      if (item['poaching_type'] != null) uploadData['poaching_type'] = item['poaching_type'];
      if (item['poached_animal'] != null) uploadData['poached_animal'] = item['poached_animal'];
      if (item['poaching_image'] != null) {
        uploadData['poaching_image'] = item['poaching_image'];
        uploadData['poaching_image_name'] = item['poaching_image_name'];
      }
    }

    if (item['latitude'] != null && item['longitude'] != null) {
      uploadData['latitude'] = item['latitude'];
      uploadData['longitude'] = item['longitude'];
    }

    final response = await http
        .post(
          Uri.parse('$apiBaseUrl/api/observations'),
          headers: headers,
          body: jsonEncode(uploadData),
        )
        .timeout(const Duration(seconds: 45));

    return _uploadResultFromResponse(response, label: 'observation');
  }
}

class SyncReport {
  final int succeeded;
  final int failed;
  final int remaining;
  final String? sampleError;

  const SyncReport({
    required this.succeeded,
    required this.failed,
    required this.remaining,
    this.sampleError,
  });

  bool get allOk => failed == 0 && remaining == 0;

  String get message {
    if (sampleError == 'Offline') {
      return 'You\'re offline — connect to WiFi, then tap Sync data';
    }
    if (sampleError == 'API key not configured' ||
        sampleError == 'Not signed in — refresh and log in again') {
      return sampleError!;
    }
    if (allOk) {
      if (succeeded == 0) return 'Nothing to sync';
      return 'All records synced to server';
    }
    if (succeeded > 0) {
      return 'Synced $succeeded, $remaining still pending'
          '${sampleError != null ? ' ($sampleError)' : ''}';
    }
    return 'Sync failed — $remaining still pending'
        '${sampleError != null ? ': $sampleError' : ''}';
  }
}

class _UploadResult {
  final bool ok;
  final String? error;
  const _UploadResult({required this.ok, this.error});
}

_UploadResult _uploadResultFromResponse(
  http.Response response, {
  required String label,
}) {
  if (response.statusCode == 200 || response.statusCode == 201) {
    return const _UploadResult(ok: true);
  }

  String detail = 'HTTP ${response.statusCode}';
  try {
    final body = jsonDecode(response.body);
    if (body is Map) {
      final err = body['error'] ?? body['message'];
      if (err != null) detail = '$detail: $err';
    }
  } catch (_) {
    if (response.body.isNotEmpty) {
      detail = '$detail: ${response.body.length > 120 ? response.body.substring(0, 120) : response.body}';
    }
  }

  if (response.statusCode == 401) {
    detail = 'Unauthorized (API key rejected)';
  }

  debugPrint('Upload $label failed: $detail');
  return _UploadResult(ok: false, error: detail);
}
