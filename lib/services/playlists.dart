import 'dart:convert';
import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';

class PlaylistEntry {
  final String id;
  final String title;
  final String? artist;
  final String uri; // file uri
  final String? artUri;
  final int? durationMs;

  const PlaylistEntry({required this.id, required this.title, this.artist, required this.uri, this.artUri, this.durationMs});

  factory PlaylistEntry.fromMediaItem(MediaItem item) => PlaylistEntry(
        id: item.id,
        title: item.title,
        artist: item.artist,
        uri: item.extras?['uri'] as String? ?? item.id,
        artUri: item.artUri?.toString(),
        durationMs: item.duration?.inMilliseconds,
      );

  MediaItem toMediaItem() => MediaItem(
        id: id,
        title: title,
        artist: artist,
        artUri: artUri != null ? Uri.parse(artUri!) : null,
        duration: durationMs != null ? Duration(milliseconds: durationMs!) : null,
        extras: {'uri': uri},
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'uri': uri,
        'artUri': artUri,
        'durationMs': durationMs,
      };

  static PlaylistEntry fromJson(Map<String, dynamic> j) => PlaylistEntry(
        id: j['id'] as String,
        title: j['title'] as String,
        artist: j['artist'] as String?,
        uri: j['uri'] as String,
        artUri: j['artUri'] as String?,
        durationMs: j['durationMs'] as int?,
      );
}

class PlaylistsService {
  static const _key = 'jupoplaylists';
  static const _libraryKey = 'jupolibrary';
  static final StreamController<void> libraryChanged = StreamController<void>.broadcast();

  Future<Map<String, List<PlaylistEntry>>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return {};
    final map = json.decode(raw) as Map<String, dynamic>;
    return map.map((name, list) => MapEntry(
          name,
          (list as List).map((e) => PlaylistEntry.fromJson(e as Map<String, dynamic>)).toList(),
        ));
  }

  Future<void> save(Map<String, List<PlaylistEntry>> data) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = json.encode(data.map((k, v) => MapEntry(k, v.map((e) => e.toJson()).toList())));
    await prefs.setString(_key, encoded);
  }

  Future<void> addTrack(String name, MediaItem item) async {
    final all = await load();
    final list = all[name] ?? <PlaylistEntry>[];
    list.add(PlaylistEntry.fromMediaItem(item));
    all[name] = list;
    await save(all);
  }

  Future<void> addToPlaylist(String playlistName, PlaylistEntry entry) async {
    final all = await load();
    final list = all[playlistName] ?? <PlaylistEntry>[];
    // Check if item already exists
    if (!list.any((e) => e.id == entry.id)) {
      list.add(entry);
      all[playlistName] = list;
      await save(all);
    }
  }

  Future<void> removeTrack(String name, String id) async {
    final all = await load();
    final list = all[name] ?? <PlaylistEntry>[];
    all[name] = list.where((e) => e.id != id).toList();
    await save(all);
  }

  Future<void> create(String name) async {
    final all = await load();
    all.putIfAbsent(name, () => <PlaylistEntry>[]);
    await save(all);
  }

  Future<void> delete(String name) async {
    final all = await load();
    all.remove(name);
    await save(all);
  }

  Future<List<String>> loadPlaylists() async {
    final all = await load();
    return all.keys.toList();
  }

  Future<void> createPlaylist(String name) async {
    await create(name);
  }

  // Library management methods
  Future<List<PlaylistEntry>> loadLibrary() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_libraryKey);
    if (raw == null) return [];
    final list = json.decode(raw) as List;
    return list.map((e) => PlaylistEntry.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> saveLibrary(List<PlaylistEntry> library) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = json.encode(library.map((e) => e.toJson()).toList());
    await prefs.setString(_libraryKey, encoded);
    // Notify listeners that library changed
    if (!libraryChanged.isClosed) {
      libraryChanged.add(null);
    }
  }

  Future<void> addToLibrary(MediaItem item) async {
    final library = await loadLibrary();
    final index = library.indexWhere((e) => e.id == item.id);
    if (index == -1) {
      // New entry
      library.add(PlaylistEntry.fromMediaItem(item));
      await saveLibrary(library);
      return;
    }

    // Existing entry: upsert missing metadata (artist/duration/artUri/title)
    final existing = library[index];
    final updated = PlaylistEntry(
      id: existing.id,
      title: (existing.title.isNotEmpty ? existing.title : item.title),
      artist: ((existing.artist == null || existing.artist!.isEmpty) ? item.artist : existing.artist),
      uri: (existing.uri.isNotEmpty ? existing.uri : (item.extras?['uri'] as String? ?? existing.id)),
      artUri: (existing.artUri ?? item.artUri?.toString()),
      durationMs: (existing.durationMs ?? item.duration?.inMilliseconds),
    );
    library[index] = updated;
    await saveLibrary(library);
  }

  Future<void> updateLibraryMetadata({required String id, String? title, String? artist}) async {
    final library = await loadLibrary();
    final idx = library.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    final old = library[idx];
    final updated = PlaylistEntry(
      id: old.id,
      title: (title != null && title.isNotEmpty) ? title : old.title,
      artist: (artist != null) ? artist : old.artist,
      uri: old.uri,
      artUri: old.artUri,
      durationMs: old.durationMs,
    );
    library[idx] = updated;
    await saveLibrary(library);
  }

  Future<void> bulkUpdateArtist(Set<String> ids, String artist) async {
    if (ids.isEmpty) return;
    final library = await loadLibrary();
    bool changed = false;
    for (int i = 0; i < library.length; i++) {
      final e = library[i];
      if (ids.contains(e.id)) {
        library[i] = PlaylistEntry(
          id: e.id,
          title: e.title,
          artist: artist,
          uri: e.uri,
          artUri: e.artUri,
          durationMs: e.durationMs,
        );
        changed = true;
      }
    }
    if (changed) {
      await saveLibrary(library);
    }
  }

  Future<int> bulkReplaceArtist(String fromArtist, String toArtist) async {
    final fromNorm = fromArtist.trim().toLowerCase();
    final to = toArtist.trim();
    if (fromNorm.isEmpty || to.isEmpty) return 0;

    final library = await loadLibrary();
    int updated = 0;
    for (int i = 0; i < library.length; i++) {
      final e = library[i];
      final current = (e.artist ?? '').trim().toLowerCase();
      if (current == fromNorm) {
        library[i] = PlaylistEntry(
          id: e.id,
          title: e.title,
          artist: to,
          uri: e.uri,
          artUri: e.artUri,
          durationMs: e.durationMs,
        );
        updated++;
      }
    }
    if (updated > 0) {
      await saveLibrary(library);
    }
    return updated;
  }

  Future<void> removeFromLibrary(String id) async {
    final library = await loadLibrary();
    library.removeWhere((e) => e.id == id);
    await saveLibrary(library);
  }

  Future<void> clearLibrary() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_libraryKey);
    if (!libraryChanged.isClosed) {
      libraryChanged.add(null);
    }
  }

  Future<List<PlaylistEntry>> loadPlaylist(String playlistName) async {
    final all = await load();
    return all[playlistName] ?? <PlaylistEntry>[];
  }

  /// Remove a track from all playlists by id. Returns total removed count.
  Future<int> removeTrackFromAllPlaylists(String id) async {
    final all = await load();
    int removed = 0;
    bool changed = false;
    final updated = <String, List<PlaylistEntry>>{};
    for (final entry in all.entries) {
      final original = entry.value;
      final filtered = original.where((e) => e.id != id).toList();
      if (filtered.length != original.length) {
        removed += (original.length - filtered.length);
        changed = true;
      }
      updated[entry.key] = filtered;
    }
    if (changed) {
      await save(updated);
    }
    return removed;
  }

  /// 플레이리스트에서 삭제된 파일들을 정리합니다
  Future<int> cleanupDeletedFiles() async {
    final all = await load();
    final library = await loadLibrary();
    final libraryIds = library.map((e) => e.id).toSet();
    
    int totalRemoved = 0;
    final updatedPlaylists = <String, List<PlaylistEntry>>{};
    
    for (final entry in all.entries) {
      final playlistName = entry.key;
      final tracks = entry.value;
      final validTracks = <PlaylistEntry>[];
      
      for (final track in tracks) {
        // 파일이 실제로 존재하는지 확인
        final fileExists = await _checkFileExists(track.uri);
        if (fileExists && libraryIds.contains(track.id)) {
          validTracks.add(track);
        } else {
          print('[Playlist] Removing deleted track: ${track.title} from $playlistName');
          totalRemoved++;
        }
      }
      
      if (validTracks.length != tracks.length) {
        updatedPlaylists[playlistName] = validTracks;
      }
    }
    
    // 업데이트된 플레이리스트 저장
    if (updatedPlaylists.isNotEmpty) {
      final finalPlaylists = <String, List<PlaylistEntry>>{};
      for (final entry in all.entries) {
        final playlistName = entry.key;
        if (updatedPlaylists.containsKey(playlistName)) {
          finalPlaylists[playlistName] = updatedPlaylists[playlistName]!;
        } else {
          finalPlaylists[playlistName] = entry.value;
        }
      }
      await save(finalPlaylists);
    }
    
    return totalRemoved;
  }

  /// 파일이 실제로 존재하는지 확인
  Future<bool> _checkFileExists(String? uri) async {
    if (uri == null || uri.isEmpty) return false;
    
    try {
      final file = File(uri);
      return await file.exists();
    } catch (e) {
      print('[Playlist] Error checking file existence: $e');
      return false;
    }
  }
}


