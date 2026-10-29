import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_foreground_task/flutter_foreground_task_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:summon_anywhere_tesla/core/services/notification_service.dart';

class _Notifications extends FlutterForegroundTaskPlatform {
  NotificationPermission permission = NotificationPermission.denied;
  int prompts = 0;
  Completer<NotificationPermission>? gate;

  @override
  Future<NotificationPermission> checkNotificationPermission() async =>
      permission;

  @override
  Future<NotificationPermission> requestNotificationPermission() async {
    prompts++;
    return gate == null ? permission : gate!.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FlutterForegroundTaskPlatform original;
  late _Notifications platform;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    original = FlutterForegroundTaskPlatform.instance;
    platform = _Notifications();
    FlutterForegroundTaskPlatform.instance = platform;
  });

  tearDown(() => FlutterForegroundTaskPlatform.instance = original);

  test('permission status does not prompt', () async {
    expect(await NotificationService().status(), NotificationPermission.denied);
    expect(platform.prompts, 0);
  });

  test(
    'denial is retained across service instances without repeated prompts',
    () async {
      expect(
        await NotificationService().requestOnce(),
        NotificationPermission.denied,
      );
      expect(
        await NotificationService().requestOnce(),
        NotificationPermission.denied,
      );
      expect(platform.prompts, 1);
    },
  );

  test('granted permission never prompts', () async {
    platform.permission = NotificationPermission.granted;
    expect(
      await NotificationService().requestOnce(),
      NotificationPermission.granted,
    );
    expect(platform.prompts, 0);
  });

  test('duplicate taps share the in-flight permission request', () async {
    platform.gate = Completer<NotificationPermission>();
    final service = NotificationService();
    final first = service.requestOnce();
    final second = service.requestOnce();
    for (var i = 0; i < 20 && platform.prompts == 0; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(platform.prompts, 1);
    platform.gate!.complete(NotificationPermission.denied);
    expect(await first, NotificationPermission.denied);
    expect(await second, NotificationPermission.denied);
  });
}
