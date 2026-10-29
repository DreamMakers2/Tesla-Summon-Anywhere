import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final notificationServiceProvider = Provider((ref) => NotificationService());

/// Permission and notification visibility are separate from service execution.
class NotificationService {
  static const _askedKey = 'notification_permission_requested';
  static const _channel = MethodChannel('com.summonanywhere/notifications');
  Future<NotificationPermission>? _requestInFlight;

  Future<NotificationPermission> status() =>
      FlutterForegroundTask.checkNotificationPermission();

  /// Called only by an explicit user action. Subsequent denials use Settings.
  Future<NotificationPermission> requestOnce() => _requestInFlight ??=
      _requestOnce().whenComplete(() => _requestInFlight = null);

  Future<NotificationPermission> _requestOnce() async {
    final current = await status();
    if (current == NotificationPermission.granted) return current;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_askedKey) ?? false) return current;
    await prefs.setBool(_askedKey, true);
    return FlutterForegroundTask.requestNotificationPermission();
  }

  Future<void> openSettings() => _channel.invokeMethod<void>('openSettings');
}
