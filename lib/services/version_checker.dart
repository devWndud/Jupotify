import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

class VersionInfo {
  final String currentVersion;
  final String latestVersion;
  final String minVersion;
  final bool updateAvailable;
  final bool forceUpdate;
  final String downloadUrl;
  final String releaseNotes;

  const VersionInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.minVersion,
    required this.updateAvailable,
    required this.forceUpdate,
    required this.downloadUrl,
    required this.releaseNotes,
  });

  factory VersionInfo.fromJson(Map<String, dynamic> json) {
    return VersionInfo(
      currentVersion: json['current_version'] ?? '1.0.0',
      latestVersion: json['latest_version'] ?? '1.0.0',
      minVersion: json['min_version'] ?? '1.0.0',
      updateAvailable: json['update_available'] ?? false,
      forceUpdate: json['force_update'] ?? false,
      downloadUrl: json['download_url'] ?? '',
      releaseNotes: json['release_notes'] ?? '',
    );
  }
}

class VersionChecker {
  static const String _serverBaseUrl = 'http://222.231.24.5:8080';
  
  static Future<VersionInfo?> checkForUpdate() async {
    try {
      // Get current app version
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;
      print('[VersionChecker] Current app version: $currentVersion');
      
      // Extract version without build number (e.g., "1.0.0+1" -> "1.0.0")
      final versionWithoutBuild = currentVersion.split('+').first;
      print('[VersionChecker] Version without build: $versionWithoutBuild');
      
      // Check with server
      final uri = Uri.parse('$_serverBaseUrl/version?version=$versionWithoutBuild');
      print('[VersionChecker] Checking version at: $uri');
      final response = await http.get(uri);
      print('[VersionChecker] Server response status: ${response.statusCode}');
      print('[VersionChecker] Server response body: ${response.body}');
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final versionInfo = VersionInfo.fromJson(data);
        print('[VersionChecker] Update available: ${versionInfo.updateAvailable}');
        print('[VersionChecker] Force update: ${versionInfo.forceUpdate}');
        return versionInfo;
      }
    } catch (e) {
      print('[VersionChecker] Error checking version: $e');
    }
    return null;
  }
}
