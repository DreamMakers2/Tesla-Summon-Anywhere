import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_foreground_task/flutter_foreground_task_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:summon_anywhere_tesla/core/services/tesla_api_service.dart';
import 'package:summon_anywhere_tesla/features/background/summon_task_handler.dart';

class _Api extends Fake implements TeslaApiService {
  int requests = 0;
  int activeRequests = 0;
  int maxActiveRequests = 0;
  Future<VehicleLocationResult> Function(int)? respond;

  @override
  Future<VehicleLocationResult> getVehicleLocation(String vehicleId) async {
    requests++;
    activeRequests++;
    if (activeRequests > maxActiveRequests) maxActiveRequests = activeRequests;
    try {
      return await (respond?.call(requests) ?? Future.value(_fresh()));
    } finally {
      activeRequests--;
    }
  }
}

VehicleLocationResult _fresh() => VehicleLocationResult(
  latitude: 52,
  longitude: 4,
  isAsleep: false,
  sourceTimestamp: DateTime.now(),
);

class _Foreground extends FlutterForegroundTaskPlatform {
  int stops = 0;
  bool running = true;
  final notifications = <String?>[];

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
  }) async {
    notifications.add(notificationText);
  }

  @override
  Future<void> stopService() async {
    stops++;
    running = false;
  }
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 50 && !ready(); attempt++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
  expect(
    ready(),
    isTrue,
    reason: 'The mocked bridge did not reach its expected state',
  );
}

Future<void> _start(SummonTaskHandler worker) async {
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
  await worker.onStart(DateTime.now(), TaskStarter.values.first);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.summonanywhere/mock_location');
  late FlutterForegroundTaskPlatform original;
  late _Foreground foreground;
  late _Api api;
  late SummonTaskHandler worker;
  late List<MethodCall> calls;
  bool wrongFused = false;

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
    calls = [];
    wrongFused = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'observeGps' || call.method == 'observeFused') {
            return {
              'latitude': 52.0,
              'longitude': call.method == 'observeFused' && wrongFused
                  ? 5.0
                  : 4.0,
              'mocked': true,
              'timestampMs': DateTime.now().millisecondsSinceEpoch,
            };
          }
          return true;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    FlutterForegroundTask.resetStatic();
    FlutterForegroundTaskPlatform.instance = original;
  });

  testWidgets(
    'fresh Tesla coordinates reach both observation paths before sync confirmation',
    (tester) async {
      await _start(worker);
      await _until(tester, () => foreground.notifications.isNotEmpty);
      expect(calls.map((call) => call.method).take(2), [
        'enableMockProvider',
        'updateLocation',
      ]);
      final update = calls.firstWhere(
        (call) => call.method == 'updateLocation',
      );
      expect(update.arguments['latitude'], 52.0);
      expect(update.arguments['longitude'], 4.0);
      expect(update.arguments['sessionId'], isA<int>());
      expect(
        calls.map((call) => call.method),
        containsAll(['observeGps', 'observeFused']),
      );
      expect(foreground.notifications.last, contains('GPS syncing'));
      await worker.onDestroy(DateTime.now(), false);
      expect(calls.last.method, 'disableMockProvider');
    },
  );

  testWidgets(
    'a mismatching fused observation cannot confirm synchronization',
    (tester) async {
      wrongFused = true;
      await _start(worker);
      await _until(
        tester,
        () => calls.any((call) => call.method == 'observeFused'),
      );
      await tester.pump();
      expect(
        foreground.notifications,
        isNot(contains(contains('GPS syncing'))),
      );
      await worker.onDestroy(DateTime.now(), false);
    },
  );

  testWidgets('a response arriving after Stop cannot enable or update GPS', (
    tester,
  ) async {
    final response = Completer<VehicleLocationResult>();
    api.respond = (_) => response.future;
    await _start(worker);
    await _until(tester, () => api.requests == 1);
    await worker.onDestroy(DateTime.now(), false);
    response.complete(_fresh());
    await tester.pump();
    expect(calls.map((call) => call.method), ['disableMockProvider']);
  });

  testWidgets('a slow Tesla request never overlaps another polling request', (
    tester,
  ) async {
    final response = Completer<VehicleLocationResult>();
    api.respond = (_) => response.future;
    await _start(worker);
    await _until(tester, () => api.requests == 1);
    await tester.pump(const Duration(seconds: 20));
    expect(api.requests, 1);
    expect(api.maxActiveRequests, 1);
    await worker.onDestroy(DateTime.now(), false);
    response.complete(_fresh());
    await tester.pump();
    expect(calls.map((call) => call.method), ['disableMockProvider']);
  });

  testWidgets('Stop during enable never submits a later location update', (
    tester,
  ) async {
    final enabled = Completer<bool>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'enableMockProvider') return enabled.future;
          return true;
        });
    await _start(worker);
    await _until(
      tester,
      () => calls.any((call) => call.method == 'enableMockProvider'),
    );
    await worker.onDestroy(DateTime.now(), false);
    enabled.complete(true);
    await tester.pump();
    expect(calls.where((call) => call.method == 'updateLocation'), isEmpty);
  });

  testWidgets('a sleeping response removes active mocks before waiting', (
    tester,
  ) async {
    api.respond = (request) async => request == 1
        ? _fresh()
        : VehicleLocationResult.asleep(
            retryAt: DateTime.now().add(const Duration(seconds: 30)),
          );
    await _start(worker);
    await _until(tester, () => foreground.notifications.isNotEmpty);
    await tester.pump(const Duration(seconds: 5));
    await _until(
      tester,
      () => calls.any((call) => call.method == 'disableMockProvider'),
    );
    expect(api.requests, 2);
    expect(
      calls.where((call) => call.method == 'updateLocation'),
      hasLength(1),
    );
    await worker.onDestroy(DateTime.now(), false);
  });

  testWidgets(
    'lost cancel message is recovered after a delayed Fleet response',
    (tester) async {
      final response = Completer<VehicleLocationResult>();
      api.respond = (_) => response.future;
      await _start(worker);
      await _until(tester, () => api.requests == 1);
      final id = await FlutterForegroundTask.getData<int>(
        key: 'sessionDeadlineMs',
      );
      await FlutterForegroundTask.saveData(
        key: 'cancelledSessionId',
        value: id!,
      );
      response.complete(_fresh());
      await _until(tester, () => foreground.stops == 1);
      expect(calls.map((call) => call.method), ['disableMockProvider']);
      expect(api.requests, 1);
      await worker.onDestroy(DateTime.now(), false);
    },
  );

  testWidgets('lost cancel message is recovered after pending native enable', (
    tester,
  ) async {
    final enabled = Completer<bool>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'enableMockProvider') return enabled.future;
          return true;
        });
    await _start(worker);
    await _until(
      tester,
      () => calls.any((call) => call.method == 'enableMockProvider'),
    );
    final id = await FlutterForegroundTask.getData<int>(
      key: 'sessionDeadlineMs',
    );
    await FlutterForegroundTask.saveData(key: 'cancelledSessionId', value: id!);
    enabled.complete(true);
    await _until(tester, () => foreground.stops == 1);
    expect(calls.map((call) => call.method), [
      'enableMockProvider',
      'disableMockProvider',
    ]);
    expect(api.requests, 1);
    await worker.onDestroy(DateTime.now(), false);
  });

  testWidgets(
    'lost cancel message after pending update prevents confirmation and more polling',
    (tester) async {
      final updated = Completer<bool>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'updateLocation') return updated.future;
            return true;
          });
      await _start(worker);
      await _until(
        tester,
        () => calls.any((call) => call.method == 'updateLocation'),
      );
      final id = await FlutterForegroundTask.getData<int>(
        key: 'sessionDeadlineMs',
      );
      await FlutterForegroundTask.saveData(
        key: 'cancelledSessionId',
        value: id!,
      );
      updated.complete(true);
      await _until(tester, () => foreground.stops == 1);
      await tester.pump(const Duration(seconds: 10));
      expect(calls.map((call) => call.method), [
        'enableMockProvider',
        'updateLocation',
        'disableMockProvider',
      ]);
      expect(foreground.notifications, isEmpty);
      expect(api.requests, 1);
      await worker.onDestroy(DateTime.now(), false);
    },
  );

  testWidgets('durable cancellation prevents even the first Fleet GET', (
    tester,
  ) async {
    await _start(worker);
    final id = await FlutterForegroundTask.getData<int>(
      key: 'sessionDeadlineMs',
    );
    await FlutterForegroundTask.saveData(key: 'cancelledSessionId', value: id!);
    await _until(tester, () => foreground.stops == 1);
    expect(api.requests, 0);
    expect(calls.map((call) => call.method), ['disableMockProvider']);
    await worker.onDestroy(DateTime.now(), false);
  });

  testWidgets(
    'durable cancellation ends sleeping-vehicle backoff without another GET',
    (tester) async {
      api.respond = (_) async => VehicleLocationResult.asleep(
        retryAt: DateTime.now().add(const Duration(seconds: 30)),
      );
      await _start(worker);
      await _until(tester, () => api.requests == 1);
      final id = await FlutterForegroundTask.getData<int>(
        key: 'sessionDeadlineMs',
      );
      await FlutterForegroundTask.saveData(
        key: 'cancelledSessionId',
        value: id!,
      );
      await tester.pump(const Duration(seconds: 30));
      await _until(tester, () => foreground.stops == 1);
      expect(api.requests, 1);
      expect(
        calls.where((call) => call.method == 'enableMockProvider'),
        isEmpty,
      );
      await worker.onDestroy(DateTime.now(), false);
    },
  );

  testWidgets('cancellation message interrupts sleeping backoff immediately', (
    tester,
  ) async {
    api.respond = (_) async => VehicleLocationResult.asleep(
      retryAt: DateTime.now().add(const Duration(seconds: 30)),
    );
    await _start(worker);
    await _until(tester, () => api.requests == 1);
    final id = await FlutterForegroundTask.getData<int>(
      key: 'sessionDeadlineMs',
    );
    worker.onReceiveData({'event': 'cancel', 'sessionId': id!});
    await _until(tester, () => foreground.stops == 1);
    await tester.pump(const Duration(minutes: 1));
    expect(api.requests, 1);
    expect(calls.map((call) => call.method), ['disableMockProvider']);
    await worker.onDestroy(DateTime.now(), false);
  });

  testWidgets(
    'cancellation message prevents a pending response from enabling GPS',
    (tester) async {
      final response = Completer<VehicleLocationResult>();
      api.respond = (_) => response.future;
      await _start(worker);
      await _until(tester, () => api.requests == 1);
      final id = await FlutterForegroundTask.getData<int>(
        key: 'sessionDeadlineMs',
      );
      worker.onReceiveData({'event': 'cancel', 'sessionId': id!});
      await _until(tester, () => foreground.stops == 1);
      response.complete(_fresh());
      await tester.pump();
      expect(calls.map((call) => call.method), ['disableMockProvider']);
      await worker.onDestroy(DateTime.now(), false);
    },
  );

  testWidgets(
    'cancellation belonging to an old session cannot stop the current worker',
    (tester) async {
      await _start(worker);
      final id = (await FlutterForegroundTask.getData<int>(
        key: 'sessionDeadlineMs',
      ))!;
      await FlutterForegroundTask.saveData(
        key: 'cancelledSessionId',
        value: id - 1,
      );
      await _until(tester, () => foreground.notifications.isNotEmpty);
      worker.onReceiveData({'event': 'cancel', 'sessionId': id - 1});
      await tester.pump(const Duration(milliseconds: 1));
      expect(foreground.stops, 0);
      expect(api.requests, 1);
      expect(foreground.notifications.last, contains('GPS syncing'));
      await worker.onDestroy(DateTime.now(), false);
    },
  );

  testWidgets('the worker deadline expires while waiting for a slow response', (
    tester,
  ) async {
    final response = Completer<VehicleLocationResult>();
    api.respond = (_) => response.future;
    await _start(worker);
    await _until(tester, () => api.requests == 1);
    await tester.pump(const Duration(minutes: 5));
    await _until(tester, () => foreground.stops == 1);
    response.complete(_fresh());
    await tester.pump();
    expect(calls.where((call) => call.method == 'enableMockProvider'), isEmpty);
    expect(calls.where((call) => call.method == 'updateLocation'), isEmpty);
    await worker.onDestroy(DateTime.now(), true);
  });
}
