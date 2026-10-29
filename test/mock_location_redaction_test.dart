import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:summon_anywhere_tesla/core/services/mock_location_service.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.summonanywhere/mock_location');
  const sensitiveMarker = 'PRIVATE_PLATFORM_DETAIL_FIXTURE';

  test('platform errors do not expose their raw message or code', () async {
    final printed = <String>[];
    final oldDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) printed.add(message);
    };
    addTearDown(() {
      debugPrint = oldDebugPrint;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      throw PlatformException(code: sensitiveMarker, message: sensitiveMarker);
    });
    final service = MockLocationService();
    for (final operation in <Future<dynamic> Function()>[
      service.blockMocking,
      () => service.allowSession(1),
      () => service.retireSession(1),
      service.disableMockProvider,
      service.openDeveloperSettings,
      service.openBatterySettings,
    ]) {
      await expectLater(
        operation(),
        throwsA(
          isA<MockLocationException>().having(
            (error) => error.message,
            'sanitized message',
            isNot(contains(sensitiveMarker)),
          ),
        ),
      );
    }
    expect(await service.isEnabled(), isFalse);
    expect(printed.join('\n'), isNot(contains(sensitiveMarker)));
  });
}
