import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static const int _downloadNotificationId = 1001;
  static const int _playlistNotificationId = 1002;

  static Future<void> initialize() async {
    if (_initialized) return;

    const androidSettings = AndroidInitializationSettings('@drawable/ic_notification');
    const iosSettings = DarwinInitializationSettings();
    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _notifications.initialize(initSettings);
    _initialized = true;
  }

  static Future<bool> requestPermission() async {
    final status = await Permission.notification.request();
    return status.isGranted;
  }

  static Future<void> showDownloadStarted(String title) async {
    final notificationId = title.hashCode.abs();
    await _notifications.show(
      notificationId,
      'Jupotify',
      '다운로드 시작: $title',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'downloads',
          '다운로드 알림',
          channelDescription: 'YouTube 다운로드 진행 상황',
          importance: Importance.low,
          priority: Priority.low,
          ongoing: true,
          showProgress: true,
          maxProgress: 100,
          progress: 0,
          icon: '@drawable/ic_notification',
        ),
      ),
    );
  }

  static Future<void> showDownloadProgress(String title, int progress) async {
    final notificationId = title.hashCode.abs();
    await _notifications.show(
      notificationId,
      'Jupotify',
      '다운로드 중: $title',
      NotificationDetails(
        android: AndroidNotificationDetails(
          'downloads',
          '다운로드 알림',
          channelDescription: 'YouTube 다운로드 진행 상황',
          importance: Importance.low,
          priority: Priority.low,
          ongoing: true,
          showProgress: true,
          maxProgress: 100,
          progress: progress,
          onlyAlertOnce: true, // 실시간 업데이트를 위해 추가
          icon: '@drawable/ic_notification',
        ),
      ),
    );
  }

  static Future<void> showDownloadCompleted(String title) async {
    final notificationId = title.hashCode.abs();
    await _notifications.show(
      notificationId,
      'Jupotify',
      '다운로드 완료: $title',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'downloads',
          '다운로드 알림',
          channelDescription: 'YouTube 다운로드 진행 상황',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          ongoing: false,
          icon: '@drawable/ic_notification',
        ),
      ),
    );
  }

  static Future<void> showDownloadFailed(String title, String error) async {
    final notificationId = title.hashCode.abs();
    await _notifications.show(
      notificationId,
      'Jupotify',
      '다운로드 실패: $title',
      NotificationDetails(
        android: AndroidNotificationDetails(
          'downloads',
          '다운로드 알림',
          channelDescription: 'YouTube 다운로드 진행 상황',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          ongoing: false,
          icon: '@drawable/ic_notification',
        ),
      ),
    );
  }

  static Future<void> showPlaylistStarted(String playlistName, int totalTracks) async {
    await _notifications.show(
      _playlistNotificationId,
      'Jupotify',
      '플레이리스트 다운로드 시작: $playlistName ($totalTracks곡)',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'playlists',
          '플레이리스트 다운로드 알림',
          channelDescription: 'YouTube 플레이리스트 다운로드 진행 상황',
          importance: Importance.low,
          priority: Priority.low,
          ongoing: true,
          showProgress: true,
          maxProgress: 100,
          progress: 0,
          icon: '@drawable/ic_notification',
        ),
      ),
    );
  }

  static Future<void> showPlaylistProgress(String playlistName, int current, int total, String currentTitle) async {
    final progress = (current / total * 100).round();
    await _notifications.show(
      _playlistNotificationId,
      'Jupotify',
      '플레이리스트 다운로드 중: $current/$total - $currentTitle',
      NotificationDetails(
        android: AndroidNotificationDetails(
          'playlists',
          '플레이리스트 다운로드 알림',
          channelDescription: 'YouTube 플레이리스트 다운로드 진행 상황',
          importance: Importance.low,
          priority: Priority.low,
          ongoing: true,
          showProgress: true,
          maxProgress: 100,
          progress: progress,
          onlyAlertOnce: true, // 실시간 업데이트를 위해 추가
          icon: '@drawable/ic_notification',
        ),
      ),
    );
  }

  static Future<void> showPlaylistCompleted(String playlistName, int totalTracks) async {
    await _notifications.show(
      _playlistNotificationId,
      'Jupotify',
      '플레이리스트 다운로드 완료: $playlistName ($totalTracks곡)',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'playlists',
          '플레이리스트 다운로드 알림',
          channelDescription: 'YouTube 플레이리스트 다운로드 진행 상황',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          ongoing: false,
          icon: '@drawable/ic_notification',
        ),
      ),
    );
  }

  static Future<void> showPlaylistFailed(String playlistName, String error) async {
    await _notifications.show(
      _playlistNotificationId,
      'Jupotify',
      '플레이리스트 다운로드 실패: $playlistName',
      NotificationDetails(
        android: AndroidNotificationDetails(
          'playlists',
          '플레이리스트 다운로드 알림',
          channelDescription: 'YouTube 플레이리스트 다운로드 진행 상황',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          ongoing: false,
          icon: '@drawable/ic_notification',
        ),
      ),
    );
  }

  static Future<void> cancelDownloadNotification() async {
    await _notifications.cancel(_downloadNotificationId);
  }

  static Future<void> cancelPlaylistNotification() async {
    await _notifications.cancel(_playlistNotificationId);
  }
}
