import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:geolocator/geolocator.dart'; // For GPS
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'map_screen.dart';

// API Configuration - Replace with your Vercel backend URL
const String API_BASE_URL = String.fromEnvironment('API_BASE_URL', defaultValue: 'https://your-backend.vercel.app');
const String API_KEY = String.fromEnvironment('API_KEY', defaultValue: 'your-api-key-here');

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Hive.initFlutter(); // Initialize Hive
  await Hive.openBox('offlineData'); // Open offline storage box

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Offline Mobile App',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const MyHomePage(title: 'Offline Form App'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final TextEditingController _maintenanceController = TextEditingController();
  final TextEditingController _latitudeController = TextEditingController();
  final TextEditingController _longitudeController = TextEditingController();

  String? _selectedCategory;
  String? _selectedAnimal;
  String? _selectedIncident;

  final List<String> _categories = ['Sighting', 'Incident', 'Maintenance'];
  final List<String> _animals = [
    'Lion', 'Leopard', 'Cheetah', 'Pangolin', 'Wild Dog', 'Aardwolf',
    'Aardvark', 'Rhino', 'African Wild Cat', 'Brown Hyena', 'Pel\'s Fishing Owl',
    'Spotted-necked Otter', 'Cape Clawless Otter'
  ];
  final List<String> _incidents = ['Poaching', 'Litter'];

  final Box box = Hive.box('offlineData');

  // Submit data offline with GPS
  Future<void> _submitData() async {
    if (_selectedCategory == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a category')),
      );
      return;
    }

    // Validate based on category
    if (_selectedCategory == 'Sighting' && _selectedAnimal == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select an animal')),
      );
      return;
    }

    if (_selectedCategory == 'Incident' && _selectedIncident == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select type of incident')),
      );
      return;
    }

    if (_selectedCategory == 'Maintenance' && _maintenanceController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter type of maintenance')),
      );
      return;
    }

    // Get GPS position - web allows manual input, mobile uses device GPS
    double? latitude;
    double? longitude;

    if (kIsWeb) {
      // Web: use manual input
      if (_latitudeController.text.isNotEmpty && _longitudeController.text.isNotEmpty) {
        try {
          latitude = double.parse(_latitudeController.text);
          longitude = double.parse(_longitudeController.text);
        } catch (e) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Invalid latitude or longitude format')),
          );
          return;
        }
      }
    } else {
      // Mobile: get current position
      try {
        bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
        if (!serviceEnabled) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Location services are disabled. Please enable GPS.')),
          );
          return;
        }

        LocationPermission permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
          if (permission == LocationPermission.denied) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Location permissions are required for GPS tracking.')),
            );
            return;
          }
        }

        if (permission == LocationPermission.deniedForever) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Location permissions are permanently denied. Please enable in app settings.')),
          );
          return;
        }

        Position position = await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.high);
        latitude = position.latitude;
        longitude = position.longitude;
        print('GPS position obtained: $latitude, $longitude');
      } catch (e) {
        print('Location error: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('GPS error: $e')),
        );
        return;
      }
    }

    // Create data object based on category
    Map<String, dynamic> data = {
      'category': _selectedCategory,
      'timestamp': DateTime.now().toIso8601String(),
      'synced': false,
      'latitude': latitude,
      'longitude': longitude,
    };

    if (_selectedCategory == 'Sighting') {
      data['animal'] = _selectedAnimal;
    } else if (_selectedCategory == 'Incident') {
      data['incident_type'] = _selectedIncident;
    } else if (_selectedCategory == 'Maintenance') {
      data['maintenance_type'] = _maintenanceController.text;
    }

    box.add(data);

    // Clear form
    _maintenanceController.clear();
    _latitudeController.clear();
    _longitudeController.clear();

    setState(() {
      _selectedCategory = null;
      _selectedAnimal = null;
      _selectedIncident = null;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Data submitted successfully')),
    );
  }


  // Sync offline data to API
  Future<bool> syncOfflineData() async {
    try {
      print('Starting sync process...');

      final unsyncedItems =
          box.values.where((item) => item['synced'] == false).toList();

      print('Found ${unsyncedItems.length} unsynced items');

      if (unsyncedItems.isEmpty) {
        print('No unsynced items to upload');
        return true; // Nothing to sync, but that's success
      }

      // Store keys of successfully synced items to delete them later
      List<int> syncedKeys = [];

      for (var item in unsyncedItems) {
        print('Uploading item: ${item['category']}');
        try {
          // Create the data to upload based on the structure
          Map<String, dynamic> uploadData = {
            'category': item['category'],
            'timestamp': item['timestamp'] ?? DateTime.now().toIso8601String(),
          };

          // Add category-specific data
          if (item['category'] == 'Sighting') {
            uploadData['animal'] = item['animal'];
          } else if (item['category'] == 'Incident') {
            uploadData['incident_type'] = item['incident_type'];
          } else if (item['category'] == 'Maintenance') {
            uploadData['maintenance_type'] = item['maintenance_type'];
          }

          // Add GPS if available
          if (item['latitude'] != null && item['longitude'] != null) {
            uploadData['latitude'] = item['latitude'];
            uploadData['longitude'] = item['longitude'];
          }

          // Make HTTP POST request to API
          print('Making request to: $API_BASE_URL/api/observations');
          print('Using API key: $API_KEY');
          print('Sending data: $uploadData');

          final response = await http.post(
            Uri.parse('$API_BASE_URL/api/observations'),
            headers: {
              'Content-Type': 'application/json',
              'x-api-key': API_KEY,
            },
            body: jsonEncode(uploadData),
          ).timeout(const Duration(seconds: 10));

          print('Response status: ${response.statusCode}');
          print('Response body: ${response.body}');

          if (response.statusCode == 201) {
            final responseData = jsonDecode(response.body);
            print('API upload successful with ID: ${responseData['data']['id']}');

            // Mark this item as successfully synced
            syncedKeys.add(box.keys.toList()[box.values.toList().indexOf(item)]);
          } else {
            print('API upload failed with status: ${response.statusCode}');
            print('Response: ${response.body}');
            throw Exception('API returned ${response.statusCode}: ${response.body}');
          }

        } catch (uploadError) {
          print('Upload failed for item ${item['category']}: $uploadError');
          throw uploadError; // Re-throw to be caught by outer catch
        }
      }

      // Delete synced items from local storage
      for (var key in syncedKeys) {
        await box.delete(key);
        print('Deleted synced item with key: $key');
      }

      setState(() {});
      print('Sync completed successfully');
      return true;
    } catch (e) {
      print('Failed to sync: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Sync failed: $e'),
        ),
      );
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.map),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const MapScreen()),
              );
            },
            tooltip: 'View Map',
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Category dropdown
            DropdownButton<String>(
              value: _selectedCategory,
              hint: const Text('Select category'),
              isExpanded: true,
              items: _categories
                  .map((category) => DropdownMenuItem(
                        value: category,
                        child: Text(category),
                      ))
                  .toList(),
              onChanged: (value) {
                setState(() {
                  _selectedCategory = value;
                  // Reset dependent fields when category changes
                  _selectedAnimal = null;
                  _selectedIncident = null;
                  _maintenanceController.clear();
                });
              },
            ),
            const SizedBox(height: 16),

            // Conditional UI based on category
            if (_selectedCategory == 'Sighting') ...[
              DropdownButton<String>(
                value: _selectedAnimal,
                hint: const Text('Select animal'),
                isExpanded: true,
                items: _animals
                    .map((animal) => DropdownMenuItem(
                          value: animal,
                          child: Text(animal),
                        ))
                    .toList(),
                onChanged: (value) {
                  setState(() {
                    _selectedAnimal = value;
                  });
                },
              ),
            ] else if (_selectedCategory == 'Incident') ...[
              DropdownButton<String>(
                value: _selectedIncident,
                hint: const Text('Type of incident'),
                isExpanded: true,
                items: _incidents
                    .map((incident) => DropdownMenuItem(
                          value: incident,
                          child: Text(incident),
                        ))
                    .toList(),
                onChanged: (value) {
                  setState(() {
                    _selectedIncident = value;
                  });
                },
              ),
            ] else if (_selectedCategory == 'Maintenance') ...[
              TextField(
                controller: _maintenanceController,
                decoration: const InputDecoration(labelText: 'Type of maintenance'),
              ),
            ],

            const SizedBox(height: 16),

            // GPS section - manual input for web, auto for mobile
            if (kIsWeb) ...[
              const Text('GPS Location (optional)', style: TextStyle(fontWeight: FontWeight.bold)),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _latitudeController,
                      decoration: const InputDecoration(labelText: 'Latitude'),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: TextField(
                      controller: _longitudeController,
                      decoration: const InputDecoration(labelText: 'Longitude'),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],

            ElevatedButton(
              onPressed: _submitData,
              child: const Text('Submit'),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () async {
                print('Sync button pressed!');
                bool success = await syncOfflineData();
                print('Sync function returned: $success');
                if (success) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Offline data synced!')),
                  );
                }
              },
              child: const Text('Sync Offline Data'),
            ),
            const SizedBox(height: 16),
            const Text('Saved offline:'),
            Expanded(
              child: ValueListenableBuilder(
                valueListenable: box.listenable(),
                builder: (context, Box box, _) {
                  if (box.isEmpty) return const Text('No data yet');
                  return ListView.builder(
                    itemCount: box.length,
                    itemBuilder: (context, index) {
                      final item = box.getAt(index);

                      // Build title and subtitle based on category
                      String title = item['category'] ?? 'Unknown';
                      String subtitle = '';

                      if (item['category'] == 'Sighting') {
                        subtitle = item['animal'] ?? 'Unknown animal';
                      } else if (item['category'] == 'Incident') {
                        subtitle = item['incident_type'] ?? 'Unknown incident';
                      } else if (item['category'] == 'Maintenance') {
                        subtitle = item['maintenance_type'] ?? 'Unknown maintenance';
                      }

                      // Add GPS info if available
                      if (item['latitude'] != null && item['longitude'] != null) {
                        subtitle += ' (${item['latitude']?.toStringAsFixed(4)}, ${item['longitude']?.toStringAsFixed(4)})';
                      }

                      // Show sync status
                      final synced = item['synced'] == true;
                      final trailing = synced
                          ? const Icon(Icons.cloud_done, color: Colors.green)
                          : const Icon(Icons.cloud_upload, color: Colors.grey);

                      return ListTile(
                        title: Text(title),
                        subtitle: Text(subtitle),
                        trailing: trailing,
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
