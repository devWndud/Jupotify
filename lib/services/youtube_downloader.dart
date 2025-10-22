import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'remote_extractor.dart';

class YouTubeDownloadResult {
  final File file;
  final String title;
  final String artist;
  final File? artwork;
  final Duration? duration;
  const YouTubeDownloadResult({required this.file, required this.title, required this.artist, this.artwork, this.duration});
}

class YouTubeDownloader {
  YoutubeExplode _yt = YoutubeExplode();
  static const int _maxAttempts = 5;
  static const Duration _baseBackoff = Duration(seconds: 2);

  bool _isDecipherError(Object e) {
    final msg = e.toString().toLowerCase();
    return msg.contains('decipher') ||
        msg.contains('player script') ||
        msg.contains('signature') ||
        msg.contains("is not a subtype of type 'uri'");
  }

  Future<T> _withRetries<T>(Future<T> Function() action, {String? label}) async {
    Object? lastError;
    for (int attempt = 0; attempt < _maxAttempts; attempt++) {
      try {
        if (label != null) {
          print('[YT] Attempt ${attempt + 1}/$_maxAttempts: $label');
        }
        return await action();
      } catch (e) {
        lastError = e;
        // If decipher-related, try to recreate client next attempt
        if (_isDecipherError(e)) {
          print('[YT] Decipher-related error detected. Recreating client...');
          try {
            _yt.close();
          } catch (_) {}
          // Recreate client
          _yt = YoutubeExplode();
        }
        if (attempt == _maxAttempts - 1) {
          rethrow;
        }
        final backoff = _baseBackoff * (attempt + 1);
        print('[YT] Error on attempt ${attempt + 1}: $e. Retrying in ${backoff.inSeconds}s');
        await Future.delayed(backoff);
      }
    }
    throw lastError ?? StateError('Unknown error in _withRetries');
  }

  Future<YouTubeDownloadResult> downloadAudio(
    String url, {
    void Function(double progress)? onProgress,
    String? remoteServerBaseUrl,
  }) async {
    // 0) Try remote extractor first, if provided
    Video? video; // used only for local extraction branch
    StreamInfo? streamInfo;
    String? directAudioUrl;
    String? extHint;
    String? title;
    String? author;
    Duration? duration;
    String? thumbnailUrl;

    if (remoteServerBaseUrl != null && remoteServerBaseUrl.isNotEmpty) {
      try {
        final remote = RemoteExtractor(remoteServerBaseUrl);
        // Prefer server-side download for speed and stability
        final r = await remote.download(url);
        if (r != null) {
          // We'll download from server-hosted file URL
          directAudioUrl = r.fileUrl;
          extHint = r.extensionHint;
          title = r.title;
          author = r.author;
          duration = r.duration;
          thumbnailUrl = r.thumbnailUrl;
        }
      } catch (e) {
        print('[YT] Remote extractor failed: $e');
      }
    }

    // 1) If remote not available, fallback to local extraction
    if (directAudioUrl == null) {
      final resolved = VideoId.parseVideoId(url) ?? url;
      video = await _withRetries(() => _yt.videos.get(resolved), label: 'get video');
      final manifest = await _withRetries(() => _yt.videos.streamsClient.getManifest(video!.id), label: 'get manifest');

      // Prefer MP4 container (m4a) when available, else highest bitrate audio-only
      final mp4Audio = manifest.audioOnly.where((e) => e.container == StreamContainer.mp4);
      streamInfo = (mp4Audio.isNotEmpty ? mp4Audio : manifest.audioOnly).withHighestBitrate();

      // Populate common fields from video
      title = video!.title;
      author = video!.author;
      duration = video!.duration;
      
      // Debug logging for metadata extraction
      print('=== YOUTUBE METADATA EXTRACTION ===');
      print('Title: $title');
      print('Author: $author');
      print('Duration: $duration');
      // Best available thumbnail
      try {
        thumbnailUrl = video!.thumbnails.highResUrl.isNotEmpty
            ? video!.thumbnails.highResUrl
            : (video!.thumbnails.maxResUrl.isNotEmpty
                ? video!.thumbnails.maxResUrl
                : (video!.thumbnails.mediumResUrl.isNotEmpty
                    ? video!.thumbnails.mediumResUrl
                    : video!.thumbnails.standardResUrl));
      } catch (_) {}
    }

    final targetDir = await _resolveMusicDir();
    if (!await targetDir.exists()) {
      await targetDir.create(recursive: true);
    }

    final safeTitle = _sanitizeFileName(title ?? 'YouTube Audio');
    final ext = extHint ?? (streamInfo != null ? streamInfo.container.name : 'm4a');
    
    // Handle duplicate filenames by adding a number suffix
    String baseFileName = safeTitle;
    String fileName = '$baseFileName.$ext';
    File outFile = File('${targetDir.path}/$fileName');
    
    int counter = 1;
    while (await outFile.exists()) {
      fileName = '${baseFileName}_$counter.$ext';
      outFile = File('${targetDir.path}/$fileName');
      counter++;
    }
    
    final sink = outFile.openWrite();

    if (directAudioUrl != null) {
      // Remote direct download with timeouts
      final client = http.Client();
      try {
        final req = http.Request('GET', Uri.parse(directAudioUrl));
        final resp = await client.send(req).timeout(const Duration(seconds: 20));
        final contentLength = resp.contentLength ?? 0;
        int received = 0;
        await for (final chunk in resp.stream.timeout(const Duration(seconds: 15))) {
          sink.add(chunk);
          received += chunk.length;
          if (onProgress != null && contentLength > 0) {
            onProgress(received / contentLength);
          }
        }
        // After successful save, ask server to delete file
        try {
          final remote = RemoteExtractor(remoteServerBaseUrl!);
          await remote.deleteFile(fileUrl: directAudioUrl);
        } catch (e) {
          print('[YT] Remote delete failed: $e');
        }
      } on TimeoutException catch (e) {
        try { await sink.flush(); await sink.close(); } catch (_) {}
        if (await outFile.exists()) {
          try { await outFile.delete(); } catch (_) {}
        }
        throw e;
      } finally {
        client.close();
      }
    } else {
      // Local streaming
      final stream = await _withRetries(() async => _yt.videos.streamsClient.get(streamInfo!), label: 'open stream');
      var received = 0;
      final total = streamInfo!.size.totalBytes;
      await for (final data in stream) {
        sink.add(data);
        received += data.length;
        if (onProgress != null && total > 0) {
          onProgress(received / total);
        }
      }
    }
    await sink.flush();
    await sink.close();

    // Download artwork persistently next to audio file
    File? artFile;
    try {
      print('=== DOWNLOADING ALBUM ART ===');
      print('Video: ${title ?? 'Unknown'}');
      print('Thumbnail URL: ${thumbnailUrl ?? ''}');
      
      final thumbUrl = thumbnailUrl ?? '';
      if (thumbUrl.isNotEmpty) {
        print('Starting artwork download from: $thumbUrl');
        
        // Try multiple thumbnail URLs if the first one fails
        List<String> thumbnailUrls = [thumbUrl];
        // Fallback variants: try non-webp and non-vi_webp forms
        try {
          if (thumbUrl.contains('vi_webp')) {
            thumbnailUrls.add(thumbUrl.replaceAll('vi_webp', 'vi'));
          }
          if (thumbUrl.endsWith('.webp')) {
            thumbnailUrls.add(thumbUrl.replaceAll('.webp', '.jpg'));
          }
        } catch (_) {}
        thumbnailUrls = thumbnailUrls.where((u) => u.isNotEmpty).toList();
        
        Future<bool> tryDownloadOnce(List<String> candidates) async {
          for (int attempt = 0; attempt < candidates.length; attempt++) {
            try {
              final currentUrl = candidates[attempt];
              print('Attempt ${attempt + 1}: Downloading from $currentUrl');
              final response = await http.get(Uri.parse(currentUrl));
              if (response.statusCode == 200) {
                final bytes = response.bodyBytes;
                print('Downloaded ${bytes.length} bytes of artwork');
                // Use the same filename as the audio file but with .jpg extension
                final artFileName = fileName.replaceAll(RegExp(r'\.[^.]+$'), '.jpg');
                final maybeJpg = File('${targetDir.path}/$artFileName');
                await maybeJpg.writeAsBytes(bytes, flush: true);
                artFile = maybeJpg;
                print('Artwork saved to: ${maybeJpg.path}');
                return true;
              } else {
                print('HTTP ${response.statusCode}: ${response.reasonPhrase}');
              }
            } catch (e) {
              print('Attempt ${attempt + 1} failed: $e');
            }
          }
          return false;
        }

        // First pass
        final ok = await tryDownloadOnce(thumbnailUrls);
        // One more retry pass if failed
        if (!ok && artFile == null) {
          print('Retrying thumbnail download once more...');
          await tryDownloadOnce(thumbnailUrls);
        }
      } else {
        print('No thumbnail URL available');
      }
    } catch (e) {
      print('Error downloading artwork: $e');
      print('Stack trace: ${StackTrace.current}');
    }

    // Artist must be the YouTube channel name (author). Do not parse from title.
    final String finalArtist = (author ?? '').trim();

    // Persist lightweight sidecar metadata for filesystem scans
    try {
      final String baseNoExt = outFile.path.substring(0, outFile.path.lastIndexOf('.'));
      final File metaFile = File('$baseNoExt.metadata.json');
      final Map<String, dynamic> meta = {
        'title': title ?? 'Unknown',
        'artist': finalArtist,
        'durationMs': duration?.inMilliseconds,
      };
      await metaFile.writeAsString(jsonEncode(meta), flush: true);
      print('Metadata saved to: ${metaFile.path}');
    } catch (e) {
      print('Failed to write sidecar metadata: $e');
    }
    
    print('=== FINAL DOWNLOAD RESULT ===');
    print('Title: ${title ?? 'Unknown'}');
    print('Artist: $finalArtist');
    print('Duration: $duration');
    
    return YouTubeDownloadResult(
      file: outFile,
      title: title ?? 'Unknown',
      artist: finalArtist,
      artwork: artFile,
      duration: duration,
    );
  }

  Future<List<Video>> getPlaylistVideos(String url, {int? max}) async {
    final id = PlaylistId(url);
    final videos = await _yt.playlists.getVideos(id).toList();
    if (max != null && videos.length > max) {
      return videos.take(max).toList();
    }
    return videos;
  }

  Future<List<YouTubeDownloadResult>> downloadPlaylist(
    String url, {
    void Function(int index, int total, double itemProgress, String title)? onProgress,
    int? max,
    String? remoteServerBaseUrl,
  }) async {
    final videos = await getPlaylistVideos(url, max: max);
    final results = <YouTubeDownloadResult>[];
    for (var i = 0; i < videos.length; i++) {
      final v = videos[i];
      
      // Retry logic for each playlist item
      bool success = false;
      for (int attempt = 0; attempt < 3; attempt++) {
        try {
          if (onProgress != null) onProgress(i + 1, videos.length, 0.0, '${v.title} (시도 ${attempt + 1}/3)');
          
          // Per-item timeout so the whole playlist doesn't hang
          final r = await downloadAudio(
            v.url,
            onProgress: (p) {
              if (onProgress != null) onProgress(i + 1, videos.length, p, v.title);
            },
            remoteServerBaseUrl: remoteServerBaseUrl,
          ).timeout(const Duration(minutes: 3));
          
          results.add(r);
          success = true;
          break; // Success, exit retry loop
          
        } on TimeoutException catch (e) {
          print('[YT] Timeout on playlist item ${i + 1}/${videos.length} (${v.title}) attempt ${attempt + 1}: $e');
          if (attempt == 2) { // Last attempt
            if (onProgress != null) onProgress(i + 1, videos.length, 0.0, '${v.title} (timeout, skipped)');
          }
        } catch (e) {
          print('[YT] Error on playlist item ${i + 1}/${videos.length} (${v.title}) attempt ${attempt + 1}: $e');
          if (attempt == 2) { // Last attempt
            if (onProgress != null) onProgress(i + 1, videos.length, 0.0, '${v.title} (failed, skipped)');
          }
        }
        
        // Wait before retry (except on last attempt)
        if (attempt < 2) {
          await Future.delayed(Duration(seconds: 2 * (attempt + 1)));
        }
      }
      
      if (!success) {
        print('[YT] Skipping playlist item ${i + 1}/${videos.length} after all retries failed');
      }
    }
    return results;
  }

  Future<List<Video>> searchVideos(String query, {int limit = 25}) async {
    // Retry logic for network issues
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        final results = await _yt.search.getVideos(query);
        if (limit > 0 && results.length > limit) {
          return results.take(limit).toList();
        }
        return results.toList();
      } catch (e) {
        if (attempt == 2) rethrow; // Last attempt, throw the error
        await Future.delayed(Duration(seconds: 2 * (attempt + 1))); // Exponential backoff
      }
    }
    return [];
  }

  void dispose() {
    _yt.close();
  }

  String _sanitizeFileName(String input) {
    return input.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }

  Future<Directory> _resolveMusicDir() async {
    if (Platform.isAndroid) {
      final dirs = await getExternalStorageDirectories(type: StorageDirectory.music);
      final base = (dirs != null && dirs.isNotEmpty) ? dirs.first : await getExternalStorageDirectory();
      if (base != null) {
        return Directory('${base.path}/Jupotify');
      }
    }
    // Fallbacks: iOS/desktop → app documents
    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}/Music/Jupotify');
  }

  Future<Playlist> getPlaylist(String url) async {
    return await _yt.playlists.get(url);
  }
}



