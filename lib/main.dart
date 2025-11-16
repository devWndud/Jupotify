import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audio_service/audio_service.dart';
import 'services/favorites.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import 'dart:math' as math;
import 'dart:convert';
import 'package:permission_handler/permission_handler.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:rxdart/rxdart.dart';

import 'audio/audio_handler.dart';
import 'services/youtube_downloader.dart';
import 'services/playlists.dart';
import 'services/notification_service.dart';
// import 'services/version_checker.dart';
// import 'widgets/update_dialog.dart';
import 'package:home_widget/home_widget.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_init.dart';

// 다국어 지원
class AppLocalizations {
  static const Map<String, Map<String, String>> _localizedValues = {
    'en': {
      'goodMorning': 'Good morning',
      'hi': 'Hi',
      'search': 'Search',
      'yourLibrary': 'Your Library',
      'recentlyPlayed': 'Recently Played',
      'quickAccess': 'Quick Access',
      'searchMusic': 'Search Music',
      'findNewSongs': 'Find new songs',
      'browseCollection': 'Browse collection',
      'download': 'Download',
      'getFromYouTube': 'Get from YouTube',
      'importPlaylist': 'Import Playlist',
      'youtubeUrl': 'YouTube URL',
      'settings': 'Settings',
      'language': 'Language',
      'nickname': 'Nickname',
      'enterNickname': 'Enter your nickname',
      'saveSettings': 'Save Settings',
      'english': 'English',
      'korean': '한국어',
      'recentSearches': 'Recent searches',
      'clearAll': 'Clear all',
      'noSearchHistory': 'No search history',
      'searchHintHistory': 'Search for music to see your history here',
      'selectAll': 'Select All',
    },
    'ko': {
      'goodMorning': '좋은 아침이에요',
      'hi': '안녕하세요',
      'search': '검색',
      'yourLibrary': '라이브러리',
      'recentlyPlayed': '최근 재생',
      'quickAccess': '바로가기',
      'searchMusic': '음악 찾기',
      'findNewSongs': '새 노래 찾아보기',
      'browseCollection': '모두 보기',
      'download': '다운로드',
      'getFromYouTube': 'YouTube에서 받기',
      'importPlaylist': '재생목록 불러오기',
      'youtubeUrl': 'YouTube URL',
      'settings': '설정',
      'language': '언어',
      'nickname': '이름',
      'enterNickname': '이름을 입력하세요',
      'saveSettings': '설정 완료',
      'english': 'English',
      'korean': '한국어',
      'recentSearches': '최근 검색',
      'clearAll': '모두 지우기',
      'noSearchHistory': '최근 검색이 없어요',
      'searchHintHistory': '음악을 검색하면 최근 검색에 표시돼요',
      'selectAll': '전체 선택',
    },
  };

  static String getText(String key, String language) {
    return _localizedValues[language]?[key] ?? _localizedValues['en']![key]!;
  }
}

JupotifyAudioHandler? _globalAudioHandler; // for widget background control
// Removed _globalManualOrder - library order is now independent of queue

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initFirebase();
  runApp(const JupotifyApp());
}

class JupotifyApp extends StatefulWidget {
  const JupotifyApp({super.key});

  @override
  State<JupotifyApp> createState() => _JupotifyAppState();
}

class _JupotifyAppState extends State<JupotifyApp> with WidgetsBindingObserver {
  late final Future<JupotifyAudioHandler> _audioHandlerFuture;
  bool _isActivated = true;
  bool _isLoading = true;
  static const _idleChannel = MethodChannel('com.example.jupotify/idle');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HomeWidget.registerBackgroundCallback(_backgroundCallback);
    NotificationService.initialize();
    _audioHandlerFuture = initAudioHandler();
    _audioHandlerFuture.then((h) {
      _globalAudioHandler = h;
      // App activation gate disabled; mark loading complete immediately
      if (mounted) {
        setState(() { _isLoading = false; });
      } else {
        _isLoading = false;
      }
      _tryResumeLastPlayback();
    }).catchError((e) {
      // Ensure we don't get stuck on loading even if init fails
      if (mounted) {
        setState(() { _isLoading = false; });
      } else {
        _isLoading = false;
      }
    });
    // Handle widget button clicks when app is brought to foreground
    HomeWidget.widgetClicked.listen(_onWidgetClick);
    
    // Disabled: app version check on startup
  }

  Future<void> _tryResumeLastPlayback() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = prefs.getString('last_track_id');
      final posMs = prefs.getInt('last_position_ms');
      final savedAt = prefs.getInt('last_saved_at');
      
      // Only resume if saved within last 24 hours
      if (id == null || id.isEmpty) return;
      if (savedAt != null) {
        final now = DateTime.now().millisecondsSinceEpoch;
        final hoursSinceSave = (now - savedAt) / (1000 * 60 * 60);
        if (hoursSinceSave > 24) return; // Don't resume if too old
      }
      
      final handler = _globalAudioHandler;
      if (handler == null) return;

      // Wait for library to be fully loaded first
      await _waitForLibraryLoad();
      
      // Load saved queue from JSON
      await _loadSavedQueue(handler);
      
      // Find item in current queue
      final queue = handler.queue.valueOrNull ?? const <MediaItem>[];
      final index = queue.indexWhere((m) => m.id == id);
      if (index < 0) return;

      // Move that song to front and seek to saved position (but don't play)
      final savedPosition = posMs != null && posMs > 0 ? Duration(milliseconds: posMs) : null;
      await handler.skipToQueueItemWithPosition(index, savedPosition);
      // Don't auto-play - let user press play button when ready
    } catch (_) {}
  }

  Future<void> _waitForLibraryLoad() async {
    // Wait a bit for library scanning to complete
    await Future.delayed(const Duration(seconds: 2));
  }

  Future<void> _loadSavedQueue(JupotifyAudioHandler handler) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final queueJson = prefs.getString('saved_queue');
      if (queueJson == null || queueJson.isEmpty) return;
      
      final List<dynamic> queueData = jsonDecode(queueJson);
      final List<MediaItem> savedQueue = queueData.map((item) => MediaItem(
        id: item['id'] ?? '',
        title: item['title'] ?? '',
        artist: item['artist'],
        album: item['album'],
        duration: item['duration'] != null ? Duration(milliseconds: item['duration']) : null,
        artUri: item['artUri'] != null ? Uri.parse(item['artUri']) : null,
        extras: item['extras']?.cast<String, dynamic>() ?? {},
      )).toList();
      
      if (savedQueue.isNotEmpty) {
        await handler.clearQueueWithoutSaving();
        await handler.addQueueItems(savedQueue);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    final handler = _globalAudioHandler;
    if (handler == null) return;
    if (state == AppLifecycleState.paused) {
      await _persistPlaybackState(handler);
      // Schedule kill if not playing
      final playing = handler.playbackState.value.playing;
      try {
        if (!playing) {
          await _idleChannel.invokeMethod('scheduleIdleKill', {
            'isPlaying': false,
          });
        } else {
          await _idleChannel.invokeMethod('cancelIdleKill');
        }
      } catch (_) {}
    }
    if (state == AppLifecycleState.detached) {
      await _persistPlaybackState(handler);
      try {
        await handler.stop();
      } catch (_) {}
    }
  }

  Future<void> _persistPlaybackState(JupotifyAudioHandler handler) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final item = handler.mediaItem.valueOrNull;
      final pos = handler.playbackState.value.updatePosition;
      final queue = handler.queue.valueOrNull ?? const <MediaItem>[];
      
      if (item != null) {
        await prefs.setString('last_track_id', item.id);
        await prefs.setString('last_track_title', item.title);
        await prefs.setString('last_track_artist', item.artist ?? '');
        await prefs.setInt('last_position_ms', pos.inMilliseconds);
        await prefs.setInt('last_saved_at', DateTime.now().millisecondsSinceEpoch);
        
        // Save current queue as JSON
        final queueJson = jsonEncode(queue.map((item) => {
          'id': item.id,
          'title': item.title,
          'artist': item.artist,
          'album': item.album,
          'duration': item.duration?.inMilliseconds,
          'artUri': item.artUri?.toString(),
          'extras': item.extras,
        }).toList());
        await prefs.setString('saved_queue', queueJson);
      }
    } catch (_) {}
  }

  // Handle widget button broadcasts in background
  static Future<void> _backgroundCallback(Uri? uri) async {
    final action = uri?.host ?? '';
    final handler = _globalAudioHandler;
    if (handler == null) return;
    switch (action) {
      case 'ACTION_PREV':
        await handler.skipToPrevious();
        break;
      case 'ACTION_TOGGLE':
        final playing = handler.playbackState.value.playing;
        if (playing) {
          await handler.pause();
          // Save state when pausing
          await _persistPlaybackStateStatic(handler);
        } else {
          await handler.play();
        }
        break;
      case 'ACTION_NEXT':
        try {
          await handler.skipToNext();
        } catch (e) {
          print('Error in notification skipToNext: $e');
        }
        break;
    }
  }

  static Future<void> _persistPlaybackStateStatic(JupotifyAudioHandler handler) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final item = handler.mediaItem.valueOrNull;
      final pos = handler.playbackState.value.updatePosition;
      final queue = handler.queue.valueOrNull ?? const <MediaItem>[];
      
      if (item != null) {
        await prefs.setString('last_track_id', item.id);
        await prefs.setString('last_track_title', item.title);
        await prefs.setString('last_track_artist', item.artist ?? '');
        await prefs.setInt('last_position_ms', pos.inMilliseconds);
        await prefs.setInt('last_saved_at', DateTime.now().millisecondsSinceEpoch);
        
        // Save current queue as JSON
        final queueJson = jsonEncode(queue.map((item) => {
          'id': item.id,
          'title': item.title,
          'artist': item.artist,
          'album': item.album,
          'duration': item.duration?.inMilliseconds,
          'artUri': item.artUri?.toString(),
          'extras': item.extras,
        }).toList());
        await prefs.setString('saved_queue', queueJson);
      }
    } catch (_) {}
  }


  void _onWidgetClick(Uri? uri) async {
    final action = uri?.host ?? '';
    final handler = _globalAudioHandler;
    if (handler == null) return;
    switch (action) {
      case 'ACTION_PREV':
        await handler.skipToPrevious();
        break;
      case 'ACTION_TOGGLE':
        final playing = handler.playbackState.value.playing;
        if (playing) {
          await handler.pause();
          // Save state when pausing
          await _persistPlaybackState(handler);
        } else {
          await handler.play();
        }
        break;
      case 'ACTION_NEXT':
        try {
          await handler.skipToNext();
        } catch (e) {
          print('Error in notification skipToNext: $e');
        }
        break;
    }
  }

  Future<void> _checkActivationStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final isActivated = prefs.getBool('app_activated') ?? false;
    
    // Load saved queue order if app is activated
    if (isActivated) {
      print('App is activated, loading saved queue order...');
      await _loadSavedQueueOrder();
      print('Queue order loading completed');
    } else {
      print('App not activated, skipping queue order load');
    }
    
    setState(() {
      _isActivated = isActivated;
      _isLoading = false;
    });
    
    if (isActivated && Platform.isAndroid) {
      final shown = prefs.getBool('battery_prompt_shown') ?? false;
      if (!shown) {
        // Wait until a frame is rendered to show dialog safely
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showBatteryOptimizationPrompt(context);
        });
        await prefs.setBool('battery_prompt_shown', true);
      }
    }
  }

  // Update check disabled per user request
  // Future<void> _checkForUpdates() async {}

  Future<void> _activateApp() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('app_activated', true);
    setState(() {
      _isActivated = true;
    });
    // After activation, prompt to disable battery optimization on Android
    if (Platform.isAndroid) {
      _showBatteryOptimizationPrompt(context);
    }
  }

  Future<void> _loadSavedQueueOrder() async {
    // NOTE: Removed queue order restoration to completely separate queue from library
    // Queue is now temporary and independent of library order
    print('Queue and library are now completely separated');
    
    try {
      // Queue restoration removed - queue is now temporary
      
      // Queue restoration removed - queue is now temporary
      print('Queue restoration disabled - queue is now independent of library');
      
      // All queue restoration logic removed
      print('Queue restoration completely disabled');
    } catch (e, stackTrace) {
      print('Error loading saved queue order: $e');
      print('Stack trace: $stackTrace');
    }
  }
  
  Future<void> _loadDurationsForQueue(JupotifyAudioHandler handler) async {
    final queue = handler.queue.valueOrNull ?? const <MediaItem>[];
    if (queue.isEmpty) return;
    
    print('Loading durations for ${queue.length} items...');
    
    for (final item in queue) {
      if (item.duration != null) continue;
      
      final uri = item.extras?['uri'] as String?;
      if (uri == null) continue;
      
      final player = AudioPlayer();
      try {
        Duration? d;
        if (item.id.isNotEmpty) {
          try {
            d = await player.setFilePath(item.id, preload: false);
          } catch (_) {}
        }
        d ??= await player.setUrl(uri);
        
        if (d != null) {
          final index = queue.indexWhere((e) => e.id == item.id);
          if (index >= 0) {
            await handler.updateQueueItem(index, item.copyWith(duration: d));
            print('Loaded duration for ${item.title}: ${_formatDuration(d)}');
          }
        }
      } catch (_) {
        // ignore probe failures
      } finally {
        await player.dispose();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final baseDark = ThemeData.dark(useMaterial3: true);
    final theme = baseDark.copyWith(
      colorScheme: baseDark.colorScheme.copyWith(
        primary: Colors.white,
        secondary: Colors.white,
      ),
      scaffoldBackgroundColor: const Color(0xFF121212),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF121212),
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: Color(0xFF181818),
        selectedItemColor: Colors.white,
        unselectedItemColor: Color(0xFFB3B3B3),
        showUnselectedLabels: true,
        type: BottomNavigationBarType.fixed,
      ),
    );

    if (_isLoading) {
    return MaterialApp(
        title: 'Jupotify',
        theme: theme,
        home: const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ),
      );
    }


    return MaterialApp(
      title: 'Jupotify',
      theme: theme,
      home: FutureBuilder<JupotifyAudioHandler>(
        future: _audioHandlerFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          if (snapshot.hasError) {
            return Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('Audio init failed:\n${snapshot.error}', textAlign: TextAlign.center),
                ),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          final handler = snapshot.data!;
          return _AuthGate(handler: handler);
        },
      ),
    );
  }

  Future<void> _showBatteryOptimizationPrompt(BuildContext context) async {
    showDialog(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: const Text('배터리 최적화 해제 권장'),
          content: const Text('백그라운드 재생이 중단되지 않도록 설정에서 Jupotify를 배터리 최적화 제외로 설정해 주세요.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('나중에'),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.of(context).pop();
                try {
                  const intent = AndroidIntent(
                    action: 'android.settings.IGNORE_BATTERY_OPTIMIZATION_SETTINGS',
                  );
                  await intent.launch();
                } catch (_) {}
              },
              child: const Text('설정 열기'),
            ),
          ],
        );
      },
    );
  }
}
class _AuthGate extends StatefulWidget {
  final JupotifyAudioHandler handler;
  const _AuthGate({required this.handler});
  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  bool _showSignup = false;

  @override
  Widget build(BuildContext context) {
    return _RootScaffold(handler: widget.handler);
  }
}

 


class _RootScaffold extends StatefulWidget {
  final JupotifyAudioHandler handler;
  const _RootScaffold({required this.handler});

  @override
  State<_RootScaffold> createState() => _RootScaffoldState();
}

class _RootScaffoldState extends State<_RootScaffold> {
  int _currentIndex = 0;
  late final PageController _pageController;
  String? _selectedPlaylist; // Currently selected playlist
  
  List<Widget> get _tabs => [
    _HomeTab(
      handler: widget.handler, 
      goTab: (i) => setState(() => _currentIndex = i),
      onPlaylistSelected: (playlist) => setState(() => _selectedPlaylist = playlist),
    ),
    _SearchTab(handler: widget.handler),
    _LibraryTab(
      handler: widget.handler,
      selectedPlaylist: _selectedPlaylist,
      onPlaylistSelected: (playlist) => setState(() => _selectedPlaylist = playlist),
    ),
  ];

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: 0);
    // Update Android home widget when the current media item changes
    widget.handler.mediaItem.listen((item) async {
      try {
        await HomeWidget.saveWidgetData<String>('title', item?.title ?? 'Jupotify');
        final art = item?.artUri?.toString();
        await HomeWidget.saveWidgetData<String>('art', art ?? '');
        await HomeWidget.updateWidget(androidName: 'HomeWidgetProvider');
      } catch (_) {}
    });
    // Update play/pause status for widget
    widget.handler.playbackState.listen((state) async {
      try {
        final isPlaying = state.playing;
        await HomeWidget.saveWidgetData<int>('isPlaying', isPlaying ? 1 : 0);
        await HomeWidget.updateWidget(androidName: 'HomeWidgetProvider');
      } catch (_) {}
    });
    // Position/progress syncing removed (widget no longer shows progress)
    // On first load, scan default download folder and hydrate queue
    // Run in microtask to avoid build timing issues
    Future.microtask(() async {
      final ok = await _ensureStoragePermission();
      if (!ok) return;
      // Don't block first frame; hydrate queue in background
      // ignore: unawaited_futures
      Future(() async {
        await _scanAndHydrateLibrary(widget.handler);
      });
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isTablet = screenWidth >= 768; // 태블릿 기준: 768px 이상
    
    return WillPopScope(
      onWillPop: () async {
        // If a playlist is selected, go back to all songs
        if (_selectedPlaylist != null) {
          setState(() => _selectedPlaylist = null);
          return false; // Prevent default back behavior
        }
        
        if (_currentIndex != 0) {
          setState(() => _currentIndex = 0);
          if (!isTablet) {
            _pageController.animateToPage(0, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
          }
          return false;
        }
        return true;
      },
      child: Scaffold(
        body: isTablet ? _buildTabletLayout() : _buildMobileLayout(),
        bottomNavigationBar: isTablet ? null : _buildBottomNavigationBar(),
      ),
    );
  }

  Widget _buildMobileLayout() {
    return Stack(
      children: [
        PageView(
          controller: _pageController,
          onPageChanged: (index) {
            setState(() => _currentIndex = index);
          },
          physics: _selectedPlaylist != null ? const NeverScrollableScrollPhysics() : const ClampingScrollPhysics(),
          allowImplicitScrolling: false,
          padEnds: false,
          children: _tabs,
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: StreamBuilder<MediaItem?>(
            stream: widget.handler.mediaItem,
            initialData: widget.handler.mediaItem.valueOrNull,
            builder: (context, snapshot) {
              if (snapshot.data == null) {
                return const SizedBox.shrink();
              }
              return _MiniPlayer(handler: widget.handler);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildTabletLayout() {
    return Row(
      children: [
        // 사이드바 (태블릿용)
        Container(
          width: 280,
          decoration: const BoxDecoration(
            color: Color(0xFF1A1A1A),
            border: Border(
              right: BorderSide(color: Color(0xFF333333), width: 1),
            ),
          ),
          child: Column(
            children: [
              // 로고/제목 영역
              Container(
                padding: const EdgeInsets.all(24),
                child: const Row(
                  children: [
                    Image(
                      image: AssetImage('assets/icon/app_icon.png'),
                      width: 32,
                      height: 32,
                    ),
                    SizedBox(width: 12),
                    Text(
                      'Jupotify',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(color: Color(0xFF333333), height: 1),
              // 네비게이션 메뉴
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  children: [
                    _TabletNavItem(
                      icon: Icons.home_filled,
                      title: 'Home',
                      isSelected: _currentIndex == 0,
                      onTap: () => setState(() => _currentIndex = 0),
                    ),
                    _TabletNavItem(
                      icon: Icons.search,
                      title: 'Search',
                      isSelected: _currentIndex == 1,
                      onTap: () => setState(() => _currentIndex = 1),
                    ),
                    _TabletNavItem(
                      icon: Icons.library_music,
                      title: 'Library',
                      isSelected: _currentIndex == 2,
                      onTap: () {
                        // If tapping Library tab and a playlist is selected, go back to all songs
                        if (_selectedPlaylist != null) {
                          setState(() {
                            _selectedPlaylist = null;
                          });
                        }
                        setState(() => _currentIndex = 2);
                      },
                    ),
                  ],
                ),
              ),
              // 미니 플레이어 (태블릿용)
              StreamBuilder<MediaItem?>(
                stream: widget.handler.mediaItem,
                initialData: widget.handler.mediaItem.valueOrNull,
                builder: (context, snapshot) {
                  if (snapshot.data == null) {
                    return const SizedBox.shrink();
                  }
                  return _TabletMiniPlayer(handler: widget.handler);
                },
              ),
            ],
          ),
        ),
        // 메인 콘텐츠 영역
        Expanded(
          child: Stack(
            children: [
              IndexedStack(
                index: _currentIndex,
                children: _tabs,
              ),
              // 태블릿용 플로팅 액션 버튼들
              if (_currentIndex == 0) // Home 탭에서만
                Positioned(
                  bottom: 24,
                  right: 24,
                  child: FloatingActionButton(
                    onPressed: () => _showDownloadDialog(),
                    backgroundColor: Colors.white,
                    child: const Icon(Icons.download, color: Colors.black),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBottomNavigationBar() {
    return BottomNavigationBar(
      currentIndex: _currentIndex,
      onTap: (i) {
        // If tapping Library tab and a playlist is selected, go back to all songs
        if (i == 2 && _selectedPlaylist != null) {
          setState(() {
            _selectedPlaylist = null;
          });
        }
        setState(() => _currentIndex = i);
        _pageController.animateToPage(i, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
      },
      type: BottomNavigationBarType.fixed,
      backgroundColor: Colors.black,
      selectedItemColor: Colors.white,
      unselectedItemColor: Colors.white54,
      iconSize: 28,
      selectedFontSize: 0,
      unselectedFontSize: 0,
      elevation: 0,
      items: const [
        BottomNavigationBarItem(
          icon: Icon(Icons.home_filled, size: 28),
          activeIcon: Icon(Icons.home_filled, size: 28),
          label: '',
          tooltip: 'Home',
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.search, size: 28),
          activeIcon: Icon(Icons.search, size: 28),
          label: '',
          tooltip: 'Search',
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.library_music, size: 28),
          activeIcon: Icon(Icons.library_music, size: 28),
          label: '',
          tooltip: 'Library',
        ),
      ],
    );
  }

  void _showDownloadDialog() {
    final screenWidth = MediaQuery.of(context).size.width;
    final isTablet = screenWidth >= 768;
    
    if (isTablet) {
      // 태블릿용 다이얼로그
      showDialog(
        context: context,
        builder: (context) => _TabletYouTubeDownloadDialog(handler: widget.handler),
      );
    } else {
      // 모바일용 바텀시트
      showModalBottomSheet(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        backgroundColor: const Color(0xFF121212),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (context) {
          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom + 16,
              left: 16,
              right: 16,
              top: 16,
            ),
            child: _YouTubeDownloadBar(
              onDownload: (result) {
                // 다운로드 완료 후 처리
                Navigator.of(context).pop();
              },
            ),
          );
        },
      );
    }
  }
}

// 태블릿용 YouTube 다운로드 다이얼로그
class _TabletYouTubeDownloadDialog extends StatefulWidget {
  final JupotifyAudioHandler handler;

  const _TabletYouTubeDownloadDialog({required this.handler});

  @override
  State<_TabletYouTubeDownloadDialog> createState() => _TabletYouTubeDownloadDialogState();
}

class _TabletYouTubeDownloadDialogState extends State<_TabletYouTubeDownloadDialog> {
  String _language = 'ko';
  final _controller = TextEditingController();
  double? _progress;
  bool _busy = false;
  String? _status;
  bool _useBackground = true;
  List<Video> _playlistVideos = [];
  Set<String> _selectedVideoIds = {};
  bool _isLoadingPlaylist = false;
  String _playlistTitle = '';
  final _playlistTitleController = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    _playlistTitleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Load saved language
    () async {
      final prefs = await SharedPreferences.getInstance();
      final savedLang = prefs.getString('app_language');
      if (mounted && savedLang != null && savedLang.isNotEmpty && savedLang != _language) {
        setState(() => _language = savedLang);
      }
    }();
    return Dialog(
      backgroundColor: const Color(0xFF121212),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: MediaQuery.of(context).size.width * 0.7,
        height: MediaQuery.of(context).size.height * 0.8,
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 헤더
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Download from YouTube',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, color: Colors.white),
                ),
              ],
            ),
            const SizedBox(height: 24),
            
            // URL 입력 필드
            TextField(
              controller: _controller,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Enter YouTube URL or playlist URL',
                hintStyle: TextStyle(color: Colors.white.withOpacity(0.6)),
                filled: true,
                fillColor: Colors.white.withOpacity(0.1),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                prefixIcon: const Icon(Icons.link, color: Colors.white70),
                suffixIcon: _busy
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        ),
                      )
                    : IconButton(
                        onPressed: _loadPlaylist,
                        icon: const Icon(Icons.search, color: Colors.white70),
                      ),
              ),
            ),
            const SizedBox(height: 16),
            
            // 플레이리스트 제목 (플레이리스트인 경우)
            if (_playlistVideos.isNotEmpty) ...[
              TextField(
                controller: _playlistTitleController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Playlist Title',
                  labelStyle: const TextStyle(color: Colors.white70),
                  filled: true,
                  fillColor: Colors.white.withOpacity(0.1),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            
            // 상태 표시
            if (_status != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info, color: Colors.blue, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _status!,
                        style: const TextStyle(color: Colors.blue),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            
            // 진행률 표시
            if (_progress != null) ...[
              LinearProgressIndicator(
                value: _progress,
                backgroundColor: Colors.white.withOpacity(0.2),
                valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
              ),
              const SizedBox(height: 16),
            ],
            
            // 비디오 목록
            if (_playlistVideos.isNotEmpty) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Videos (${_playlistVideos.length})',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Row(
                    children: [
                      TextButton.icon(
                        onPressed: _selectedVideoIds.length == _playlistVideos.length
                            ? _clearAll
                            : _selectAll,
                        icon: Icon(
                          _selectedVideoIds.length == _playlistVideos.length
                              ? Icons.clear_all
                              : Icons.select_all,
                          color: Colors.white70,
                        ),
                        label: Text(
                          _selectedVideoIds.length == _playlistVideos.length
                              ? AppLocalizations.getText('clearAll', _language)
                              : AppLocalizations.getText('selectAll', _language),
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView.builder(
                  itemCount: _playlistVideos.length,
                  itemBuilder: (context, index) {
                    final video = _playlistVideos[index];
                    final isSelected = _selectedVideoIds.contains(video.id.value);
                    
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: isSelected 
                            ? Colors.white.withOpacity(0.1)
                            : Colors.white.withOpacity(0.05),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isSelected 
                              ? Colors.white.withOpacity(0.3)
                              : Colors.white.withOpacity(0.1),
                        ),
                      ),
                      child: CheckboxListTile(
                        value: isSelected,
                        onChanged: (value) {
                          setState(() {
                            if (value == true) {
                              _selectedVideoIds.add(video.id.value);
                            } else {
                              _selectedVideoIds.remove(video.id.value);
                            }
                          });
                        },
                        title: Text(
                          video.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          video.author,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                        activeColor: Colors.white,
                        checkColor: Colors.white,
                      ),
                    );
                  },
                ),
              ),
            ],
            
            // 다운로드 버튼
            if (_selectedVideoIds.isNotEmpty) ...[
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: _busy ? null : _downloadSelected,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: _busy
                      ? const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                              ),
                            ),
                            SizedBox(width: 12),
                            Text('Downloading...'),
                          ],
                        )
                      : Text('Download Selected (${_selectedVideoIds.length})'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _loadPlaylist() async {
    final url = _controller.text.trim();
    if (url.isEmpty) return;

    setState(() {
      _busy = true;
      _status = null;
      _playlistVideos.clear();
      _selectedVideoIds.clear();
    });

    try {
      final yt = YoutubeExplode();
      
      if (url.contains('playlist')) {
        final playlist = await yt.playlists.get(url);
        _playlistTitleController.text = playlist.title;
        
        final videos = await yt.playlists.getVideos(playlist.id).toList();
        setState(() {
          _playlistVideos = videos;
          _selectedVideoIds = videos.map((v) => v.id.value).toSet();
          _status = 'Loaded ${videos.length} videos from "${playlist.title}"';
        });
      } else {
        final video = await yt.videos.get(url);
        setState(() {
          _playlistVideos = [video];
          _selectedVideoIds = {video.id.value};
          _status = 'Loaded video: "${video.title}"';
        });
      }
    } catch (e) {
      setState(() {
        _status = 'Error: $e';
      });
    } finally {
      setState(() {
        _busy = false;
      });
    }
  }

  void _selectAll() {
    setState(() {
      _selectedVideoIds = _playlistVideos.map((v) => v.id.value).toSet();
    });
  }

  void _clearAll() {
    setState(() {
      _selectedVideoIds.clear();
    });
  }

  Future<void> _downloadSelected() async {
    if (_selectedVideoIds.isEmpty) return;

    setState(() {
      _busy = true;
      _progress = 0;
    });

    try {
      final downloader = YouTubeDownloader();
      final selectedVideos = _playlistVideos
          .where((v) => _selectedVideoIds.contains(v.id.value))
          .toList();

      for (int i = 0; i < selectedVideos.length; i++) {
        final video = selectedVideos[i];
        setState(() {
          _status = 'Downloading: ${video.title}';
          _progress = i / selectedVideos.length;
        });

        // 권한 확인
        final hasPermission = await _ensureStoragePermission();
        if (!hasPermission) {
          setState(() {
            _status = 'Storage permission required. Please grant permission in settings.';
          });
          return;
        }

        // Ensure we have a valid video URL
        final videoUrl = video.url.isNotEmpty ? video.url : 'https://www.youtube.com/watch?v=${video.id.value}';
        final result = await downloader.downloadAudio(
          videoUrl,
          remoteServerBaseUrl: 'http://222.231.24.5:8080',
        );

        // 다운로드 성공 시 큐에 추가
        final mediaItem = MediaItem(
          id: result.file.path,
          title: result.title,
          artist: result.artist,
          duration: result.duration,
          artUri: result.artwork != null ? Uri.file(result.artwork!.path) : null,
          extras: {
            'uri': result.file.path,
            'file': result.file.path,
          },
        );
        widget.handler.addQueueItem(mediaItem);
      }

      setState(() {
        _status = 'Download completed!';
        _progress = 1.0;
      });

      // 2초 후 다이얼로그 닫기
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) {
          Navigator.of(context).pop();
        }
      });
    } catch (e) {
      setState(() {
        _status = 'Download error: $e';
      });
    } finally {
      setState(() {
        _busy = false;
      });
    }
  }
}

// 태블릿용 네비게이션 아이템
class _TabletNavItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool isSelected;
  final VoidCallback onTap;

  const _TabletNavItem({
    required this.icon,
    required this.title,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Material(
        color: isSelected ? Colors.white.withOpacity(0.1) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(
                  icon,
                  color: isSelected ? Colors.white : Colors.white70,
                  size: 24,
                ),
                const SizedBox(width: 16),
                Text(
                  title,
                  style: TextStyle(
                    color: isSelected ? Colors.white : Colors.white70,
                    fontSize: 16,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// 태블릿용 미니 플레이어
class _TabletMiniPlayer extends StatelessWidget {
  final JupotifyAudioHandler handler;

  const _TabletMiniPlayer({required this.handler});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<MediaItem?>(
      stream: handler.mediaItem,
      initialData: handler.mediaItem.valueOrNull,
      builder: (context, snapshot) {
        final mediaItem = snapshot.data;
        if (mediaItem == null) return const SizedBox.shrink();

        return Container(
          padding: const EdgeInsets.all(16),
          decoration: const BoxDecoration(
            border: Border(
              top: BorderSide(color: Color(0xFF333333), width: 1),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 현재 재생 중인 곡 정보
              Row(
                children: [
                  // 앨범 아트
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFF3E3E3E), Color(0xFF2A2A2A)],
                        ),
                      ),
                      child: mediaItem.artUri != null
                          ? _ArtworkImage(uri: mediaItem.artUri!)
                          : const Icon(
                              Icons.music_note,
                              color: Colors.white70,
                              size: 24,
                            ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 곡 정보
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          mediaItem.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          mediaItem.artist ?? 'Unknown Artist',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // 컨트롤 버튼들
              StreamBuilder<PlaybackState>(
                stream: handler.playbackState,
                initialData: handler.playbackState.valueOrNull,
                builder: (context, snapshot) {
                  final playbackState = snapshot.data;
                  final isPlaying = playbackState?.playing ?? false;

                  return Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      // 이전 곡
                      IconButton(
                        onPressed: () => handler.skipToPrevious(),
                        icon: const Icon(Icons.skip_previous, color: Colors.white),
                        iconSize: 24,
                      ),
                      // 재생/일시정지
                      Container(
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                        ),
                        child: IconButton(
                          onPressed: () {
                            if (isPlaying) {
                              handler.pause();
                            } else {
                              handler.play();
                            }
                          },
                          icon: Icon(
                            isPlaying ? Icons.pause : Icons.play_arrow,
                            color: Colors.black,
                          ),
                          iconSize: 24,
                        ),
                      ),
                      // 다음 곡
                      IconButton(
                        onPressed: () async {
                          try {
                            await handler.skipToNext();
                          } catch (e) {
                            print('Error in UI skipToNext: $e');
                          }
                        },
                        icon: const Icon(Icons.skip_next, color: Colors.white),
                        iconSize: 24,
                      ),
                      // 전체 플레이어 열기
                      IconButton(
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) => FullPlayerPage(handler: handler),
                            ),
                          );
                        },
                        icon: const Icon(Icons.fullscreen, color: Colors.white),
                        iconSize: 20,
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _HomeTab extends StatefulWidget {
  final JupotifyAudioHandler handler;
  final void Function(int tabIndex) goTab;
  final void Function(String? playlist)? onPlaylistSelected;
  const _HomeTab({
    required this.handler, 
    required this.goTab,
    this.onPlaylistSelected,
  });

  @override
  State<_HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<_HomeTab> with TickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  late AnimationController _fadeController;
  late AnimationController _slideController;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;
  String _nickname = 'User';
  String _language = 'ko';

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _slideController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    
    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    ));
    
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.3),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _slideController,
      curve: Curves.easeOut,
    )    );
    
    
    _fadeController.forward();
    _slideController.forward();
    _loadUserSettings();
  }

  Future<void> _loadUserSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final savedName = prefs.getString('user_nickname');
    final savedLang = prefs.getString('app_language');
    if (!mounted) return;
    setState(() {
      if (savedName != null && savedName.isNotEmpty) {
        _nickname = savedName;
      }
      if (savedLang != null && savedLang.isNotEmpty) _language = savedLang;
    });
  }

  void _notifyLanguageChange() {
    // This will trigger rebuild of all tabs that depend on _language
    setState(() {});
  }

  @override
  void dispose() {
    _fadeController.dispose();
    _slideController.dispose();
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1A1A1A), Color(0xFF000000)],
          ),
        ),
        child: CustomScrollView(
          slivers: [
            // Modern App Bar that disappears on scroll
            SliverAppBar(
              expandedHeight: 80,
              floating: true,
              pinned: false,
              backgroundColor: Colors.transparent,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              forceElevated: false,
              flexibleSpace: FlexibleSpaceBar(
                titlePadding: EdgeInsets.zero,
                background: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xFF1A1A1A), Color(0xFF000000)],
                    ),
                  ),
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              Text(
                                '${AppLocalizations.getText('hi', _language)}, $_nickname',
                                style: const TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                              ),
                              const Spacer(),
                              GestureDetector(
                                onTap: () async {
                                  final result = await Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (context) => SettingsScreen(
                                        currentNickname: _nickname,
                                        currentLanguage: _language,
                                      ),
                                    ),
                                  );
                                  if (result != null && result is Map<String, String>) {
                                    setState(() {
                                      _nickname = result['nickname'] ?? _nickname;
                                      _language = result['language'] ?? _language;
                                    });
                                    // Persist settings
                                    final prefs = await SharedPreferences.getInstance();
                                    await prefs.setString('user_nickname', _nickname);
                                    await prefs.setString('app_language', _language);
                                    // Force rebuild of all tabs
                                    _notifyLanguageChange();
                                  }
                                },
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: const Icon(
                                    Icons.settings_outlined,
                                    color: Colors.white,
                                    size: 24,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            
            // Content
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  AnimatedBuilder(
                    animation: _fadeAnimation,
                    builder: (context, child) {
                      return Opacity(
                        opacity: _fadeAnimation.value,
                        child: SlideTransition(
                          position: _slideAnimation,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _ModernRecentlyPlayedSection(handler: widget.handler, language: _language),
                              const SizedBox(height: 32),
                              _ModernQuickAccessSection(handler: widget.handler, goTab: widget.goTab, language: _language, onDownload: _onDownloadResult),
                              const SizedBox(height: 32),
                              _ModernPlaylistsSection(
                                handler: widget.handler, 
                                goTab: widget.goTab,
                                language: _language,
                                onPlaylistSelected: (playlistName) {
                                  // Navigate to Library tab and select playlist
                                  widget.goTab(2);
                                  widget.onPlaylistSelected?.call(playlistName);
                                },
                              ),
                              const SizedBox(height: 32),
                              _ModernLibraryStatsSection(handler: widget.handler, language: _language),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _onDownloadResult(YouTubeDownloadResult result) {
    // Debug logging
    print('=== DOWNLOAD RESULT DEBUG ===');
    print('Title: ${result.title}');
    print('Artist: ${result.artist}');
    print('Duration: ${result.duration}');
    print('File: ${result.file.path}');
    
    // Add to queue
    final item = MediaItem(
      id: result.file.path,
      title: result.title,
      artist: result.artist,
      duration: result.duration,
      extras: {
        'uri': result.file.path,
        'artUri': result.artwork?.path,
      },
    );
    widget.handler.addQueueItem(item);
    
    // Also save to library JSON (await to ensure metadata upsert completes)
    () async {
      try {
        final svc = PlaylistsService();
        await svc.addToLibrary(item);
        print('Saved to library: ${result.title} by ${result.artist}');
      } catch (e) {
        print('Failed to save to library: $e');
      }
    }();
    
    // If duration is missing, try to load it immediately
    if (result.duration == null) {
      print('Duration missing for ${result.title}, loading immediately...');
      Future(() async {
        final player = AudioPlayer();
        try {
          final duration = await player.setFilePath(result.file.path, preload: false);
          if (duration != null) {
            final queue = widget.handler.queue.valueOrNull ?? const <MediaItem>[];
            final index = queue.indexWhere((e) => e.id == result.file.path);
            if (index >= 0) {
              await widget.handler.updateQueueItem(index, item.copyWith(duration: duration));
              print('Updated duration for ${result.title}: $duration');
            }
          }
        } catch (e) {
          print('Failed to load duration for ${result.title}: $e');
        } finally {
          await player.dispose();
        }
      });
    }
  }
}

class _ModernRecentlyPlayedSection extends StatelessWidget {
  final JupotifyAudioHandler handler;
  final String language;
  const _ModernRecentlyPlayedSection({required this.handler, required this.language});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<MediaItem>>(
      stream: handler.queue,
      initialData: handler.queue.valueOrNull ?? const [],
      builder: (context, snapshot) {
        final queue = snapshot.data ?? [];
        if (queue.isEmpty) return const SizedBox.shrink();
        
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppLocalizations.getText('recentlyPlayed', language),
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 200,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: math.min(queue.length, 10),
                separatorBuilder: (_, __) => const SizedBox(width: 16),
                itemBuilder: (_, i) {
                  final item = queue[i];
                  return _ModernMusicCard(
                    item: item,
                    onTap: () async {
                      await handler.skipToQueueItem(i);
                      await handler.play();
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ModernMusicCard extends StatelessWidget {
  final MediaItem item;
  final VoidCallback onTap;
  
  const _ModernMusicCard({
    required this.item,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 160,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: Colors.white.withOpacity(0.1),
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
              child: Container(
                height: 120,
                width: double.infinity,
                child: item.artUri != null
                    ? _ArtworkImage(uri: item.artUri!)
                    : Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color(0xFF2A2A2A), Color(0xFF1A1A1A)],
                          ),
                        ),
                        child: const Icon(
                          Icons.music_note,
                          size: 40,
                          color: Colors.white38,
                        ),
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title.length > 15 ? '${item.title.substring(0, 15)}...' : item.title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item.artist ?? 'Unknown Artist',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.white70,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModernQuickAccessSection extends StatelessWidget {
  final JupotifyAudioHandler handler;
  final void Function(int tabIndex) goTab;
  final String language;
  final Function(YouTubeDownloadResult) onDownload;
  
  const _ModernQuickAccessSection({
    required this.handler,
    required this.goTab,
    required this.language,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          AppLocalizations.getText('quickAccess', language),
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _ModernQuickAccessCard(
                icon: Icons.search,
                title: AppLocalizations.getText('searchMusic', language),
                subtitle: AppLocalizations.getText('findNewSongs', language),
                onTap: () => goTab(1),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _ModernQuickAccessCard(
                icon: Icons.library_music,
                title: AppLocalizations.getText('yourLibrary', language),
                subtitle: AppLocalizations.getText('browseCollection', language),
                onTap: () => goTab(2),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _ModernQuickAccessCard(
                icon: Icons.settings,
                title: AppLocalizations.getText('settings', language),
                subtitle: '${AppLocalizations.getText('language', language)} · ${AppLocalizations.getText('nickname', language)}',
                onTap: () async {
                  final prefs = await SharedPreferences.getInstance();
                  final currentNickname = prefs.getString('user_nickname') ?? '';
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => SettingsScreen(
                        currentNickname: currentNickname,
                        currentLanguage: language,
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _ModernQuickAccessCard(
                icon: Icons.playlist_add,
                title: AppLocalizations.getText('importPlaylist', language),
                subtitle: AppLocalizations.getText('youtubeUrl', language),
                onTap: () async {
                  await showModalBottomSheet(
                    context: context,
                    useSafeArea: true,
                    isScrollControlled: true,
                    backgroundColor: const Color(0xFF121212),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                    ),
                    builder: (_) {
                      return Padding(
                        padding: EdgeInsets.only(
                          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
                          left: 16,
                          right: 16,
                          top: 16,
                        ),
                        child: _YouTubeDownloadBar(
                          onDownload: onDownload,
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ModernQuickAccessCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  
  const _ModernQuickAccessCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: Colors.white.withOpacity(0.1),
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                icon,
                color: Colors.white,
                size: 20,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: const TextStyle(
                fontSize: 12,
                color: Colors.white70,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModernPlaylistsSection extends StatelessWidget {
  final JupotifyAudioHandler handler;
  final void Function(int tabIndex) goTab;
  final void Function(String playlistName)? onPlaylistSelected;
  final String language;
  const _ModernPlaylistsSection({
    required this.handler, 
    required this.goTab,
    this.onPlaylistSelected,
    required this.language,
  });

  void _showPlaylistInSongsTab(String playlistName) {
    // Navigate to Library tab (index 2) and select the playlist
    goTab(2);
    // Notify parent widget to select the playlist
    onPlaylistSelected?.call(playlistName);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              AppLocalizations.getText('yourLibrary', language),
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            TextButton(
              onPressed: () => goTab(2),
              child: Text(
                AppLocalizations.getText('browseCollection', language),
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        StreamBuilder<List<MediaItem>>(
          stream: handler.queue,
          initialData: handler.queue.valueOrNull ?? const [],
          builder: (context, snapshot) {
            final queue = snapshot.data ?? [];
            if (queue.isEmpty) {
              return Container(
                height: 100,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.1),
                    width: 1,
                  ),
                ),
                child: const Center(
                  child: Text(
                    'No playlists yet',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                    ),
                  ),
                ),
              );
            }
            
            return Container(
              height: 100,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: Colors.white.withOpacity(0.1),
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 80,
                    height: 80,
                    margin: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.queue_music,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            AppLocalizations.getText('searchMusic', language),
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${queue.length}',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.white70,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => goTab(2),
                    icon: const Icon(
                      Icons.arrow_forward_ios,
                      color: Colors.white70,
                      size: 16,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

class _ModernLibraryStatsSection extends StatelessWidget {
  final JupotifyAudioHandler handler;
  final String language;
  const _ModernLibraryStatsSection({required this.handler, required this.language});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<MediaItem>>(
      stream: handler.queue,
      initialData: handler.queue.valueOrNull ?? const [],
      builder: (context, snapshot) {
        final queue = snapshot.data ?? [];
        return Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Colors.white.withOpacity(0.1),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _StatItem(
                icon: Icons.music_note,
                label: AppLocalizations.getText('searchMusic', language),
                value: queue.length.toString(),
              ),
              _StatItem(
                icon: Icons.library_music,
                label: AppLocalizations.getText('yourLibrary', language),
                value: '1',
              ),
              _StatItem(
                icon: Icons.download,
                label: AppLocalizations.getText('download', language),
                value: queue.length.toString(),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _StatItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  
  const _StatItem({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(
          icon,
          color: Colors.white,
          size: 24,
        ),
        const SizedBox(height: 8),
        Text(
          value,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            color: Colors.white70,
          ),
        ),
      ],
    );
  }
}

class _SearchTab extends StatefulWidget {
  final JupotifyAudioHandler handler;
  const _SearchTab({required this.handler});

  @override
  State<_SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<_SearchTab> with AutomaticKeepAliveClientMixin {
  final _controller = TextEditingController();
  String _language = 'ko';
  final _downloader = YouTubeDownloader();
  List<Video> _results = const [];
  bool _loading = false;
  final Map<String, double> _progress = {};
  List<String> _searchHistory = [];
  bool _showHistory = true;
  String _currentQuery = '';

  @override
  void initState() {
    super.initState();
    _loadSearchHistory();
    _loadUserSettings();
  }

  Future<void> _loadUserSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final savedLang = prefs.getString('app_language');
    if (!mounted) return;
    if (savedLang != null && savedLang.isNotEmpty) {
      setState(() => _language = savedLang);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _downloader.dispose();
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true;

  Future<void> _loadSearchHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final history = prefs.getStringList('search_history') ?? [];
    if (mounted) {
      setState(() => _searchHistory = history);
    }
  }

  Future<void> _saveSearchHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('search_history', _searchHistory);
  }

  void _addToHistory(String query) {
    if (query.trim().isEmpty) return;
    final trimmed = query.trim();
    setState(() {
      _searchHistory.remove(trimmed); // Remove if exists
      _searchHistory.insert(0, trimmed); // Add to beginning
      if (_searchHistory.length > 10) {
        _searchHistory = _searchHistory.take(10).toList(); // Keep only 10 items
      }
    });
    _saveSearchHistory();
  }

  Future<void> _onSearch({bool reset = true}) async {
    final q = _controller.text.trim();
    if (q.isEmpty) return;
    _addToHistory(q);
    setState(() {
      _loading = true;
      _showHistory = false;
      _results = [];
      _currentQuery = q;
    });
    
    try {
      final res = await _downloader.searchVideos(q, limit: 15);
      if (!mounted) return;
      setState(() => _results = res);
    } catch (e) {
      print('[Search] Error: $e');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _openVideoInApp(String url, String title) async {
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
      appBar: AppBar(
          backgroundColor: Colors.black,
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        body: SafeArea(
          child: WebViewWidget(
            controller: () {
              final c = WebViewController()
                ..setJavaScriptMode(JavaScriptMode.unrestricted)
                ..setBackgroundColor(const Color(0xFF000000))
                ..loadRequest(Uri.parse(url));
              return c;
            }(),
          ),
        ),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: CustomScrollView(
        slivers: [
          // Modern App Bar
          SliverAppBar(
            expandedHeight: 124,
            floating: false,
            pinned: true,
            backgroundColor: Colors.transparent,
            elevation: 0,
            systemOverlayStyle: SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              statusBarIconBrightness: Brightness.light,
            ),
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFF1A1A1A), Color(0xFF000000)],
                  ),
                ),
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
        child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 16),
                          Text(
                            AppLocalizations.getText('search', _language),
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _controller,
                                style: const TextStyle(color: Colors.white),
                                decoration: InputDecoration(
                                  hintText: AppLocalizations.getText('searchMusic', _language),
                                  hintStyle: const TextStyle(color: Colors.white54),
                                  prefixIcon: const Icon(Icons.search, color: Colors.white54),
                                  filled: true,
                                  fillColor: Colors.white.withOpacity(0.1),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    borderSide: BorderSide.none,
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                ),
                                onSubmitted: (_) => _onSearch(reset: true),
                                onTap: () {
                                  if (_results.isEmpty) {
                                    setState(() => _showHistory = true);
                                  }
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            GestureDetector(
                              onTap: _loading ? null : _onSearch,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Icon(
                                  Icons.search,
                                  color: Colors.white,
                                  size: 20,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          
          // Content
          SliverPadding(
            padding: const EdgeInsets.all(20),
            sliver: SliverFillRemaining(
              child: Column(
                children: [
                  if (_loading) ...[
                    Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      child: const LinearProgressIndicator(
                        backgroundColor: Color(0xFF2A2A2A),
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    ),
                  ],
                  Expanded(
                    child: _showHistory && _results.isEmpty
                        ? _buildSearchHistory()
                        : ListView.builder(
                            itemCount: _results.length,
                            itemBuilder: (_, i) {
                            final v = _results[i];
                            final p = _progress[v.id.value];
                            
                            return Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              decoration: BoxDecoration(
                                color: const Color(0xFF2A2A2A),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: ListTile(
                                leading: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: SizedBox(
                                    width: 48,
                                    height: 48,
                                    child: Image.network(
                                      v.thumbnails.highResUrl,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => const ColoredBox(
                                        color: Color(0xFF1A1A1A),
                                        child: Icon(Icons.ondemand_video, color: Colors.white70),
                                      ),
                                    ),
                                  ),
                                ),
                                title: Text(
                                  v.title,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  '${v.author} • ${_formatDuration(v.duration)}',
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 14,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: p == null
                                    ? IconButton(
                                        onPressed: () => _onDownload(v),
                                        icon: const Icon(Icons.download_rounded, color: Colors.white54),
                                      )
                                    : SizedBox(
                                        width: 28,
                                        height: 28,
                                        child: CircularProgressIndicator(
                                          value: p,
                                          backgroundColor: const Color(0xFF2A2A2A),
                                          valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                                        ),
                                      ),
                                onTap: () => _openVideoInApp(v.url, v.title),
                              ),
                            );
                          },
                        ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchHistory() {
    if (_searchHistory.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.history, size: 64, color: Colors.white38),
            const SizedBox(height: 16),
            Text(AppLocalizations.getText('noSearchHistory', _language), style: const TextStyle(color: Colors.white54, fontSize: 16)),
            const SizedBox(height: 8),
            Text(AppLocalizations.getText('searchHintHistory', _language), style: const TextStyle(color: Colors.white38, fontSize: 14)),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
            Text(
                AppLocalizations.getText('recentSearches', _language), 
                style: const TextStyle(
                  fontSize: 18, 
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              GestureDetector(
                onTap: () {
                  setState(() => _searchHistory.clear());
                  _saveSearchHistory();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    AppLocalizations.getText('clearAll', _language), 
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.white70,
                    ),
                  ),
                ),
            ),
          ],
        ),
      ),
        Expanded(
          child: ListView.builder(
            itemBuilder: (_, i) {
              final query = _searchHistory[i];
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2A2A),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ListTile(
                  leading: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1A1A),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.history, color: Colors.white70, size: 24),
                  ),
                  title: Text(
                    query, 
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.close, size: 20, color: Colors.white54),
                    onPressed: () {
                      setState(() => _searchHistory.removeAt(i));
                      _saveSearchHistory();
                    },
                  ),
                  onTap: () {
                    _controller.text = query;
                    _onSearch(reset: true);
                  },
                ),
              );
            },
            itemCount: _searchHistory.length,
          ),
        ),
      ],
    );
  }

  // Removed duplicate no-arg _onSearch; use _onSearch(reset: true) instead

  Future<void> _onDownload(Video v) async {
    final ok = await _ensureStoragePermission();
    if (!ok) return;
    setState(() => _progress[v.id.value] = 0);
    try {
      // Ensure we have a valid video URL
      final videoUrl = v.url.isNotEmpty ? v.url : 'https://www.youtube.com/watch?v=${v.id.value}';
      final result = await _downloader.downloadAudio(videoUrl, remoteServerBaseUrl: 'http://222.231.24.5:8080', onProgress: (p) {
        setState(() => _progress[v.id.value] = p);
      });
      // Add to queue
      final item = MediaItem(
        id: result.file.path,
        title: result.title,
        artist: result.artist,
        duration: result.duration ?? v.duration, // Use result duration first, fallback to video duration
        artUri: result.artwork != null
            ? Uri.file(result.artwork!.path)
            : Uri.tryParse(v.thumbnails.highResUrl),
        extras: {'uri': Uri.file(result.file.path).toString()},
      );
      await widget.handler.addQueueItem(item);
      if (!mounted) return;
      // Added to library - silently continue
    } catch (e) {
      if (!mounted) return;
      // Download failed - silently continue
    } finally {
      if (!mounted) return;
      setState(() => _progress.remove(v.id.value));
    }
  }

  void _onDownloadResult(YouTubeDownloadResult result) {
    // Debug logging
    print('=== DOWNLOAD RESULT DEBUG ===');
    print('Title: ${result.title}');
    print('Artist: ${result.artist}');
    print('Duration: ${result.duration}');
    print('File: ${result.file.path}');
    
    // Add to queue
    final item = MediaItem(
      id: result.file.path,
      title: result.title,
      artist: result.artist,
      duration: result.duration,
      extras: {
        'uri': result.file.path,
        'artUri': result.artwork?.path,
      },
    );
    widget.handler.addQueueItem(item);
    
    // Also save to library JSON (await to ensure metadata upsert completes)
    () async {
      try {
        final svc = PlaylistsService();
        await svc.addToLibrary(item);
        print('Saved to library: ${result.title} by ${result.artist}');
      } catch (e) {
        print('Failed to save to library: $e');
      }
    }();
    
    // If duration is missing, try to load it immediately
    if (result.duration == null) {
      print('Duration missing for ${result.title}, loading immediately...');
      Future(() async {
        final player = AudioPlayer();
        try {
          final duration = await player.setFilePath(result.file.path, preload: false);
          if (duration != null) {
            final queue = widget.handler.queue.valueOrNull ?? const <MediaItem>[];
            final index = queue.indexWhere((e) => e.id == result.file.path);
            if (index >= 0) {
              await widget.handler.updateQueueItem(index, item.copyWith(duration: duration));
              print('Updated duration for ${result.title}: $duration');
            }
          }
        } catch (e) {
          print('Failed to load duration for ${result.title}: $e');
        } finally {
          await player.dispose();
        }
      });
    }
  }
}

class _YouTubeDownloadBar extends StatefulWidget {
  final Function(YouTubeDownloadResult) onDownload;
  
  const _YouTubeDownloadBar({required this.onDownload});

  @override
  State<_YouTubeDownloadBar> createState() => _YouTubeDownloadBarState();
}

class _YouTubeDownloadBarState extends State<_YouTubeDownloadBar> {
  String _language = 'ko';
  final _controller = TextEditingController();
  double? _progress;
  bool _busy = false;
  String? _status;
  bool _useBackground = true; // Always true, no UI control
  List<Video> _playlistVideos = [];
  Set<String> _selectedVideoIds = {};
  bool _isLoadingPlaylist = false;
  String _playlistTitle = '';
  final _playlistTitleController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadLang();
  }

  Future<void> _loadLang() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('app_language');
    if (mounted && saved != null && saved.isNotEmpty) {
      setState(() => _language = saved);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _playlistTitleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1A1A1A), Color(0xFF000000)],
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              Text(
                AppLocalizations.getText('importPlaylist', _language),
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                AppLocalizations.getText('getFromYouTube', _language),
                style: const TextStyle(
                  fontSize: 16,
                  color: Colors.white70,
                ),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _controller,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: AppLocalizations.getText('youtubeUrl', _language),
                  hintStyle: const TextStyle(color: Colors.white54),
                  prefixIcon: const Icon(Icons.link, color: Colors.white54),
                  filled: true,
                  fillColor: Colors.white.withOpacity(0.1),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
              ),
              // Show controls only when playlist is not loaded
              if (_playlistVideos.isEmpty) ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: ElevatedButton.icon(
                          onPressed: _busy ? null : _onDownload,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.transparent,
                            shadowColor: Colors.transparent,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          icon: const Icon(Icons.download_rounded, color: Colors.white),
                          label: const Text('Download audio', style: TextStyle(color: Colors.white)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: ElevatedButton.icon(
                          onPressed: _busy || _isLoadingPlaylist ? null : _onLoadPlaylist,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.transparent,
                            shadowColor: Colors.transparent,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          icon: _isLoadingPlaylist 
                            ? const SizedBox(
                                width: 16, 
                                height: 16, 
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)
                              )
                            : const Icon(Icons.queue_music_rounded, color: Colors.white),
                          label: const Text('Load playlist', style: TextStyle(color: Colors.white)),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              // Show playlist controls when loaded
              if (_playlistVideos.isNotEmpty) ...[
                const SizedBox(height: 16),
                TextField(
                  controller: _playlistTitleController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Playlist title (default: YouTube playlist name)',
                    hintStyle: const TextStyle(color: Colors.white54),
                    prefixIcon: const Icon(Icons.playlist_play_rounded, color: Colors.white54),
                    filled: true,
                    fillColor: Colors.white.withOpacity(0.1),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                  onChanged: (value) => setState(() => _playlistTitle = value),
                ),
              ],
              if (_playlistVideos.isNotEmpty) ...[
                const SizedBox(height: 16),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2A2A2A),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                      Row(
                        children: [
                          Text(
                            'Playlist Videos (${_playlistVideos.length})',
                            style: const TextStyle(
                              fontWeight: FontWeight.w600, 
                              fontSize: 18,
                              color: Colors.white,
                            ),
                          ),
                          const Spacer(),
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: IconButton(
                              onPressed: _busy ? null : () {
                                setState(() {
                                  if (_selectedVideoIds.length == _playlistVideos.length) {
                                    // All selected, clear all
                                    _selectedVideoIds.clear();
                                  } else {
                                    // Not all selected, select all
                                    _selectedVideoIds = _playlistVideos.map((v) => v.id.value).toSet();
                                  }
                                });
                              },
                              icon: Icon(
                                _selectedVideoIds.length == _playlistVideos.length 
                                  ? Icons.clear_all 
                                  : Icons.select_all, 
                                color: Colors.white, 
                                size: 20
                              ),
                              tooltip: _selectedVideoIds.length == _playlistVideos.length ? AppLocalizations.getText('clearAll', _language) : AppLocalizations.getText('selectAll', _language),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: ListView.builder(
                          itemCount: _playlistVideos.length,
                          itemBuilder: (context, index) {
                            final video = _playlistVideos[index];
                            final isSelected = _selectedVideoIds.contains(video.id.value);
                            return Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              decoration: BoxDecoration(
                                color: isSelected ? Colors.white.withOpacity(0.1) : Colors.white.withOpacity(0.05),
                                borderRadius: BorderRadius.circular(12),
                                border: isSelected ? Border.all(color: Colors.white, width: 1) : null,
                              ),
                              child: ListTile(
                                leading: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.network(
                                    video.thumbnails.mediumResUrl,
                                    width: 48,
                                    height: 48,
                                    fit: BoxFit.cover,
                                    errorBuilder: (context, error, stackTrace) => Container(
                                      width: 48,
                                      height: 48,
                                      decoration: BoxDecoration(
                                        color: Colors.white.withOpacity(0.1),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: const Icon(Icons.music_note, color: Colors.white54),
                                    ),
                                  ),
                                ),
                                title: Text(
                                  video.title,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  video.author,
                                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                                ),
                                trailing: Checkbox(
                                  value: isSelected,
                                  onChanged: _busy ? null : (value) {
                                    setState(() {
                                      if (value == true) {
                                        _selectedVideoIds.add(video.id.value);
                                      } else {
                                        _selectedVideoIds.remove(video.id.value);
                                      }
                                    });
                                  },
                                  activeColor: Colors.white,
                                ),
                                onTap: _busy ? null : () {
                                  setState(() {
                                    if (isSelected) {
                                      _selectedVideoIds.remove(video.id.value);
                                    } else {
                                      _selectedVideoIds.add(video.id.value);
                                    }
                                  });
                                },
                              ),
                            );
                          },
                        ),
                      ),
                      if (_selectedVideoIds.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: _busy ? null : _onDownloadSelected,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.transparent,
                                shadowColor: Colors.transparent,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                              ),
                              icon: const Icon(Icons.download_rounded, color: Colors.white),
                              label: Text('Download Selected (${_selectedVideoIds.length})', style: const TextStyle(color: Colors.white)),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                ),
              ],
              if (_progress != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: LinearProgressIndicator(
                    value: _progress,
                    backgroundColor: Colors.white.withOpacity(0.2),
                    valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                ),
              ],
              if (_status != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _status!,
                    style: const TextStyle(fontSize: 14, color: Colors.white70),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _onDownload() async {
    final url = _controller.text.trim();
    if (url.isEmpty) return;
    
    if (_useBackground) {
      setState(() {
        _busy = true;
        _status = 'Downloading...';
      });
      try {
        final ok = await _ensureStoragePermission();
        if (!ok) throw 'Storage permission denied';
        
        // Request notification permission
        final notificationOk = await NotificationService.requestPermission();
        if (!notificationOk) {
          throw 'Notification permission denied';
        }
        
        // Use Isolate for background processing
        await _downloadInBackground(url);
        
        if (!mounted) return;
        // Background download started - silently continue
      } catch (e) {
        if (!mounted) return;
        // Download failed - silently continue
        setState(() {
          _busy = false;
          _status = null;
        });
      }
    } else {
      setState(() {
        _busy = true;
        _progress = 0;
      });
      try {
        final ok = await _ensureStoragePermission();
        if (!ok) throw 'Storage permission denied';
        final yt = YouTubeDownloader();
        // Ensure URL is valid (might be video ID or full URL)
        final videoUrl = url.startsWith('http') ? url : 'https://www.youtube.com/watch?v=$url';
        final result = await yt.downloadAudio(videoUrl, remoteServerBaseUrl: 'http://222.231.24.5:8080', onProgress: (p) {
          setState(() => _progress = p);
        });
        yt.dispose();

        if (!mounted) return;
        // Downloaded - silently continue
      } catch (e) {
        if (!mounted) return;
        // Download failed - silently continue
      } finally {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _onLoadPlaylist() async {
    final url = _controller.text.trim();
    if (url.isEmpty) return;
    
    setState(() {
      _isLoadingPlaylist = true;
      _status = 'Loading playlist...';
      _playlistVideos.clear();
      _selectedVideoIds.clear();
    });
    
    try {
      final yt = YouTubeDownloader();
      final videos = await yt.getPlaylistVideos(url);
      
      // Get playlist title from YouTube
      String playlistTitle = '';
      try {
        final playlist = await yt.getPlaylist(url);
        playlistTitle = playlist.title;
      } catch (e) {
        print('Error getting playlist title: $e');
        playlistTitle = 'YouTube Playlist';
      }
      
      setState(() {
        _playlistVideos = videos;
        _playlistTitle = playlistTitle;
        _playlistTitleController.text = playlistTitle;
        _status = null;
      });
    } catch (e) {
      setState(() {
        _status = 'Error loading playlist: $e';
      });
    } finally {
      setState(() {
        _isLoadingPlaylist = false;
      });
    }
  }


  Future<void> _onDownloadSelected() async {
    if (_selectedVideoIds.isEmpty) return;
    
    final selectedVideos = _playlistVideos
        .where((v) => _selectedVideoIds.contains(v.id.value))
        .toList();
    
    // Get playlist title (use custom title if provided, otherwise use default)
    final playlistTitle = _playlistTitleController.text.trim().isNotEmpty 
        ? _playlistTitleController.text.trim() 
        : _playlistTitle;
    
    if (_useBackground) {
      setState(() {
        _busy = true;
        _status = 'Downloading ${selectedVideos.length} videos to playlist "$playlistTitle"...';
      });
      try {
        final ok = await _ensureStoragePermission();
        if (!ok) throw 'Storage permission denied';
        
        // Request notification permission
        final notificationOk = await NotificationService.requestPermission();
        if (!notificationOk) {
          throw 'Notification permission denied';
        }
        
        // Use Isolate for background processing
        await _downloadSelectedInBackground(selectedVideos, playlistTitle);
      } catch (e) {
        setState(() {
          _status = 'Error: $e';
        });
      } finally {
        setState(() {
          _busy = false;
        });
      }
    } else {
      setState(() {
        _busy = true;
        _status = 'Downloading ${selectedVideos.length} videos to playlist "$playlistTitle"...';
      });
      try {
        final ok = await _ensureStoragePermission();
        if (!ok) throw 'Storage permission denied';
        
        // Create playlist first
        await _createPlaylistAndDownload(selectedVideos, playlistTitle);
      } catch (e) {
        setState(() {
          _status = 'Error: $e';
        });
      } finally {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _createPlaylistAndDownload(List<Video> videos, String playlistTitle) async {
    final yt = YouTubeDownloader();
    int completed = 0;
    
    // Create playlist
    final playlist = await _createPlaylist(playlistTitle);
    
    // Show download started notification
    await NotificationService.showPlaylistStarted(playlistTitle, videos.length);
    
    for (final video in videos) {
      setState(() {
        _status = 'Downloading: ${video.title} (${completed + 1}/${videos.length})';
      });
      
      // Ensure we have a valid video URL
      final videoUrl = video.url.isNotEmpty ? video.url : 'https://www.youtube.com/watch?v=${video.id.value}';
      final downloadResult = await yt.downloadAudio(videoUrl, remoteServerBaseUrl: 'https://infotherapy.kro.kr', onProgress: (progress) {
        setState(() {
          _progress = progress;
        });
      });
      
      // Add to playlist after download
      await _addToPlaylist(playlist, video, downloadResult);
      
      completed++;
      setState(() {
        _progress = null;
        _status = 'Downloaded ${videos.length} videos to "$playlistTitle"';
      });
      
      // Show playlist progress (only playlist progress, no individual notifications)
      await NotificationService.showPlaylistProgress(playlistTitle, completed, videos.length, video.title);
    }
    
    // Show completion notification
    await NotificationService.showPlaylistCompleted(playlistTitle, completed);
    
    setState(() {
      _status = 'Successfully downloaded ${videos.length} videos to playlist "$playlistTitle"';
    });
  }

  Future<Map<String, dynamic>> _createPlaylist(String title) async {
    // Create a new playlist using PlaylistsService
    final playlistsService = PlaylistsService();
    await playlistsService.create(title);
    
    print('Created playlist: $title');
    
    // Return playlist info
    return {
      'id': DateTime.now().millisecondsSinceEpoch.toString(),
      'name': title,
      'songs': <Map<String, dynamic>>[],
    };
  }

  Future<void> _addToPlaylist(Map<String, dynamic> playlist, Video video, YouTubeDownloadResult? downloadResult) async {
    if (downloadResult == null) {
      print('No download result for ${video.title}');
      return;
    }
    
    // Create MediaItem from download result
    final mediaItem = MediaItem(
      id: downloadResult.file.path,
      title: downloadResult.title,
      artist: downloadResult.artist,
      album: 'YouTube Playlist',
      duration: downloadResult.duration, // Use duration from download result
      artUri: downloadResult.artwork != null ? Uri.file(downloadResult.artwork!.path) : null,
      extras: {
        'uri': 'file://${downloadResult.file.path}',
      },
    );
    
    // Add to playlist using PlaylistsService
    final playlistsService = PlaylistsService();
    await playlistsService.addTrack(playlist['name'], mediaItem);
    
    print('Added ${video.title} to playlist ${playlist['name']}');
  }

  Future<void> _downloadSelectedInBackground(List<Video> videos, String playlistTitle) async {
    // Create playlist first
    final playlist = await _createPlaylist(playlistTitle);
    
    // Show download started notification
    await NotificationService.showPlaylistStarted(playlistTitle, videos.length);
    
    // Download videos in background
    await Future.microtask(() async {
      final yt = YouTubeDownloader();
      int completed = 0;
      
      for (final video in videos) {
        try {
          final downloadResult = await yt.downloadAudio(
            video.url,
            remoteServerBaseUrl: 'https://infotherapy.kro.kr',
          );
          await _addToPlaylist(playlist, video, downloadResult);
          completed++;
          
          // Update progress via SharedPreferences
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('download_progress', 'Downloaded $completed/${videos.length} to "$playlistTitle"');
          
          // Show playlist progress (only playlist progress, no individual notifications)
          await NotificationService.showPlaylistProgress(playlistTitle, completed, videos.length, video.title);
        } catch (e) {
          print('Error downloading ${video.title}: $e');
          // Only show error for individual songs if they fail
          await NotificationService.showDownloadFailed(video.title, e.toString());
        }
      }
      
      // Show completion notification
      await NotificationService.showPlaylistCompleted(playlistTitle, completed);
    });
  }

  Future<void> _onImportPlaylist() async {
    final url = _controller.text.trim();
    if (url.isEmpty) return;
    
    if (_useBackground) {
      setState(() {
        _busy = true;
        _status = 'Downloading playlist...';
      });
      try {
        final ok = await _ensureStoragePermission();
        if (!ok) throw 'Storage permission denied';
        
        // Request notification permission
        final notificationOk = await NotificationService.requestPermission();
        if (!notificationOk) {
          throw 'Notification permission denied';
        }
        
        // Use Isolate for background processing
        await _downloadPlaylistInBackground(url);
        
        if (!mounted) return;
        // Background playlist download started - silently continue
      } catch (e) {
        if (!mounted) return;
        // Playlist import failed - silently continue
        setState(() {
          _busy = false;
          _status = null;
        });
      }
    } else {
      setState(() {
        _busy = true;
        _progress = 0;
        _status = 'Fetching playlist...';
      });
      try {
        final ok = await _ensureStoragePermission();
        if (!ok) throw 'Storage permission denied';
        final yt = YouTubeDownloader();
        
        // Get playlist title and videos
        String playlistTitle = 'YouTube Playlist';
        List<Video> videos = [];
        try {
          final playlist = await yt.getPlaylist(url);
          playlistTitle = playlist.title;
          videos = await yt.getPlaylistVideos(url);
        } catch (e) {
          print('Error getting playlist info: $e');
          throw 'Failed to load playlist: $e';
        }
        
        if (videos.isEmpty) {
          throw 'Playlist is empty';
        }
        
        // Create playlist
        final playlist = await _createPlaylist(playlistTitle);
        
        // Show download started notification
        await NotificationService.showPlaylistStarted(playlistTitle, videos.length);
        
        // Download each video one by one (like search download)
        int completed = 0;
        for (int i = 0; i < videos.length; i++) {
          final video = videos[i];
          if (!mounted) return;
          
          setState(() {
            _status = 'Downloading (${i + 1}/${videos.length}): ${video.title}';
            _progress = i / videos.length;
          });
          
          try {
            // Download video (same as search download) - ensure valid URL
            final videoUrl = video.url.isNotEmpty ? video.url : 'https://www.youtube.com/watch?v=${video.id.value}';
            final downloadResult = await yt.downloadAudio(
              videoUrl,
              remoteServerBaseUrl: 'https://infotherapy.kro.kr',
              onProgress: (progress) {
                if (!mounted) return;
                setState(() {
                  _progress = (i + progress) / videos.length;
                });
              },
            );
            
            // Add to playlist after download
            await _addToPlaylist(playlist, video, downloadResult);
            completed++;
            
            // Show playlist progress
            await NotificationService.showPlaylistProgress(playlistTitle, completed, videos.length, video.title);
            
            if (!mounted) return;
            setState(() {
              _progress = (i + 1) / videos.length;
              _status = 'Downloaded ${completed}/${videos.length} to "$playlistTitle"';
            });
          } catch (e) {
            print('Error downloading ${video.title}: $e');
            // Continue with next video even if one fails
          }
        }
        
        // Show completion notification
        await NotificationService.showPlaylistCompleted(playlistTitle, completed);
        
        yt.dispose();

        if (!mounted) return;
        setState(() {
          _status = 'Successfully downloaded $completed/${videos.length} videos to playlist "$playlistTitle"';
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _status = 'Error downloading playlist: $e';
        });
      } finally {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _downloadInBackground(String url) async {
    // Simple background download using Future.microtask
    Future.microtask(() async {
      String? videoTitle;
      try {
        // Show download started notification
        await NotificationService.showDownloadStarted('YouTube Video');
        
        final yt = YouTubeDownloader();
        final result = await yt.downloadAudio(url, onProgress: (progress) async {
          // Update progress notification
          if (videoTitle != null) {
            await NotificationService.showDownloadProgress(videoTitle!, (progress * 100).round());
          }
        });
        videoTitle = result.title;
        yt.dispose();
        
        // Show completion notification
        await NotificationService.showDownloadCompleted(result.title);
        
        // Save result to SharedPreferences
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('last_download', result.title);
        await prefs.setString('download_status', 'completed');
      } catch (e) {
        // Show failure notification
        await NotificationService.showDownloadFailed(videoTitle ?? 'YouTube Video', e.toString());
        
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('download_status', 'failed: $e');
      }
    });
  }


  Future<void> _downloadPlaylistInBackground(String url) async {
    // Simple background playlist download using Future.microtask
    Future.microtask(() async {
      String playlistName = 'YouTube Playlist'; // Default name
      Map<String, dynamic>? playlist;
      try {
        final yt = YouTubeDownloader();
        
        // Get playlist info first
        List<Video> videos = [];
        try {
          final playlistInfo = await yt.getPlaylist(url);
          playlistName = playlistInfo.title;
          videos = await yt.getPlaylistVideos(url);
        } catch (e) {
          print('Error getting playlist info: $e');
          throw 'Failed to load playlist: $e';
        }
        
        if (videos.isEmpty) {
          throw 'Playlist is empty';
        }
        
        final totalTracks = videos.length;
        
        // Create playlist
        playlist = await _createPlaylist(playlistName);
        
        // Show playlist download started notification
        await NotificationService.showPlaylistStarted(playlistName, totalTracks);
        
        // Download each video one by one (like search download)
        int completed = 0;
        for (int i = 0; i < videos.length; i++) {
          final video = videos[i];
          
          try {
            // Download video (same as search download) - ensure valid URL
            final videoUrl = video.url.isNotEmpty ? video.url : 'https://www.youtube.com/watch?v=${video.id.value}';
            final downloadResult = await yt.downloadAudio(
              videoUrl,
              remoteServerBaseUrl: 'https://infotherapy.kro.kr',
            );
            
            // Add to playlist after download
            await _addToPlaylist(playlist!, video, downloadResult);
            completed++;
            
            // Show playlist progress
            await NotificationService.showPlaylistProgress(playlistName, completed, videos.length, video.title);
            
            // Update SharedPreferences
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('download_progress', 'Downloaded $completed/${videos.length} to "$playlistName"');
          } catch (e) {
            print('Error downloading ${video.title}: $e');
            // Continue with next video even if one fails
          }
        }
        
        yt.dispose();
        
        // Show completion notification
        await NotificationService.showPlaylistCompleted(playlistName, completed);
        
        // Save result to SharedPreferences
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('last_download', '$completed tracks from $playlistName');
        await prefs.setString('download_status', 'completed');
      } catch (e) {
        // Show failure notification
        await NotificationService.showPlaylistFailed(playlistName, e.toString());
        
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('download_status', 'failed: $e');
      }
    });
  }
}

class _ModernActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ModernActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.1),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 14),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LibraryTab extends StatefulWidget {
  final JupotifyAudioHandler handler;
  final String? selectedPlaylist;
  final void Function(String? playlist)? onPlaylistSelected;
  const _LibraryTab({
    required this.handler,
    this.selectedPlaylist,
    this.onPlaylistSelected,
  });

  @override
  State<_LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<_LibraryTab> with AutomaticKeepAliveClientMixin {
  String _language = 'ko';
  final _filterController = TextEditingController();
  bool _showPlaylists = false;
  final _svc = PlaylistsService();
  Map<String, List<PlaylistEntry>> _playlists = {};
  bool _isDeleteMode = false;
  Set<String> _selectedItems = {};
  bool get _isManualOrder => false; // Library order is now independent
  List<MediaItem> _libraryItems = [];
  Map<String, PlaylistEntry> _savedEntriesById = {};
  // Removed custom unlock logic; using built-in delayed drag listener

  @override
  void initState() {
    super.initState();
    _loadPlaylists();
    _loadLibraryItems();
    _loadUserSettings();
    
    // Periodically refresh library to catch new downloads
    _startLibraryRefreshTimer();

    // Live refresh when playlists service notifies library changes
    PlaylistsService.libraryChanged.stream.listen((_) {
      if (!mounted) return;
      _loadLibraryItems();
    });
  }
  
  void _startLibraryRefreshTimer() {
    // Check for new library items every 2 seconds
    Timer.periodic(const Duration(seconds: 2), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      _refreshLibraryIfNeeded();
    });
  }
  
  Future<void> _refreshLibraryIfNeeded() async {
    try {
      final currentLibrary = await _svc.loadLibrary();
      final currentIds = currentLibrary.map((e) => e.id).toSet();
      final currentItemIds = _libraryItems.map((e) => e.id).toSet();

      // If library has new or removed items, refresh
      if (currentIds.length != currentItemIds.length ||
          !currentIds.every((id) => currentItemIds.contains(id))) {
        print('Library count/ids changed, refreshing...');
        await _loadLibraryItems();
        return;
      }

      // Also detect metadata updates (artist/duration/title) and refresh if changed
      final savedById = {for (final e in currentLibrary) e.id: e};
      bool metadataChanged = false;
      for (final mi in _libraryItems) {
        final e = savedById[mi.id];
        if (e == null) { metadataChanged = true; break; }
        final savedArtist = e.artist ?? '';
        final savedDurationMs = e.durationMs ?? -1;
        final savedTitle = e.title;
        final uiArtist = mi.artist ?? '';
        final uiDurationMs = mi.duration?.inMilliseconds ?? -1;
        final uiTitle = mi.title;
        if (savedArtist != uiArtist || savedDurationMs != uiDurationMs || savedTitle != uiTitle) {
          metadataChanged = true;
          break;
        }
      }
      if (metadataChanged) {
        print('Library metadata changed, refreshing...');
        await _loadLibraryItems();
      }
    } catch (e) {
      print('Error checking library changes: $e');
    }
  }

  Future<void> _loadUserSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final savedLang = prefs.getString('app_language');
    if (!mounted) return;
    if (savedLang != null && savedLang.isNotEmpty) {
      setState(() => _language = savedLang);
    }
  }

  Future<void> _loadPlaylists() async {
    _playlists = await _svc.load();
    if (mounted) setState(() {});
  }

  void setManualOrder(bool isManual) {
    // Library order is now independent of queue
    setState(() {
      // Trigger UI rebuild
    });
  }

  void selectPlaylist(String playlistName) {
    setState(() {
      _showPlaylists = false; // Show songs instead of playlist list
    });
    widget.onPlaylistSelected?.call(playlistName);
  }

  void showAllSongs() {
    setState(() {
      _showPlaylists = false;
    });
    widget.onPlaylistSelected?.call(null);
  }

  void showPlaylists() {
    setState(() {
      _showPlaylists = true;
    });
    widget.onPlaylistSelected?.call(null);
  }

  Future<void> _loadLibraryFromQueue() async {
    print('=== LOADING LIBRARY FROM QUEUE ===');
    // Get current queue items as library items (independent copy)
    final currentQueue = widget.handler.queue.valueOrNull ?? const [];
    _libraryItems = List<MediaItem>.from(currentQueue);
    print('Loaded ${_libraryItems.length} library items from queue');
    if (mounted) setState(() {});
  }

  Future<void> _loadLibraryItems() async {
    print('=== LOADING LIBRARY ITEMS FROM JSON ===');
    try {
      // Load library from JSON first (maintains order from JSON)
      final libraryEntries = await _svc.loadLibrary();
      _savedEntriesById = {for (final e in libraryEntries) e.id: e};
      if (libraryEntries.isNotEmpty) {
        _libraryItems = libraryEntries.map((entry) {
          final mediaItem = entry.toMediaItem();
          print('=== LOADED FROM JSON ===');
          print('Entry ID: ${entry.id}');
          print('Entry Title: ${entry.title}');
          print('Entry Artist: ${entry.artist}');
          print('Entry DurationMs: ${entry.durationMs}');
          print('MediaItem Title: ${mediaItem.title}');
          print('MediaItem Artist: ${mediaItem.artist}');
          print('MediaItem Duration: ${mediaItem.duration}');
          return mediaItem;
        }).toList();
        print('Loaded ${_libraryItems.length} library items from JSON in download time order');
        print('Library order (download time): ${_libraryItems.map((e) => e.title).toList()}');
        if (mounted) setState(() {});
        return;
      }
      
      // If JSON is empty, scan file system and save to JSON
      print('JSON library is empty, scanning file system...');
      // Run scan in background to avoid blocking startup
      // UI will update via setState when done
      // Return early so the screen can render quickly
      // Schedule the scan without awaiting
      // ignore: unawaited_futures
      Future(() async {
        await _scanAndSaveLibraryToJson();
        if (!mounted) return;
        setState(() {});
      });
      return;
    } catch (e) {
      print('Error loading library from JSON: $e');
      // Fallback to file system scan
      await _scanAndSaveLibraryToJson();
    }
  }

  Future<void> _scanAndSaveLibraryToJson() async {
    print('=== SCANNING FILE SYSTEM AND SAVING TO JSON ===');
    Directory? baseDir;
    if (Platform.isAndroid) {
      final dirs = await getExternalStorageDirectories(type: StorageDirectory.music);
      baseDir = (dirs != null && dirs.isNotEmpty) ? dirs.first : await getExternalStorageDirectory();
    } else {
      baseDir = await getApplicationDocumentsDirectory();
    }
    if (baseDir == null) {
      print('Base directory is null');
      _libraryItems = const [];
      if (mounted) setState(() {});
      return;
    }
    print('Base directory: ${baseDir.path}');
    final target = Platform.isAndroid ? Directory('${baseDir.path}/Jupotify') : Directory('${baseDir.path}/Music/Jupotify');
    if (!await target.exists()) {
      print('Target directory does not exist: ${target.path}');
      _libraryItems = const [];
      if (mounted) setState(() {});
      return;
    }
    print('Target directory exists: ${target.path}');
    final allowed = {'.mp3', '.m4a', '.aac', '.wav', '.flac', '.ogg', '.mp4', '.webm'};
    final items = <MediaItem>[];
    await for (final entity in target.list(recursive: true, followLinks: false)) {
      if (entity is File && allowed.contains(_ext(entity.path))) {
        final base = entity.path.substring(0, entity.path.lastIndexOf('.'));
        final artPath = File('$base.jpg');
        // Try read sidecar metadata
        String title = _fileNameNoExt(entity.path);
        String artist = '';
        Duration? duration;
        try {
          final metaFile = File('$base.metadata.json');
          if (await metaFile.exists()) {
            final raw = await metaFile.readAsString();
            final m = json.decode(raw) as Map<String, dynamic>;
            title = (m['title'] as String?)?.trim().isNotEmpty == true ? (m['title'] as String) : title;
            artist = (m['artist'] as String?) ?? '';
            final dm = m['durationMs'];
            if (dm is int) duration = Duration(milliseconds: dm);
          }
        } catch (_) {}

        items.add(MediaItem(
          id: entity.path,
          title: title,
          artist: artist,
          artUri: artPath.existsSync() ? Uri.file(artPath.path) : null,
          duration: duration,
          extras: {'uri': Uri.file(entity.path).toString()},
        ));
      }
    }
    
    // Merge with existing saved order to preserve manual ordering
    print('Found ${items.length} library items from file system');
    try {
      final saved = await _svc.loadLibrary();
      final savedById = {for (final e in saved) e.id: e};
      final scannedById = {for (final mi in items) mi.id: mi};
      
      // Start with saved order, keep only files that still exist
      final merged = <PlaylistEntry>[];
      for (final e in saved) {
        if (scannedById.containsKey(e.id)) {
          // File still exists. Preserve saved metadata (title/artist/duration),
          // refresh URIs from scan (artUri if available) and keep order.
          final mi = scannedById[e.id]!;
          merged.add(PlaylistEntry(
            id: e.id,
            title: e.title.isNotEmpty ? e.title : mi.title,
            artist: e.artist, // keep saved channel/artist
            uri: e.uri.isNotEmpty ? e.uri : (mi.extras?['uri'] as String? ?? e.id),
            artUri: mi.artUri?.toString() ?? e.artUri,
            durationMs: e.durationMs, // keep saved duration
          ));
        }
      }
      
      // Append newly found files not present in saved order
      for (final mi in items) {
        if (!savedById.containsKey(mi.id)) {
          merged.add(PlaylistEntry.fromMediaItem(mi));
        }
      }
      
      await _svc.saveLibrary(merged);
      print('Saved ${merged.length} library items to JSON preserving existing order');
      _libraryItems = merged.map((e) => e.toMediaItem()).toList();
    } catch (e) {
      // Fallback to saving scanned order if merging fails
      final libraryEntries = items.map((item) => PlaylistEntry.fromMediaItem(item)).toList();
      await _svc.saveLibrary(libraryEntries);
      print('Saved ${libraryEntries.length} library items to JSON (fallback scanned order)');
      _libraryItems = items;
    }
    if (mounted) setState(() {});
  }

  String _ext(String path) {
    final i = path.lastIndexOf('.');
    return i == -1 ? '' : path.substring(i).toLowerCase();
  }

  String _fileNameNoExt(String path) {
    final i = path.lastIndexOf('/');
    final name = i == -1 ? path : path.substring(i + 1);
    final j = name.lastIndexOf('.');
    return j == -1 ? name : name.substring(0, j);
  }


  @override
  void dispose() {
    _filterController.dispose();
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return WillPopScope(
      onWillPop: () async {
        // If a playlist is selected, go back to playlist list
        if (widget.selectedPlaylist != null) {
          showPlaylists();
          return false; // Prevent default back behavior
        }
        return true; // Allow default back behavior
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: CustomScrollView(
          slivers: [
            // Modern App Bar
            SliverAppBar(
              expandedHeight: 120,
              floating: false,
              pinned: true,
              backgroundColor: Colors.transparent,
              elevation: 0,
              systemOverlayStyle: SystemUiOverlayStyle(
                statusBarColor: Colors.transparent,
                statusBarIconBrightness: Brightness.light,
              ),
              flexibleSpace: FlexibleSpaceBar(
                background: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xFF1A1A1A), Color(0xFF000000)],
                    ),
                  ),
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              if (widget.selectedPlaylist != null) ...[
                                IconButton(
                                  icon: const Icon(
                                    Icons.arrow_back_ios,
                                    color: Colors.white,
                                    size: 20,
                                  ),
                                  onPressed: () => showPlaylists(),
                                ),
                                const SizedBox(width: 8),
                              ],
                              Expanded(
                                child: Text(
                                  widget.selectedPlaylist != null ? widget.selectedPlaylist! : AppLocalizations.getText('yourLibrary', _language),
                                  style: const TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          // Action buttons - Hide when playlist is selected
                          if (widget.selectedPlaylist == null) ...[
                            SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                // Search button
                                _ModernActionButton(
                                  icon: Icons.search,
                                  label: _filterController.text.isEmpty ? 'Search' : 'Search: ${_filterController.text}',
                                  onTap: () async {
                                    final result = await showDialog<String>(
                                      context: context,
                                      builder: (context) => AlertDialog(
                                        backgroundColor: const Color(0xFF2A2A2A),
                                        title: const Text(
                                          'Search in Library',
                                          style: TextStyle(color: Colors.white),
                                      ),
                                      content: TextField(
                                        controller: _filterController,
                                        autofocus: true,
                                        decoration: const InputDecoration(
                                          hintText: 'Enter search term',
                                          hintStyle: TextStyle(color: Colors.white54),
                                          border: OutlineInputBorder(),
                                          focusedBorder: OutlineInputBorder(
                                            borderSide: BorderSide(color: Colors.white),
                                          ),
                                        ),
                                        style: const TextStyle(color: Colors.white),
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.pop(context),
                                          child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
                                        ),
                                        TextButton(
                                          onPressed: () {
                                            setState(() {});
                                            Navigator.pop(context);
                                          },
                                          child: const Text('Search', style: TextStyle(color: Colors.white)),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                              const SizedBox(width: 8),
                              
                              // Songs/Playlists toggle button
                              if (widget.selectedPlaylist != null) ...[
                                _ModernActionButton(
                                  icon: Icons.music_note,
                                  label: 'All Songs',
                                  onTap: () => showAllSongs(),
                                ),
                                const SizedBox(width: 8),
                                _ModernActionButton(
                                  icon: Icons.queue_music,
                                  label: 'Playlists',
                                  onTap: () async {
                                    setState(() => _showPlaylists = true);
                                    await _loadPlaylists();
                                  },
                                ),
                              ] else ...[
                                _ModernActionButton(
                                  icon: _showPlaylists ? Icons.queue_music : Icons.music_note,
                                  label: _showPlaylists ? 'Songs' : 'Playlists',
                                  onTap: () async {
                                    if (_showPlaylists) {
                                      setState(() => _showPlaylists = false);
                                    } else {
                                      setState(() => _showPlaylists = true);
                                      await _loadPlaylists();
                                    }
                                  },
                                ),
                              ],
                              const SizedBox(width: 8),
                              
                              if (_isDeleteMode) ...[
                                _ModernActionButton(
                                  icon: Icons.close,
                                  label: 'Cancel',
                                  onTap: () => setState(() {
                                    _isDeleteMode = false;
                                    _selectedItems.clear();
                                  }),
                                ),
                                if (_selectedItems.isNotEmpty) ...[
                                  const SizedBox(width: 8),
                                  _ModernActionButton(
                                    icon: Icons.tag,
                                    label: 'Edit artist',
                                    onTap: () async {
                                      final newArtist = await _promptText(context, 'Set artist (channel name) for selected', initial: '');
                                      if (newArtist == null) return;
                                      final artist = newArtist.trim();
                                      if (artist.isEmpty) return;
                                      await _svc.bulkUpdateArtist(_selectedItems, artist);
                                      await _loadLibraryItems();
                                      if (!mounted) return;
                                      setState(() {
                                        _isDeleteMode = false;
                                        _selectedItems.clear();
                                      });
                                    },
                                  ),
                                  const SizedBox(width: 8),
                                  _ModernActionButton(
                                    icon: Icons.drive_file_rename_outline,
                                    label: 'Replace artist',
                                    onTap: () async {
                                      final from = await _promptText(context, 'Current artist (exact match)', initial: '');
                                      if (from == null) return;
                                      final to = await _promptText(context, 'New artist (channel name)', initial: '');
                                      if (to == null) return;
                                      final changed = await _svc.bulkReplaceArtist(from, to);
                                      await _loadLibraryItems();
                                      if (!mounted) return;
                                      setState(() {});
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text('Updated $changed items')),
                                      );
                                    },
                                  ),
                                  const SizedBox(width: 8),
                                  _ModernActionButton(
                                    icon: Icons.delete_forever,
                                    label: 'Delete',
                                    onTap: _deleteSelectedItems,
                                  ),
                                ],
                                const SizedBox(width: 8),
                                _ModernActionButton(
                                  icon: Icons.auto_fix_high,
                                  label: 'Remove dup',
                                  onTap: _removeDuplicateTitles,
                                ),
                                const SizedBox(width: 8),
                                _ModernActionButton(
                                  icon: Icons.cleaning_services,
                                  label: 'Clean playlists',
                                  onTap: _cleanupPlaylists,
                                ),
                              ] else ...[
                                _ModernActionButton(
                                  icon: Icons.select_all,
                                  label: 'Select',
                                  onTap: () => setState(() => _isDeleteMode = true),
                                ),
                                const SizedBox(width: 8),
                                _ModernActionButton(
                                  icon: Icons.drive_file_rename_outline,
                                  label: 'Replace artist',
                                  onTap: () async {
                                    final from = await _promptText(context, 'Current artist (exact match)', initial: '');
                                    if (from == null) return;
                                    final to = await _promptText(context, 'New artist (channel name)', initial: '');
                                    if (to == null) return;
                                    final changed = await _svc.bulkReplaceArtist(from, to);
                                    await _loadLibraryItems();
                                    if (!mounted) return;
                                    setState(() {});
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('Updated $changed items')),
                                    );
                                  },
                                ),
                                const SizedBox(width: 8),
                                _ModernActionButton(
                                  icon: Icons.refresh,
                                  label: 'Rescan',
                                  onTap: () async {
                                    final ok = await _ensureStoragePermission();
                                    if (!ok) return;
                                    // Update JSON and UI order (preserve manual order)
                                    await _scanAndSaveLibraryToJson();
                                    if (!mounted) return;
                                    // Rescanned - silently continue
                                  },
                                ),
                              ],
                            ],
                          ),
                        ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          
           // Content
           SliverPadding(
             padding: const EdgeInsets.all(20),
             sliver: _showPlaylists
                 ? SliverList(
                     delegate: SliverChildBuilderDelegate(
                       (context, index) {
                         final names = _playlists.keys.toList()
                           ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
                         final q = _filterController.text.trim().toLowerCase();
                         final filtered = q.isEmpty ? names : names.where((n) => n.toLowerCase().contains(q)).toList();
                         
                         // 첫 번째 아이템은 플레이리스트 추가 버튼
                         if (index == 0) {
                           return Container(
                             margin: const EdgeInsets.only(bottom: 8),
                             decoration: BoxDecoration(
                               color: const Color(0xFF1A1A1A),
                               borderRadius: BorderRadius.circular(12),
                               border: Border.all(color: Colors.white.withOpacity(0.2), width: 1),
                             ),
                             child: ListTile(
                               leading: Container(
                                 width: 48,
                                 height: 48,
                                 decoration: BoxDecoration(
                                   color: const Color(0xFF2A2A2A),
                                   borderRadius: BorderRadius.circular(8),
                                 ),
                                child: const Icon(
                                  Icons.add,
                                  color: Colors.white70,
                                  size: 24,
                                ),
                              ),
                              title: const Text(
                                 'Create New Playlist',
                                 style: TextStyle(
                                   fontSize: 16,
                                   fontWeight: FontWeight.w600,
                                   color: Colors.white,
                                 ),
                               ),
                               subtitle: const Text(
                                 'Add a new playlist to your library',
                                 style: TextStyle(
                                   color: Colors.white70,
                                   fontSize: 14,
                                 ),
                               ),
                               onTap: () async {
                                 final name = await _promptText(context, 'Create Playlist', initial: '');
                                 if (name != null && name.trim().isNotEmpty) {
                                   await _svc.create(name.trim());
                                   await _loadPlaylists();
                                   setState(() {});
                                 }
                               },
                             ),
                           );
                         }
                         
                         // 실제 플레이리스트 아이템들 (인덱스 1부터 시작)
                         final playlistIndex = index - 1;
                         if (playlistIndex >= filtered.length) return null;
                         final name = filtered[playlistIndex];
                         final count = _playlists[name]?.length ?? 0;
                         
                         return Container(
                           margin: const EdgeInsets.only(bottom: 8),
                           decoration: BoxDecoration(
                             color: const Color(0xFF2A2A2A),
                             borderRadius: BorderRadius.circular(12),
                           ),
                           child: ListTile(
                             leading: Container(
                               width: 48,
                               height: 48,
                               decoration: BoxDecoration(
                                 color: const Color(0xFF1A1A1A),
                                 borderRadius: BorderRadius.circular(8),
                               ),
                               child: const Icon(
                                 Icons.queue_music,
                                 color: Colors.white70,
                                 size: 24,
                               ),
                             ),
                             title: Text(
                               name,
                               style: const TextStyle(
                                 fontSize: 16,
                                 fontWeight: FontWeight.w600,
                                 color: Colors.white,
                               ),
                               maxLines: 1,
                               overflow: TextOverflow.ellipsis,
                             ),
                             subtitle: Text(
                               '$count tracks',
                               style: const TextStyle(
                                 color: Colors.white70,
                                 fontSize: 14,
                               ),
                             ),
                             trailing: Row(
                               mainAxisSize: MainAxisSize.min,
                               children: [
                                 IconButton(
                                   icon: const Icon(Icons.play_arrow_rounded, color: Colors.white54),
                                   onPressed: () async {
                                     final entries = _playlists[name] ?? const [];
                                     if (entries.isEmpty) return;
                                     await widget.handler.clearQueueWithoutSaving();
                                     await widget.handler.addQueueItems(entries.map((e) => e.toMediaItem()).toList());
                                     await widget.handler.play();
                                   },
                                 ),
                                Theme(
                                  data: Theme.of(context).copyWith(
                                    popupMenuTheme: const PopupMenuThemeData(
                                      color: Color(0xFF1E1E1E),
                                      elevation: 8,
                                      textStyle: TextStyle(color: Colors.white),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.all(Radius.circular(12)),
                                      ),
                                    ),
                                  ),
                                  child: PopupMenuButton<String>(
                                    tooltip: 'More options',
                                    icon: const Icon(Icons.more_vert, color: Colors.white70),
                                    offset: const Offset(0, 8),
                                    constraints: const BoxConstraints(minWidth: 220),
                                    itemBuilder: (context) => [
                                      PopupMenuItem(
                                        value: 'play',
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                        child: Row(
                                          children: const [
                                            Icon(Icons.play_arrow_rounded, color: Colors.white70, size: 20),
                                            SizedBox(width: 12),
                                            Expanded(
                                              child: Text(
                                                'Play',
                                                style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      PopupMenuItem(
                                        value: 'shuffle',
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                        child: Row(
                                          children: const [
                                            Icon(Icons.shuffle_rounded, color: Colors.white70, size: 20),
                                            SizedBox(width: 12),
                                            Expanded(
                                              child: Text(
                                                'Shuffle Play',
                                                style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      PopupMenuItem(
                                        value: 'edit',
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                        child: Row(
                                          children: const [
                                            Icon(Icons.edit_outlined, color: Colors.white70, size: 20),
                                            SizedBox(width: 12),
                                            Expanded(
                                              child: Text(
                                                'Edit',
                                                style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      PopupMenuItem(
                                        value: 'delete',
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                        child: Row(
                                          children: const [
                                            Icon(Icons.delete_outline, color: Colors.white70, size: 20),
                                            SizedBox(width: 12),
                                            Expanded(
                                              child: Text(
                                                'Delete',
                                                style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                    onSelected: (value) async {
                                      final entries = _playlists[name] ?? const [];
                                      if (entries.isEmpty) return;
                                      
                                      switch (value) {
                                       case 'play':
                                         await widget.handler.clearQueueWithoutSaving();
                                         await widget.handler.addQueueItems(entries.map((e) => e.toMediaItem()).toList());
                                         await widget.handler.play();
                                         break;
                                       case 'shuffle':
                                         await widget.handler.clearQueueWithoutSaving();
                                         
                                         // Create shuffled list for queue (playlist order remains unchanged)
                                         final shuffledEntries = List<PlaylistEntry>.from(entries)..shuffle();
                                         await widget.handler.addQueueItems(shuffledEntries.map((e) => e.toMediaItem()).toList());
                                         await widget.handler.setShuffleMode(AudioServiceShuffleMode.all);
                                         await widget.handler.play();
                                         break;
                                       case 'edit':
                                         await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlaylistDetailPage(name: name, handler: widget.handler)));
                                         await _loadPlaylists();
                                         setState(() {});
                                         break;
                                       case 'delete':
                                         final confirm = await _confirm(context, 'Delete playlist "$name"?');
                                         if (confirm == true) {
                                           await _svc.delete(name);
                                           await _loadPlaylists();
                                           setState(() {});
                                         }
                                        break;
                                      }
                                    },
                                  ),
                                ),
                               ],
                             ),
                            onTap: () async {
                              selectPlaylist(name);
                            },
                           ),
                         );
                       },
                       childCount: () {
                         final names = _playlists.keys.toList()
                           ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
                         final q = _filterController.text.trim().toLowerCase();
                         final filtered = q.isEmpty ? names : names.where((n) => n.toLowerCase().contains(q)).toList();
                         return filtered.length + 1; // +1 for the "Create New Playlist" button
                       }(),
                     ),
                   )
                 : Builder(
                     builder: (context) {
                       // Show loading indicator if library is empty and not yet loaded
                       if (_libraryItems.isEmpty) {
                         return const SliverToBoxAdapter(
                           child: Center(
                             child: Padding(
                               padding: EdgeInsets.all(32),
                               child: CircularProgressIndicator(),
                             ),
                           ),
                         );
                       }
                       
                       var items = <MediaItem>[];
                       
                       if (widget.selectedPlaylist != null) {
                         // Show selected playlist songs
                         final playlistEntries = _playlists[widget.selectedPlaylist!] ?? [];
                         items = playlistEntries.map((e) => e.toMediaItem()).toList();
                       } else {
                         // Show all library songs
                         items = List<MediaItem>.from(_libraryItems);
                       }
                       
                       final q = _filterController.text.trim().toLowerCase();
                       if (q.isNotEmpty) {
                         items = items
                             .where((e) => e.title.toLowerCase().contains(q) || (e.artist ?? '').toLowerCase().contains(q))
                             .toList();
                       }
                       // Library items are already in download time order from JSON

                       // Show empty message if no items after filtering
                       if (items.isEmpty) {
                         return SliverToBoxAdapter(
                           child: Column(
                             children: [
                               const Center(
                                 child: Padding(
                                   padding: EdgeInsets.all(32),
                                   child: Text(
                                     'No music found',
                                     style: TextStyle(
                                       color: Colors.white70,
                                       fontSize: 16,
                                     ),
                                   ),
                                 ),
                               ),
                               // Add music section (show even when playlist is empty)
                               if (widget.selectedPlaylist != null) ...[
                                 const SizedBox(height: 24),
                                 _AddMusicToPlaylistSection(
                                   playlistName: widget.selectedPlaylist!,
                                   onMusicAdded: () async {
                                     await _loadPlaylists();
                                     setState(() {});
                                   },
                                 ),
                               ],
                             ],
                           ),
                         );
                       }

                       return SliverToBoxAdapter(
                         child: Column(
                           children: [
                             // Playlist songs
                            ReorderableListView.builder(
                           shrinkWrap: true,
                           physics: const NeverScrollableScrollPhysics(),
                              buildDefaultDragHandles: false,
                           proxyDecorator: (child, index, animation) {
                             return Material(
                               color: Colors.transparent,
                               child: child,
                             );
                           },
                           onReorder: (oldIndex, newIndex) async {
                             if (oldIndex < newIndex) newIndex--;
                                 // If a playlist is selected, reorder its entries and save to JSON
                                 if (widget.selectedPlaylist != null) {
                                   final current = await _svc.loadPlaylist(widget.selectedPlaylist!);
                                   if (oldIndex >= 0 && oldIndex < current.length) {
                                     final moved = current.removeAt(oldIndex);
                                     if (newIndex < 0) newIndex = 0;
                                     if (newIndex > current.length) newIndex = current.length;
                                     current.insert(newIndex, moved);
                                     // Persist
                                     final all = await _svc.load();
                                     all[widget.selectedPlaylist!] = current;
                                     await _svc.save(all);
                                     // Refresh view model lists
                                     await _loadPlaylists();
                                   }
                                 } else {
                                   // Otherwise, reorder library list and persist to JSON
                                   final newItems = List<MediaItem>.from(_libraryItems);
                                   final item = newItems.removeAt(oldIndex);
                                   newItems.insert(newIndex, item);
                                   _libraryItems = newItems;
                                   // Persist library order
                                   final entries = _libraryItems.map((e) => PlaylistEntry.fromMediaItem(e)).toList();
                                   await _svc.saveLibrary(entries);
                                 }
                                 setState(() {});
                           },
                           itemBuilder: (context, index) {
                             if (index >= items.length) return const SizedBox.shrink();
                             final item = items[index];
                             final art = item.artUri;
                             final isSelected = _selectedItems.contains(item.id);
                             
                           return Container(
                              key: ValueKey(item.id),
                                margin: const EdgeInsets.only(bottom: 8),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF2A2A2A),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: ListTile(
                                 leading: _isDeleteMode 
                                   ? Checkbox(
                                       value: isSelected,
                                       onChanged: (value) {
                                         setState(() {
                                           if (value == true) {
                                             _selectedItems.add(item.id);
                                           } else {
                                             _selectedItems.remove(item.id);
                                           }
                                         });
                                       },
                                     )
                                   : ClipRRect(
                                       borderRadius: BorderRadius.circular(8),
                                       child: SizedBox(
                                         width: 48,
                                         height: 48,
                                         child: art != null
                                             ? _ArtworkImage(uri: art)
                                             : const ColoredBox(
                                                 color: Color(0xFF1A1A1A),
                                                 child: Icon(Icons.music_note, color: Colors.white70),
                                               ),
                                       ),
                                    ),
                                  title: Text(
                                   item.title,
                                   style: const TextStyle(
                                     fontSize: 16,
                                     fontWeight: FontWeight.w600,
                                     color: Colors.white,
                                   ),
                                   maxLines: 1,
                                   overflow: TextOverflow.ellipsis,
                                 ),
                                  subtitle: Text(
                                   _librarySubtitle(item),
                                   style: const TextStyle(
                                     color: Colors.white70,
                                     fontSize: 14,
                                   ),
                                   maxLines: 1,
                                   overflow: TextOverflow.ellipsis,
                                 ),
                                  trailing: _isDeleteMode 
                                   ? null
                                   : Row(
                                       mainAxisSize: MainAxisSize.min,
                                       children: [
                                      Theme(
                                         data: Theme.of(context).copyWith(
                                           popupMenuTheme: const PopupMenuThemeData(
                                             color: Color(0xFF1E1E1E),
                                             elevation: 8,
                                             textStyle: TextStyle(color: Colors.white),
                                             shape: RoundedRectangleBorder(
                                               borderRadius: BorderRadius.all(Radius.circular(12)),
                                             ),
                                           ),
                                         ),
                                         child: PopupMenuButton<String>(
                                           tooltip: 'More options',
                                           icon: const Icon(Icons.more_vert, color: Colors.white70),
                                           offset: const Offset(0, 8),
                                           constraints: const BoxConstraints(minWidth: 220),
                                           itemBuilder: (context) => [
                                             PopupMenuItem(
                                               value: 'add',
                                               padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                               child: Row(
                                                 children: const [
                                                   Icon(Icons.playlist_add, color: Colors.white70, size: 20),
                                                   SizedBox(width: 12),
                                                   Expanded(
                                                     child: Text('Add to playlist',
                                                       style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                                                       overflow: TextOverflow.ellipsis,
                                                     ),
                                                   ),
                                                 ],
                                               ),
                                             ),
                                             PopupMenuItem(
                                               value: 'rename',
                                               padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                               child: Row(
                                                 children: const [
                                                   Icon(Icons.edit_outlined, color: Colors.white70, size: 20),
                                                   SizedBox(width: 12),
                                                   Expanded(
                                                     child: Text('Rename',
                                                       style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                                                       overflow: TextOverflow.ellipsis,
                                                     ),
                                                   ),
                                                 ],
                                               ),
                                             ),
                                             PopupMenuItem(
                                               value: 'remove',
                                               padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                               child: Row(
                                                 children: [
                                                   const Icon(Icons.delete_outline, color: Colors.white70, size: 20),
                                                   const SizedBox(width: 12),
                                                   Expanded(
                                                     child: Text(
                                                       widget.selectedPlaylist != null ? 'Remove from playlist' : 'Remove from library',
                                                       style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                                                       overflow: TextOverflow.ellipsis,
                                                     ),
                                                   ),
                                                 ],
                                               ),
                                             ),
                                           ],
                                           onSelected: (v) async {
                                            if (v == 'add') {
                                              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => AddToPlaylistSheet(item: item)));
                                            } else if (v == 'remove') {
                                              if (widget.selectedPlaylist != null) {
                                                // Remove only from this playlist
                                                await _svc.removeTrack(widget.selectedPlaylist!, item.id);
                                                await _loadPlaylists();
                                                setState(() {});
                                              } else {
                                                // Remove from library (delete from device)
                                                final confirm = await _confirm(context, 'Delete this file from device?');
                                                if (confirm != true) return;
                                                await _deleteFromDisk(item.id);
                                                await widget.handler.removeQueueItemById(item.id);
                                                try {
                                                  final svc = PlaylistsService();
                                                  await svc.removeTrackFromAllPlaylists(item.id);
                                                } catch (e) {
                                                  print('Failed to remove from playlists: $e');
                                                }
                                                if (!mounted) return;
                                                // Deleted from device - silently continue
                                              }
                                            } else if (v == 'rename') {
                                              // Prompt for both title and artist (channel name)
                                              final entry = _savedEntriesById[item.id];
                                              final initialTitle = entry?.title ?? item.title;
                                              final initialArtist = entry?.artist ?? (item.artist ?? '');
                                              final updated = await showDialog<Map<String, String>>(
                                                context: context,
                                                builder: (ctx) {
                                                  final titleCtrl = TextEditingController(text: initialTitle);
                                                  final artistCtrl = TextEditingController(text: initialArtist);
                                                  return AlertDialog(
                                                    backgroundColor: const Color(0xFF1E1E1E),
                                                    title: const Text('Edit metadata', style: TextStyle(color: Colors.white)),
                                                    content: Column(
                                                      mainAxisSize: MainAxisSize.min,
                                                      children: [
                                                        TextField(
                                                          controller: titleCtrl,
                                                          decoration: const InputDecoration(
                                                            labelText: 'Title',
                                                            labelStyle: TextStyle(color: Colors.white70),
                                                          ),
                                                          style: const TextStyle(color: Colors.white),
                                                        ),
                                                        const SizedBox(height: 12),
                                                        TextField(
                                                          controller: artistCtrl,
                                                          decoration: const InputDecoration(
                                                            labelText: 'Artist (Channel name)',
                                                            labelStyle: TextStyle(color: Colors.white70),
                                                          ),
                                                          style: const TextStyle(color: Colors.white),
                                                        ),
                                                      ],
                                                    ),
                                                    actions: [
                                                      TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
                                                      TextButton(onPressed: () => Navigator.of(ctx).pop({ 'title': titleCtrl.text.trim(), 'artist': artistCtrl.text.trim() }), child: const Text('Save')),
                                                    ],
                                                  );
                                                },
                                              );
                                              if (updated != null) {
                                                final newTitle = (updated['title'] ?? '').trim();
                                                final newArtist = (updated['artist'] ?? '').trim();
                                                // Persist to library JSON
                                                await _svc.updateLibraryMetadata(id: item.id, title: newTitle, artist: newArtist);
                                                // Update queue item if present
                                                final index = (widget.handler.queue.valueOrNull ?? const [])
                                                    .indexWhere((e) => e.id == item.id);
                                                if (index >= 0) {
                                                  await widget.handler.updateQueueItem(index, item.copyWith(title: newTitle.isNotEmpty ? newTitle : item.title, artist: newArtist));
                                                }
                                                // Reload library list/cache
                                                await _loadLibraryItems();
                                                if (mounted) setState(() {});
                                              }
                                            }
                                           },
                                         ),
                                        ),
                                        ReorderableDelayedDragStartListener(
                                          index: index,
                                          child: Padding(
                                            padding: EdgeInsets.all(8),
                                            child: Icon(
                                              Icons.drag_handle,
                                              color: Colors.white54,
                                              size: 20,
                                            ),
                                          ),
                                        ),
                                       ],
                                     ),
                                 onTap: () async {
                                   if (_isDeleteMode) {
                                     setState(() {
                                       if (isSelected) {
                                         _selectedItems.remove(item.id);
                                       } else {
                                         _selectedItems.add(item.id);
                                       }
                                     });
                                  } else {
                                    // Create new queue based on the currently displayed list (playlist or full library)
                                    final displayedItems = items; // Use the same source as the builder
                                    final selectedIndex = displayedItems.indexWhere((e) => e.id == item.id);
                                    if (selectedIndex >= 0) {
                                      // Check shuffle mode
                                      final shuffleMode = widget.handler.playbackState.valueOrNull?.shuffleMode ?? AudioServiceShuffleMode.none;
                                      
                                      if (shuffleMode == AudioServiceShuffleMode.all) {
                                        // Shuffle mode: create shuffled queue from displayed items only
                                        final shuffledItems = List<MediaItem>.from(displayedItems)..shuffle();
                                        // Put selected music first
                                        final selectedItem = shuffledItems.removeAt(shuffledItems.indexWhere((e) => e.id == item.id));
                                        shuffledItems.insert(0, selectedItem);
                                        
                                        await widget.handler.clearQueueWithoutSaving();
                                        await widget.handler.addQueueItems(shuffledItems);
                                        await widget.handler.play();
                                      } else {
                                        // Normal mode: play in the displayed order starting from the tapped item
                                        final newQueue = <MediaItem>[];
                                        
                                        // Add from selected index to end
                                        for (int i = selectedIndex; i < displayedItems.length; i++) {
                                          newQueue.add(displayedItems[i]);
                                        }
                                        
                                        // Add remaining songs from beginning
                                        for (int i = 0; i < selectedIndex; i++) {
                                          newQueue.add(displayedItems[i]);
                                        }
                                        
                                        await widget.handler.clearQueueWithoutSaving();
                                        await widget.handler.addQueueItems(newQueue);
                                        await widget.handler.play();
                                      }
                                    }
                                  }
                                 },
                              ),
                            );
                          },
                           itemCount: items.length,
                           ),
                         
                         // Add music section (only show when playlist is selected)
                         if (widget.selectedPlaylist != null) ...[
                           const SizedBox(height: 24),
                           _AddMusicToPlaylistSection(
                             playlistName: widget.selectedPlaylist!,
                             onMusicAdded: () async {
                               await _loadPlaylists();
                               setState(() {});
                             },
                           ),
                         ],
                       ],
                     ),
                   );
                     },
                   ),
           ),
        ],
      ),
    ),
    );
  }


  String _librarySubtitle(MediaItem item) {
    print('=== LIBRARY SUBTITLE DEBUG ===');
    print('Title: ${item.title}');
    print('Artist: ${item.artist}');
    print('Duration: ${item.duration}');
    // Extra debug: show saved artist/duration from JSON if MediaItem is missing them
    final saved = _savedEntriesById[item.id];
    if (saved != null) {
      print('Saved Artist: ${saved.artist}');
      print('Saved DurationMs: ${saved.durationMs}');
    } else {
      print('Saved entry: (none)');
    }
    
    final parts = <String>[];
    final displayArtist = (item.artist != null && item.artist!.isNotEmpty)
        ? item.artist!
        : (saved?.artist ?? '');
    final displayDuration = item.duration ??
        (saved?.durationMs != null ? Duration(milliseconds: saved!.durationMs!) : null);

    if (displayArtist.isNotEmpty) parts.add(displayArtist);
    if (displayDuration != null) parts.add(_formatDuration(displayDuration));
    final result = parts.isEmpty ? '' : parts.join(' • ');
    
    print('Subtitle result: $result');
    return result;
  }

  Future<void> _deleteSelectedItems() async {
    if (_selectedItems.isEmpty) return;
    
    final confirm = await _confirm(context, 'Delete ${_selectedItems.length} selected items from device?');
    if (confirm != true) return;
    
    int deletedCount = 0;
    for (final itemId in _selectedItems) {
      try {
        await _deleteFromDisk(itemId);
        await widget.handler.removeQueueItemById(itemId);
        try {
          final svc = PlaylistsService();
          await svc.removeTrackFromAllPlaylists(itemId);
        } catch (e) {
          print('Failed to remove from playlists: $e');
        }
        deletedCount++;
      } catch (e) {
        print('Failed to delete item $itemId: $e');
      }
    }
    
    setState(() {
      _isDeleteMode = false;
      _selectedItems.clear();
    });
    
    if (!mounted) return;
    // Deleted items - silently continue
  }

  Future<void> _removeDuplicateTitles() async {
    if (_libraryItems.isEmpty) return;

    // Debug: print full title list and counts
    try {
      final titles = _libraryItems.map((e) => e.title).toList();
      print('[Dedup] Total items: ${_libraryItems.length}');
      print('[Dedup] Titles:');
      for (final t in titles) {
        print(' - "$t"');
      }
      String base(String s) => s.trim().replaceAll(RegExp(r'_(\d+)$'), '');
      final counts = <String, int>{};
      for (final t in titles) {
        final k = base(t);
        counts[k] = (counts[k] ?? 0) + 1;
      }
      print('[Dedup] Duplicate base-title candidates (count > 1):');
      counts.entries.where((e) => e.value > 1).forEach((e) => print(' * base="${e.key}": ${e.value}'));
    } catch (e) {
      print('[Dedup] Debug print failed: $e');
    }

    String baseTitle(String s) => s.trim().replaceAll(RegExp(r'_(\d+)$'), '');
    final seenByTitle = <String, String>{}; // base title (strip trailing _n) -> kept itemId
    final duplicates = <MediaItem>[];

    for (final item in _libraryItems) {
      final key = baseTitle(item.title);
      if (key.isEmpty) continue;
      if (!seenByTitle.containsKey(key)) {
        seenByTitle[key] = item.id; // keep first encounter
      } else {
        duplicates.add(item);
      }
    }

    if (duplicates.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('중복 없음 (제목 기준)')));
      return;
    }

    // Debug: list duplicates that will be removed
    print('[Dedup] Duplicates to remove (${duplicates.length}) (by base title):');
    for (final d in duplicates) {
      print(' - title="${d.title}", base="${baseTitle(d.title)}", id=${d.id}');
    }

    final confirm = await _confirm(context, '중복 음악 ${duplicates.length}개를 삭제할까요?');
    if (confirm != true) return;

    for (final item in duplicates) {
      try {
        await _deleteFromDisk(item.id);
        await widget.handler.removeQueueItemById(item.id);
        try {
          final svc = PlaylistsService();
          await svc.removeTrackFromAllPlaylists(item.id);
        } catch (e) {
          print('Failed to remove from playlists: $e');
        }
      } catch (e) {
        print('Failed to remove duplicate ${item.id}: $e');
      }
    }

    await _scanAndSaveLibraryToJson();
    if (!mounted) return;
    setState(() {
      _isDeleteMode = false;
      _selectedItems.clear();
    });
  }

  Future<void> _cleanupPlaylists() async {
    if (!mounted) return;
    
    // Show loading indicator
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: CircularProgressIndicator(),
      ),
    );

    try {
      final removedCount = await _svc.cleanupDeletedFiles();
      
      if (!mounted) return;
      Navigator.of(context).pop(); // Close loading dialog
      
      await _loadPlaylists();
      setState(() {});
      
      if (removedCount > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('플레이리스트에서 ${removedCount}개의 삭제된 파일을 정리했습니다.'))
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('정리할 파일이 없습니다.'))
        );
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop(); // Close loading dialog
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('정리 중 오류가 발생했습니다: $e'))
      );
    }
  }
}

class _AddMusicToPlaylistSection extends StatefulWidget {
  final String playlistName;
  final VoidCallback onMusicAdded;
  const _AddMusicToPlaylistSection({
    required this.playlistName,
    required this.onMusicAdded,
  });

  @override
  State<_AddMusicToPlaylistSection> createState() => _AddMusicToPlaylistSectionState();
}

class _AddMusicToPlaylistSectionState extends State<_AddMusicToPlaylistSection> {
  final _svc = PlaylistsService();
  List<MediaItem> _availableMusic = [];
  List<MediaItem> _filteredMusic = [];
  int _currentPage = 0;
  final int _itemsPerPage = 5;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadAvailableMusic();
  }

  Future<void> _loadAvailableMusic() async {
    setState(() => _loading = true);
    try {
      // Get all library items
      final libraryItems = await _svc.loadLibrary();
      
      if (libraryItems.isEmpty) {
        // If library is empty, scan file system
        print('Library is empty, scanning file system for available music...');
        _availableMusic = await _scanFileSystemForMusic();
      } else {
        _availableMusic = libraryItems.map((e) => e.toMediaItem()).toList();
      }
      
      // Filter out songs already in the playlist
      await _filterOutExistingSongs();
    } catch (e) {
      print('Error loading available music: $e');
      // Fallback to file system scan
      _availableMusic = await _scanFileSystemForMusic();
      await _filterOutExistingSongs();
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _filterOutExistingSongs() async {
    try {
      // Get current playlist songs
      final playlist = await _svc.loadPlaylist(widget.playlistName);
      final existingIds = playlist.map((e) => e.id).toSet();
      
      // Filter out songs that are already in the playlist
      _filteredMusic = _availableMusic.where((item) => !existingIds.contains(item.id)).toList();
    } catch (e) {
      print('Error filtering existing songs: $e');
      _filteredMusic = _availableMusic;
    }
  }

  Future<List<MediaItem>> _scanFileSystemForMusic() async {
    Directory? baseDir;
    if (Platform.isAndroid) {
      final dirs = await getExternalStorageDirectories(type: StorageDirectory.music);
      baseDir = (dirs != null && dirs.isNotEmpty) ? dirs.first : await getExternalStorageDirectory();
    } else {
      baseDir = await getApplicationDocumentsDirectory();
    }
    
    if (baseDir == null) {
      print('Base directory is null');
      return [];
    }
    
    final target = Platform.isAndroid ? Directory('${baseDir.path}/Jupotify') : Directory('${baseDir.path}/Music/Jupotify');
    if (!await target.exists()) {
      print('Target directory does not exist: ${target.path}');
      return [];
    }
    
    final allowed = {'.mp3', '.m4a', '.aac', '.wav', '.flac', '.ogg', '.mp4', '.webm'};
    final items = <MediaItem>[];
    
    await for (final entity in target.list(recursive: true, followLinks: false)) {
      if (entity is File && allowed.contains(_ext(entity.path))) {
        final base = entity.path.substring(0, entity.path.lastIndexOf('.'));
        final artPath = File('$base.jpg');
        items.add(MediaItem(
          id: entity.path,
          title: _fileNameNoExt(entity.path),
          artist: '', // Will be loaded from saved metadata
          artUri: artPath.existsSync() ? Uri.file(artPath.path) : null,
          extras: {'uri': Uri.file(entity.path).toString()},
        ));
      }
    }
    
    print('Scanned ${items.length} music files from file system');
    return items;
  }

  String _ext(String path) {
    final i = path.lastIndexOf('.');
    return i == -1 ? '' : path.substring(i).toLowerCase();
  }

  String _fileNameNoExt(String path) {
    final i = path.lastIndexOf('/');
    final name = i == -1 ? path : path.substring(i + 1);
    final j = name.lastIndexOf('.');
    return j == -1 ? name : name.substring(0, j);
  }

  Future<void> _addToPlaylist(MediaItem item) async {
    try {
      await _svc.addToPlaylist(widget.playlistName, PlaylistEntry.fromMediaItem(item));
      
      // Remove the added song from filtered music list
      setState(() {
        _filteredMusic.removeWhere((music) => music.id == item.id);
        // Reset to first page if current page is empty
        if (_currentPage > 0 && _filteredMusic.length <= _currentPage * _itemsPerPage) {
          _currentPage = 0;
        }
      });
      
      widget.onMusicAdded();
    } catch (e) {
      if (mounted) {
        // Failed to add music - silently continue
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: CircularProgressIndicator(),
        ),
      );
    }

    final startIndex = _currentPage * _itemsPerPage;
    final endIndex = (startIndex + _itemsPerPage).clamp(0, _filteredMusic.length);
    final currentItems = _filteredMusic.sublist(startIndex, endIndex);
    final totalPages = (_filteredMusic.length / _itemsPerPage).ceil();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Colors.white.withOpacity(0.1),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Add Music to Playlist',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              if (totalPages > 1) ...[
                Row(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: _currentPage > 0 ? Colors.white.withOpacity(0.1) : Colors.white.withOpacity(0.05),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.chevron_left, color: Colors.white, size: 20),
                        onPressed: _currentPage > 0 ? () => setState(() => _currentPage--) : null,
                        tooltip: 'Previous page',
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: _currentPage < totalPages - 1 ? Colors.white.withOpacity(0.1) : Colors.white.withOpacity(0.05),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.chevron_right, color: Colors.white, size: 20),
                        onPressed: _currentPage < totalPages - 1 ? () => setState(() => _currentPage++) : null,
                        tooltip: 'Next page',
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          if (currentItems.isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  children: [
                    Icon(
                      _filteredMusic.isEmpty ? Icons.music_off : Icons.check_circle,
                      color: _filteredMusic.isEmpty ? Colors.white70 : Colors.green,
                      size: 48,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _filteredMusic.isEmpty ? 'No music available' : 'All songs added to playlist',
                      style: TextStyle(
                        color: _filteredMusic.isEmpty ? Colors.white70 : Colors.green,
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (_filteredMusic.isEmpty) ...[
                      const SizedBox(height: 8),
                      const Text(
                        'Download some music first',
                        style: TextStyle(color: Colors.white54, fontSize: 14),
                      ),
                    ],
                  ],
                ),
              ),
            )
          else
            ...currentItems.map((item) => Container(
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF2A2A2A),
                borderRadius: BorderRadius.circular(8),
              ),
              child: ListTile(
                leading: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: Colors.white.withOpacity(0.1),
                  ),
                  child: item.artUri != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: _ArtworkImage(uri: item.artUri!),
                        )
                      : Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [Colors.white.withOpacity(0.1), Colors.white.withOpacity(0.05)],
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(
                            Icons.music_note,
                            color: Colors.white70,
                            size: 24,
                          ),
                        ),
                ),
                title: Text(
                  item.title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Colors.white,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  item.artist ?? 'Unknown Artist',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: IconButton(
                    icon: const Icon(Icons.add, color: Colors.white, size: 20),
                    onPressed: () => _addToPlaylist(item),
                    tooltip: 'Add to playlist',
                  ),
                ),
              ),
            )),
        ],
      ),
    );
  }
}

class _PlaylistRow extends StatelessWidget {
  final String title;
  const _PlaylistRow({required this.title});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        ),
        SizedBox(
          height: 150,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemBuilder: (_, i) => ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: 150,
                color: const Color(0xFF2A2A2A),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    Icon(Icons.music_note, size: 40, color: Colors.white70),
                    SizedBox(height: 8),
                    Text('Playlist', maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
            ),
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemCount: 10,
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _MiniPlayer extends StatefulWidget {
  final JupotifyAudioHandler handler;
  const _MiniPlayer({required this.handler});

  @override
  State<_MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<_MiniPlayer> {
  bool _isVisible = true;

  @override
  void initState() {
    super.initState();
    // Listen to playback state changes to show mini player when music starts playing
    widget.handler.playbackState.listen((state) {
      if (state.playing && !_isVisible) {
    setState(() {
          _isVisible = true;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Keep a tiny gap and honor device bottom inset only
    final bottomGap = MediaQuery.of(context).padding.bottom + 8;
    if (!_isVisible) return const SizedBox.shrink();
    
    return SafeArea(
      top: false,
      child: Dismissible(
        key: const ValueKey('mini_player'),
        direction: DismissDirection.horizontal,
        onDismissed: (direction) {
          setState(() {
            _isVisible = false;
          });
        },
        child: InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => FullPlayerPage(handler: widget.handler)),
          ),
          child: Container(
            // Sit just above the bottom navigation bar
            margin: EdgeInsets.fromLTRB(12, 0, 12, bottomGap),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF282828),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: SizedBox(
                        width: 44,
                        height: 44,
                        child: StreamBuilder<MediaItem?>(
                          stream: widget.handler.mediaItem,
                          initialData: widget.handler.mediaItem.valueOrNull,
                          builder: (context, snap) {
                            final item = snap.data;
                            if (item?.artUri != null) {
                              return _ArtworkImage(uri: item!.artUri!);
                            }
                            return Container(
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [Color(0xFF3E3E3E), Color(0xFF2A2A2A)],
                                ),
                              ),
                              child: const Icon(
                                Icons.music_note,
                                color: Colors.white70,
                                size: 20,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: StreamBuilder<MediaItem?>(
                        stream: widget.handler.mediaItem,
                        initialData: widget.handler.mediaItem.valueOrNull,
                        builder: (context, snap) {
                          final item = snap.data;
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
            Text(
                                item?.title != null && item!.title.length > 10 
                                  ? '${item.title.substring(0, 10)}...' 
                                  : (item?.title ?? 'Nothing playing'), 
                                maxLines: 1, 
                                overflow: TextOverflow.ellipsis
                              ),
                              const SizedBox(height: 2),
                              Text(item?.artist ?? '', style: const TextStyle(color: Colors.white70), maxLines: 1, overflow: TextOverflow.ellipsis),
                            ],
                          );
                        },
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.skip_previous_rounded),
                      onPressed: widget.handler.skipToPrevious,
                    ),
                    StreamBuilder<bool>(
                      stream: widget.handler.playbackState.map((s) => s.playing).distinct(),
                      initialData: widget.handler.playbackState.valueOrNull?.playing ?? false,
                      builder: (context, snap) {
                        final playing = snap.data ?? false;
                        return IconButton(
                          icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                          color: theme.colorScheme.primary,
                          onPressed: () => playing ? widget.handler.pause() : widget.handler.play(),
                        );
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.skip_next_rounded),
                      onPressed: () async {
                        try {
                          await widget.handler.skipToNext();
                        } catch (e) {
                          print('Error in mini player skipToNext: $e');
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                // Slim progress bar
                StreamBuilder<Duration>(
                  stream: widget.handler.positionStream,
                  initialData: Duration.zero,
                  builder: (context, posSnap) {
                    final pos = posSnap.data ?? Duration.zero;
                    return StreamBuilder<MediaItem?>(
                      stream: widget.handler.mediaItem,
                      initialData: widget.handler.mediaItem.valueOrNull,
                      builder: (context, itemSnap) {
                        final dur = itemSnap.data?.duration ?? Duration.zero;
                        final value = dur.inMilliseconds == 0 ? null : (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0);
                        return LinearProgressIndicator(
                          value: value,
                          minHeight: 2,
                          backgroundColor: const Color(0xFF3A3A3A),
                        );
                      },
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class FullPlayerPage extends StatefulWidget {
  final JupotifyAudioHandler handler;
  const FullPlayerPage({required this.handler, super.key});

  @override
  State<FullPlayerPage> createState() => _FullPlayerPageState();
}

class _FullPlayerPageState extends State<FullPlayerPage> with TickerProviderStateMixin {
  late AnimationController _albumArtController;
  late AnimationController _fadeController;
  late Animation<double> _albumArtAnimation;
  late Animation<double> _fadeAnimation;
  String _language = 'en';

  @override
  void initState() {
    super.initState();
    _albumArtController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    
    _albumArtAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _albumArtController,
      curve: Curves.easeOut,
    ));
    
    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeInOut,
    ));
    
    _albumArtController.forward();
    _fadeController.forward();
    _loadUserSettings();
  }

  Future<void> _loadUserSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final savedLang = prefs.getString('app_language');
    if (!mounted) return;
    if (savedLang != null && savedLang.isNotEmpty) {
      setState(() => _language = savedLang);
    }
  }

  @override
  void dispose() {
    _albumArtController.dispose();
    _fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isTablet = screenWidth >= 768;
    
    return Scaffold(
      backgroundColor: Colors.black,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF3A3A3A), Color(0xFF000000)],
          ),
        ),
        child: SafeArea(
          child: isTablet ? _buildTabletLayout() : _buildMobileLayout(),
        ),
      ),
    );
  }

  Widget _buildMobileLayout() {
    return Column(
      children: [
        // Top bar with back button and like button
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Icon(
                    Icons.keyboard_arrow_down,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
              ),
              StreamBuilder<MediaItem?>(
                stream: widget.handler.mediaItem,
                initialData: widget.handler.mediaItem.valueOrNull,
                builder: (context, snap) {
                  final item = snap.data;
                  return FutureBuilder<bool>(
                    future: item == null ? Future.value(false) : FavoritesService().isFavorite(item.id),
                    builder: (context, favSnap) {
                      final isFav = favSnap.data == true;
                      return GestureDetector(
                        onTap: () async {
                          if (item == null) return;
                          await FavoritesService().toggle(item.id);
                          if (mounted) setState(() {});
                        },
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Icon(
                            isFav ? Icons.favorite : Icons.favorite_border,
                            color: isFav ? Colors.redAccent : Colors.white,
                            size: 24,
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ],
          ),
        ),
        
        // Album art section
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: AspectRatio(
            aspectRatio: 1,
            child: AnimatedBuilder(
              animation: _albumArtAnimation,
              builder: (context, child) {
                return Transform.scale(
                  scale: 0.8 + (0.2 * _albumArtAnimation.value),
                  child: Opacity(
                    opacity: _albumArtAnimation.value,
                    child: StreamBuilder<MediaItem?>(
                      stream: widget.handler.mediaItem,
                      initialData: widget.handler.mediaItem.valueOrNull,
                      builder: (context, snap) {
                        final item = snap.data;
                        return item?.artUri != null
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(20),
                                child: item!.artUri!.isScheme('file')
                                    ? Image.file(
                                        File.fromUri(item.artUri!),
                                        fit: BoxFit.cover,
                                        errorBuilder: (context, error, stackTrace) => Container(
                                          color: Colors.black26,
                                          child: const Icon(Icons.music_note, size: 80, color: Colors.white38),
                                        ),
                                      )
                                    : Image.network(
                                        item.artUri!.toString(),
                                        fit: BoxFit.cover,
                                        errorBuilder: (context, error, stackTrace) => Container(
                                          color: Colors.black26,
                                          child: const Icon(Icons.music_note, size: 80, color: Colors.white38),
                                        ),
                                      ),
                              )
                            : Container(
                                decoration: const BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [Color(0xFF2A2A2A), Color(0xFF1A1A1A)],
                                  ),
                                ),
                                child: const Icon(Icons.music_note, size: 80, color: Colors.white38),
                              );
                      },
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        
        // Song info section
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 10),
          child: AnimatedBuilder(
            animation: _fadeAnimation,
            builder: (context, child) {
              return Opacity(
                opacity: _fadeAnimation.value,
                child: StreamBuilder<MediaItem?>(
                  stream: widget.handler.mediaItem,
                  initialData: widget.handler.mediaItem.valueOrNull,
                  builder: (context, snap) {
                    final item = snap.data;
                    return Column(
                      children: [
                        Text(
                          item?.title ?? 'Nothing playing',
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          item?.artist ?? '',
                          style: const TextStyle(
                            fontSize: 16,
                            color: Colors.white70,
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    );
                  },
                ),
              );
            },
          ),
        ),
        
        // Progress bar section
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: AnimatedBuilder(
            animation: _fadeAnimation,
            builder: (context, child) {
              return Opacity(
                opacity: _fadeAnimation.value,
                child: _ModernPositionSlider(handler: widget.handler),
              );
            },
          ),
        ),
        
        const SizedBox(height: 10),
        
        // Control buttons section
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: AnimatedBuilder(
            animation: _fadeAnimation,
            builder: (context, child) {
              return Opacity(
                opacity: _fadeAnimation.value,
                child: _ModernControlButtons(handler: widget.handler),
              );
            },
          ),
        ),
        
        const SizedBox(height: 20),
        
        // Next up section
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: AnimatedBuilder(
            animation: _fadeAnimation,
            builder: (context, child) {
              return Opacity(
                opacity: _fadeAnimation.value,
                child: _NextUpSection(handler: widget.handler),
              );
            },
          ),
        ),
        
        const Spacer(),
      ],
    );
  }

  Widget _buildTabletLayout() {
    return Row(
      children: [
        // Left side - Album art
        Expanded(
          flex: 1,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Top bar with back button and like button
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Icon(
                          Icons.keyboard_arrow_down,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                    ),
                    StreamBuilder<MediaItem?>(
                      stream: widget.handler.mediaItem,
                      initialData: widget.handler.mediaItem.valueOrNull,
                      builder: (context, snap) {
                        final item = snap.data;
                        return FutureBuilder<bool>(
                          future: item == null ? Future.value(false) : FavoritesService().isFavorite(item.id),
                          builder: (context, favSnap) {
                            final isFav = favSnap.data == true;
                            return GestureDetector(
                              onTap: () async {
                                if (item == null) return;
                                await FavoritesService().toggle(item.id);
                                if (mounted) setState(() {});
                              },
                              child: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Icon(
                                  isFav ? Icons.favorite : Icons.favorite_border,
                                  color: isFav ? Colors.redAccent : Colors.white,
                                  size: 24,
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ],
                ),
              ),
              
              // Album art section (smaller for tablet)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: AnimatedBuilder(
                  animation: _albumArtAnimation,
                  builder: (context, child) {
                    return Transform.scale(
                      scale: 0.8 + (0.2 * _albumArtAnimation.value),
                      child: Opacity(
                        opacity: _albumArtAnimation.value,
                        child: StreamBuilder<MediaItem?>(
                          stream: widget.handler.mediaItem,
                          initialData: widget.handler.mediaItem.valueOrNull,
                          builder: (context, snap) {
                            final item = snap.data;
                            return Container(
                              width: 300,
                              height: 300,
                              child: item?.artUri != null
                                  ? ClipRRect(
                                      borderRadius: BorderRadius.circular(20),
                                      child: item!.artUri!.isScheme('file')
                                          ? Image.file(
                                              File.fromUri(item.artUri!),
                                              fit: BoxFit.cover,
                                              errorBuilder: (context, error, stackTrace) => Container(
                                                color: Colors.black26,
                                                child: const Icon(Icons.music_note, size: 60, color: Colors.white38),
                                              ),
                                            )
                                          : Image.network(
                                              item.artUri!.toString(),
                                              fit: BoxFit.cover,
                                              errorBuilder: (context, error, stackTrace) => Container(
                                                color: Colors.black26,
                                                child: const Icon(Icons.music_note, size: 60, color: Colors.white38),
                                              ),
                                            ),
                                    )
                                  : Container(
                                      decoration: const BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.topLeft,
                                          end: Alignment.bottomRight,
                                          colors: [Color(0xFF2A2A2A), Color(0xFF1A1A1A)],
                                        ),
                                      ),
                                      child: const Icon(Icons.music_note, size: 60, color: Colors.white38),
                                    ),
                            );
                          },
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        
        // Right side - Controls and info
        Expanded(
          flex: 1,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Song info section
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
                child: AnimatedBuilder(
                  animation: _fadeAnimation,
                  builder: (context, child) {
                    return Opacity(
                      opacity: _fadeAnimation.value,
                      child: StreamBuilder<MediaItem?>(
                        stream: widget.handler.mediaItem,
                        initialData: widget.handler.mediaItem.valueOrNull,
                        builder: (context, snap) {
                          final item = snap.data;
                          return Column(
                            children: [
                              Text(
                                item?.title ?? 'Nothing playing',
                                style: const TextStyle(
                                  fontSize: 32,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                item?.artist ?? '',
                                style: const TextStyle(
                                  fontSize: 20,
                                  color: Colors.white70,
                                ),
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          );
                        },
                      ),
                    );
                  },
                ),
              ),
              
              // Progress bar section
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: AnimatedBuilder(
                  animation: _fadeAnimation,
                  builder: (context, child) {
                    return Opacity(
                      opacity: _fadeAnimation.value,
                      child: _ModernPositionSlider(handler: widget.handler),
                    );
                  },
                ),
              ),
              
              const SizedBox(height: 20),
              
              // Control buttons section
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: AnimatedBuilder(
                  animation: _fadeAnimation,
                  builder: (context, child) {
                    return Opacity(
                      opacity: _fadeAnimation.value,
                      child: _ModernControlButtons(handler: widget.handler),
                    );
                  },
                ),
              ),
              
              const SizedBox(height: 30),
              
              // Next up section
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                  child: AnimatedBuilder(
                    animation: _fadeAnimation,
                    builder: (context, child) {
                      return Opacity(
                        opacity: _fadeAnimation.value,
                        child: _NextUpSection(handler: widget.handler),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _NextUpSection extends StatelessWidget {
  final JupotifyAudioHandler handler;
  
  const _NextUpSection({required this.handler});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<MediaItem>>(
      stream: handler.queue,
      builder: (context, snapshot) {
        final queue = snapshot.data ?? [];
        final currentIndex = handler.playbackState.valueOrNull?.queueIndex ?? -1;
        
        if (queue.length <= 1) {
          return const SizedBox.shrink();
        }
        
        // Get next song (index 1 if current is 0, or next in queue)
        final nextIndex = currentIndex >= 0 && currentIndex < queue.length - 1 
            ? currentIndex + 1 
            : 1;
        
        if (nextIndex >= queue.length) {
          return const SizedBox.shrink();
        }
        
        final nextSong = queue[nextIndex];
        
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Next Up',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.white70,
                    ),
                  ),
                  // Queue button
                  GestureDetector(
                    onTap: () {
                      showModalBottomSheet(
                        context: context,
                        useSafeArea: true,
                        isScrollControlled: true,
                        backgroundColor: Colors.transparent,
                        builder: (context) => _QueueBottomSheet(handler: handler),
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Icon(
                        Icons.queue_music,
                        color: Colors.white70,
                        size: 16,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  // Album art
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      color: Colors.white.withOpacity(0.1),
                    ),
                    child: nextSong.artUri != null
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: nextSong.artUri!.isScheme('file')
                                ? Image.file(
                                    File.fromUri(nextSong.artUri!),
                                    fit: BoxFit.cover,
                                    errorBuilder: (context, error, stackTrace) => 
                                        const Icon(Icons.music_note, color: Colors.white38, size: 20),
                                  )
                                : Image.network(
                                    nextSong.artUri!.toString(),
                                    fit: BoxFit.cover,
                                    errorBuilder: (context, error, stackTrace) => 
                                        const Icon(Icons.music_note, color: Colors.white38, size: 20),
                                  ),
                          )
                        : const Icon(Icons.music_note, color: Colors.white38, size: 20),
                  ),
                  const SizedBox(width: 12),
                  // Song info
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          nextSong.title,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: Colors.white,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          nextSong.artist ?? '',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white60,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _QueueBottomSheet extends StatelessWidget {
  final JupotifyAudioHandler handler;
  const _QueueBottomSheet({required this.handler});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.7,
      decoration: const BoxDecoration(
        color: Color(0xFF1A1A1A),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          // Handle bar
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          
          // Title
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Text(
              '재생 큐',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
          
          // Queue list
          Expanded(
            child: StreamBuilder<List<MediaItem>>(
              stream: handler.queue,
              builder: (context, snapshot) {
                final queue = snapshot.data ?? [];
                final currentIndex = handler.playbackState.valueOrNull?.queueIndex ?? -1;
                
                if (queue.isEmpty) {
                  return const Center(
                    child: Text(
                      '재생 큐가 비어있습니다',
                      style: TextStyle(color: Colors.white70),
                    ),
                  );
                }
                
                return ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: queue.length,
                  itemBuilder: (context, index) {
                    final item = queue[index];
                    final isCurrent = index == currentIndex;
                    
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: isCurrent ? Colors.white.withOpacity(0.1) : Colors.transparent,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ListTile(
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox(
                            width: 48,
                            height: 48,
                            child: item.artUri != null
                                ? (item.artUri!.isScheme('file')
                                    ? Image.file(
                                        File.fromUri(item.artUri!),
                                        fit: BoxFit.cover,
                                        errorBuilder: (context, error, stackTrace) => Container(
                                          color: Colors.grey[800],
                                          child: const Icon(Icons.music_note, color: Colors.white54),
                                        ),
                                      )
                                    : Image.network(
                                        item.artUri!.toString(),
                                        fit: BoxFit.cover,
                                        errorBuilder: (context, error, stackTrace) => Container(
                                          color: Colors.grey[800],
                                          child: const Icon(Icons.music_note, color: Colors.white54),
                                        ),
                                      ))
                                : Container(
                                    color: Colors.grey[800],
                                    child: const Icon(Icons.music_note, color: Colors.white54),
                                  ),
                          ),
                        ),
                        title: Text(
                          item.title,
                          style: TextStyle(
                            color: isCurrent ? Colors.white : Colors.white70,
                            fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          item.artist ?? '',
                          style: const TextStyle(color: Colors.white54),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: isCurrent
                            ? const Icon(Icons.equalizer, color: Colors.white)
                            : null,
                        onTap: () async {
                          await handler.skipToQueueItem(index);
                          if (context.mounted) {
                            Navigator.pop(context);
                          }
                        },
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ModernPositionSlider extends StatefulWidget {
  final JupotifyAudioHandler handler;
  const _ModernPositionSlider({required this.handler});

  @override
  State<_ModernPositionSlider> createState() => _ModernPositionSliderState();
}

class _ModernPositionSliderState extends State<_ModernPositionSlider> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: widget.handler.positionStream,
      initialData: Duration.zero,
      builder: (context, posSnap) {
        return StreamBuilder<MediaItem?>(
          stream: widget.handler.mediaItem,
          initialData: widget.handler.mediaItem.valueOrNull,
          builder: (context, itemSnap) {
            if (!itemSnap.hasData || itemSnap.data == null) {
              return Container(
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              );
            }

            final currentDuration = itemSnap.data!.duration ?? Duration.zero;
            final bool hasDuration = currentDuration.inMilliseconds > 0;
            final durationMs = hasDuration
                ? currentDuration.inMilliseconds.toDouble()
                : (widget.handler.duration ?? Duration.zero).inMilliseconds.toDouble();

            final position = _dragValue != null
                ? Duration(milliseconds: _dragValue!.toInt())
                : posSnap.data ?? Duration.zero;
            final clampedValue = position.inMilliseconds.clamp(0, durationMs.toInt()).toDouble();

            return Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _formatDuration(position),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      _formatDuration(Duration(milliseconds: durationMs.toInt())),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: Colors.white.withOpacity(0.2),
                    thumbColor: Colors.white,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    trackHeight: 4,
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                  ),
                  child: Slider(
                    value: durationMs == 0 ? 0 : clampedValue,
                    max: durationMs,
                    onChanged: (value) {
                      setState(() {
                        _dragValue = value;
                      });
                    },
                    onChangeEnd: (value) async {
                      setState(() {
                        _dragValue = null;
                      });
                      await widget.handler.seek(Duration(milliseconds: value.toInt()));
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }
}

class _ModernControlButtons extends StatelessWidget {
  final JupotifyAudioHandler handler;
  const _ModernControlButtons({required this.handler});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlaybackState>(
      stream: handler.playbackState,
      initialData: handler.playbackState.valueOrNull,
      builder: (context, snap) {
        final state = snap.data;
        final playing = state?.playing ?? false;
        
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            // Shuffle button
            StreamBuilder<AudioServiceShuffleMode>(
              stream: handler.playbackState.map((s) => s.shuffleMode),
              initialData: AudioServiceShuffleMode.none,
              builder: (context, shuffleSnapshot) {
                final shuffleMode = shuffleSnapshot.data ?? AudioServiceShuffleMode.none;
                return _ControlButton(
                  icon: Icons.shuffle,
                  isActive: shuffleMode == AudioServiceShuffleMode.all,
                  onTap: () async {
                    final mode = shuffleMode == AudioServiceShuffleMode.all
                        ? AudioServiceShuffleMode.none
                        : AudioServiceShuffleMode.all;
                    await handler.setShuffleMode(mode);
                  },
                );
              },
            ),
            
            // Previous button
            _ControlButton(
              icon: Icons.skip_previous_rounded,
              size: 28,
              onTap: handler.skipToPrevious,
            ),
            
            // Play/Pause button
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(30),
                  onTap: playing ? handler.pause : handler.play,
                  child: Container(
                    width: 60,
                    height: 60,
                    decoration: const BoxDecoration(shape: BoxShape.circle),
                    child: Icon(
                      playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      size: 32,
                      color: Colors.black,
                    ),
                  ),
                ),
              ),
            ),
            
            // Next button
            _ControlButton(
              icon: Icons.skip_next_rounded,
              size: 28,
              onTap: () async {
                try {
                  await handler.skipToNext();
                } catch (e) {
                  print('Error in control button skipToNext: $e');
                }
              },
            ),
            
            // Repeat button
            StreamBuilder<AudioServiceRepeatMode>(
              stream: handler.playbackState.map((s) => s.repeatMode),
              initialData: AudioServiceRepeatMode.none,
              builder: (context, repeatSnapshot) {
                final repeatMode = repeatSnapshot.data ?? AudioServiceRepeatMode.none;
                IconData icon;
                switch (repeatMode) {
                  case AudioServiceRepeatMode.none:
                    icon = Icons.repeat;
                    break;
                  case AudioServiceRepeatMode.all:
                    icon = Icons.repeat;
                    break;
                  case AudioServiceRepeatMode.one:
                    icon = Icons.repeat_one;
                    break;
                  case AudioServiceRepeatMode.group:
                    icon = Icons.repeat;
                    break;
                }
                return _ControlButton(
                  icon: icon,
                  isActive: repeatMode != AudioServiceRepeatMode.none,
                  onTap: () async {
                    final next = {
                      AudioServiceRepeatMode.none: AudioServiceRepeatMode.all,
                      AudioServiceRepeatMode.all: AudioServiceRepeatMode.one,
                      AudioServiceRepeatMode.one: AudioServiceRepeatMode.none,
                      AudioServiceRepeatMode.group: AudioServiceRepeatMode.none,
                    }[repeatMode]!;
                    await handler.setRepeatMode(next);
                  },
                );
              },
            ),
          ],
        );
      },
    );
  }
}

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool isActive;
  final double size;

  const _ControlButton({
    required this.icon,
    required this.onTap,
    this.isActive = false,
    this.size = 24,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isActive ? Colors.white.withOpacity(0.2) : Colors.transparent,
              borderRadius: BorderRadius.circular(25),
            ),
            child: Icon(
              icon,
              color: isActive ? Colors.white : Colors.white70,
              size: size,
            ),
          ),
          if (isActive)
            Container(
              width: 4,
              height: 4,
              margin: const EdgeInsets.only(top: 4),
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
            ),
        ],
      ),
    );
  }
}

class _PositionSlider extends StatefulWidget {
  final JupotifyAudioHandler handler;
  const _PositionSlider({required this.handler});

  @override
  State<_PositionSlider> createState() => _PositionSliderState();
}

class _PositionSliderState extends State<_PositionSlider> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: widget.handler.positionStream,
      initialData: Duration.zero,
      builder: (context, posSnap) {
        return StreamBuilder<MediaItem?>(
          stream: widget.handler.mediaItem,
          initialData: widget.handler.mediaItem.valueOrNull,
          builder: (context, itemSnap) {
            // Handle case when there's no current media item
            if (!itemSnap.hasData || itemSnap.data == null) {
              return Slider(
                value: 0,
                max: 1.0,
                onChanged: null,
                onChangeEnd: null,
              );
            }

            // Cache the last known non-zero duration to avoid greying out during mode toggles
            final currentDuration = itemSnap.data!.duration ?? Duration.zero;
            final bool hasDuration = currentDuration.inMilliseconds > 0;
            final durationMs = hasDuration
                ? currentDuration.inMilliseconds.toDouble()
                : (widget.handler.duration ?? Duration.zero).inMilliseconds.toDouble();

            final position = _dragValue != null
                ? Duration(milliseconds: _dragValue!.toInt())
                : posSnap.data ?? Duration.zero;
            final clampedValue = position.inMilliseconds.clamp(0, durationMs.toInt()).toDouble();

            return Slider(
              value: durationMs == 0 ? 0 : clampedValue,
              max: durationMs == 0 ? 1.0 : durationMs,
              onChanged: durationMs == 0
                  ? null
                  : (v) => setState(() {
                        _dragValue = v;
                      }),
              onChangeEnd: durationMs == 0
                  ? null
                  : (v) {
                      setState(() => _dragValue = null);
                      final d = Duration(milliseconds: v.toInt());
                      widget.handler.seek(d);
                    },
            );
          },
        );
      },
    );
  }
}

String _ext(String path) {
  final idx = path.lastIndexOf('.');
  if (idx == -1) return '';
  return path.substring(idx).toLowerCase();
}

Future<bool> _ensureStoragePermission() async {
  if (Platform.isAndroid) {
    print('=== REQUESTING STORAGE PERMISSIONS ===');
    
    // Android 13+ (API 33)에서는 READ_MEDIA_AUDIO 권한 사용
    // Android 12 이하에서는 READ_EXTERNAL_STORAGE 권한 사용
    
    // 먼저 READ_MEDIA_AUDIO 권한 요청 (Android 13+)
    print('Requesting READ_MEDIA_AUDIO permission...');
    final audioStatus = await Permission.audio.request();
    print('READ_MEDIA_AUDIO permission status: $audioStatus');
    
    if (audioStatus.isGranted) {
      print('READ_MEDIA_AUDIO permission granted');
      return true;
    }
    
    // READ_MEDIA_AUDIO가 거부된 경우 READ_EXTERNAL_STORAGE 권한 요청 (Android 12 이하)
    print('Requesting READ_EXTERNAL_STORAGE permission...');
    final storageStatus = await Permission.storage.request();
    print('READ_EXTERNAL_STORAGE permission status: $storageStatus');
    
    if (storageStatus.isGranted) {
      print('READ_EXTERNAL_STORAGE permission granted');
      return true;
    }
    
    // 추가로 WRITE_EXTERNAL_STORAGE 권한도 요청
    print('Requesting MANAGE_EXTERNAL_STORAGE permission...');
    final writeStatus = await Permission.manageExternalStorage.request();
    print('MANAGE_EXTERNAL_STORAGE permission status: $writeStatus');
    
    if (writeStatus.isGranted) {
      print('MANAGE_EXTERNAL_STORAGE permission granted');
      return true;
    }
    
    print('=== ALL STORAGE PERMISSIONS DENIED ===');
    print('Audio permission status: $audioStatus');
    print('Storage permission status: $storageStatus');
    print('Write permission status: $writeStatus');
    
    // 권한이 거부된 경우 사용자에게 설명
    print('Please grant storage permissions in device settings to download music');
    return false;
  }
  return true;
}

Future<String?> _getAndroidSdkInt() async {
  try {
    // Fallback: env var is not available; return 33 to default to new flow
    return null;
  } catch (_) {
    return null;
  }
}


Future<void> _scanAndHydrateLibrary(JupotifyAudioHandler handler) async {
  // This function should never mutate library UI order; only add missing items to the audio queue
  // Determine default download dir (same rule as downloader)
  Directory? baseDir;
  if (Platform.isAndroid) {
    final dirs = await getExternalStorageDirectories(type: StorageDirectory.music);
    baseDir = (dirs != null && dirs.isNotEmpty) ? dirs.first : await getExternalStorageDirectory();
  } else {
    baseDir = await getApplicationDocumentsDirectory();
  }
  if (baseDir == null) return;
  final target = Platform.isAndroid
      ? Directory('${baseDir.path}/Jupotify')
      : Directory('${baseDir.path}/Music/Jupotify');
  if (!await target.exists()) return;

  final allowed = {'.mp3', '.m4a', '.aac', '.wav', '.flac', '.ogg', '.mp4', '.webm'};
  final files = <File>[];
  await for (final entity in target.list(recursive: true, followLinks: false)) {
    if (entity is File && allowed.contains(_ext(entity.path))) {
      files.add(entity);
    }
  }
  if (files.isEmpty) return;
  
  // Keep files in download time order (file system scan order)

  // Avoid duplicates by checking existing ids (paths) and normalize paths
  final existing = (handler.queue.valueOrNull ?? const <MediaItem>[]).map((e) => e.id).toSet();
  final items = files
      .where((f) {
        // Check both normalized and original paths to avoid duplicates
        final normalizedPath = f.path.replaceAll('\\', '/');
        return !existing.contains(f.path) && !existing.contains(normalizedPath);
      })
      .map((f) {
        final base = f.path.substring(0, f.path.lastIndexOf('.'));
        final artPath = File('$base.jpg');
        return MediaItem(
          id: f.path,
          title: _fileNameNoExt(f.path),
          artist: '', // Will be loaded from saved metadata
          artUri: artPath.existsSync() ? Uri.file(artPath.path) : null,
          extras: {'uri': Uri.file(f.path).toString()},
        );
      })
      .toList();
  
  // Additional check: remove any items that might have been added with different paths
  final finalItems = <MediaItem>[];
  final seenTitles = <String>{};
  
  for (final item in items) {
    final title = item.title.toLowerCase().trim();
    if (!seenTitles.contains(title)) {
      seenTitles.add(title);
      finalItems.add(item);
    }
  }
  if (finalItems.isEmpty) return;
  // Only hydrate queue; do not touch library JSON/UI ordering
  await handler.addQueueItems(finalItems);

  // Hydrate durations in background for items missing duration
  Future(() async {
    print('=== LOADING DURATIONS FOR ${finalItems.length} ITEMS ===');
    for (final item in finalItems) {
      if (item.duration != null) {
        print('Item ${item.title} already has duration: ${item.duration}');
        continue;
      }
      print('Loading duration for: ${item.title}');
      final uri = item.extras?['uri'] as String?;
      if (uri == null) {
        print('No URI for ${item.title}');
        continue;
      }
      final player = AudioPlayer();
      try {
        // Prefer file path for local files; fallback to uri
        Duration? d;
        if (item.id.isNotEmpty) {
          try {
            d = await player.setFilePath(item.id, preload: false);
            print('Loaded duration from file path: $d');
          } catch (e) {
            print('Failed to load from file path: $e');
          }
        }
        if (d == null) {
          try {
            d = await player.setUrl(uri);
            print('Loaded duration from URI: $d');
          } catch (e) {
            print('Failed to load from URI: $e');
          }
        }
        if (d != null) {
          final index = (handler.queue.valueOrNull ?? const <MediaItem>[]) .indexWhere((e) => e.id == item.id);
          if (index >= 0) {
            await handler.updateQueueItem(index, item.copyWith(duration: d));
            print('Updated duration for ${item.title}: $d');
          } else {
            print('Could not find item in queue: ${item.title}');
          }
        } else {
          print('Could not load duration for ${item.title}');
        }
      } catch (e) {
        print('Error loading duration for ${item.title}: $e');
      } finally {
        await player.dispose();
      }
    }
    print('=== FINISHED LOADING DURATIONS ===');
  });
}

String _formatDuration(Duration? d) {
  if (d == null) return '--:--';
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

class _ArtworkImage extends StatelessWidget {
  final Uri uri;
  const _ArtworkImage({required this.uri});

  @override
  Widget build(BuildContext context) {
    if (uri.scheme == 'file') {
      final path = uri.toFilePath();
      return Image.file(
        File(path),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF3E3E3E), Color(0xFF2A2A2A)],
            ),
          ),
          child: const Icon(
            Icons.music_note,
            color: Colors.white70,
            size: 20,
          ),
        ),
      );
    }
    return Image.network(
      uri.toString(),
      fit: BoxFit.cover,
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        return Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF3E3E3E), Color(0xFF2A2A2A)],
            ),
          ),
          child: const Center(
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white70),
            ),
          ),
        );
      },
      errorBuilder: (_, __, ___) => Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF3E3E3E), Color(0xFF2A2A2A)],
          ),
        ),
        child: const Icon(
          Icons.music_note,
          color: Colors.white70,
          size: 20,
        ),
      ),
    );
  }
}

class PlaylistsPage extends StatefulWidget {
  final JupotifyAudioHandler handler;
  const PlaylistsPage({required this.handler, super.key});

  @override
  State<PlaylistsPage> createState() => _PlaylistsPageState();
}

class _PlaylistsPageState extends State<PlaylistsPage> {
  final _svc = PlaylistsService();
  Map<String, List<PlaylistEntry>> _data = {};
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _data = await _svc.load();
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Playlists')),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemBuilder: (_, i) {
          if (i == 0) {
            return Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: InputDecoration(
                      hintText: 'New playlist name',
                      filled: true,
                      fillColor: const Color(0xFF2A2A2A),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () async {
                    final name = _controller.text.trim();
                    if (name.isEmpty) return;
                    await _svc.create(name);
                    _controller.clear();
                    await _load();
                  },
                  child: const Text('Create'),
                )
              ],
            );
          }
          final names = _data.keys.toList();
          final name = names[i - 1];
          final count = _data[name]?.length ?? 0;
          return ListTile(
            title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text('$count tracks'),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                await _svc.delete(name);
                await _load();
              },
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => PlaylistDetailPage(name: name, handler: widget.handler)),
            ),
          );
        },
        separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFF2A2A2A)),
        itemCount: _data.length + 1,
      ),
    );
  }
}

class PlaylistDetailPage extends StatefulWidget {
  final String name;
  final JupotifyAudioHandler handler;
  const PlaylistDetailPage({required this.name, required this.handler, super.key});

  @override
  State<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends State<PlaylistDetailPage> {
  final _svc = PlaylistsService();
  List<PlaylistEntry> _tracks = const [];
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await _svc.load();
    _tracks = all[widget.name] ?? const [];
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.8,
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Colors.white12, width: 1)),
              ),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, color: Colors.white),
                  ),
                  Expanded(
                    child: Text(
                      widget.name,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Play',
                    icon: const Icon(Icons.play_arrow_rounded, color: Colors.white),
                    onPressed: () async {
                      final handler = (context.findAncestorStateOfType<_RootScaffoldState>()?.widget.handler);
                      if (handler == null) return;
                      await handler.clearQueueWithoutSaving();
                      await handler.addQueueItems(_tracks.map((e) => e.toMediaItem()).toList());
                      await handler.setShuffleMode(AudioServiceShuffleMode.none);
                      await handler.setRepeatMode(AudioServiceRepeatMode.none);
                      await handler.play();
                    },
                  ),
                  IconButton(
                    tooltip: 'Shuffle Play',
                    icon: const Icon(Icons.shuffle, color: Colors.white),
                    onPressed: () async {
                      final handler = (context.findAncestorStateOfType<_RootScaffoldState>()?.widget.handler);
                      if (handler == null || _tracks.isEmpty) return;
                      await handler.clearQueueWithoutSaving();
                      
                      // Create shuffled list for queue (library order remains unchanged)
                      final shuffledTracks = List<PlaylistEntry>.from(_tracks)..shuffle();
                      await handler.addQueueItems(shuffledTracks.map((e) => e.toMediaItem()).toList());
                      await handler.setShuffleMode(AudioServiceShuffleMode.all);
                      await handler.setRepeatMode(AudioServiceRepeatMode.none);
                      await handler.play();
                    },
                  ),
                ],
              ),
            ),
            
            // Content
            Expanded(
              child: _tracks.isEmpty
                  ? const Center(
                      child: Text(
                        'No tracks in this playlist',
                        style: TextStyle(color: Colors.white70),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _tracks.length,
                      itemBuilder: (context, index) {
                        final t = _tracks[index];
                        return Column(
                          children: [
                            Dismissible(
                              key: ValueKey('playlist_${widget.name}_${t.id}'),
                              background: Container(
                                color: const Color(0xFFB00020),
                                alignment: Alignment.centerLeft,
                                padding: const EdgeInsets.symmetric(horizontal: 20),
                                child: const Icon(Icons.delete, color: Colors.white),
                              ),
                              secondaryBackground: Container(
                                color: const Color(0xFFB00020),
                                alignment: Alignment.centerRight,
                                padding: const EdgeInsets.symmetric(horizontal: 20),
                                child: const Icon(Icons.delete, color: Colors.white),
                              ),
                              onDismissed: (direction) async {
                                await _svc.removeTrack(widget.name, t.id);
                                await _load();
                              },
                              child: ListTile(
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: SizedBox(
                                  width: 48,
                                  height: 48,
                                  child: t.artUri != null ? _ArtworkImage(uri: Uri.parse(t.artUri!)) : const ColoredBox(color: Color(0xFF2A2A2A), child: Icon(Icons.music_note, color: Colors.white70)),
                                ),
                              ),
                              title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white)),
                              subtitle: Text(t.artist ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70)),
                                trailing: Theme(
                                  data: Theme.of(context).copyWith(
                                    popupMenuTheme: const PopupMenuThemeData(
                                      color: Color(0xFF1E1E1E),
                                      elevation: 8,
                                      textStyle: TextStyle(color: Colors.white),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.all(Radius.circular(12)),
                                      ),
                                    ),
                                  ),
                                  child: PopupMenuButton<String>(
                                    tooltip: 'More options',
                                    icon: const Icon(Icons.more_vert, color: Colors.white70),
                                    offset: const Offset(0, 8),
                                    constraints: const BoxConstraints(minWidth: 220),
                                    onSelected: (value) async {
                                      if (value == 'remove') {
                                        await _svc.removeTrack(widget.name, t.id);
                                        await _load();
                                      }
                                    },
                                    itemBuilder: (context) => [
                                      PopupMenuItem(
                                        value: 'remove',
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                        child: Row(
                                          children: const [
                                            Icon(Icons.delete_outline, color: Colors.white70, size: 20),
                                            SizedBox(width: 12),
                                            Expanded(
                                              child: Text(
                                                'Remove from playlist',
                                                style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              onTap: () async {
                                final handler = (context.findAncestorStateOfType<_RootScaffoldState>()?.widget.handler);
                                if (handler == null) return;
                                
                                // Create new queue starting from selected music
                                final selectedIndex = _tracks.indexWhere((e) => e.id == t.id);
                                if (selectedIndex >= 0) {
                                  // Check shuffle mode
                                  final shuffleMode = handler.playbackState.valueOrNull?.shuffleMode ?? AudioServiceShuffleMode.none;
                                  
                                  if (shuffleMode == AudioServiceShuffleMode.all) {
                                    // Shuffle mode: create shuffled queue
                                    final shuffledTracks = List<PlaylistEntry>.from(_tracks)..shuffle();
                                    // Put selected music first
                                    final selectedTrack = shuffledTracks.removeAt(shuffledTracks.indexWhere((e) => e.id == t.id));
                                    shuffledTracks.insert(0, selectedTrack);
                                    
                                    await handler.clearQueueWithoutSaving();
                                    await handler.addQueueItems(shuffledTracks.map((e) => e.toMediaItem()).toList());
                                    await handler.play();
                                  } else {
                                    // Normal mode: play in playlist order
                                    final newQueue = <MediaItem>[];
                                    
                                    // Add from selected index to end
                                    for (int i = selectedIndex; i < _tracks.length; i++) {
                                      newQueue.add(_tracks[i].toMediaItem());
                                    }
                                    
                                    // Add remaining songs from beginning
                                    for (int i = 0; i < selectedIndex; i++) {
                                      newQueue.add(_tracks[i].toMediaItem());
                                    }
                                    
                                    await handler.clearQueueWithoutSaving();
                                    await handler.addQueueItems(newQueue);
                                    await handler.play();
                                  }
                                }
                              },
                                onLongPress: () async {
                                  // Show details/options sheet for this track
                                  await showModalBottomSheet(
                                    context: context,
                                    backgroundColor: const Color(0xFF121212),
                                    shape: const RoundedRectangleBorder(
                                      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                                    ),
                                    builder: (_) {
                                      return SafeArea(
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                children: [
                                                  ClipRRect(
                                                    borderRadius: BorderRadius.circular(8),
                                                    child: SizedBox(
                                                      width: 48,
                                                      height: 48,
                                                      child: t.artUri != null
                                                        ? _ArtworkImage(uri: Uri.parse(t.artUri!))
                                                        : const ColoredBox(color: Color(0xFF2A2A2A), child: Icon(Icons.music_note, color: Colors.white70)),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 12),
                                                  Expanded(
                                                    child: Column(
                                                      crossAxisAlignment: CrossAxisAlignment.start,
                                                      children: [
                                                        Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                                                        const SizedBox(height: 4),
                                                        Text(t.artist ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70)),
                                                      ],
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 16),
                                              ListTile(
                                                contentPadding: EdgeInsets.zero,
                                                leading: const Icon(Icons.delete_outline, color: Colors.white70),
                                                title: const Text('Remove from this playlist', style: TextStyle(color: Colors.white)),
                                                onTap: () async {
                                                  Navigator.of(context).pop();
                                                  await _svc.removeTrack(widget.name, t.id);
                                                  await _load();
                                                },
                                              ),
                                            ],
                                          ),
                                        ),
                                      );
                                    },
                                  );
                                },
                            ),
                            ),
                            if (index < _tracks.length - 1) const Divider(height: 1, color: Colors.white12),
                          ],
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

class _QuickAddSection extends StatefulWidget {
  final String name;
  final int page;
  final ValueChanged<int> onPage;
  final List<PlaylistEntry> existingTracks;
  const _QuickAddSection({
    required this.name, 
    required this.page, 
    required this.onPage,
    required this.existingTracks,
  });

  @override
  State<_QuickAddSection> createState() => _QuickAddSectionState();
}

class _QuickAddSectionState extends State<_QuickAddSection> {
  List<MediaItem> _library = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadLibrary();
  }

  @override
  void didUpdateWidget(_QuickAddSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Refresh if existing tracks changed
    if (widget.existingTracks.length != oldWidget.existingTracks.length ||
        !_listsEqual(widget.existingTracks, oldWidget.existingTracks)) {
      _loadLibrary();
    }
  }

  bool _listsEqual(List<PlaylistEntry> a, List<PlaylistEntry> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  Future<void> _loadLibrary() async {
    // Scan storage for library items without mutating the queue
    Directory? baseDir;
    if (Platform.isAndroid) {
      final dirs = await getExternalStorageDirectories(type: StorageDirectory.music);
      baseDir = (dirs != null && dirs.isNotEmpty) ? dirs.first : await getExternalStorageDirectory();
    } else {
      baseDir = await getApplicationDocumentsDirectory();
    }
    if (baseDir == null) {
      setState(() { _library = const []; _loading = false; });
      return;
    }
    final target = Platform.isAndroid ? Directory('${baseDir.path}/Jupotify') : Directory('${baseDir.path}/Music/Jupotify');
    if (!await target.exists()) {
      setState(() { _library = const []; _loading = false; });
      return;
    }
    final allowed = {'.mp3', '.m4a', '.aac', '.wav', '.flac', '.ogg', '.mp4', '.webm'};
    final items = <MediaItem>[];
    await for (final entity in target.list(recursive: true, followLinks: false)) {
      if (entity is File && allowed.contains(_ext(entity.path))) {
        final base = entity.path.substring(0, entity.path.lastIndexOf('.'));
        final artPath = File('$base.jpg');
        items.add(MediaItem(
          id: entity.path,
          title: _fileNameNoExt(entity.path),
          artist: '', // Will be loaded from saved metadata
          artUri: artPath.existsSync() ? Uri.file(artPath.path) : null,
          extras: {'uri': Uri.file(entity.path).toString()},
        ));
      }
    }
    if (!mounted) return;
    
    // Filter out tracks that are already in the playlist
    final existingIds = widget.existingTracks.map((e) => e.id).toSet();
    final filteredItems = items.where((item) => !existingIds.contains(item.id)).toList();
    
    setState(() { _library = filteredItems; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || _library.isEmpty) return const SizedBox.shrink();
    const pageSize = 5;
    final start = widget.page * pageSize;
    if (start >= _library.length) return const SizedBox.shrink();
    final end = math.min(start + pageSize, _library.length);
    final slice = _library.sublist(start, end);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Add from Library', style: TextStyle(fontWeight: FontWeight.w700)),
            Row(children: [
              IconButton(onPressed: widget.page > 0 ? () => widget.onPage(widget.page - 1) : null, icon: const Icon(Icons.chevron_left)),
              IconButton(onPressed: end < _library.length ? () => widget.onPage(widget.page + 1) : null, icon: const Icon(Icons.chevron_right)),
            ]),
          ],
        ),
        ...slice.map((item) => ListTile(
              dense: true,
              leading: SizedBox(width: 40, height: 40, child: item.artUri != null ? _ArtworkImage(uri: item.artUri!) : const ColoredBox(color: Color(0xFF2A2A2A))),
              title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: IconButton(
                icon: const Icon(Icons.add),
                onPressed: () async {
                  await PlaylistsService().addTrack(widget.name, item);
                  if (!mounted) return;
                  // Added - silently continue
                  // Refresh the library to remove the added track
                  _loadLibrary();
                },
              ),
            )),
      ],
    );
  }
}

Future<String?> _promptText(BuildContext context, String title, {String initial = ''}) async {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(controller: controller, autofocus: true),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('OK')),
      ],
    ),
  );
}

Future<bool?> _confirm(BuildContext context, String message) async {
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
      ],
    ),
  );
}

Future<void> _deleteFromDisk(String filePath) async {
  try {
    final f = File(filePath);
    if (await f.exists()) {
      await f.delete();
    }
    // Delete sidecar artwork if present
    final dot = filePath.lastIndexOf('.');
    if (dot > 0) {
      final art = File('${filePath.substring(0, dot)}.jpg');
      if (await art.exists()) {
        await art.delete();
      }
    }
  } catch (_) {}
}

class AddToPlaylistSheet extends StatefulWidget {
  final MediaItem item;
  const AddToPlaylistSheet({required this.item, super.key});

  @override
  State<AddToPlaylistSheet> createState() => _AddToPlaylistSheetState();
}

class _AddToPlaylistSheetState extends State<AddToPlaylistSheet> {
  final _svc = PlaylistsService();
  Map<String, List<PlaylistEntry>> _data = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _data = await _svc.load();
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final names = _data.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'Select Playlist',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1A1A1A), Color(0xFF000000)],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
        child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 8),
                Text(
                  'Add to Playlist',
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Choose a playlist to add "${widget.item.title}"',
                  style: const TextStyle(
                    fontSize: 16,
                    color: Colors.white70,
                  ),
                ),
                const SizedBox(height: 24),
                Expanded(
                  child: ListView.builder(
                    itemBuilder: (_, i) {
                      final name = names[i];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2A2A2A),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: ListTile(
                          leading: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(
                              Icons.queue_music,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                          title: Text(
                            name,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                          subtitle: Text(
                            '${_data[name]?.length ?? 0} songs',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 14,
                            ),
                          ),
                          onTap: () async {
                            await _svc.addTrack(name, widget.item);
                            if (!mounted) return;
                            Navigator.of(context).pop();
                            // Added to playlist - silently continue
                          },
                        ),
                      );
                    },
                    itemCount: names.length,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _nameNoExt(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

String _fileNameNoExt(String path) {
  final base = path.split(Platform.pathSeparator).last;
  return _nameNoExt(base);
}

class _RecentlyPlayedSection extends StatelessWidget {
  final JupotifyAudioHandler handler;
  const _RecentlyPlayedSection({required this.handler});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<MediaItem>>(
      stream: handler.queue,
      initialData: const [],
      builder: (context, snapshot) {
        final queue = snapshot.data ?? [];
        if (queue.isEmpty) {
          return const SizedBox.shrink();
        }
        
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Recently Played', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            SizedBox(
              height: 200,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemBuilder: (_, i) {
                  final item = queue[i];
                  return GestureDetector(
                    onTap: () async {
                      await handler.skipToQueueItem(i);
                      await handler.play();
                    },
                    child: Container(
                      width: 160,
                      decoration: BoxDecoration(
                        color: const Color(0xFF2A2A2A),
                        borderRadius: BorderRadius.circular(12),
                      ),
        child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ClipRRect(
                            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                            child: SizedBox(
                              height: 120,
                              width: double.infinity,
                              child: item.artUri != null 
                                  ? _ArtworkImage(uri: item.artUri!)
                                  : const ColoredBox(
                                      color: Color(0xFF1A1A1A),
                                      child: Icon(Icons.music_note, size: 40, color: Colors.white38),
                                    ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.title.length > 10 ? '${item.title.substring(0, 10)}...' : item.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  item.artist ?? 'Unknown Artist',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ],
        ),
      ),
                        ],
                      ),
                    ),
                  );
                },
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemCount: math.min(queue.length, 10),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PlaylistsSection extends StatelessWidget {
  final JupotifyAudioHandler handler;
  final void Function(int tabIndex) goTab;
  final void Function(String? playlistName)? onPlaylistSelected;
  const _PlaylistsSection({
    required this.handler,
    required this.goTab,
    this.onPlaylistSelected,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<String>>(
      future: PlaylistsService().loadPlaylists(),
      builder: (context, snapshot) {
        final playlists = snapshot.data ?? [];
        if (playlists.isEmpty) {
          return const SizedBox.shrink();
        }
        
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Your Playlists', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                TextButton(
                  onPressed: () {
                    // Navigate to Library tab with playlists view
                    DefaultTabController.of(context)?.animateTo(2);
                  },
                  child: const Text('See all'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 120,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemBuilder: (_, i) {
                  final playlist = playlists[i];
                  return GestureDetector(
                    onTap: () async {
                      // Navigate to Library tab and show playlist
                      goTab(2); // Go to Library tab
                      // Pass playlist name to Library tab
                      if (context.mounted) {
                        onPlaylistSelected?.call(playlist);
                      }
                    },
                    child: Container(
                      width: 120,
                      decoration: BoxDecoration(
                        color: const Color(0xFF2A2A2A),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.queue_music, size: 40, color: Colors.white70),
                          const SizedBox(height: 8),
            Text(
                            playlist,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
                  );
                },
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemCount: math.min(playlists.length, 5),
              ),
            ),
          ],
        );
      },
    );
  }
}


class _QuickAccessCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  
  const _QuickAccessCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 80,
        decoration: BoxDecoration(
          color: const Color(0xFF2A2A2A),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(icon, size: 24, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                    Text(
                      subtitle,
                      style: const TextStyle(fontSize: 12, color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LibraryStatsSection extends StatelessWidget {
  final JupotifyAudioHandler handler;
  const _LibraryStatsSection({required this.handler});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<MediaItem>>(
      stream: handler.queue,
      initialData: const [],
      builder: (context, snapshot) {
        final queue = snapshot.data ?? [];
        final totalSongs = queue.length;
        
        return FutureBuilder<List<String>>(
          future: PlaylistsService().loadPlaylists(),
          builder: (context, playlistSnapshot) {
            final playlists = playlistSnapshot.data ?? [];
            final totalPlaylists = playlists.length;
            
            return Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF2A2A2A),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Your Music', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: _StatItem(
                          icon: Icons.music_note,
                          label: 'Songs',
                          value: totalSongs.toString(),
                        ),
                      ),
                      Expanded(
                        child: _StatItem(
                          icon: Icons.queue_music,
                          label: 'Playlists',
                          value: totalPlaylists.toString(),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}


class _ActivationScreen extends StatefulWidget {
  final VoidCallback onActivated;
  const _ActivationScreen({required this.onActivated});

  @override
  State<_ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends State<_ActivationScreen> {
  final _controller = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _checkActivationCode() async {
    final enteredCode = _controller.text.trim();
    
    if (enteredCode.isEmpty) {
      setState(() {
        _errorMessage = 'Please enter the activation code';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    // Simulate network delay
    await Future.delayed(const Duration(seconds: 1));

    if (enteredCode == 'wndud0731!!') {
      setState(() {
        _isLoading = false;
      });
      widget.onActivated();
    } else {
      setState(() {
        _isLoading = false;
        _errorMessage = 'Invalid activation code. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF1A1A1A),
              Color(0xFF121212),
            ],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // App Logo/Icon
                Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Icon(
                    Icons.music_note,
                    size: 60,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 32),
                
                // App Title
                const Text(
                  'Jupotify',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                
                // Subtitle
                const Text(
                  'Your Personal Music Player',
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.white70,
                  ),
                ),
                const SizedBox(height: 48),
                
                // Activation Code Input
                const Text(
                  'Enter Activation Code',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 16),
                
                TextField(
                  controller: _controller,
                  obscureText: true,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 18,
                    letterSpacing: 2,
                    color: Colors.white,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Enter code here',
                    hintStyle: const TextStyle(color: Colors.white54),
                    filled: true,
                    fillColor: const Color(0xFF2A2A2A),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 16,
                    ),
                  ),
                  onSubmitted: (_) => _checkActivationCode(),
                ),
                const SizedBox(height: 16),
                
                // Error Message
                if (_errorMessage != null)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.red.withOpacity(0.3)),
                    ),
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(
                        color: Colors.red,
                        fontSize: 14,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                const SizedBox(height: 24),
                
                // Activate Button
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: FilledButton(
                    onPressed: _isLoading ? null : _checkActivationCode,
                    style: FilledButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          )
                        : const Text(
                            'Activate App',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 32),
                
                // Info Text
                const Text(
                  'This is a one-time activation process.\nYour app will be activated permanently.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white54,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class QueueState {
  final MediaItem? current;
  final List<MediaItem> queue;
  QueueState(this.current, this.queue);
}

class SettingsScreen extends StatefulWidget {
  final String currentNickname;
  final String currentLanguage;
  const SettingsScreen({super.key, required this.currentNickname, required this.currentLanguage});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late String _nickname;
  late String _language;
  final TextEditingController _nicknameController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _nickname = widget.currentNickname;
    _language = widget.currentLanguage;
    _nicknameController.text = _nickname;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          AppLocalizations.getText('settings', _language),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Language Setting
              Text(
                AppLocalizations.getText('language', _language),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: DropdownButton<String>(
                  value: _language,
                  dropdownColor: const Color(0xFF1A1A1A),
                  style: const TextStyle(color: Colors.white),
                  underline: Container(),
                  isExpanded: true,
                  items: [
                    DropdownMenuItem(value: 'en', child: Text(AppLocalizations.getText('english', _language))),
                    DropdownMenuItem(value: 'ko', child: Text(AppLocalizations.getText('korean', _language))),
                  ],
                  onChanged: (String? newValue) {
                    if (newValue != null) {
                      setState(() {
                        _language = newValue;
                      });
                    }
                  },
                ),
              ),
              const SizedBox(height: 32),
              
              
              // Nickname Setting
              Text(
                AppLocalizations.getText('nickname', _language),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _nicknameController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: AppLocalizations.getText('enterNickname', _language),
                  hintStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
                  filled: true,
                  fillColor: Colors.white.withOpacity(0.1),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
                onChanged: (value) {
                  setState(() {
                    _nickname = value.isEmpty ? 'User' : value;
                  });
                },
              ),
              const SizedBox(height: 32),
              
              // Save Button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    // Save settings and go back with updated nickname and language
                    Navigator.pop(context, {
                      'nickname': _nickname,
                      'language': _language,
                    });
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white12,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    AppLocalizations.getText('saveSettings', _language),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
