import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Windows용 간단한 오디오 핸들러
/// audioplayers 플러그인을 사용하여 Windows에서 오디오 재생
/// JupotifyAudioHandler와 호환되는 인터페이스 제공
class WindowsAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final AudioPlayer _player = AudioPlayer();
  final List<MediaItem> _queue = [];
  int _currentIndex = 0;
  Timer? _positionTimer;
  
  // Shuffle and repeat mode tracking
  AudioServiceShuffleMode _shuffleMode = AudioServiceShuffleMode.none;
  AudioServiceRepeatMode _repeatMode = AudioServiceRepeatMode.none;
  
  // Position tracking
  Duration _currentPosition = Duration.zero;
  Duration _currentDuration = Duration.zero;
  
  // Stream controllers for compatibility
  final StreamController<AudioServiceShuffleMode> _shuffleModeController = StreamController<AudioServiceShuffleMode>.broadcast();
  final StreamController<AudioServiceRepeatMode> _repeatModeController = StreamController<AudioServiceRepeatMode>.broadcast();

  WindowsAudioHandler() {
    _init();
  }

  Future<void> _init() async {
    print('WindowsAudioHandler: Initializing for Windows platform');
    
    // 초기 상태 설정
    _updatePlaybackState();

    // 플레이어 상태 변화 감지
    _player.onPlayerStateChanged.listen((PlayerState state) {
      _updatePlaybackState();
    });

    // 위치 변화 감지
    _player.onPositionChanged.listen((Duration position) {
      _currentPosition = position;
      _updatePlaybackState();
    });

    // 지속시간 변화 감지
    _player.onDurationChanged.listen((Duration duration) {
      _currentDuration = duration;
      // 현재 미디어 아이템의 지속시간 업데이트
      if (_currentIndex < _queue.length) {
        final currentItem = _queue[_currentIndex];
        final updatedItem = currentItem.copyWith(duration: duration);
        _queue[_currentIndex] = updatedItem;
        mediaItem.add(updatedItem);
      }
      _updatePlaybackState();
    });


    _player.onPlayerComplete.listen((_) {
      skipToNext();
    });
  }


  AudioProcessingState _getProcessingState(PlayerState state) {
    switch (state) {
      case PlayerState.stopped:
        return AudioProcessingState.idle;
      case PlayerState.playing:
        return AudioProcessingState.ready;
      case PlayerState.paused:
        return AudioProcessingState.ready;
      case PlayerState.completed:
        return AudioProcessingState.completed;
      default:
        return AudioProcessingState.idle;
    }
  }


  @override
  Future<void> addQueueItems(List<MediaItem> mediaItems) async {
    print('WindowsAudioHandler: Adding ${mediaItems.length} items to queue');
    _queue.clear();
    _queue.addAll(mediaItems);
    queue.add(_queue);
    
    if (_queue.isNotEmpty) {
      _currentIndex = 0;
      mediaItem.add(_queue[_currentIndex]);
    }
  }

  @override
  Future<void> play() async {
    print('WindowsAudioHandler: play() called, queue length: ${_queue.length}');
    
    if (_queue.isEmpty) {
      print('WindowsAudioHandler: No items in queue');
      return;
    }

    try {
      final currentItem = _queue[_currentIndex];
      print('WindowsAudioHandler: Playing ${currentItem.title}');
      print('WindowsAudioHandler: File path: ${currentItem.id}');
      
      // 파일 존재 확인
      final file = File(currentItem.id);
      if (!await file.exists()) {
        print('WindowsAudioHandler: File does not exist: ${currentItem.id}');
        return;
      }

      await _player.play(DeviceFileSource(currentItem.id));
      print('WindowsAudioHandler: Playback started successfully');
    } catch (e) {
      print('WindowsAudioHandler: Error in play(): $e');
    }
  }

  @override
  Future<void> pause() async {
    print('WindowsAudioHandler: Pausing playback');
    await _player.pause();
  }

  @override
  Future<void> stop() async {
    print('WindowsAudioHandler: Stopping playback');
    await _player.stop();
  }


  @override
  Future<void> skipToNext() async {
    print('WindowsAudioHandler: Skipping to next');
    if (_currentIndex < _queue.length - 1) {
      _currentIndex++;
      mediaItem.add(_queue[_currentIndex]);
      await play();
    }
  }

  @override
  Future<void> skipToPrevious() async {
    print('WindowsAudioHandler: Skipping to previous');
    if (_currentIndex > 0) {
      _currentIndex--;
      mediaItem.add(_queue[_currentIndex]);
      await play();
    }
  }

  @override
  Future<void> seek(Duration position) async {
    print('WindowsAudioHandler: Seeking to $position');
    await _player.seek(position);
    _currentPosition = position;
    _updatePlaybackState();
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    print('WindowsAudioHandler: Skipping to queue item $index');
    if (index >= 0 && index < _queue.length) {
      _currentIndex = index;
      mediaItem.add(_queue[_currentIndex]);
      await play();
    }
  }

  @override
  Future<void> removeQueueItemAt(int index) async {
    if (index >= 0 && index < _queue.length) {
      _queue.removeAt(index);
      queue.add(_queue);
      
      if (_currentIndex >= _queue.length && _queue.isNotEmpty) {
        _currentIndex = _queue.length - 1;
      }
      
      if (_queue.isNotEmpty && _currentIndex >= 0) {
        mediaItem.add(_queue[_currentIndex]);
      }
    }
  }

  // JupotifyAudioHandler 호환성을 위한 추가 메서드들
  
  /// 현재 재생 위치 스트림 (JupotifyAudioHandler 호환)
  Stream<Duration> get positionStream {
    return Stream.periodic(const Duration(milliseconds: 200), (_) {
      return _currentPosition;
    });
  }

  /// 큐에 단일 아이템 추가 (JupotifyAudioHandler 호환)
  Future<void> addQueueItem(MediaItem mediaItem) async {
    await addQueueItems([mediaItem]);
  }

  /// 큐 아이템을 특정 위치로 이동 (JupotifyAudioHandler 호환)
  Future<void> moveQueueItem(int currentIndex, int newIndex) async {
    if (currentIndex >= 0 && currentIndex < _queue.length &&
        newIndex >= 0 && newIndex < _queue.length) {
      final item = _queue.removeAt(currentIndex);
      _queue.insert(newIndex, item);
      queue.add(_queue);
      
      // 현재 재생 중인 인덱스 조정
      if (_currentIndex == currentIndex) {
        _currentIndex = newIndex;
      } else if (_currentIndex > currentIndex && _currentIndex <= newIndex) {
        _currentIndex--;
      } else if (_currentIndex < currentIndex && _currentIndex >= newIndex) {
        _currentIndex++;
      }
    }
  }

  /// 큐 전체 교체 (JupotifyAudioHandler 호환)
  Future<void> updateQueue(List<MediaItem> newQueue) async {
    await addQueueItems(newQueue);
  }

  /// 현재 재생 상태 확인 (JupotifyAudioHandler 호환)
  bool get isPlaying {
    return _player.state == PlayerState.playing;
  }

  /// 현재 재생 위치 (JupotifyAudioHandler 호환)
  Duration get currentPosition {
    return _currentPosition;
  }

  /// 현재 미디어 아이템의 지속 시간 (JupotifyAudioHandler 호환)
  Duration? get currentDuration {
    return _currentDuration.inMilliseconds > 0 ? _currentDuration : mediaItem.valueOrNull?.duration;
  }

  /// 재생 상태 변경 이벤트 스트림 (JupotifyAudioHandler 호환)
  Stream<bool> get playingStream {
    return super.playbackState.map((state) => state.playing);
  }

  /// JupotifyAudioHandler와 동일한 인터페이스 제공
  /// 현재 재생 위치 (position과 동일)
  Duration get position => _currentPosition;
  
  /// 현재 미디어 지속시간 (duration getter)
  Duration? get duration => _currentDuration.inMilliseconds > 0 ? _currentDuration : null;
  
  /// 지속시간 스트림 (JupotifyAudioHandler 호환)
  Stream<Duration?> get durationStream {
    return Stream.periodic(const Duration(milliseconds: 500), (_) {
      return duration;
    });
  }


  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    _shuffleMode = shuffleMode;
    _shuffleModeController.add(_shuffleMode);
    
    // Windows에서는 간단한 셔플 모드만 지원
    if (shuffleMode == AudioServiceShuffleMode.all && _queue.length > 1) {
      // 현재 재생 중인 곡을 제외하고 나머지를 셔플
      final currentItem = _currentIndex < _queue.length ? _queue[_currentIndex] : null;
      final otherItems = List<MediaItem>.from(_queue);
      if (currentItem != null) {
        otherItems.removeAt(_currentIndex);
        otherItems.shuffle();
        _queue.clear();
        _queue.add(currentItem);
        _queue.addAll(otherItems);
        _currentIndex = 0;
        queue.add(_queue);
      }
    }
    _updatePlaybackState();
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    _repeatMode = repeatMode;
    _repeatModeController.add(_repeatMode);
    _updatePlaybackState();
  }

  void _updatePlaybackState() {
    super.playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        _player.state == PlayerState.playing
            ? MediaControl.pause
            : MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: _getProcessingState(_player.state),
      playing: _player.state == PlayerState.playing,
      updatePosition: _currentPosition, // 실제 재생 위치 사용
      bufferedPosition: _currentPosition, // 간단한 구현을 위해 현재 위치와 동일하게 설정
      speed: 1.0,
      shuffleMode: _shuffleMode,
      repeatMode: _repeatMode,
      queueIndex: _currentIndex,
    ));
  }

  void dispose() {
    _positionTimer?.cancel();
    _player.dispose();
    _shuffleModeController.close();
    _repeatModeController.close();
  }
}
