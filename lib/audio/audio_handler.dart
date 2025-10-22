import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/playlists.dart';

/// Simple AudioHandler backed by just_audio that supports a single queue
/// of local files and exposes standard playback controls and state.
class JupotifyAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final _player = AudioPlayer();
  final _playlistsService = PlaylistsService();
  final _playlist = ConcatenatingAudioSource(children: []);
  // Enforce single-item playback to prevent natural auto-advance flicker
  bool _singleItemPlayback = true;
  Timer? _positionTicker;

  JupotifyAudioHandler() {
    _init();
  }

  Future<void> _init() async {
    // Configure audio session for background playback
    final session = await AudioSession.instance;
    try {
      await session.configure(const AudioSessionConfiguration.music());
    } catch (_) {
      // If session configure fails, continue with defaults
    }

    // Broadcast initial empty queue
    queue.add(const []);

    // Propagate playback state
    _player.playbackEventStream.map(_transformEvent).pipe(playbackState);

    // Load empty playlist initially and observe index changes to update media item
    try {
      await _player.setAudioSource(_playlist, preload: false);
    } catch (_) {
      // ignore load errors on empty playlist
    }
    _player.currentIndexStream.listen((index) {
      if (index == null) return;
      
      // Always use index 0 for mediaItem since we keep currentIndex at 0
      final item = _getMediaItemAt(0);
      if (item != null) mediaItem.add(item);
    });
    // Also mirror the sequence state's current source tag (only for normal playback)
    _player.sequenceStateStream.listen((state) {
      final current = state?.currentSource;
      final tag = (current as dynamic)?.tag;
      if (tag is MediaItem) {
        // Only update if it's different from current mediaItem to avoid flickering
        final currentMediaItem = mediaItem.valueOrNull;
        if (currentMediaItem == null || currentMediaItem.id != tag.id) {
          mediaItem.add(tag);
        }
      }
    });

    // Keep mediaItem.duration in sync for proper notification seek bar
    _player.durationStream.listen((duration) {
      final idx = _player.currentIndex;
      if (idx == null || duration == null) return;
      final current = _getMediaItemAt(idx);
      if (current == null) return;
      if (current.duration == duration) return;
      
      // Only update if duration actually changed to avoid unnecessary updates
      final updated = current.copyWith(duration: duration);
      final currentMediaItem = mediaItem.valueOrNull;
      if (currentMediaItem == null || currentMediaItem.duration != updated.duration) {
        // Update only the queue and mediaItem, don't modify the playlist
        final currentQueue = List<MediaItem>.from(queue.valueOrNull ?? const <MediaItem>[]);
        if (idx < currentQueue.length) {
          currentQueue[idx] = updated;
          queue.add(currentQueue);
        }
        mediaItem.add(updated);
      }
    });

    // Natural auto-advance is disabled via single-item playback strategy below.
  }

  Future<void> _ensurePlaylistLoaded() async {
    try {
      if (_player.audioSource != _playlist) {
        await _player.setAudioSource(_playlist, preload: false);
        // Wait for the playlist to be ready
        await Future.delayed(const Duration(milliseconds: 100));
      }
      // Do not modify loop mode here; respect user's repeat setting
    } catch (e) {
      print('Error loading playlist: $e');
      // Don't rethrow to prevent UI freezing
    }
  }

  Future<void> _waitUntilStable({Duration timeout = Duration.zero}) async {
    if (timeout == Duration.zero) return;
    await Future.delayed(timeout);
  }

  @override
  Future<void> addQueueItem(MediaItem mediaItem) async {
    // Ensure playlist is ready
    await _ensurePlaylistLoaded();

    // If artist/duration are missing, hydrate from saved library JSON
    mediaItem = await _hydrateMediaItemFromLibrary(mediaItem);
    // Expect mediaItem.extras!['uri'] to be a file:// or content:// URI
    final uri = mediaItem.extras?['uri'] as String?;
    if (uri == null) return;
    // If the same id already exists, update it instead of adding a duplicate
    final current = List<MediaItem>.from(queue.valueOrNull ?? const <MediaItem>[]);
    final existingIndex = current.indexWhere((e) => e.id == mediaItem.id);
    if (existingIndex >= 0) {
      await updateQueueItem(existingIndex, mediaItem);
      return;
    }
    final source = AudioSource.uri(Uri.parse(uri), tag: mediaItem);
    await _playlist.add(source);
    final newQueue = <MediaItem>[...current, mediaItem];
    queue.add(newQueue);
    
    // Queue order saving removed - queue is now temporary
  }

  @override
  Future<void> addQueueItems(List<MediaItem> mediaItems) async {
    // Ensure playlist is ready
    await _ensurePlaylistLoaded();

    final sources = <AudioSource>[];
    final validItems = <MediaItem>[];
    final existingIds = (queue.valueOrNull ?? const <MediaItem>[]).map((e) => e.id).toSet();
    
    for (final raw in mediaItems) {
      // If artist/duration are missing, hydrate from saved library JSON
      final item = await _hydrateMediaItemFromLibrary(raw);
      final uri = item.extras?['uri'] as String?;
      if (uri != null && !existingIds.contains(item.id)) {
        sources.add(AudioSource.uri(Uri.parse(uri), tag: item));
        validItems.add(item);
        existingIds.add(item.id); // Prevent duplicates within the same batch
      }
    }
    if (sources.isEmpty) return;
    await _playlist.addAll(sources);
    final List<MediaItem> current = List<MediaItem>.from(queue.valueOrNull ?? const <MediaItem>[]);
    final updated = <MediaItem>[...current, ...validItems];
    queue.add(updated);
    
    // Queue order saving removed - queue is now temporary
    
    if (_player.currentIndex == null && updated.isNotEmpty) {
      mediaItem.add(updated.first);
    }
  }

  // Fill in missing artist/duration from the saved library if available
  Future<MediaItem> _hydrateMediaItemFromLibrary(MediaItem item) async {
    try {
      final bool needsArtist = (item.artist == null || item.artist!.isEmpty);
      final bool needsDuration = (item.duration == null);
      if (!needsArtist && !needsDuration) return item;

      final List<PlaylistEntry> library = await _playlistsService.loadLibrary();
      final match = library.firstWhere(
        (e) => e.id == item.id,
        orElse: () => const PlaylistEntry(id: '', title: '', uri: ''),
      );
      if (match.id.isEmpty) return item;

      final updated = item.copyWith(
        artist: needsArtist ? match.artist : item.artist,
        duration: needsDuration && match.durationMs != null
            ? Duration(milliseconds: match.durationMs!)
            : item.duration,
      );
      return updated;
    } catch (_) {
      return item;
    }
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= _playlist.length) return;
    
    try {
      // Move the selected song to front of queue
      await _moveSongToFront(index);
      
      // Always stay at index 0
      await _player.seek(Duration.zero, index: 0);
      
      // Update media item
      final currentItem = _getMediaItemAt(0);
      if (currentItem != null) {
        mediaItem.add(currentItem);
      }
    } catch (e) {
      print('Error in skipToQueueItem(): $e');
      // Don't rethrow to prevent app crash
    }
  }

  // New method for resuming playback with position preservation
  Future<void> skipToQueueItemWithPosition(int index, Duration? position) async {
    if (index < 0 || index >= _playlist.length) return;
    
    try {
      // Move the selected song to front of queue
      await _moveSongToFront(index);
      
      // Seek to the specified position or zero if not provided
      await _player.seek(position ?? Duration.zero, index: 0);
      
      // Update media item
      final currentItem = _getMediaItemAt(0);
      if (currentItem != null) {
        mediaItem.add(currentItem);
      }
    } catch (e) {
      print('Error in skipToQueueItemWithPosition(): $e');
      // Don't rethrow to prevent app crash
    }
  }

  @override
  Future<void> play() async {
    if (_playlist.length == 0) {
      // Nothing loaded yet; ignore play to avoid startup crashes
      return;
    }
    
    try {
      // Always ensure playlist is loaded
      await _ensurePlaylistLoaded();
      
      // If nothing is selected yet, start from index 0. Otherwise, resume from current position.
      if (_player.currentIndex == null) {
        await _player.seek(Duration.zero, index: 0);
        final first = _getMediaItemAt(0);
        if (first != null) mediaItem.add(first);
      }
      
      // Play with error handling
      await _player.play();
      // Emit a fresh snapshot so notification/UI seek bars update immediately
      _emitPlaybackSnapshot();
      _startPositionTicker();
      // Cancel idle kill while actively playing
      try {
        final channel = MethodChannel('com.example.jupotify/idle');
        await channel.invokeMethod('cancelIdleKill');
      } catch (_) {}
    } catch (e) {
      print('Error in play(): $e');
      // Don't rethrow to prevent UI freezing
    }
  }

  @override
  Future<void> pause() async {
    try {
      await _player.pause();
      // Emit a fresh snapshot so notification/UI seek bars freeze at current position
      _emitPlaybackSnapshot();
      _stopPositionTicker();
      // Schedule idle kill when paused and app goes background
      try {
        final channel = MethodChannel('com.example.jupotify/idle');
        await channel.invokeMethod('scheduleIdleKill', { 'isPlaying': false });
      } catch (_) {}
    } catch (e) {
      print('Error in pause(): $e');
      // Don't rethrow to prevent app crash
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _player.stop();
      _stopPositionTicker();
    } catch (e) {
      print('Error in stop(): $e');
      // Don't rethrow to prevent app crash
    }
  }

  @override
  Future<void> seek(Duration position) async {
    if (_playlist.length == 0) return;
    
    try {
      // Don't check currentIndex as it might be null in release builds
      await _ensurePlaylistLoaded();
      await _player.seek(position);
      // Emit a fresh snapshot so notification/UI seek bars jump to the new position
      _emitPlaybackSnapshot();
      // Keep ticker running state in sync
      if (_player.playing) {
        _startPositionTicker();
      }
    } catch (e) {
      print('Error in seek(): $e');
      // Don't rethrow to prevent app crash
    }
  }

  /// The current playback position
  Duration get position => _player.position;
  /// The current media duration (may be null while loading)
  Duration? get duration => _player.duration;
  
  /// Stream of current playback position
  Stream<Duration> get positionStream => _player.positionStream;
  /// Stream of current media duration (may emit null temporarily)
  Stream<Duration?> get durationStream => _player.durationStream;

  /// The current queue in display order (shuffled if shuffle is enabled)
  List<MediaItem> get displayQueue {
    final items = queue.valueOrNull ?? [];
    if (_player.shuffleModeEnabled && items.isNotEmpty) {
      // Return the current sequence order which reflects shuffle
      final sequence = _player.sequenceState?.sequence ?? [];
      return sequence.map((source) {
        final tag = (source as dynamic)?.tag;
        if (tag is MediaItem) return tag;
        return null;
      }).where((item) => item != null).cast<MediaItem>().toList();
    }
    return items;
  }

  @override
  Future<void> skipToNext() async {
    if (_playlist.length == 0) return;
    _pendingNextCount++;
    await _processPendingSkips();
  }

  @override
  Future<void> skipToPrevious() async {
    if (_playlist.length == 0) return;
    _pendingPrevCount++;
    await _processPendingSkips();
  }

  // Store original order before shuffling
  List<MediaItem>? _originalQueueOrder;
  
  // Track current shuffle mode for UI display
  AudioServiceShuffleMode _currentShuffleMode = AudioServiceShuffleMode.none;
  // Serialize rapid shuffle toggles to avoid race conditions
  bool _isApplyingShuffle = false;
  AudioServiceShuffleMode? _pendingShuffleMode;
  
  // Flag to prevent duplicate first song moves
  bool _isMovingFirstSong = false;

  // Serialize rapid next/previous actions to prevent race conditions
  bool _isProcessingSkips = false;
  int _pendingNextCount = 0;
  int _pendingPrevCount = 0;

  void _emitPlaybackSnapshot() {
    try {
      playbackState.add(_transformEvent(PlaybackEvent(
        processingState: _player.processingState,
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        updateTime: DateTime.now(),
      )));
    } catch (_) {}
  }

  void _startPositionTicker() {
    _positionTicker?.cancel();
    // Emit periodic snapshots so notification progress stays in sync on all devices
    _positionTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_player.playing) return;
      _emitPlaybackSnapshot();
    });
  }

  void _stopPositionTicker() {
    _positionTicker?.cancel();
    _positionTicker = null;
  }

  Future<void> _processPendingSkips() async {
    if (_isProcessingSkips) return;
    _isProcessingSkips = true;
    try {
      while (_pendingNextCount > 0 || _pendingPrevCount > 0) {
        final cancelable = (_pendingNextCount > 0 && _pendingPrevCount > 0)
            ? (_pendingNextCount < _pendingPrevCount ? _pendingNextCount : _pendingPrevCount)
            : 0;
        if (cancelable > 0) {
          _pendingNextCount -= cancelable;
          _pendingPrevCount -= cancelable;
          continue;
        }

        if (_pendingNextCount > 0) {
          _pendingNextCount--;
          await _performSkipNext();
        } else if (_pendingPrevCount > 0) {
          _pendingPrevCount--;
          await _performSkipPrevious();
        }
      }
    } catch (e) {
      print('Error processing pending skips: $e');
    } finally {
      _isProcessingSkips = false;
    }
  }

  Future<void> _performSkipNext() async {
    if (_playlist.length == 0) return;
    try {
      await _ensurePlaylistLoaded();
      await _moveCurrentSongToEnd();
      await _player.seek(Duration.zero, index: 0);
      final currentItem = _getMediaItemAt(0);
      if (currentItem != null) mediaItem.add(currentItem);
      _emitPlaybackSnapshot();
    } catch (e) {
      print('Error in _performSkipNext: $e');
    }
  }

  Future<void> _performSkipPrevious() async {
    if (_playlist.length == 0) return;
    try {
      await _ensurePlaylistLoaded();
      await _moveLastSongToFront();
      await _player.seek(Duration.zero, index: 0);
      final currentItem = _getMediaItemAt(0);
      if (currentItem != null) mediaItem.add(currentItem);
      _emitPlaybackSnapshot();
    } catch (e) {
      print('Error in _performSkipPrevious: $e');
    }
  }

  // Rotate first item to end using in-place move to avoid heavy rebuilds
  Future<void> _rotateFirstToEndInPlace() async {
    final currentQueue = List<MediaItem>.from(queue.valueOrNull ?? []);
    if (currentQueue.length <= 1) return;
    final first = currentQueue.removeAt(0);
    currentQueue.add(first);
    // Update UI queue first
    queue.add(currentQueue);
    // Perform in-place move on audio source if possible
    try {
      if (_playlist.length >= 2) {
        await _playlist.move(0, _playlist.length - 1);
      }
    } catch (_) {
      // Fallback to rebuild only if move fails
      await _rebuildPlaylistWithOrder(currentQueue);
    }
    // Update media item to new first
    final currentItem = _getMediaItemAt(0);
    if (currentItem != null) mediaItem.add(currentItem);
  }

  // Move current song to end of queue (for skipToNext)
  Future<void> _moveCurrentSongToEnd() async {
    final currentQueue = List<MediaItem>.from(queue.valueOrNull ?? []);
    if (currentQueue.length <= 1) return; // Don't move if only one song or empty
    
    // Get the current song (always at index 0)
    final currentSong = currentQueue[0];
    
    // Remove current song from front
    currentQueue.removeAt(0);
    
    // Add it to the end
    currentQueue.add(currentSong);
    
    // Update the queue
    queue.add(currentQueue);
    
    // Rebuild playlist with new order
    await _rebuildPlaylistWithOrder(currentQueue);
    
    print('=== MOVED CURRENT SONG TO END ===');
    print('Moved: ${currentSong.title}');
    print('New order: ${currentQueue.map((e) => e.title).toList()}');
  }

  // Move last song to front of queue (for skipToPrevious)
  Future<void> _moveLastSongToFront() async {
    final currentQueue = List<MediaItem>.from(queue.valueOrNull ?? []);
    if (currentQueue.length <= 1) return; // Don't move if only one song or empty
    
    // Get the last song
    final lastSong = currentQueue.removeLast();
    
    // Add it to the front
    currentQueue.insert(0, lastSong);
    
    // Update the queue
    queue.add(currentQueue);
    
    // Rebuild playlist with new order
    await _rebuildPlaylistWithOrder(currentQueue);
    
    print('=== MOVED LAST SONG TO FRONT ===');
    print('Moved: ${lastSong.title}');
    print('New order: ${currentQueue.map((e) => e.title).toList()}');
  }

  // Move specific song to front of queue (for skipToQueueItem)
  Future<void> _moveSongToFront(int index) async {
    final currentQueue = List<MediaItem>.from(queue.valueOrNull ?? []);
    if (index < 0 || index >= currentQueue.length) return;
    
    // Get the song at the specified index
    final selectedSong = currentQueue.removeAt(index);
    
    // Add it to the front
    currentQueue.insert(0, selectedSong);
    
    // Update the queue
    queue.add(currentQueue);
    
    // Rebuild playlist with new order
    await _rebuildPlaylistWithOrder(currentQueue);
    
    print('=== MOVED SONG TO FRONT ===');
    print('Moved: ${selectedSong.title} from index $index to front');
    print('New order: ${currentQueue.map((e) => e.title).toList()}');
  }

  // Move previous song to back of queue when track changes
  Future<void> _movePreviousSongToBack() async {
    final currentQueue = List<MediaItem>.from(queue.valueOrNull ?? []);
    if (currentQueue.length <= 1) return; // Don't move if only one song or empty
    
    final currentIndex = _player.currentIndex;
    if (currentIndex == null || currentIndex >= currentQueue.length) return;
    
    // Move the previous song (currentIndex - 1) to back
    if (currentIndex > 0) {
      final previousSong = currentQueue.removeAt(currentIndex - 1);
      currentQueue.add(previousSong);
      
      // Update queue
      queue.add(currentQueue);
      
      // Rebuild playlist with new order
      await _rebuildPlaylistWithOrder(currentQueue);
      
      // Adjust current index since we removed an item before current
      final newCurrentIndex = currentIndex - 1;
      await _player.seek(_player.position, index: newCurrentIndex);
      
      print('=== MOVED PREVIOUS SONG TO BACK ===');
      print('Moved: ${previousSong.title} to position ${currentQueue.length - 1}');
      print('Current song is now at index: $newCurrentIndex');
    }
  }

  // Rebuild playlist with specific order without affecting library
  Future<void> _rebuildPlaylistWithOrder(List<MediaItem> newOrder) async {
    print('=== REBUILDING PLAYLIST WITH NEW ORDER ===');
    print('New order length: ${newOrder.length}');

    if (newOrder.isEmpty) {
      print('Empty order, nothing to rebuild');
      return;
    }

    // Clear current playlist and rebuild with new order
    await _playlist.clear();

    // Add audio sources in new order
    for (final item in newOrder) {
      final uri = item.extras?['uri'] as String?;
      if (uri != null) {
        await _playlist.add(AudioSource.uri(Uri.parse(uri), tag: item));
      }
    }

    print('Playlist rebuilt with ${newOrder.length} items');
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    // If a shuffle change is already in progress, coalesce to the latest request
    if (_isApplyingShuffle) {
      _pendingShuffleMode = shuffleMode;
      return;
    }
    _isApplyingShuffle = true;
    final enableShuffle = shuffleMode == AudioServiceShuffleMode.all;
    final bool wasPlaying = _player.playing;
    final int? currentIndex = _player.currentIndex;
    final Duration currentPosition = _player.position;
    
    // Update current shuffle mode for UI display
    _currentShuffleMode = shuffleMode;

    // Ensure playlist is attached as the audio source
    await _ensurePlaylistLoaded();

    try {
      // NEVER use just_audio's built-in shuffle - it affects the entire playlist
      // Keep shuffle mode disabled in just_audio
      await _player.setShuffleModeEnabled(false);
      
      if (enableShuffle) {
        // Store original order before shuffling (always store current order as original)
        final currentQueue = List<MediaItem>.from(queue.valueOrNull ?? []);
        if (currentQueue.isNotEmpty) {
          _originalQueueOrder = List<MediaItem>.from(currentQueue);
          print('=== STORED ORIGINAL ORDER ===');
          print('Original: ${_originalQueueOrder!.map((e) => e.title).toList()}');
        }
        
        // Create a shuffled copy of the current queue, keeping current song first
        final currentIndex = _player.currentIndex ?? 0;
        final currentSong = currentIndex < currentQueue.length ? currentQueue[currentIndex] : null;
        
        final shuffledQueue = List<MediaItem>.from(currentQueue);
        if (currentSong != null) {
          // Remove current song from the list
          shuffledQueue.removeWhere((item) => item.id == currentSong.id);
          // Shuffle the remaining songs
          shuffledQueue.shuffle();
          // Put current song at the beginning
          shuffledQueue.insert(0, currentSong);
        } else {
          // If no current song, just shuffle everything
          shuffledQueue.shuffle();
        }
        
        // Update the queue stream with shuffled order
        queue.add(shuffledQueue);
        // Queue order saving removed - queue is now temporary
        
        // Rebuild the playlist with shuffled order
        await _rebuildPlaylistWithOrder(shuffledQueue);
        
        // Update mediaItem without seeking (more efficient)
        final newCurrentItem = _getMediaItemAt(0);
        if (newCurrentItem != null) {
          mediaItem.add(newCurrentItem);
        }
        
        print('=== SHUFFLE APPLIED (CURRENT SONG KEPT FIRST) ===');
        print('Current song: ${currentSong?.title ?? 'None'}');
        print('Next song: ${shuffledQueue.length > 1 ? shuffledQueue[1].title : 'None'}');
        print('Shuffled queue: ${shuffledQueue.map((e) => e.title).toList()}');
      } else {
        // When turning off shuffle, restore to original order from JSON
        if (_originalQueueOrder != null && _originalQueueOrder!.isNotEmpty) {
          // Get current playing song from current queue
          final currentQueue = queue.valueOrNull ?? [];
          final currentPlayingSong = currentQueue.isNotEmpty ? currentQueue[0] : null;
          
          // Restore to the original order that was stored when shuffle was first enabled
          queue.add(_originalQueueOrder!);
          
          // If we have a current playing song, move it to the front of the restored queue
          if (currentPlayingSong != null) {
            final restoredQueue = List<MediaItem>.from(_originalQueueOrder!);
            final currentIndex = restoredQueue.indexWhere((item) => item.id == currentPlayingSong.id);
            if (currentIndex > 0) {
              // Move current playing song to the front
              final currentSong = restoredQueue.removeAt(currentIndex);
              restoredQueue.insert(0, currentSong);
              queue.add(restoredQueue);
            }
          }
          
          // Rebuild the playlist with restored order
          await _rebuildPlaylistWithOrder(queue.valueOrNull ?? []);
          
          // Explicitly update mediaItem to ensure next song display is correct
          final newCurrentItem = _getMediaItemAt(0);
          if (newCurrentItem != null) {
            mediaItem.add(newCurrentItem);
          }
          
          print('=== SHUFFLE DISABLED - RESTORED TO ORIGINAL ORDER ===');
          print('Current song: ${newCurrentItem?.title ?? 'None'}');
          print('Next song: ${(queue.valueOrNull ?? []).length > 1 ? (queue.valueOrNull ?? [])[1].title : 'None'}');
          print('Restored: ${(queue.valueOrNull ?? []).map((e) => e.title).toList()}');
        } else {
          // If no original order was stored, try to restore from JSON library
          try {
            final libraryEntries = await _playlistsService.loadLibrary();
            if (libraryEntries.isNotEmpty) {
              final libraryItems = libraryEntries.map((entry) => entry.toMediaItem()).toList();
              
              // Get current playing song from current queue
              final currentQueue = queue.valueOrNull ?? [];
              final currentPlayingSong = currentQueue.isNotEmpty ? currentQueue[0] : null;
              
              // If we have a current playing song, move it to the front of the library queue
              if (currentPlayingSong != null) {
                final currentIndex = libraryItems.indexWhere((item) => item.id == currentPlayingSong.id);
                if (currentIndex > 0) {
                  // Move current playing song to the front
                  final currentSong = libraryItems.removeAt(currentIndex);
                  libraryItems.insert(0, currentSong);
                }
              }
              
              queue.add(libraryItems);
              await _rebuildPlaylistWithOrder(libraryItems);
              
              // Explicitly update mediaItem to ensure next song display is correct
              final newCurrentItem = _getMediaItemAt(0);
              if (newCurrentItem != null) {
                mediaItem.add(newCurrentItem);
              }
              
              print('=== SHUFFLE DISABLED - RESTORED FROM JSON LIBRARY ===');
              print('Current song: ${newCurrentItem?.title ?? 'None'}');
              print('Next song: ${libraryItems.length > 1 ? libraryItems[1].title : 'None'}');
              print('Restored: ${libraryItems.map((e) => e.title).toList()}');
            } else {
              print('=== SHUFFLE DISABLED - NO ORIGINAL ORDER TO RESTORE ===');
            }
          } catch (e) {
            print('Error restoring from JSON library: $e');
            print('=== SHUFFLE DISABLED - NO ORIGINAL ORDER TO RESTORE ===');
          }
        }
        _originalQueueOrder = null; // Clear stored order
      }

    // Always keep our invariant: current item is at index 0. Preserve position only.
    await _player.seek(currentPosition, index: 0);

      if (wasPlaying) {
        await _player.play();
      }
      
      // Update playback state to reflect shuffle mode change
      playbackState.add(_transformEvent(PlaybackEvent(
        processingState: _player.processingState,
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        updateTime: DateTime.now(),
      )));
    } catch (e) {
      print('Shuffle error: $e');
      // No-op: avoid crashing on devices that momentarily invalidate the source during shuffle toggles
    } finally {
      _isApplyingShuffle = false;
      // If another toggle was requested while we were working, apply the latest now
      final next = _pendingShuffleMode;
      _pendingShuffleMode = null;
      if (next != null && next != _currentShuffleMode) {
        // Schedule microtask to avoid deep recursion
        Future.microtask(() => setShuffleMode(next));
      }
    }
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    final bool wasPlaying = _player.playing;
    final int? currentIndex = _player.currentIndex;
    final Duration currentPosition = _player.position;

    LoopMode loopMode = LoopMode.off;
    if (repeatMode == AudioServiceRepeatMode.one) loopMode = LoopMode.one;
    if (repeatMode == AudioServiceRepeatMode.all) loopMode = LoopMode.all;

    try {
      await _player.setLoopMode(loopMode);

      // Restore position/index to keep seek bar stable
      if (currentIndex != null && currentIndex >= 0) {
        await _player.seek(currentPosition, index: currentIndex);
      }

      if (wasPlaying) {
        await _player.play();
      }
    } catch (_) {
      // Swallow errors to prevent UI breakage on some devices
    }
  }

  Future<void> removeQueueItemAt(int index) async {
    if (index < 0 || index >= _playlist.length) return;
    await _playlist.removeAt(index);
    final current = List<MediaItem>.from(queue.valueOrNull ?? const <MediaItem>[]);
    current.removeAt(index);
    queue.add(current);
    
    // Queue order saving removed - queue is now temporary
  }

  Future<void> removeQueueItemById(String id) async {
    final current = List<MediaItem>.from(queue.valueOrNull ?? const <MediaItem>[]);
    final index = current.indexWhere((e) => e.id == id);
    if (index >= 0) await removeQueueItemAt(index);
  }

  Future<void> updateQueueItem(int index, MediaItem updated) async {
    if (index < 0 || index >= _playlist.length) return;
    // Replace audio source at index to update tag
    final old = _playlist.children[index] as UriAudioSource;
    final uri = old.uri;
    await _playlist.removeAt(index);
    await _playlist.insert(index, AudioSource.uri(uri, tag: updated));

    final current = List<MediaItem>.from(queue.valueOrNull ?? const <MediaItem>[]);
    current[index] = updated;
    queue.add(current);

    if (_player.currentIndex == index) {
      mediaItem.add(updated);
    }
  }

  Future<void> reorderQueueItem(int oldIndex, int newIndex) async {
    print('=== REORDERING QUEUE ITEM ===');
    print('Old index: $oldIndex, New index: $newIndex');
    
    if (oldIndex < 0 || oldIndex >= _playlist.length) {
      print('Invalid old index: $oldIndex');
      return;
    }
    if (newIndex < 0 || newIndex >= _playlist.length) {
      print('Invalid new index: $newIndex');
      return;
    }
    if (oldIndex == newIndex) {
      print('Same index, no change needed');
      return;
    }

    // Get current queue
    final currentQueue = List<MediaItem>.from(queue.valueOrNull ?? const <MediaItem>[]);
    print('Current queue length: ${currentQueue.length}');
    
    if (oldIndex >= currentQueue.length || newIndex >= currentQueue.length) {
      print('Index out of bounds');
      return;
    }

    // Reorder the MediaItem
    final item = currentQueue.removeAt(oldIndex);
    currentQueue.insert(newIndex, item);
    print('Moved item: ${item.title} from $oldIndex to $newIndex');

    // Reorder the audio source
    final audioSource = _playlist.children[oldIndex];
    await _playlist.removeAt(oldIndex);
    await _playlist.insert(newIndex, audioSource);

    // Update the queue
    queue.add(currentQueue);
    print('Updated queue with ${currentQueue.length} items');

    // Queue order saving removed - queue is now temporary
    print('=== REORDERING COMPLETE ===');
    
    // Set manual order flag to prevent auto-sorting
    // This will be handled by the main.dart file
  }

  Future<void> reorderQueue(List<MediaItem> newOrder) async {
    print('=== REORDERING ENTIRE QUEUE ===');
    print('New order length: ${newOrder.length}');
    
    if (newOrder.isEmpty) {
      print('Empty queue, nothing to reorder');
      return;
    }

    // Clear current playlist and rebuild with new order
    await _playlist.clear();
    
    // Add audio sources in new order
    for (final item in newOrder) {
      final uri = item.extras?['uri'] as String?;
      if (uri != null) {
        await _playlist.add(AudioSource.uri(Uri.parse(uri), tag: item));
      }
    }

    // Update the queue
    queue.add(newOrder);
    print('Updated queue with ${newOrder.length} items');

    // Queue order saving removed - queue is now temporary
    print('=== REORDERING COMPLETE ===');
  }

  Future<void> clearQueue() async {
    await _playlist.clear();
    queue.add(const []);
    
    // Queue order file deletion removed - queue is now temporary
    print('Queue cleared (temporary)');
    
    await stop();
  }

  Future<void> clearQueueWithoutSaving() async {
    await _playlist.clear();
    queue.add(const []);
    await stop();
  }

  PlaybackState _transformEvent(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        _player.playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      // We expose only previous, play/pause, next to avoid a "white square" stop icon
      androidCompactActionIndices: const [0, 1, 2],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_player.processingState]!,
      playing: _player.playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: _player.currentIndex,
      shuffleMode: _currentShuffleMode,
      repeatMode: {
        LoopMode.off: AudioServiceRepeatMode.none,
        LoopMode.one: AudioServiceRepeatMode.one,
        LoopMode.all: AudioServiceRepeatMode.all,
      }[_player.loopMode]!,
      // Provide an explicit timestamp so clients (notification/UI) can correctly compute
      // the elapsed position based on updatePosition and playback speed/state
      updateTime: DateTime.now(),
    );
  }

  MediaItem? _getMediaItemAt(int index) {
    final currentQueue = queue.valueOrNull ?? const [];
    if (index < 0 || index >= currentQueue.length) return null;
    return currentQueue[index];
  }

  // Method to restore playlist order from JSON
  Future<void> restorePlaylistOrder(String playlistName) async {
    try {
      final playlists = await _playlistsService.load();
      final playlistEntries = playlists[playlistName];
      if (playlistEntries != null && playlistEntries.isNotEmpty) {
        final playlistItems = playlistEntries.map((entry) => entry.toMediaItem()).toList();
        queue.add(playlistItems);
        await _rebuildPlaylistWithOrder(playlistItems);
        print('=== RESTORED PLAYLIST ORDER FROM JSON ===');
        print('Playlist: $playlistName, Items: ${playlistItems.map((e) => e.title).toList()}');
      }
    } catch (e) {
      print('Error restoring playlist order from JSON: $e');
    }
  }

  // Move first song to last when advancing to second song
  Future<void> _moveFirstSongToLast() async {
    try {
      final currentQueue = List<MediaItem>.from(queue.valueOrNull ?? []);
      if (currentQueue.length <= 1) {
        _isMovingFirstSong = false; // Reset flag
        return; // Nothing to move if only one song
      }
      
      // Check if shuffle mode is enabled
      final isShuffleEnabled = _currentShuffleMode == AudioServiceShuffleMode.all;
      
      // Remove first song (completed song) and add to end
      final completedSong = currentQueue.removeAt(0);
      currentQueue.add(completedSong);
      
      // Update queue first
      queue.add(currentQueue);
      
      // Rebuild playlist with new order
      await _rebuildPlaylistWithOrder(currentQueue);
      
      // Get current item without seeking (more efficient)
      final newCurrentItem = _getMediaItemAt(0);
      if (newCurrentItem != null) {
        mediaItem.add(newCurrentItem);
      }
      
      print('=== MOVED COMPLETED SONG TO LAST ===');
      print('Shuffle mode: $isShuffleEnabled');
      print('Moved completed song: ${completedSong.title}');
      print('New queue: ${currentQueue.map((e) => e.title).toList()}');
      print('Current song: ${newCurrentItem?.title ?? 'None'}');
      print('Next song: ${currentQueue.length > 1 ? currentQueue[1].title : 'None'}');
    } catch (e) {
      print('Error moving completed song to last: $e');
    } finally {
      _isMovingFirstSong = false; // Reset flag
    }
  }

  // Removed _saveQueueOrder and _loadQueueOrder - queue is now temporary
}

Future<JupotifyAudioHandler> initAudioHandler() async {
  return await AudioService.init(
    builder: () => JupotifyAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.example.jupotify.audio',
      androidNotificationChannelName: 'Jupotify Playback',
      androidNotificationIcon: 'drawable/ic_notification',
      androidShowNotificationBadge: true,
      androidStopForegroundOnPause: true,
    ),
  );
}


