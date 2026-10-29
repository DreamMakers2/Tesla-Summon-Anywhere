import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/services/auth_service.dart';
import '../../core/services/location_safety.dart';
import '../../core/services/tesla_api_service.dart';
import '../../core/services/vehicle_polling.dart';
import '../../core/storage/secure_storage.dart';

const legacyCleanupUnconfirmedKey = 'legacyCleanupUnconfirmed';
const _timeout = Duration(seconds: 15);

@pragma('vm:entry-point')
void startSummonCallback() {
  FlutterForegroundTask.setTaskHandler(SummonTaskHandler());
}

/// Runs a bounded GPS sync independently of the visible Flutter screen.
class SummonTaskHandler extends TaskHandler {
  SummonTaskHandler({TeslaApiService? api}) : _api = api;

  final MethodChannel _channel = const MethodChannel(
    'com.summonanywhere/mock_location',
  );
  TeslaApiService? _api;
  Timer? _pollTimer;
  Timer? _expiryTimer;
  Timer? _cleanupTimer;
  DateTime? _deadline;
  String? _vehicleId;
  int? _sessionId;
  bool _stopping = false;
  bool _enabled = false;
  bool _polling = false;
  bool _attemptingCleanup = false;
  Future<void>? _cleaning;
  String? _stopError;

  void _send(String event, [Map<String, Object?> extra = const {}]) {
    FlutterForegroundTask.sendDataToMain({
      'event': event,
      'sessionId': _sessionId,
      ...extra,
    });
  }

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    try {
      _vehicleId = await FlutterForegroundTask.getData<String>(
        key: 'vehicleId',
      );
      _sessionId = await FlutterForegroundTask.getData<int>(
        key: 'sessionDeadlineMs',
      );
      if (_vehicleId == null || _vehicleId!.isEmpty || _sessionId == null) {
        throw StateError('Missing session data');
      }
      _deadline = DateTime.fromMillisecondsSinceEpoch(_sessionId!);
      if (!LocationSafety.validDeadline(_deadline!, DateTime.now())) {
        throw StateError('Invalid session deadline');
      }
      _api ??= TeslaApiService(
        AuthService(const SecureStorage(FlutterSecureStorage())),
      );
      _expiryTimer = Timer(_deadline!.difference(DateTime.now()), () {
        unawaited(_stopAndClean());
      });
      _send('started');
      _schedule(Duration.zero);
    } catch (_) {
      await _stopAndClean(error: 'Could not start GPS sync. Please retry.');
    }
  }

  void _schedule(Duration delay) {
    if (_stopping) return;
    final deadline = _deadline;
    if (deadline == null || !DateTime.now().isBefore(deadline)) {
      unawaited(_stopAndClean());
      return;
    }
    _pollTimer?.cancel();
    _pollTimer = Timer(delay.isNegative ? Duration.zero : delay, () {
      unawaited(_pollLocation());
    });
  }

  Future<void> _pollLocation() async {
    if (_polling || _stopping) return;
    _polling = true;
    final started = DateTime.now();
    try {
      if (await _isCancelled()) {
        await _stopAndClean();
        return;
      }
      final deadline = _deadline;
      final vehicleId = _vehicleId;
      if (deadline == null ||
          vehicleId == null ||
          !started.isBefore(deadline)) {
        await _stopAndClean();
        return;
      }

      final location = await _api!.getVehicleLocation(vehicleId);
      if (await _isCancelled()) {
        await _stopAndClean();
        return;
      }
      if (!DateTime.now().isBefore(deadline)) return;
      if (location.isAsleep || location.isLocationUnavailable) {
        final message = location.isAsleep
            ? 'Vehicle asleep or offline. Retrying shortly.'
            : location.isStale
            ? 'Vehicle location is stale. Waiting for an update.'
            : 'Vehicle location unavailable. Check Tesla location access.';
        if (!await _pauseMocking()) return;
        _send('waiting', {'message': message, 'asleep': location.isAsleep});
        _scheduleAt(location.retryAt);
        return;
      }

      if (!_enabled) {
        await _channel
            .invokeMethod<bool>('enableMockProvider', {'sessionId': _sessionId})
            .timeout(_timeout);
        _enabled = true;
        if (await _isCancelled()) {
          await _stopAndClean();
          return;
        }
      }
      if (_stopping || !DateTime.now().isBefore(deadline)) return;
      await _channel
          .invokeMethod<bool>('updateLocation', {
            'sessionId': _sessionId,
            'latitude': location.latitude,
            'longitude': location.longitude,
          })
          .timeout(_timeout);
      if (await _isCancelled()) {
        await _stopAndClean();
        return;
      }
      if (!DateTime.now().isBefore(deadline)) return;
      _send('location', {
        'latitude': location.latitude,
        'longitude': location.longitude,
        'sourceTimestampMs': location.sourceTimestamp?.millisecondsSinceEpoch,
        'vehicleName': location.vehicleName,
      });

      // Both requests return fresh Android callbacks after the latest update.
      final observations = await Future.wait([
        _channel.invokeMapMethod<String, dynamic>('observeGps', {
          'timeoutMs': 10000,
        }),
        _channel.invokeMapMethod<String, dynamic>('observeFused', {
          'timeoutMs': 10000,
        }),
      ]).timeout(_timeout);
      if (_stopping || !DateTime.now().isBefore(deadline)) return;
      if (observations.every((fix) => _matches(fix, location))) {
        _send('syncing');
        await FlutterForegroundTask.updateService(
          notificationText: 'GPS syncing — stops automatically after 5 minutes',
        );
      } else {
        _send('waiting', {
          'message': 'Waiting for Android to confirm mock GPS.',
        });
      }
      _schedule(VehiclePolling.interval - DateTime.now().difference(started));
    } on TeslaApiException catch (error) {
      if (_stopping) return;
      if (!error.retryable) {
        await _stopAndClean(error: error.message);
        return;
      }
      if (!error.coolingDown && !await _pauseMocking()) return;
      _send('waiting', {'message': error.message});
      _scheduleAt(error.retryAt);
    } on PlatformException {
      if (!_stopping) {
        await _stopAndClean(
          error:
              'Could not update mock GPS. Select this app in Developer options and retry.',
        );
      }
    } on TimeoutException {
      if (!_stopping) {
        await _stopAndClean(
          error: 'Android GPS did not respond. Check location settings.',
        );
      }
    } catch (_) {
      if (!_stopping) {
        await _stopAndClean(
          error: 'GPS sync failed. Check location and connection.',
        );
      }
    } finally {
      _polling = false;
    }
  }

  Future<bool> _isCancelled() async {
    if (_stopping) return true;
    final cancelled = await FlutterForegroundTask.getData<int>(
      key: 'cancelledSessionId',
    );
    return _stopping || (cancelled != null && cancelled == _sessionId);
  }

  void _scheduleAt(DateTime? time) {
    _schedule(
      time == null
          ? const Duration(seconds: 30)
          : time.difference(DateTime.now()),
    );
  }

  bool _matches(
    Map<String, dynamic>? observation,
    VehicleLocationResult location,
  ) {
    if (observation == null || observation['mocked'] != true) return false;
    final latitude = observation['latitude'];
    final longitude = observation['longitude'];
    if (latitude is! num || longitude is! num) return false;
    final north = (latitude.toDouble() - location.latitude) * 111320;
    final east =
        (longitude.toDouble() - location.longitude) *
        111320 *
        math.cos(location.latitude * math.pi / 180);
    return math.sqrt(north * north + east * east) <= 10;
  }

  Future<bool> _pauseMocking() async {
    if (!_enabled) return !_stopping;
    try {
      await _disableMocking();
      return !_stopping;
    } catch (_) {
      await _stopAndClean(error: 'Could not stop mock GPS. Retry Stop.');
      return false;
    }
  }

  Future<void> _disableMocking() => _cleaning ??= (() async {
    await _channel.invokeMethod<void>('disableMockProvider').timeout(_timeout);
    _enabled = false;
  })().whenComplete(() => _cleaning = null);

  Future<void> _stopAndClean({String? error}) async {
    if (_stopping) return;
    _stopping = true;
    _stopError = error;
    _pollTimer?.cancel();
    _expiryTimer?.cancel();
    await _attemptCleanup();
  }

  Future<void> _attemptCleanup() async {
    if (_attemptingCleanup) return;
    _attemptingCleanup = true;
    try {
      await _disableMocking();
      await FlutterForegroundTask.removeData(key: legacyCleanupUnconfirmedKey);
      _cleanupTimer?.cancel();
      _cleanupTimer = null;
      if (_stopError == null) {
        _send('stopped');
      } else {
        _send('failed', {'message': _stopError});
      }
      final result = await FlutterForegroundTask.stopService();
      if (result is ServiceRequestFailure) {
        // The UI may have stopped it while this worker was cleaning up.
        if (await FlutterForegroundTask.isRunningService.timeout(_timeout)) {
          throw StateError('Unable to stop the foreground service');
        }
      }
    } catch (_) {
      await FlutterForegroundTask.saveData(
        key: legacyCleanupUnconfirmedKey,
        value: true,
      );
      _send('cleanup_failed');
      await FlutterForegroundTask.updateService(
        notificationText: 'Mock GPS cleanup failed. Check the app.',
      );
      _cleanupTimer ??= Timer.periodic(const Duration(seconds: 3), (_) {
        unawaited(_attemptCleanup());
      });
    } finally {
      _attemptingCleanup = false;
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  void onReceiveData(Object data) {
    if (data is Map &&
        data['event'] == 'cancel' &&
        data['sessionId'] == _sessionId) {
      unawaited(_stopAndClean());
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _stopping = true;
    _pollTimer?.cancel();
    _expiryTimer?.cancel();
    _cleanupTimer?.cancel();
    try {
      await _disableMocking();
      await FlutterForegroundTask.removeData(key: legacyCleanupUnconfirmedKey);
    } catch (_) {
      await FlutterForegroundTask.saveData(
        key: legacyCleanupUnconfirmedKey,
        value: true,
      );
      _send('cleanup_failed');
    }
  }
}
