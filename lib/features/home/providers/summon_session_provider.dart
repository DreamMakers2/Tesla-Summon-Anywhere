import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/services/mock_location_service.dart';
import '../../../core/services/tesla_api_service.dart';
import '../../../core/storage/prefs_storage.dart';
import '../../background/summon_task_handler.dart';
import 'vehicle_location_provider.dart';

part 'summon_session_provider.g.dart';

const summonSessionDuration = Duration(minutes: 5);
const _serviceOperationTimeout = Duration(seconds: 12);

class SummonSessionState {
  const SummonSessionState({
    this.isActive = false,
    this.isStarting = false,
    this.isStopping = false,
    this.remaining = summonSessionDuration,
    this.error,
    this.statusMessage,
    this.lastSubmittedAt,
    this.lastSubmittedLatitude,
    this.lastSubmittedLongitude,
  });

  final bool isActive;
  final bool isStarting;
  final bool isStopping;
  final Duration remaining;
  final String? error;
  final String? statusMessage;
  final DateTime? lastSubmittedAt;
  final double? lastSubmittedLatitude;
  final double? lastSubmittedLongitude;

  SummonSessionState copyWith({
    bool? isActive,
    bool? isStarting,
    bool? isStopping,
    Duration? remaining,
    String? error,
    String? statusMessage,
    DateTime? lastSubmittedAt,
    double? lastSubmittedLatitude,
    double? lastSubmittedLongitude,
    bool clearError = false,
  }) {
    return SummonSessionState(
      isActive: isActive ?? this.isActive,
      isStarting: isStarting ?? this.isStarting,
      isStopping: isStopping ?? this.isStopping,
      remaining: remaining ?? this.remaining,
      error: clearError ? null : (error ?? this.error),
      statusMessage: statusMessage ?? this.statusMessage,
      lastSubmittedAt: lastSubmittedAt ?? this.lastSubmittedAt,
      lastSubmittedLatitude:
          lastSubmittedLatitude ?? this.lastSubmittedLatitude,
      lastSubmittedLongitude:
          lastSubmittedLongitude ?? this.lastSubmittedLongitude,
    );
  }
}

/// Applies worker events while local service and GPS cleanup are in progress.
@visibleForTesting
SummonSessionState applySessionTaskEvent(
  SummonSessionState state,
  Object data, {
  int? sessionId,
}) {
  if (data is! Map) return state;
  switch (data['event']) {
    case 'failed':
      if (sessionId == null || data['sessionId'] != sessionId) return state;
      return state.copyWith(
        isActive: false,
        isStarting: false,
        error: data['message'] as String? ?? 'GPS sync could not continue.',
      );
    case 'cleanup_failed':
      return state.copyWith(
        isActive: true,
        isStarting: false,
        remaining: Duration.zero,
        error: 'Mock GPS cleanup failed. Retry Stop and check your phone.',
      );
    case 'stopped':
      if (sessionId == null ||
          data['sessionId'] != sessionId ||
          state.isStopping) {
        return state;
      }
      return state.copyWith(
        isStarting: false,
        isStopping: true,
        remaining: Duration.zero,
      );
    default:
      return state;
  }
}

@Riverpod(keepAlive: true)
class SummonSession extends _$SummonSession {
  Timer? _countdownTimer;
  DateTime? _sessionEnd;
  int? _sessionId;
  Future<void>? _stopInFlight;
  Future<void>? _startupCleanup;
  Completer<bool>? _pendingReady;
  Completer<void>? _startupFinished;
  bool _starting = false;
  bool _cancelStart = false;
  bool _checkingService = false;

  @override
  SummonSessionState build() {
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
    // On process restart, never assume an orphaned mock provider is idle.
    // Fail closed by cleaning it up before another session can start.
    _startupCleanup = Future<void>.delayed(Duration.zero, () async {
      try {
        final unconfirmed =
            await FlutterForegroundTask.getData<bool>(
              key: legacyCleanupUnconfirmedKey,
            ).timeout(_serviceOperationTimeout) ??
            false;
        final running = await FlutterForegroundTask.isRunningService.timeout(
          _serviceOperationTimeout,
        );
        if (running) {
          await _performStop();
          if (!state.isActive) {
            final vehicle = ref.read(vehicleLocationProvider.notifier);
            await vehicle.waitForIdle();
            await vehicle.refresh();
          }
        } else {
          await ref
              .read(mockLocationServiceProvider)
              .disableMockProvider()
              .timeout(_serviceOperationTimeout);
          await FlutterForegroundTask.removeData(
            key: legacyCleanupUnconfirmedKey,
          );
        }
        if (unconfirmed && state.error == null) {
          state = state.copyWith(
            statusMessage: 'Previous GPS session was cleaned up.',
          );
        }
      } catch (e, st) {
        AppLogger.error(
          'SUMMON',
          'Startup GPS cleanup was not confirmed',
          error: e,
          stackTrace: st,
        );
        state = const SummonSessionState(
          isActive: true,
          remaining: Duration.zero,
          error: 'Cannot verify GPS cleanup. Tap Stop to retry.',
        );
      }
    });
    ref.onDispose(() {
      _countdownTimer?.cancel();
      FlutterForegroundTask.removeTaskDataCallback(_onTaskData);
    });
    return const SummonSessionState();
  }

  void _onTaskData(Object data) {
    if (data is! Map) return;
    final event = data['event'];
    if (event != 'cleanup_failed' && data['sessionId'] != _sessionId) return;
    if (event == 'location') {
      final latitude = data['latitude'];
      final longitude = data['longitude'];
      final sourceMs = data['sourceTimestampMs'];
      if (latitude is num && longitude is num && sourceMs is int) {
        ref
            .read(vehicleLocationProvider.notifier)
            .acceptLocation(
              VehicleLocationResult(
                latitude: latitude.toDouble(),
                longitude: longitude.toDouble(),
                isAsleep: false,
                vehicleName: data['vehicleName'] as String?,
                sourceTimestamp: DateTime.fromMillisecondsSinceEpoch(sourceMs),
              ),
            );
        state = state.copyWith(
          statusMessage: 'Checking Android location…',
          lastSubmittedAt: DateTime.now(),
          lastSubmittedLatitude: latitude.toDouble(),
          lastSubmittedLongitude: longitude.toDouble(),
          clearError: true,
        );
      }
      return;
    }
    if (event == 'syncing') {
      state = state.copyWith(statusMessage: 'GPS syncing', clearError: true);
      return;
    }
    if (event == 'waiting') {
      final message =
          data['message'] as String? ?? 'Waiting for Tesla location.';
      ref
          .read(vehicleLocationProvider.notifier)
          .reportUnavailable(
            asleep: data['asleep'] == true,
            // The session already displays the waiting reason; avoid a
            // second, alarming error banner for a normal retry cooldown.
            error: null,
          );
      state = state.copyWith(statusMessage: message, clearError: true);
      return;
    }
    if (event != 'cleanup_failed' && event != 'stopped' && event != 'failed') {
      return;
    }
    if ((event == 'stopped' || event == 'failed') &&
        (_sessionId == null || data['sessionId'] != _sessionId)) {
      return;
    }
    _countdownTimer?.cancel();
    _sessionEnd = null;
    final wasStopping = state.isStopping;
    state = applySessionTaskEvent(state, data, sessionId: _sessionId);
    if ((event == 'cleanup_failed' || event == 'failed') && _starting) {
      _cancelStart = true;
      final ready = _pendingReady;
      if (ready != null && !ready.isCompleted) ready.complete(false);
    }
    if (!_starting && !wasStopping) {
      if (event == 'stopped' || event == 'failed') {
        unawaited(_finishWorkerStop());
      } else if (_sessionId != null) {
        // Cleanup failures affect the shared OS provider, even if an old
        // worker reported them. Stop the current session conservatively.
        unawaited(stop());
      }
    }
  }

  Future<void> _finishWorkerStop() async {
    final reportedError = state.error;
    await stop();
    if (!state.isActive && !state.isStopping) {
      state = state.copyWith(
        error: reportedError,
        statusMessage: reportedError == null ? 'GPS session ended.' : null,
      );
    }
  }

  Future<bool> start() async {
    // A synchronous guard closes the double-tap race before the first await.
    if (state.isActive ||
        state.isStopping ||
        _starting ||
        _stopInFlight != null) {
      return false;
    }
    _starting = true;
    _startupFinished = Completer<void>();
    _cancelStart = false;
    state = const SummonSessionState(isStarting: true);
    try {
      await _startupCleanup;
      if (state.isActive || _cancelStart) {
        throw StateError('Pending GPS cleanup or cancelled startup');
      }
      if (await FlutterForegroundTask.isRunningService.timeout(
        _serviceOperationTimeout,
      )) {
        throw StateError('A previous GPS service is still running');
      }
      final vehicleLocation = ref.read(vehicleLocationProvider.notifier);
      await vehicleLocation.waitForIdle();
      if (_cancelStart) throw StateError('Startup cancelled');
      if (ref.read(prefsStorageProvider).selectedVehicleId == null) {
        await vehicleLocation.refresh();
      }
      final vehicleId = ref.read(prefsStorageProvider).selectedVehicleId;
      if (vehicleId == null || vehicleId.isEmpty) {
        throw StateError('No vehicle selected');
      }
      // The worker resolves and refreshes credentials from encrypted storage.
      if (_cancelStart) throw StateError('Startup cancelled');

      final end = DateTime.now().add(summonSessionDuration);
      _sessionId = end.millisecondsSinceEpoch;
      await FlutterForegroundTask.removeData(key: 'accessToken');
      await FlutterForegroundTask.removeData(key: 'cancelledSessionId');
      await FlutterForegroundTask.saveData(key: 'vehicleId', value: vehicleId);
      await FlutterForegroundTask.saveData(
        key: 'sessionDeadlineMs',
        value: end.millisecondsSinceEpoch,
      );
      if (_cancelStart) throw StateError('Startup cancelled');
      await ref
          .read(mockLocationServiceProvider)
          .allowSession(_sessionId!)
          .timeout(_serviceOperationTimeout);
      if (_cancelStart) throw StateError('Startup cancelled');

      // Starting the worker and confirming a mocked fix are separate events.
      final ready = Completer<bool>();
      _pendingReady = ready;
      void onStartupData(Object data) {
        if (data is! Map) return;
        if (data['event'] != 'cleanup_failed' &&
            data['sessionId'] != _sessionId) {
          return;
        }
        if (data['event'] == 'stopped' ||
            data['event'] == 'cleanup_failed' ||
            data['event'] == 'failed') {
          // Even if readiness was already reported, do not mark a worker
          // active after it has subsequently stopped.
          _cancelStart = true;
          if (!ready.isCompleted) ready.complete(false);
        } else if (data['event'] == 'started' && !ready.isCompleted) {
          ready.complete(true);
        }
      }

      FlutterForegroundTask.addTaskDataCallback(onStartupData);
      try {
        final result = await FlutterForegroundTask.startService(
          notificationTitle: 'Summon Anywhere',
          notificationText: 'Waiting for a confirmed location update…',
          callback: startSummonCallback,
        ).timeout(_serviceOperationTimeout);
        if (result case ServiceRequestFailure(:final error)) {
          throw StateError('Foreground service start failed: $error');
        }
        if (_cancelStart) throw StateError('Startup cancelled');
        if (!await ready.future.timeout(
          const Duration(seconds: 25),
          onTimeout: () => false,
        )) {
          throw StateError('Background service did not start');
        }
      } finally {
        _pendingReady = null;
        FlutterForegroundTask.removeTaskDataCallback(onStartupData);
      }
      if (_cancelStart) throw StateError('Startup cancelled');

      _sessionEnd = end;
      _countdownTimer?.cancel();
      _countdownTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _tick(),
      );
      state = SummonSessionState(
        isActive: true,
        remaining: end.difference(DateTime.now()),
        statusMessage: state.statusMessage ?? 'Waiting for Tesla location…',
        lastSubmittedAt: state.lastSubmittedAt,
        lastSubmittedLatitude: state.lastSubmittedLatitude,
        lastSubmittedLongitude: state.lastSubmittedLongitude,
      );
      return true;
    } catch (e, st) {
      AppLogger.error(
        'SUMMON',
        'Session start failed',
        error: e,
        stackTrace: st,
      );
      // Startup owns cleanup even when cancellation races startService().
      final reportedError = state.error;
      await _performStop();
      if (!state.isActive) {
        state = SummonSessionState(
          error:
              reportedError ??
              'Unable to start the GPS session. Check sign-in, connection, and permissions before retrying.',
        );
      }
      return false;
    } finally {
      _pendingReady = null;
      _starting = false;
      _startupFinished?.complete();
      _startupFinished = null;
    }
  }

  void _tick() {
    final end = _sessionEnd;
    if (end == null) return;
    final remaining = end.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      unawaited(stop());
    } else {
      state = state.copyWith(remaining: remaining);
      if (remaining.inSeconds % 5 == 0) unawaited(checkService());
    }
  }

  /// Keep the control honest if Android stops the worker unexpectedly.
  Future<void> checkService() async {
    if (_checkingService || _starting || !state.isActive || state.isStopping) {
      return;
    }
    final sessionId = _sessionId;
    _checkingService = true;
    try {
      final running = await FlutterForegroundTask.isRunningService.timeout(
        _serviceOperationTimeout,
      );
      if (running ||
          sessionId != _sessionId ||
          !state.isActive ||
          state.isStopping) {
        return;
      }
      await stop();
      if (!state.isActive && state.error == null) {
        state = state.copyWith(
          error: 'GPS sync stopped unexpectedly. Start it again.',
        );
      }
    } catch (_) {
      // A failed status check is not proof that the service has stopped.
    } finally {
      _checkingService = false;
    }
  }

  Future<void> stop() {
    if (_starting) {
      _cancelStart = true;
      final ready = _pendingReady;
      if (ready != null && !ready.isCompleted) ready.complete(false);
      state = state.copyWith(isStarting: false, isStopping: true);
      // The in-flight startup performs cleanup once startService() returns.
      return _startupFinished?.future ?? Future.value();
    }
    // Serialize stop requests so concurrent taps cannot overlap cleanup.
    return _stopInFlight ??= _performStop().whenComplete(() {
      _stopInFlight = null;
    });
  }

  Future<void> _performStop() async {
    state = state.copyWith(isStarting: false, isStopping: true);
    _countdownTimer?.cancel();
    _sessionEnd = null;
    String? failure;
    try {
      await ref
          .read(mockLocationServiceProvider)
          .blockMocking()
          .timeout(_serviceOperationTimeout);
    } catch (_) {
      failure = 'Could not block mock GPS. Retry Stop.';
    }
    int? sessionId = _sessionId;
    try {
      sessionId ??= await FlutterForegroundTask.getData<int>(
        key: 'sessionDeadlineMs',
      ).timeout(_serviceOperationTimeout);
    } catch (_) {
      failure = 'Could not identify the GPS session. Retry Stop.';
    }
    if (sessionId != null) {
      try {
        await FlutterForegroundTask.saveData(
          key: 'cancelledSessionId',
          value: sessionId,
        ).timeout(_serviceOperationTimeout);
      } catch (_) {
        failure = 'Could not cancel the GPS session. Retry Stop.';
      }
      try {
        FlutterForegroundTask.sendDataToTask({
          'event': 'cancel',
          'sessionId': sessionId,
        });
      } catch (_) {
        // The durable cancellation is also checked before every poll.
      }
      try {
        await ref
            .read(mockLocationServiceProvider)
            .retireSession(sessionId)
            .timeout(_serviceOperationTimeout);
      } catch (_) {
        failure = 'Could not cancel the GPS session. Retry Stop.';
      }
    }
    var stopFailed = false;
    try {
      // A not-yet-started session has no service to stop. Avoid treating that
      // normal case as a service-stop failure.
      if (await FlutterForegroundTask.isRunningService.timeout(
        _serviceOperationTimeout,
      )) {
        final result = await FlutterForegroundTask.stopService().timeout(
          _serviceOperationTimeout,
        );
        if (result is ServiceRequestFailure) stopFailed = true;
      }
    } catch (_) {
      stopFailed = true;
    }
    if (stopFailed) {
      // The worker can finish itself between the running check and Stop.
      // Confirm it is actually still running before reporting a failure.
      try {
        if (await FlutterForegroundTask.isRunningService.timeout(
          _serviceOperationTimeout,
        )) {
          failure = 'Background service failed to stop. Retry Stop.';
        }
      } catch (_) {
        failure =
            'Could not verify the background service stopped. Retry Stop.';
      }
      if (failure != null) AppLogger.error('SUMMON', failure);
    }

    // A stopped service is not proof the OS-level GPS provider was removed.
    try {
      await ref
          .read(mockLocationServiceProvider)
          .disableMockProvider()
          .timeout(_serviceOperationTimeout);
    } catch (e, st) {
      failure =
          'Could not verify mock GPS cleanup. Retry Stop and check your phone.';
      AppLogger.error('SUMMON', failure, error: e, stackTrace: st);
    }

    try {
      if (failure == null) {
        await FlutterForegroundTask.removeData(
          key: legacyCleanupUnconfirmedKey,
        );
        await FlutterForegroundTask.removeData(key: 'vehicleId');
        await FlutterForegroundTask.removeData(key: 'sessionDeadlineMs');
        await FlutterForegroundTask.removeData(key: 'cancelledSessionId');
      }
      await FlutterForegroundTask.removeData(key: 'accessToken');
    } catch (e, st) {
      // Failure to clear bookkeeping must not strand the UI in STOPPING.
      AppLogger.error(
        'SUMMON',
        'Could not clear old task preferences',
        error: e,
        stackTrace: st,
      );
    }
    if (failure == null) _sessionId = null;
    state = SummonSessionState(
      isActive: failure != null,
      isStopping: false,
      remaining: Duration.zero,
      error: failure,
      lastSubmittedAt: state.lastSubmittedAt,
      lastSubmittedLatitude: state.lastSubmittedLatitude,
      lastSubmittedLongitude: state.lastSubmittedLongitude,
    );
  }
}
