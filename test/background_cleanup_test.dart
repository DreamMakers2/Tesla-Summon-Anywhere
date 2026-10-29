import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_foreground_task/flutter_foreground_task_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:summon_anywhere_tesla/core/services/tesla_api_service.dart';
import 'package:summon_anywhere_tesla/features/background/summon_task_handler.dart';

class _Api extends Fake implements TeslaApiService {
  int requests = 0;
  bool failAfterFirst = false;

  @override
  Future<VehicleLocationResult> getVehicleLocation(String vehicleId) async {
    requests++;
    if (failAfterFirst && requests > 1) {
      throw TeslaApiException(
        'Connection unavailable.',
        statusCode: 503,
        retryable: true,
        retryAt: DateTime.now().add(const Duration(seconds: 10)),
      );
    }
    return VehicleLocationResult(
      latitude: 52,
      longitude: 4,
      isAsleep: false,
      sourceTimestamp: DateTime.now(),
    );
  }
}

class _Foreground extends FlutterForegroundTaskPlatform {
  int stops = 0;
  int stopFailures = 0;
  bool disappearsOnStopFailure = false;
  bool running = true;

  @override
  Future<bool> get isRunningService async => running;

  @override
  Future<void> updateService({
    ForegroundTaskOptions? foregroundTaskOptions,
    String? notificationTitle,
    String? notificationText,
    NotificationIcon? notificationIcon,
    List<NotificationButton>? notificationButtons,
    String? notificationInitialRoute,
    Function? callback,
  }) async {}

  @override
  Future<void> stopService() async {
    stops++;
    if (stopFailures > 0) {
      stopFailures--;
      if (disappearsOnStopFailure) running = false;
      throw StateError('Service stop failed');
    }
    running = false;
  }
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 50 && !ready(); attempt++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
  expect(ready(), isTrue, reason: 'Cleanup did not reach its expected state');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.summonanywhere/mock_location');
  late FlutterForegroundTaskPlatform original;
  late _Foreground foreground;
  late SummonTaskHandler worker;
  late _Api api;
  late List<String> methods;
  int cleanupFailures = 0;
  bool failEnable = false;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    original = FlutterForegroundTaskPlatform.instance;
    foreground = _Foreground();
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
    api = _Api();
    worker = SummonTaskHandler(api: api);
    methods = [];
    cleanupFailures = 0;
    failEnable = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          methods.add(call.method);
          if (call.method == 'disableMockProvider' && cleanupFailures > 0) {
            cleanupFailures--;
            throw PlatformException(code: 'CLEANUP_FAILED');
          }
          if (call.method == 'enableMockProvider' && failEnable) {
            throw PlatformException(code: 'MOCK_PERMISSION_DENIED');
          }
          if (call.method == 'observeGps' || call.method == 'observeFused') {
            return {'latitude': 52.0, 'longitude': 4.0, 'mocked': true};
          }
          return true;
        });
  });

  tearDown(() async {
    await worker.onDestroy(DateTime.now(), false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    FlutterForegroundTask.resetStatic();
    FlutterForegroundTaskPlatform.instance = original;
  });

  Future<void> validSession() async {
    await FlutterForegroundTask.saveData(
      key: 'vehicleId',
      value: 'VEHICLE_FIXTURE',
    );
    await FlutterForegroundTask.saveData(
      key: 'sessionDeadlineMs',
      value: DateTime.now()
          .add(const Duration(minutes: 5))
          .millisecondsSinceEpoch,
    );
  }

  Future<bool?> pending() =>
      FlutterForegroundTask.getData<bool>(key: legacyCleanupUnconfirmedKey);

  testWidgets('invalid session data cleans mocks without requesting Tesla', (
    tester,
  ) async {
    await FlutterForegroundTask.saveData(
      key: legacyCleanupUnconfirmedKey,
      value: true,
    );
    await worker.onStart(DateTime.now(), TaskStarter.values.first);
    expect(methods, ['disableMockProvider']);
    expect(foreground.stops, 1);
    expect(await pending(), isNot(isTrue));
    expect(api.requests, 0);
  });

  testWidgets('failed cleanup remains durable until a later retry succeeds', (
    tester,
  ) async {
    cleanupFailures = 2;
    await worker.onStart(DateTime.now(), TaskStarter.values.first);
    expect(await pending(), isTrue);
    expect(foreground.stops, 0);
    await tester.pump(const Duration(seconds: 3));
    await _until(tester, () => methods.length == 2);
    expect(await pending(), isTrue);
    await tester.pump(const Duration(seconds: 3));
    await _until(tester, () => foreground.stops == 1);
    expect(await pending(), isNot(isTrue));
    expect(api.requests, 0);
    expect(methods.every((method) => method == 'disableMockProvider'), isTrue);
  });

  testWidgets(
    'a still-running service Stop failure retains cleanup attention and retries',
    (tester) async {
      foreground.stopFailures = 1;
      await worker.onStart(DateTime.now(), TaskStarter.values.first);
      expect(foreground.stops, 1);
      expect(foreground.running, isTrue);
      expect(await pending(), isTrue);
      await tester.pump(const Duration(seconds: 3));
      await _until(tester, () => foreground.stops == 2);
      expect(foreground.running, isFalse);
      expect(await pending(), isNot(isTrue));
    },
  );

  testWidgets(
    'a concurrently stopped service does not leave worker cleanup retrying',
    (tester) async {
      foreground.stopFailures = 1;
      foreground.disappearsOnStopFailure = true;
      await worker.onStart(DateTime.now(), TaskStarter.values.first);
      expect(foreground.stops, 1);
      expect(foreground.running, isFalse);
      expect(methods, ['disableMockProvider']);
      expect(await pending(), isNot(isTrue));
      await tester.pump(const Duration(seconds: 6));
      expect(
        foreground.stops,
        1,
        reason: 'An absent service must not schedule Stop retries',
      );
      expect(methods, ['disableMockProvider']);
      expect(api.requests, 0);
    },
  );

  testWidgets(
    'partial enable failure rolls back instead of submitting a location',
    (tester) async {
      await validSession();
      failEnable = true;
      await worker.onStart(DateTime.now(), TaskStarter.values.first);
      await _until(tester, () => foreground.stops == 1);
      expect(methods, ['enableMockProvider', 'disableMockProvider']);
      expect(await pending(), isNot(isTrue));
    },
  );

  testWidgets(
    'cleanup failure after an API error prevents automatic reinjection',
    (tester) async {
      await validSession();
      api.failAfterFirst = true;
      await worker.onStart(DateTime.now(), TaskStarter.values.first);
      await _until(tester, () => methods.contains('observeFused'));
      cleanupFailures = 99;
      await tester.pump(const Duration(seconds: 5));
      await _until(tester, () => methods.contains('disableMockProvider'));
      expect(await pending(), isTrue);
      await tester.pump(const Duration(seconds: 30));
      expect(api.requests, 2);
      expect(
        methods.where((method) => method == 'enableMockProvider'),
        hasLength(1),
      );
      expect(
        methods.where((method) => method == 'updateLocation'),
        hasLength(1),
      );
      expect(foreground.stops, 0);
      cleanupFailures = 0;
      await tester.pump(const Duration(seconds: 3));
      await _until(tester, () => foreground.stops == 1);
      expect(await pending(), isNot(isTrue));
    },
  );

  testWidgets(
    'destroy cleanup failure is recoverable without losing its marker',
    (tester) async {
      cleanupFailures = 1;
      await worker.onDestroy(DateTime.now(), true);
      expect(await pending(), isTrue);
      await worker.onDestroy(DateTime.now(), true);
      expect(await pending(), isNot(isTrue));
      expect(api.requests, 0);
    },
  );
}
