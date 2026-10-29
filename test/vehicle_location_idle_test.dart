import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_foreground_task/flutter_foreground_task_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:summon_anywhere_tesla/core/services/tesla_api_service.dart';
import 'package:summon_anywhere_tesla/core/storage/prefs_storage.dart';
import 'package:summon_anywhere_tesla/features/home/providers/vehicle_location_provider.dart';

class _Api extends Fake implements TeslaApiService {
  int requests = 0;
  int vehicleLists = 0;

  @override
  Future<List<TeslaVehicle>> getVehicles() async {
    vehicleLists++;
    return [
      const TeslaVehicle(
        id: 'fixture',
        vin: '',
        displayName: 'Tesla',
        state: 'online',
      ),
    ];
  }

  @override
  Future<VehicleLocationResult> getVehicleLocation(String vehicleId) async {
    requests++;
    return VehicleLocationResult(
      latitude: 52,
      longitude: 4,
      isAsleep: false,
      sourceTimestamp: DateTime.now(),
    );
  }
}

class _Foreground extends FlutterForegroundTaskPlatform {
  @override
  Future<bool> get isRunningService async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('opening the map fetches once without idle polling', (
    tester,
  ) async {
    final original = FlutterForegroundTaskPlatform.instance;
    FlutterForegroundTaskPlatform.instance = _Foreground();
    addTearDown(() => FlutterForegroundTaskPlatform.instance = original);
    SharedPreferences.setMockInitialValues({'selected_vehicle_id': 'fixture'});
    final prefs = await PrefsStorage.create();
    final api = _Api();
    final container = ProviderContainer(
      overrides: [
        prefsStorageProvider.overrideWithValue(prefs),
        teslaApiServiceProvider.overrideWith((ref) => api),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(vehicleLocationProvider).isLoading, isTrue);
    await tester.pump();
    await tester.pump();
    expect(container.read(vehicleLocationProvider).latitude, 52);
    expect(container.read(vehicleLocationProvider).vehicleName, 'Tesla');
    expect(api.requests, 1);
    expect(api.vehicleLists, 1);
    await tester.pump(const Duration(seconds: 15));
    expect(api.requests, 1);
  });

  testWidgets('a saved vehicle name avoids another vehicle-list request', (
    tester,
  ) async {
    final original = FlutterForegroundTaskPlatform.instance;
    FlutterForegroundTaskPlatform.instance = _Foreground();
    addTearDown(() => FlutterForegroundTaskPlatform.instance = original);
    SharedPreferences.setMockInitialValues({
      'selected_vehicle_id': 'fixture',
      'selected_vehicle_name': 'Saved Tesla',
    });
    final prefs = await PrefsStorage.create();
    final api = _Api();
    final container = ProviderContainer(
      overrides: [
        prefsStorageProvider.overrideWithValue(prefs),
        teslaApiServiceProvider.overrideWith((ref) => api),
      ],
    );
    addTearDown(container.dispose);
    expect(container.read(vehicleLocationProvider).vehicleName, 'Saved Tesla');
    await tester.pump();
    await tester.pump();
    expect(api.requests, 1);
    expect(api.vehicleLists, 0);
  });
}
