import 'dart:convert';
import 'package:http/http.dart' as http;

class RemoteExtractResult {
  final String audioUrl; // when using /extract
  final String? fileUrl; // when using /download
  final String title;
  final String author;
  final String? thumbnailUrl;
  final String? extensionHint; // e.g. m4a/webm
  final Duration? duration;

  const RemoteExtractResult({
    required this.audioUrl,
    this.fileUrl,
    required this.title,
    required this.author,
    this.thumbnailUrl,
    this.extensionHint,
    this.duration,
  });
}

class RemoteExtractor {
  final String serverBaseUrl; // e.g. https://your-domain.com
  const RemoteExtractor(this.serverBaseUrl);

  Future<RemoteExtractResult?> extract(String url) async {
    final endpoint = Uri.parse('$serverBaseUrl/extract');
    final res = await http.post(
      endpoint,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'url': url}),
    );
    if (res.statusCode != 200) return null;
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final audioUrl = (data['audio_url'] as String?) ?? '';
    if (audioUrl.isEmpty) return null;
    return RemoteExtractResult(
      audioUrl: audioUrl,
      title: (data['title'] as String?) ?? 'Unknown',
      author: (data['author'] as String?) ?? 'Unknown',
      thumbnailUrl: data['thumbnail_url'] as String?,
      extensionHint: data['ext'] as String?,
      duration: _parseDuration(data['duration']),
    );
  }

  Future<RemoteExtractResult?> download(String url) async {
    // Validate server URL
    if (serverBaseUrl.isEmpty) {
      throw ArgumentError('serverBaseUrl cannot be empty');
    }
    
    // Parse endpoint URI
    final endpoint = Uri.parse('$serverBaseUrl/download');
    if (!endpoint.hasScheme || !endpoint.hasAuthority) {
      throw FormatException('Invalid server URL: $serverBaseUrl');
    }
    
    // Send POST request to server
    final res = await http.post(
      endpoint,
      headers: {
        'Content-Type': 'application/json',
        'User-Agent': 'Jupotify/1.0',
      },
      body: jsonEncode({'url': url}),
    ).timeout(const Duration(seconds: 30));
    
    // Check response status
    if (res.statusCode != 200) {
      return null;
    }
    
    // Parse response
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final fileUrl = data['file_url'] as String?;
    
    if (fileUrl == null || fileUrl.isEmpty) {
      return null;
    }
    
    return RemoteExtractResult(
      audioUrl: '',
      fileUrl: fileUrl,
      title: (data['title'] as String?) ?? 'Unknown',
      author: (data['author'] as String?) ?? 'Unknown',
      thumbnailUrl: data['thumbnail_url'] as String?,
      extensionHint: data['ext'] as String?,
      duration: _parseDuration(data['duration']),
    );
  }

  Future<void> deleteFile({String? fileUrl, String? filename}) async {
    final endpoint = Uri.parse('$serverBaseUrl/delete');
    await http.post(
      endpoint,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'file_url': fileUrl, 'filename': filename}),
    );
  }

  Duration? _parseDuration(dynamic v) {
    if (v == null) return null;
    if (v is int) return Duration(seconds: v);
    if (v is String) {
      final secs = int.tryParse(v);
      if (secs != null) return Duration(seconds: secs);
    }
    return null;
  }
}


