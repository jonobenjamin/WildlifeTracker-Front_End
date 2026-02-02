# Wildlife Tracker Frontend

A Flutter mobile application for wildlife tracking with offline capabilities and interactive maps.

## Features

- **Offline Data Collection**: Submit wildlife sightings, incidents, and maintenance reports
- **GPS Integration**: Automatic location tracking for mobile devices
- **Interactive Maps**: View concession boundaries and road networks
- **Real-time Location**: Show current position on the map
- **Data Synchronization**: Sync offline data to backend when online

## Setup Instructions

### 1. Clone and Install Dependencies

```bash
git clone https://github.com/jonobenjamin/WildlifeTracker-Front_End.git
cd WildlifeTracker-Front_End
flutter pub get
```

### 2. Configure API URLs

Update the API configuration in `lib/main.dart`:

```dart
// Replace with your actual Vercel backend URL
const String API_BASE_URL = 'https://your-backend-name.vercel.app';
const String API_KEY = 'your-api-key-from-backend';
```

### 3. Run the App

```bash
flutter run
```

## Building for Production

### Web Deployment
```bash
flutter build web --release
# Deploy the build/web folder to any static hosting service
```

### Mobile Deployment
```bash
# For Android
flutter build apk --release

# For iOS
flutter build ios --release
```

## API Endpoints

The app communicates with a backend API that provides:

- `GET /api/map/boundary` - Concession boundary GeoJSON
- `GET /api/map/roads` - Road network GeoJSON
- `POST /api/observations` - Submit wildlife observations

## Environment Variables

For production builds, you can set environment variables:

```bash
flutter run --dart-define=API_BASE_URL=https://your-backend.vercel.app --dart-define=API_KEY=your-api-key
```

## Project Structure

```
lib/
├── main.dart          # Main app entry point
└── map_screen.dart    # Interactive map screen

android/               # Android platform files
ios/                   # iOS platform files
web/                   # Web platform files
linux/                 # Linux platform files
macos/                 # macOS platform files
windows/               # Windows platform files
```

## Dependencies

- `flutter_map`: Interactive maps
- `geolocator`: GPS location services
- `hive`: Local offline storage
- `http`: API communication

## License

This project is part of the Wildlife Tracker system.