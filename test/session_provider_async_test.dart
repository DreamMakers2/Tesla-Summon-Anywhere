import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_foreground_task/flutter_foreground_task_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:summon_anywhere_tesla/core/services/mock_location_service.dart';
import 'package:summon_anywhere_tesla/core/services/tesla_api_service.dart';
import 'package:summon_anywhere_tesla/core/storage/prefs_storage.dart';
import 'package:summon_anywhere_tesla/features/background/summon_task_handler.dart';
import 'package:summon_anywhere_tesla/features/home/providers/summon_session_provider.dart';
import 'package:summon_anywhere_tesla/features/home/providers/vehicle_location_provider.dart';

class _Vehicle extends VehicleLocation {
  Completer<void>? _fetchGate;
  int _waits = 0;

  @override
  VehicleLocationState build() => const VehicleLocationState();

  @override
  Future<void> waitForIdle() async {
    _waits++;
    await _fetchGate?.future;
  }
}

class _DelayedApi extends Fake implements TeslaApiService {
  final result = Completer<VehicleLocationResult>();
  int requests = 0;

  @override
  Future<List<TeslaVehicle>> getVehicles() async => [
    const TeslaVehicle(
      id: 'fixture',
      vin: '',
      displayName: 'Tesla',
      state: 'online',
    ),
  ];

  @override
  Future<VehicleLocationResult> getVehicleLocation(String vehicleId) {
    requests++;
    return result.future;
  }
}

class _MockGps extends MockLocationService {
  Completer<void>? cleanupGate;
  Object? cleanupError;
  int calls = 0;
  Completer<void>? retirementGate;
  Object? retirementError;
  final retiredSessionIds = <int>[];
  final cancellationAtRetirement = <int?>[];
  final operations = <String>[];
  int blocks = 0;
  final allowedSessionIds = <int>[];
  final allowedWithRunningWorker = <bool>[];
  bool Function()? workerRunning;

  @override
  Future<void> blockMocking() async {
    blocks++;
    operations.add('block');
  }

  @override
  Future<void> allowSession(int sessionId) async {
    allowedSessionIds.add(sessionId);
    allowedWithRunningWorker.add(workerRunning?.call() ?? false);
  }

  @override
  Future<void> retireSession(int sessionId) async {
    cancellationAtRetirement.add(
      await FlutterForegroundTask.getData<int>(key: 'cancelledSessionId'),
    );
    retiredSessionIds.add(sessionId);
    operations.add('retire:$sessionId');
    await retirementGate?.future;
    final error = retirementError;
    if (error != null) throw error;
  }

  @override
  Future<void> disableMockProvider() async {
    calls++;
    operations.add('cleanup');
    await cleanupGate?.future;
    final error = cleanupError;
    if (error != null) throw error;
  }
}

class _Foreground extends FlutterForegroundTaskPlatform {
  bool running = false;
  int starts = 0;
  int stops = 0;
  Completer<void>? startGate;
  Object? startError;
  Completer<void>? stopGate;
  Object? stopError;
  bool disappearsOnStopFailure = false;
  Completer<bool>? statusGate;
  int statusChecks = 0;
  List<String>? operations;

  @override
  Future<bool> get isRunningService async {
    statusChecks++;
    final gate = statusGate;
    statusGate = null;
    return gate == null ? running : gate.future;
  }

  @override
  Future<void> startService({
    required AndroidNotificationOptions androidNotificationOptions,
    required IOSNotificationOptions iosNotificationOptions,
    required ForegroundTaskOptions foregroundTaskOptions,
    int? serviceId,
    List<ForegroundServiceTypes>? serviceTypes,
    required String notificationTitle,
    required String notificationText,
    NotificationIcon? notificationIcon,
    List<NotificationButton>? notificationButtons,
    String? notificationInitialRoute,
    Function? callback,
  }) async {
    starts++;
    if (startError != null) throw startError!;
    await startGate?.future;
    running = true;
  }

  @override
  Future<void> stopService() async {
    stops++;
    operations?.add('stop');
    await stopGate?.future;
    if (stopError != null) {
      if (disappearsOnStopFailure) running = false;
      throw stopError!;
    }
    running = false;
  }
}

Future<void> _until(bool Function() ready) async {
  for (var attempt = 0; attempt < 100 && !ready(); attempt++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(
    ready(),
    isTrue,
    reason: 'The session did not reach its expected gate',
  );
}

void _emit(Map<String, Object> data) {
  for (final callback in FlutterForegroundTask.dataCallbacks.toList()) {
    callback(data);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  late _Vehicle vehicle;
  late _MockGps gps;
  late _Foreground foreground;
  late FlutterForegroundTaskPlatform original;
  late PrefsStorage prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'selected_vehicle_id': 'VEHICLE_FIXTURE',
    });
    prefs = await PrefsStorage.create();
    vehicle = _Vehicle();
    gps = _MockGps();
    foreground = _Foreground()..operations = gps.operations;
    gps.workerRunning = () => foreground.running;
    original = FlutterForegroundTaskPlatform.instance;
    FlutterForegroundTaskPlatform.instance = foreground;
    FlutterForegroundTask.resetStatic();
    FlutterForegroundTask.skipServiceResponseCheck = true;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'test',
        channelName: 'test',
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
      ),
    );
    container = ProviderContainer(
      overrides: [
        prefsStorageProvider.overrideWithValue(prefs),
        vehicleLocationProvider.overrideWith(() => vehicle),
        mockLocationServiceProvider.overrideWithValue(gps),
      ],
    );
    container.read(summonSessionProvider);
    await _until(() => gps.calls == 1);
    await Future<void>.delayed(Duration.zero);
    gps.operations.clear();
  });

  tearDown(() {
    container.dispose();
    FlutterForegroundTask.resetStatic();
    FlutterForegroundTaskPlatform.instance = original;
  });

  Future<int> sessionId() async {
    final value = await FlutterForegroundTask.getData<int>(
      key: 'sessionDeadlineMs',
    );
    expect(value, isNotNull);
    return value!;
  }

  Future<void> startSession() async {
    final previousStarts = foreground.starts;
    final starting = container.read(summonSessionProvider.notifier).start();
    await _until(() => foreground.starts == previousStarts + 1);
    _emit({'event': 'started', 'sessionId': await sessionId()});
    expect(await starting, isTrue);
  }

  test(
    'Stop blocks native mocking with an unreadable session ID and failed OS Stop',
    () async {
      await FlutterForegroundTask.saveData(
        key: 'sessionDeadlineMs',
        value: 'UNREADABLE_SESSION_FIXTURE',
      );
      await expectLater(
        FlutterForegroundTask.getData<int>(key: 'sessionDeadlineMs'),
        completion(isNull),
      );
      foreground.running = true;
      foreground.stopError = StateError('SERVICE_STOP_FAILED_FIXTURE');
      await container.read(summonSessionProvider.notifier).stop();
      expect(gps.operations, ['block', 'stop', 'cleanup']);
      expect(gps.blocks, 1);
      expect(gps.retiredSessionIds, isEmpty);
      expect(gps.allowedSessionIds, isEmpty);
      expect(foreground.running, isTrue);
      expect(container.read(summonSessionProvider).isActive, isTrue);
      expect(
        container.read(summonSessionProvider).error,
        contains('Retry Stop'),
      );
    },
  );

  test(
    'only a new start allows its session while no worker is running',
    () async {
      await startSession();
      final id = await sessionId();
      expect(gps.allowedSessionIds, [id]);
      expect(gps.allowedWithRunningWorker, [false]);
      await container.read(summonSessionProvider.notifier).stop();
      expect(gps.allowedSessionIds, [
        id,
      ], reason: 'Stop must never reopen native mocking');
      expect(gps.blocks, 1);
    },
  );

  test(
    'Start refuses to allow mocking while another worker is still running',
    () async {
      foreground.running = true;
      expect(
        await container.read(summonSessionProvider.notifier).start(),
        isFalse,
      );
      expect(gps.allowedSessionIds, isEmpty);
      expect(foreground.starts, 0);
      expect(gps.blocks, 1);
      expect(gps.operations, ['block', 'stop', 'cleanup']);
    },
  );

  test(
    'session retirement completes before service Stop and GPS cleanup',
    () async {
      await startSession();
      final id = await sessionId();
      gps.retirementGate = Completer<void>();
      final stopping = container.read(summonSessionProvider.notifier).stop();
      await _until(() => gps.retiredSessionIds.isNotEmpty);
      expect(gps.retiredSessionIds, [id]);
      expect(gps.cancellationAtRetirement, [id]);
      expect(
        await FlutterForegroundTask.getData<int>(key: 'cancelledSessionId'),
        id,
      );
      expect(foreground.stops, 0);
      expect(gps.calls, 1);
      expect(gps.operations, ['block', 'retire:$id']);
      gps.retirementGate!.complete();
      await stopping;
      expect(gps.operations, ['block', 'retire:$id', 'stop', 'cleanup']);
      expect(container.read(summonSessionProvider).isActive, isFalse);
      expect(
        await FlutterForegroundTask.getData<int>(key: 'cancelledSessionId'),
        isNull,
      );
    },
  );

  test(
    'retirement failure retains the worker identity and permits retry',
    () async {
      await startSession();
      final id = await sessionId();
      gps.retirementError = StateError('RETIREMENT_FAILED_FIXTURE');
      final notifier = container.read(summonSessionProvider.notifier);
      await notifier.stop();
      expect(container.read(summonSessionProvider).isActive, isTrue);
      expect(
        container.read(summonSessionProvider).error,
        contains('Could not cancel the GPS session'),
      );
      expect(await sessionId(), id);
      expect(
        await FlutterForegroundTask.getData<int>(key: 'cancelledSessionId'),
        id,
      );
      expect(
        await FlutterForegroundTask.getData<String>(key: 'vehicleId'),
        'VEHICLE_FIXTURE',
      );
      expect(
        gps.calls,
        2,
        reason: 'Cleanup is still attempted after retirement fails',
      );
      gps.retirementError = null;
      await notifier.stop();
      expect(gps.retiredSessionIds, [id, id]);
      expect(gps.cancellationAtRetirement, [id, id]);
      expect(gps.calls, 3);
      expect(container.read(summonSessionProvider).isActive, isFalse);
      expect(container.read(summonSessionProvider).error, isNull);
      expect(
        await FlutterForegroundTask.getData<int>(key: 'sessionDeadlineMs'),
        isNull,
      );
      expect(
        await FlutterForegroundTask.getData<String>(key: 'vehicleId'),
        isNull,
      );
      expect(
        await FlutterForegroundTask.getData<int>(key: 'cancelledSessionId'),
        isNull,
      );
    },
  );

  test(
    'a running worker check retains the active session without cleanup',
    () async {
      await startSession();
      final notifier = container.read(summonSessionProvider.notifier);
      await notifier.checkService();
      expect(container.read(summonSessionProvider).isActive, isTrue);
      expect(container.read(summonSessionProvider).error, isNull);
      expect(foreground.stops, 0);
      expect(gps.calls, 1);
      await notifier.stop();
    },
  );

  test(
    'an absent worker is cleaned up and reported as unexpectedly stopped',
    () async {
      await startSession();
      foreground.running = false;
      await container.read(summonSessionProvider.notifier).checkService();
      final state = container.read(summonSessionProvider);
      expect(state.isActive, isFalse);
      expect(state.isStopping, isFalse);
      expect(state.error, contains('GPS sync stopped unexpectedly'));
      expect(gps.calls, 2);
      expect(foreground.stops, 0, reason: 'The worker has already stopped');
    },
  );

  test(
    'a service disappearing during Stop still completes GPS cleanup successfully',
    () async {
      await startSession();
      foreground.stopError = StateError('SERVICE_ALREADY_STOPPED_FIXTURE');
      foreground.disappearsOnStopFailure = true;
      await container.read(summonSessionProvider.notifier).stop();
      final state = container.read(summonSessionProvider);
      expect(foreground.stops, 1);
      expect(foreground.running, isFalse);
      expect(gps.calls, 2);
      expect(state.isActive, isFalse);
      expect(state.isStopping, isFalse);
      expect(state.error, isNull);
    },
  );

  test(
    'a service still running after failed Stop remains actionable and retryable',
    () async {
      await startSession();
      final id = await sessionId();
      foreground.stopError = StateError('SERVICE_STOP_FAILED_FIXTURE');
      final notifier = container.read(summonSessionProvider.notifier);
      await notifier.stop();
      final state = container.read(summonSessionProvider);
      expect(foreground.running, isTrue);
      expect(
        gps.calls,
        2,
        reason: 'Native cleanup must run even if service Stop fails',
      );
      expect(state.isActive, isTrue);
      expect(state.isStopping, isFalse);
      expect(
        state.error,
        contains('Background service failed to stop. Retry Stop.'),
      );
      expect(await notifier.start(), isFalse);
      expect(await sessionId(), id);
      expect(gps.retiredSessionIds, [id]);
      expect(gps.cancellationAtRetirement, [id]);
      expect(
        await FlutterForegroundTask.getData<int>(key: 'cancelledSessionId'),
        id,
      );
      expect(
        await FlutterForegroundTask.getData<String>(key: 'vehicleId'),
        'VEHICLE_FIXTURE',
      );
      foreground.stopError = null;
      await notifier.stop();
      expect(foreground.stops, 2);
      expect(gps.calls, 3);
      expect(gps.retiredSessionIds, [id, id]);
      expect(container.read(summonSessionProvider).isActive, isFalse);
      expect(container.read(summonSessionProvider).error, isNull);
      expect(
        await FlutterForegroundTask.getData<int>(key: 'cancelledSessionId'),
        isNull,
      );
      expect(
        await FlutterForegroundTask.getData<int>(key: 'sessionDeadlineMs'),
        isNull,
      );
    },
  );

  test(
    'an unavailable worker-status reply does not claim the worker stopped',
    () async {
      await startSession();
      final reply = Completer<bool>();
      foreground.statusGate = reply;
      final checking = container
          .read(summonSessionProvider.notifier)
          .checkService();
      reply.completeError(StateError('STATUS_FIXTURE_UNAVAILABLE'));
      await checking;
      expect(container.read(summonSessionProvider).isActive, isTrue);
      expect(container.read(summonSessionProvider).error, isNull);
      expect(gps.calls, 1);
      await container.read(summonSessionProvider.notifier).stop();
    },
  );

  test(
    'concurrent worker checks share one outstanding status request',
    () async {
      await startSession();
      final before = foreground.statusChecks;
      final reply = Completer<bool>();
      foreground.statusGate = reply;
      final notifier = container.read(summonSessionProvider.notifier);
      final checking = notifier.checkService();
      await notifier.checkService();
      expect(foreground.statusChecks, before + 1);
      reply.complete(true);
      await checking;
      expect(container.read(summonSessionProvider).isActive, isTrue);
      await notifier.stop();
    },
  );

  test('a delayed absent-worker reply cannot stop a newer session', () async {
    await startSession();
    final oldId = await sessionId();
    final reply = Completer<bool>();
    foreground.statusGate = reply;
    final notifier = container.read(summonSessionProvider.notifier);
    final checking = notifier.checkService();
    await notifier.stop();
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await startSession();
    expect(await sessionId(), isNot(oldId));
    reply.complete(false);
    await checking;
    expect(container.read(summonSessionProvider).isActive, isTrue);
    expect(container.read(summonSessionProvider).error, isNull);
    expect(foreground.stops, 1);
    expect(gps.calls, 2);
    await notifier.stop();
  });

  test('a delayed worker check does not race manual Stop cleanup', () async {
    await startSession();
    final reply = Completer<bool>();
    foreground.statusGate = reply;
    final notifier = container.read(summonSessionProvider.notifier);
    final checking = notifier.checkService();
    foreground.stopGate = Completer<void>();
    final stopping = notifier.stop();
    await _until(() => foreground.stops == 1);
    reply.complete(false);
    await checking;
    expect(foreground.stops, 1);
    expect(container.read(summonSessionProvider).isStopping, isTrue);
    expect(gps.calls, 1);
    foreground.stopGate!.complete();
    await stopping;
    expect(gps.calls, 2);
    expect(container.read(summonSessionProvider).isActive, isFalse);
    expect(container.read(summonSessionProvider).error, isNull);
  });

  test(
    'cold restoration stops the old worker and cleans GPS before map polling',
    () async {
      container.dispose();
      final restoredId = DateTime.now()
          .add(const Duration(minutes: 5))
          .millisecondsSinceEpoch;
      await FlutterForegroundTask.saveData(
        key: 'sessionDeadlineMs',
        value: restoredId,
      );
      await FlutterForegroundTask.saveData(
        key: 'vehicleId',
        value: 'VEHICLE_FIXTURE',
      );
      final api = _DelayedApi();
      foreground.running = true;
      foreground.stopGate = Completer<void>();
      gps.cleanupGate = Completer<void>();
      container = ProviderContainer(
        overrides: [
          prefsStorageProvider.overrideWithValue(prefs),
          teslaApiServiceProvider.overrideWithValue(api),
          mockLocationServiceProvider.overrideWithValue(gps),
        ],
      );
      container.read(vehicleLocationProvider);
      await _until(() => !container.read(vehicleLocationProvider).isLoading);
      expect(api.requests, 0, reason: 'The existing worker still owns polling');
      container.read(summonSessionProvider);
      await _until(() => foreground.stops == 1);
      expect(api.requests, 0);
      foreground.stopGate!.complete();
      await _until(() => gps.calls == 2);
      expect(api.requests, 0, reason: 'GPS cleanup has not completed');
      expect(gps.retiredSessionIds, [restoredId]);
      expect(gps.cancellationAtRetirement, [restoredId]);
      expect(gps.operations, [
        'block',
        'retire:$restoredId',
        'stop',
        'cleanup',
      ]);
      gps.cleanupGate!.complete();
      await _until(() => api.requests == 1);
      expect(foreground.running, isFalse);
      api.result.complete(
        VehicleLocationResult(
          latitude: 52,
          longitude: 4,
          isAsleep: false,
          sourceTimestamp: DateTime.now(),
        ),
      );
      await _until(() => !container.read(vehicleLocationProvider).isLoading);
      expect(api.requests, 1);
      expect(container.read(summonSessionProvider).isActive, isFalse);
    },
  );

  test(
    'manual refresh coalesces and real foreground fetch finishes before worker startup',
    () async {
      container.dispose();
      final api = _DelayedApi();
      container = ProviderContainer(
        overrides: [
          prefsStorageProvider.overrideWithValue(prefs),
          teslaApiServiceProvider.overrideWithValue(api),
          mockLocationServiceProvider.overrideWithValue(gps),
        ],
      );
      container.read(vehicleLocationProvider);
      container.read(summonSessionProvider);
      await _until(() => api.requests == 1 && gps.calls == 2);
      final manualRefresh = container
          .read(vehicleLocationProvider.notifier)
          .refresh();
      final starting = container.read(summonSessionProvider.notifier).start();
      await Future<void>.delayed(Duration.zero);
      expect(api.requests, 1);
      expect(foreground.starts, 0);
      api.result.complete(
        VehicleLocationResult(
          latitude: 52,
          longitude: 4,
          isAsleep: false,
          sourceTimestamp: DateTime.now(),
        ),
      );
      await manualRefresh;
      await _until(() => foreground.starts == 1);
      _emit({'event': 'started', 'sessionId': await sessionId()});
      expect(await starting, isTrue);
      expect(api.requests, 1);
      await container.read(summonSessionProvider.notifier).stop();
    },
  );

  test(
    'startup waits for the foreground request before launching the worker',
    () async {
      vehicle._fetchGate = Completer<void>();
      final notifier = container.read(summonSessionProvider.notifier);
      final starting = notifier.start();
      await _until(() => vehicle._waits == 1);
      expect(foreground.starts, 0);
      expect(container.read(summonSessionProvider).isStarting, isTrue);
      expect(await notifier.start(), isFalse);
      final stopping = notifier.stop();
      vehicle._fetchGate!.complete();
      expect(await starting, isFalse);
      await stopping;
      expect(foreground.starts, 0);
      expect(container.read(summonSessionProvider).isActive, isFalse);
    },
  );

  test(
    'startup acknowledgement does not wait for location or cooldown',
    () async {
      final starting = container.read(summonSessionProvider.notifier).start();
      await _until(() => foreground.starts == 1);
      final id = await sessionId();
      _emit({'event': 'started', 'sessionId': id});
      _emit({
        'event': 'waiting',
        'sessionId': id,
        'message': 'Rate limited. Waiting before retry.',
      });
      expect(await starting, isTrue);
      final state = container.read(summonSessionProvider);
      expect(state.isActive, isTrue);
      expect(state.isStarting, isFalse);
      expect(state.lastSubmittedAt, isNull);
      expect(state.statusMessage, contains('Rate limited'));
      expect(state.error, isNull);
      await container.read(summonSessionProvider.notifier).stop();
    },
  );

  test('stale startup events cannot activate a newer session', () async {
    final notifier = container.read(summonSessionProvider.notifier);
    final starting = notifier.start();
    await _until(() => foreground.starts == 1);
    _emit({'event': 'started', 'sessionId': await sessionId() - 1});
    await Future<void>.delayed(Duration.zero);
    expect(container.read(summonSessionProvider).isStarting, isTrue);
    expect(container.read(summonSessionProvider).isActive, isFalse);
    final stopping = notifier.stop();
    expect(await starting, isFalse);
    await stopping;
    expect(container.read(summonSessionProvider).isActive, isFalse);
  });

  test(
    'Stop during service startup prevents a later acknowledgement activating GPS',
    () async {
      foreground.startGate = Completer<void>();
      final notifier = container.read(summonSessionProvider.notifier);
      final starting = notifier.start();
      await _until(() => foreground.starts == 1);
      final id = await sessionId();
      final stopping = notifier.stop();
      _emit({'event': 'started', 'sessionId': id});
      foreground.startGate!.complete();
      expect(await starting, isFalse);
      await stopping;
      expect(foreground.stops, 1);
      expect(container.read(summonSessionProvider).isActive, isFalse);
    },
  );

  test(
    'concurrent stops wait for service and GPS cleanup before another start',
    () async {
      await startSession();
      foreground.stopGate = Completer<void>();
      gps.cleanupGate = Completer<void>();
      final notifier = container.read(summonSessionProvider.notifier);
      final first = notifier.stop();
      final second = notifier.stop();
      await _until(() => foreground.stops == 1);
      expect(await notifier.start(), isFalse);
      foreground.stopGate!.complete();
      await _until(() => gps.calls == 2);
      expect(container.read(summonSessionProvider).isStopping, isTrue);
      gps.cleanupGate!.complete();
      await Future.wait([first, second]);
      expect(foreground.stops, 1);
      expect(gps.calls, 2);
      expect(container.read(summonSessionProvider).isStopping, isFalse);
    },
  );

  test('cleanup failure remains retryable and blocks a new session', () async {
    await startSession();
    gps.cleanupError = StateError('PRIVATE_CLEANUP_FIXTURE');
    final notifier = container.read(summonSessionProvider.notifier);
    await notifier.stop();
    expect(container.read(summonSessionProvider).isActive, isTrue);
    expect(container.read(summonSessionProvider).error, contains('Retry Stop'));
    expect(await notifier.start(), isFalse);
    gps.cleanupError = null;
    await notifier.stop();
    expect(container.read(summonSessionProvider).isActive, isFalse);
    expect(container.read(summonSessionProvider).error, isNull);
  });

  test('worker failure message survives the local cleanup', () async {
    await startSession();
    _emit({
      'event': 'failed',
      'sessionId': await sessionId(),
      'message': 'Tesla location access was denied.',
    });
    await _until(() => foreground.stops == 1);
    await _until(() => !container.read(summonSessionProvider).isStopping);
    final state = container.read(summonSessionProvider);
    expect(state.isActive, isFalse);
    expect(state.error, 'Tesla location access was denied.');
  });

  test(
    'worker location updates populate map data without another Tesla request',
    () async {
      await startSession();
      final id = await sessionId();
      _emit({
        'event': 'location',
        'sessionId': id,
        'latitude': 52.0,
        'longitude': 4.0,
        'sourceTimestampMs': DateTime.now().millisecondsSinceEpoch,
        'vehicleName': 'Fixture Tesla',
      });
      expect(container.read(vehicleLocationProvider).latitude, 52.0);
      expect(
        container.read(vehicleLocationProvider).vehicleName,
        'Fixture Tesla',
      );
      expect(container.read(summonSessionProvider).lastSubmittedLatitude, 52.0);
      await container.read(summonSessionProvider.notifier).stop();
      _emit({
        'event': 'location',
        'sessionId': id,
        'latitude': 53.0,
        'longitude': 5.0,
        'sourceTimestampMs': DateTime.now().millisecondsSinceEpoch,
      });
      expect(container.read(vehicleLocationProvider).latitude, 52.0);
    },
  );

  test(
    'worker expiry stops the UI session and preserves a useful completion status',
    () async {
      await startSession();
      _emit({'event': 'stopped', 'sessionId': await sessionId()});
      await _until(() => foreground.stops == 1);
      await _until(() => !container.read(summonSessionProvider).isStopping);
      expect(container.read(summonSessionProvider).isActive, isFalse);
      expect(
        container.read(summonSessionProvider).statusMessage,
        'GPS session ended.',
      );
    },
  );

  test('startup recovery clears an old pending-cleanup marker', () async {
    await FlutterForegroundTask.saveData(
      key: legacyCleanupUnconfirmedKey,
      value: true,
    );
    container.invalidate(summonSessionProvider);
    container.read(summonSessionProvider);
    await _until(() => gps.calls == 2);
    expect(container.read(summonSessionProvider).error, isNull);
    expect(
      await FlutterForegroundTask.getData<bool>(
        key: legacyCleanupUnconfirmedKey,
      ),
      isNot(isTrue),
    );
  });
}
