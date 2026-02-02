import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_map_geojson/flutter_map_geojson.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  late MapController _mapController;
  GeoJsonParser? _boundaryParser;
  GeoJsonParser? _roadsParser;
  Position? _currentPosition;
  bool _isLoading = true;
  String? _errorMessage;

  // Concession center coordinates (approximate center of the boundary)
  final LatLng _concessionCenter = const LatLng(-18.95, 23.7);
  final double _initialZoom = 10.0;

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    _loadMapData();
    _getCurrentLocation();
  }

  Future<void> _loadMapData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Load both boundary and roads data
      final responses = await Future.wait([
        http.get(
          Uri.parse('${const String.fromEnvironment('API_BASE_URL', defaultValue: 'https://wildlife-tracker-gxz5.vercel.app')}/api/map/boundary'),
          headers: {
            'x-api-key': const String.fromEnvironment('API_KEY', defaultValue: '98394a83034f3db48e5acd3ef54bd622c5748ca5bb4fb3ff39c052319711c9a9'),
          },
        ),
        http.get(
          Uri.parse('${const String.fromEnvironment('API_BASE_URL', defaultValue: 'https://wildlife-tracker-gxz5.vercel.app')}/api/map/roads'),
          headers: {
            'x-api-key': const String.fromEnvironment('API_KEY', defaultValue: '98394a83034f3db48e5acd3ef54bd622c5748ca5bb4fb3ff39c052319711c9a9'),
          },
        ),
      ]);

      // Check if both requests succeeded
      if (responses[0].statusCode == 200 && responses[1].statusCode == 200) {
        final boundaryData = jsonDecode(responses[0].body);
        final roadsData = jsonDecode(responses[1].body);

        // Initialize GeoJSON parsers
        _boundaryParser = GeoJsonParser(
          defaultPolygonFillColor: Colors.green.withOpacity(0.3),
          defaultPolygonBorderColor: Colors.green,
          defaultPolygonBorderWidth: 2.0,
        );

        _roadsParser = GeoJsonParser(
          defaultLineColor: Colors.blue,
          defaultLineWidth: 2.0,
        );

        // Parse the GeoJSON data
        await _boundaryParser!.parseGeoJson(boundaryData);
        await _roadsParser!.parseGeoJson(roadsData);

        setState(() {
          _isLoading = false;
        });
      } else {
        throw Exception('Failed to load map data: ${responses[0].statusCode}, ${responses[1].statusCode}');
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to load map data: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _getCurrentLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        return;
      }

      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      setState(() {
        _currentPosition = position;
      });

      // Center map on current location if within concession bounds
      if (_isWithinConcessionBounds(position.latitude, position.longitude)) {
        _mapController.move(LatLng(position.latitude, position.longitude), 13.0);
      }
    } catch (e) {
      print('Location error: $e');
    }
  }

  bool _isWithinConcessionBounds(double lat, double lon) {
    // Simple bounding box check for the concession area
    // Based on the GeoJSON coordinates, the concession is roughly between:
    // Lat: -18.73 to -19.18, Lon: 23.5 to 23.88
    return lat >= -19.2 && lat <= -18.7 && lon >= 23.5 && lon <= 23.9;
  }

  void _centerOnLocation() {
    if (_currentPosition != null) {
      _mapController.move(
        LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
        13.0,
      );
    }
  }

  void _centerOnConcession() {
    _mapController.move(_concessionCenter, _initialZoom);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Concession Map'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadMapData,
            tooltip: 'Refresh map data',
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              center: _concessionCenter,
              zoom: _initialZoom,
              minZoom: 8.0,
              maxZoom: 18.0,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.offline_mobile_app',
              ),
              // Add boundary polygons
              if (_boundaryParser != null)
                PolygonLayer(
                  polygons: _boundaryParser!.polygons,
                ),
              // Add roads polylines
              if (_roadsParser != null)
                PolylineLayer(
                  polylines: _roadsParser!.polylines,
                ),
              // Add current location marker
              if (_currentPosition != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
                      builder: (ctx) => Container(
                        decoration: BoxDecoration(
                          color: Colors.blue.withOpacity(0.8),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                        child: const Icon(
                          Icons.my_location,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
          // Loading indicator
          if (_isLoading)
            Container(
              color: Colors.black.withOpacity(0.5),
              child: const Center(
                child: CircularProgressIndicator(),
              ),
            ),
          // Error message
          if (_errorMessage != null)
            Container(
              color: Colors.black.withOpacity(0.8),
              padding: const EdgeInsets.all(16),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error, color: Colors.red, size: 48),
                    const SizedBox(height: 16),
                    Text(
                      _errorMessage!,
                      style: const TextStyle(color: Colors.white),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _loadMapData,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton(
            onPressed: _centerOnConcession,
            tooltip: 'Center on concession',
            child: const Icon(Icons.home),
          ),
          const SizedBox(height: 16),
          if (_currentPosition != null)
            FloatingActionButton(
              onPressed: _centerOnLocation,
              tooltip: 'Center on my location',
              child: const Icon(Icons.my_location),
            ),
        ],
      ),
    );
  }
}