import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:summon_anywhere_tesla/core/services/tesla_api_service.dart';
import 'package:summon_anywhere_tesla/core/services/vehicle_polling.dart';

class _Preferences extends Fake implements SharedPreferencesAsync {
  _Preferences(this.values);
  final Map<String, int> values;

  @override
  Future<int?> getInt(String key) async => values[key];

  @override
  Future<void> setInt(String key, int value) async => values[key] = value;
}

void main() {
  test(
    'separate clients retain cooldown and failure count until success',
    () async {
      final values = <String, int>{};
      final now = DateTime.utc(2026, 1, 1);
      VehiclePolling reopened() =>
          VehiclePolling(preferences: _Preferences(values));
      final foreground = reopened();
      final first = await foreground.failed(now);
      expect(first, now.add(const Duration(seconds: 10)));
      expect((await reopened().nextRequest())?.toUtc(), first);
      final second = await reopened().failed(first);
      expect(second, first.add(const Duration(seconds: 20)));
      expect((await foreground.nextRequest())?.toUtc(), second);
      await reopened().succeeded(second);
      expect(
        (await foreground.nextRequest())?.toUtc(),
        second.add(const Duration(seconds: 5)),
      );
      final afterRecovery = await reopened().failed(second);
      expect(afterRecovery, second.add(const Duration(seconds: 10)));
    },
  );

  test('transient and unavailable failures back off and remain bounded', () {
    expect(VehiclePolling.delayFor(1), const Duration(seconds: 10));
    expect(VehiclePolling.delayFor(2), const Duration(seconds: 20));
    expect(VehiclePolling.delayFor(5), const Duration(seconds: 120));
    expect(VehiclePolling.delayFor(20), const Duration(seconds: 120));
    expect(
      VehiclePolling.delayFor(1, unavailable: true),
      const Duration(seconds: 30),
    );
    expect(
      VehiclePolling.delayFor(2, unavailable: true),
      const Duration(seconds: 60),
    );
    expect(
      VehiclePolling.delayFor(5, rateLimited: true),
      const Duration(seconds: 120),
    );
    expect(
      VehiclePolling.delayFor(
        1,
        rateLimited: true,
        serverDelay: const Duration(minutes: 5),
      ),
      const Duration(minutes: 5),
    );
  });

  test('retry and reset headers are honored without shortening the wait', () {
    final now = DateTime.utc(2026, 1, 1);
    expect(
      VehiclePolling.serverDelay({
        'retry-after': ['45'],
      }, now),
      const Duration(seconds: 45),
    );
    expect(
      VehiclePolling.serverDelay({
        'Retry-After': ['Thu, 01 Jan 2026 00:02:00 GMT'],
      }, now),
      const Duration(minutes: 2),
    );
    expect(
      VehiclePolling.serverDelay({
        'RateLimit-Vehicle-Reset': ['90'],
      }, now),
      const Duration(seconds: 90),
    );
    expect(
      VehiclePolling.serverDelay({
        'RateLimit-Reset': [
          now
              .add(const Duration(seconds: 90))
              .millisecondsSinceEpoch
              .toString(),
        ],
      }, now),
      const Duration(seconds: 90),
    );
    expect(
      VehiclePolling.serverDelay({
        'retry-after': ['bad'],
      }, now),
      isNull,
    );
    expect(
      VehiclePolling.serverDelay({
        'Retry-After': ['15'],
        'RateLimit-Global-Reset': [
          '${now.add(const Duration(minutes: 3)).millisecondsSinceEpoch ~/ 1000}',
        ],
      }, now),
      const Duration(minutes: 3),
    );
  });

  test('only fresh, valid Tesla coordinates are eligible for injection', () {
    final now = DateTime.utc(2026, 1, 1);
    Map<String, dynamic> data(
      Object timestamp, {
      double lat = 52,
      double lon = 4,
    }) => {
      'display_name': 'Tesla',
      'drive_state': {
        'latitude': lat,
        'longitude': lon,
        'timestamp': timestamp,
      },
    };
    final fresh = TeslaApiService.parseLocation(
      data(now.millisecondsSinceEpoch),
      now,
    );
    expect(fresh.isLocationUnavailable, isFalse);
    expect(fresh.latitude, 52);
    expect(
      fresh.sourceTimestamp?.millisecondsSinceEpoch,
      now.millisecondsSinceEpoch,
    );
    expect(fresh.vehicleName, 'Tesla');
    expect(
      TeslaApiService.parseLocation(
        data(now.subtract(const Duration(minutes: 3)).millisecondsSinceEpoch),
        now,
      ).isStale,
      isTrue,
    );
    expect(
      TeslaApiService.parseLocation(
        data(now.add(const Duration(minutes: 1)).millisecondsSinceEpoch),
        now,
      ).isLocationUnavailable,
      isTrue,
    );
    expect(
      TeslaApiService.parseLocation(data('missing'), now).isLocationUnavailable,
      isTrue,
    );
    expect(
      TeslaApiService.parseLocation(
        data(now.millisecondsSinceEpoch, lat: 91),
        now,
      ).isLocationUnavailable,
      isTrue,
    );
  });
}
