import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
// The existing Maps dependency supplies its platform interface for this fake.
// ignore: depend_on_referenced_packages
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:summon_anywhere_tesla/core/router/app_router.dart';
import 'package:summon_anywhere_tesla/core/services/auth_service.dart';
import 'package:summon_anywhere_tesla/core/storage/prefs_storage.dart';
import 'package:summon_anywhere_tesla/core/storage/secure_storage.dart';
import 'package:summon_anywhere_tesla/features/home/providers/summon_session_provider.dart';
import 'package:summon_anywhere_tesla/features/home/providers/vehicle_location_provider.dart';
import 'package:summon_anywhere_tesla/features/home/screens/home_screen.dart';
import 'package:summon_anywhere_tesla/features/home/widgets/location_status_sheet.dart';
import 'package:summon_anywhere_tesla/features/home/widgets/vehicle_map.dart';
import 'package:summon_anywhere_tesla/features/settings/settings_screen.dart';
import 'package:summon_anywhere_tesla/main.dart';

class _MapPlatform extends GoogleMapsFlutterPlatform {
  @override
  Widget buildViewWithConfiguration(
    int creationId,
    PlatformViewCreatedCallback onPlatformViewCreated, {
    required MapWidgetConfiguration widgetConfiguration,
    MapObjects mapObjects = const MapObjects(),
    MapConfiguration mapConfiguration = const MapConfiguration(),
  }) => const SizedBox.expand();
}

class _LocationPlatform extends GeolocatorPlatform {
  final streams = <StreamController<Position>>[];
  int cancellations = 0;
  int activeStreams = 0;
  int mostActiveStreams = 0;
  int startupChecks = 0;
  Position? cachedPosition;
  bool controlCurrentPosition = false;
  final currentSettings = <LocationSettings?>[];
  final currentPositions = <Completer<Position>>[];

  @override
  Future<bool> isLocationServiceEnabled() async {
    startupChecks++;
    return true;
  }

  @override
  Future<LocationPermission> checkPermission() async =>
      LocationPermission.whileInUse;

  @override
  Future<Position?> getLastKnownPosition({
    bool forceLocationManager = false,
  }) async => cachedPosition;

  @override
  Future<Position> getCurrentPosition({LocationSettings? locationSettings}) {
    currentSettings.add(locationSettings);
    if (!controlCurrentPosition) {
      return Future.error(TimeoutException('No current-position fixture.'));
    }
    final result = Completer<Position>();
    currentPositions.add(result);
    return result.future;
  }

  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) {
    final controller = StreamController<Position>.broadcast(
      onListen: () {
        activeStreams++;
        if (activeStreams > mostActiveStreams) {
          mostActiveStreams = activeStreams;
        }
      },
      onCancel: () {
        cancellations++;
        activeStreams--;
      },
    );
    streams.add(controller);
    return controller.stream;
  }
}

class _LocationSession extends SummonSession {
  _LocationSession(this.initial);
  final SummonSessionState initial;

  @override
  SummonSessionState build() => initial;

  void show(SummonSessionState next) => state = next;
}

Future<void> _pumpRecoveryHome(
  WidgetTester tester,
  _LocationPlatform locations, {
  _LocationSession? session,
}) async {
  final originalLocation = GeolocatorPlatform.instance;
  GeolocatorPlatform.instance = locations;
  final messenger = tester.binding.defaultBinaryMessenger;
  const connectivity = MethodChannel('dev.fluttercommunity.plus/connectivity');
  const connectivityEvents = MethodChannel(
    'dev.fluttercommunity.plus/connectivity_status',
  );
  messenger.setMockMethodCallHandler(connectivity, (_) async => ['wifi']);
  messenger.setMockMethodCallHandler(connectivityEvents, (_) async => null);
  final container = ProviderContainer(
    overrides: [
      vehicleLocationProvider.overrideWithValue(const VehicleLocationState()),
      if (session == null)
        summonSessionProvider.overrideWithValue(const SummonSessionState())
      else
        summonSessionProvider.overrideWith(() => session),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    container.dispose();
    GeolocatorPlatform.instance = originalLocation;
    messenger.setMockMethodCallHandler(connectivity, null);
    messenger.setMockMethodCallHandler(connectivityEvents, null);
    for (final stream in locations.streams) {
      await stream.close();
    }
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: HomeScreen()),
    ),
  );
  await tester.pump();
}

class _SettingsStorage extends SecureStorage {
  _SettingsStorage() : super(const FlutterSecureStorage());
  String? accessToken = 'existing-access-token';
  int clears = 0;

  @override
  Future<void> clearTokens() async {
    clears++;
    accessToken = null;
  }
}

class _SettingsAuth extends AuthService {
  _SettingsAuth(super.storage);
  int signIns = 0;
  Completer<void>? pending;

  @override
  Future<void> signIn() {
    signIns++;
    pending = Completer<void>();
    return pending!.future;
  }
}

class _SettingsVehicle extends VehicleLocation {
  int refreshes = 0;

  @override
  VehicleLocationState build() => const VehicleLocationState();

  @override
  Future<void> refresh() async {
    refreshes++;
  }
}

Position _position(
  double latitude, {
  bool mocked = false,
  DateTime? timestamp,
}) => Position(
  latitude: latitude,
  longitude: 5,
  timestamp: timestamp ?? DateTime.now(),
  accuracy: 3,
  altitude: 0,
  altitudeAccuracy: 1,
  heading: 0,
  headingAccuracy: 1,
  speed: 0,
  speedAccuracy: 1,
  isMocked: mocked,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GoogleMapsFlutterPlatform originalMaps;

  setUp(() {
    originalMaps = GoogleMapsFlutterPlatform.instance;
    GoogleMapsFlutterPlatform.instance = _MapPlatform();
  });
  tearDown(() => GoogleMapsFlutterPlatform.instance = originalMaps);

  testWidgets(
    'home restores controls and compact navigation without debug banner',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 780);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final messenger = tester.binding.defaultBinaryMessenger;
      const connectivity = MethodChannel(
        'dev.fluttercommunity.plus/connectivity',
      );
      const connectivityEvents = MethodChannel(
        'dev.fluttercommunity.plus/connectivity_status',
      );
      const location = MethodChannel('flutter.baseflow.com/geolocator');
      const gps = MethodChannel('com.summonanywhere/mock_location');
      final gpsCalls = <String>[];
      messenger.setMockMethodCallHandler(connectivity, (_) async => ['wifi']);
      messenger.setMockMethodCallHandler(connectivityEvents, (_) async => null);
      messenger.setMockMethodCallHandler(location, (call) async {
        if (call.method == 'isLocationServiceEnabled') return true;
        if (call.method == 'checkPermission') return 1; // Permanently denied.
        return null;
      });
      messenger.setMockMethodCallHandler(gps, (call) async {
        gpsCalls.add(call.method);
        return true;
      });
      SharedPreferences.setMockInitialValues({'onboarding_complete': true});
      final prefs = await PrefsStorage.create();
      final container = ProviderContainer(
        overrides: [
          prefsStorageProvider.overrideWithValue(prefs),
          vehicleLocationProvider.overrideWithValue(
            const VehicleLocationState(
              latitude: 52,
              longitude: 5,
              vehicleName: 'My Tesla',
            ),
          ),
          summonSessionProvider.overrideWithValue(const SummonSessionState()),
        ],
      );
      final router = container.read(appRouterProvider);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        router.dispose();
        container.dispose();
        for (final channel in [
          connectivity,
          connectivityEvents,
          location,
          gps,
        ]) {
          messenger.setMockMethodCallHandler(channel, null);
        }
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const SummonAnywhereApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(GoogleMap), findsOneWidget);
      expect(find.byType(CheckedModeBanner), findsNothing);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('My Tesla'), findsOneWidget);
      expect(find.text('Location status'), findsOneWidget);
      expect(find.text('Show both'), findsOneWidget);
      expect(
        find.text('Allow location access for the phone marker.'),
        findsOneWidget,
      );

      await tester.tap(find.text('Location status'));
      await tester.pumpAndSettle();
      expect(find.text('Effective phone GPS'), findsOneWidget);
      expect(find.text('Last real phone fix'), findsOneWidget);
      expect(gpsCalls, isEmpty);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.text('Mock location app'), findsOneWidget);
      expect(find.textContaining('Client Secret'), findsNothing);
      expect(find.byType(CheckedModeBanner), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, '/home');
      expect(tester.takeException(), isNull);
      tester.view.physicalSize = const Size(780, 360);
      await tester.pumpAndSettle();
      expect(find.text('Location status'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'silent location streams retry once, report unavailability, recover and dispose',
    (tester) async {
      final originalLocation = GeolocatorPlatform.instance;
      final locations = _LocationPlatform();
      GeolocatorPlatform.instance = locations;
      final messenger = tester.binding.defaultBinaryMessenger;
      const connectivity = MethodChannel(
        'dev.fluttercommunity.plus/connectivity',
      );
      const connectivityEvents = MethodChannel(
        'dev.fluttercommunity.plus/connectivity_status',
      );
      messenger.setMockMethodCallHandler(connectivity, (_) async => ['wifi']);
      messenger.setMockMethodCallHandler(connectivityEvents, (_) async => null);
      final container = ProviderContainer(
        overrides: [
          vehicleLocationProvider.overrideWithValue(
            const VehicleLocationState(),
          ),
          summonSessionProvider.overrideWithValue(const SummonSessionState()),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        container.dispose();
        GeolocatorPlatform.instance = originalLocation;
        messenger.setMockMethodCallHandler(connectivity, null);
        messenger.setMockMethodCallHandler(connectivityEvents, null);
        for (final stream in locations.streams) {
          await stream.close();
        }
      });
      Widget home() => UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: HomeScreen()),
      );

      await tester.pumpWidget(home());
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(locations.streams, hasLength(1));
      expect(locations.activeStreams, 1);
      await tester.pump(const Duration(seconds: 9));
      expect(locations.cancellations, 0);
      await tester.pump(const Duration(seconds: 1));
      expect(locations.cancellations, 1);
      expect(locations.activeStreams, 0);
      // Let the stream's asynchronous cancellation finish before advancing
      // the fake clock for the retry's separate startup delay.
      await tester.runAsync(() async {
        await Future<void>.delayed(Duration.zero);
      });
      await tester
          .pump(); // Complete cancellation and the new permission check.
      await tester.pump(const Duration(seconds: 1));
      expect(
        locations.streams,
        hasLength(2),
        reason: 'startup checks: ${locations.startupChecks}',
      );
      expect(locations.activeStreams, 1);
      expect(locations.mostActiveStreams, 1);

      await tester.pump(const Duration(seconds: 10));
      expect(
        find.text('Phone location unavailable. Retry location.'),
        findsOneWidget,
      );
      expect(locations.streams, hasLength(2));
      expect(locations.cancellations, 1);
      expect(locations.activeStreams, 1);
      await tester.pump(const Duration(seconds: 25));
      expect(locations.streams, hasLength(2));

      locations.streams[1].add(_position(53, mocked: true));
      await tester.runAsync(() async {
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
      final map = tester.widget<VehicleMap>(find.byType(VehicleMap));
      expect(map.phoneLatitude, 53);
      expect(map.phoneIsMocked, isTrue);
      expect(
        find.text('Phone location unavailable. Retry location.'),
        findsNothing,
      );
      await tester.pump(const Duration(seconds: 25));
      expect(locations.streams, hasLength(2));
      expect(locations.cancellations, 1);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(locations.cancellations, 2);
      expect(locations.activeStreams, 0);

      // Start another silent stream, then dispose before its watchdog expires.
      await tester.pumpWidget(home());
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(locations.streams, hasLength(3));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(locations.cancellations, 3);
      expect(locations.activeStreams, 0);
      await tester.pump(const Duration(seconds: 9));
      expect(locations.streams, hasLength(3));
      expect(tester.takeException(), isNull);
      // Flutter's pending-timer invariant also fails here if disposal leaves
      // that 10-second watchdog scheduled, even with a mounted callback guard.
    },
  );

  testWidgets(
    'idle mocked cache stays explicit while separate real GPS and fresh fused fixes recover',
    (tester) async {
      const warning =
          'Last phone fix is mocked or stale. Waiting for fresh effective location.';
      final locations = _LocationPlatform()
        ..cachedPosition = _position(
          53,
          mocked: true,
          timestamp: DateTime.now().subtract(const Duration(minutes: 3)),
        )
        ..controlCurrentPosition = true;
      await _pumpRecoveryHome(tester, locations);
      expect(find.text(warning), findsOneWidget);
      expect(locations.currentPositions, hasLength(1));
      final settings = locations.currentSettings.single as AndroidSettings;
      expect(settings.forceLocationManager, isTrue);
      expect(settings.timeLimit, const Duration(seconds: 15));
      expect(
        tester.widget<VehicleMap>(find.byType(VehicleMap)).phoneLatitude,
        53,
      );

      locations.currentPositions.single.complete(_position(51));
      await tester.pump();
      expect(find.text(warning), findsOneWidget);
      expect(
        tester.widget<VehicleMap>(find.byType(VehicleMap)).phoneLatitude,
        53,
      );
      await tester.tap(find.text('Location status'));
      await tester.pumpAndSettle();
      expect(find.textContaining('GPS provider (non-mocked)'), findsOneWidget);
      expect(find.textContaining('51.000000, 5.000000'), findsOneWidget);
      expect(find.textContaining('Mocked/stale effective fix'), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      await tester.pump(const Duration(seconds: 1));
      locations.streams.single.add(_position(53, mocked: true));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      locations.streams.single.add(
        _position(
          52,
          timestamp: DateTime.now().subtract(const Duration(minutes: 3)),
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(find.text(warning), findsOneWidget);
      expect(locations.currentPositions, hasLength(1));

      locations.streams.single.add(_position(51));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(find.text(warning), findsNothing);
      expect(
        tester.widget<VehicleMap>(find.byType(VehicleMap)).phoneLatitude,
        51,
      );
      expect(locations.currentPositions, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'starting and waiting sessions retain stale warning until a location is submitted',
    (tester) async {
      const warning =
          'Last phone fix is mocked or stale. Waiting for fresh effective location.';
      final stale = DateTime.now().subtract(const Duration(minutes: 3));
      final locations = _LocationPlatform()
        ..cachedPosition = _position(53, mocked: true, timestamp: stale)
        ..controlCurrentPosition = true;
      final session = _LocationSession(const SummonSessionState());
      await _pumpRecoveryHome(tester, locations, session: session);
      await tester.pump(const Duration(seconds: 1));
      expect(locations.currentPositions, hasLength(1));
      session.show(const SummonSessionState(isStarting: true));
      await tester.pump();
      expect(find.text(warning), findsOneWidget);
      session.show(
        const SummonSessionState(
          isActive: true,
          statusMessage: 'Waiting for vehicle.',
        ),
      );
      await tester.pump();
      locations.currentPositions.single.complete(_position(51));
      await tester.pump();
      locations.streams.single.add(_position(52, timestamp: stale));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(find.text(warning), findsOneWidget);
      expect(locations.currentPositions, hasLength(1));
      locations.streams.single.add(_position(53, mocked: true));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(find.text(warning), findsOneWidget);
      session.show(
        SummonSessionState(isActive: true, lastSubmittedAt: DateTime.now()),
      );
      await tester.pump();
      expect(find.text(warning), findsNothing);
      expect(locations.currentPositions, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'session transitions request real GPS once after Stop and ignore a result after restart',
    (tester) async {
      const warning =
          'Last phone fix is mocked or stale. Waiting for fresh effective location.';
      final locations = _LocationPlatform()
        ..cachedPosition = _position(53, mocked: true)
        ..controlCurrentPosition = true;
      final session = _LocationSession(
        SummonSessionState(isActive: true, lastSubmittedAt: DateTime.now()),
      );
      await _pumpRecoveryHome(tester, locations, session: session);
      expect(find.text(warning), findsNothing);
      expect(locations.currentPositions, isEmpty);

      session.show(const SummonSessionState(isActive: true, isStopping: true));
      await tester.pump();
      expect(find.text(warning), findsOneWidget);
      expect(locations.currentPositions, isEmpty);
      session.show(const SummonSessionState());
      await tester.pump();
      expect(locations.currentPositions, hasLength(1));
      session.show(const SummonSessionState());
      await tester.pump();
      expect(locations.currentPositions, hasLength(1));

      session.show(const SummonSessionState(isStarting: true));
      await tester.pump();
      locations.currentPositions.single.complete(_position(51));
      await tester.pump();
      expect(find.text(warning), findsOneWidget);
      expect(locations.currentPositions, hasLength(1));
      await tester.tap(find.text('Location status'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('No non-mocked fix observed yet'),
        findsOneWidget,
      );
      expect(find.textContaining('GPS provider (non-mocked)'), findsNothing);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      session.show(const SummonSessionState());
      await tester.pump();
      expect(find.text(warning), findsOneWidget);
      expect(locations.currentPositions, hasLength(2));
      locations.currentPositions.last.complete(_position(52));
      await tester.pump();
      expect(
        tester.widget<VehicleMap>(find.byType(VehicleMap)).phoneLatitude,
        53,
      );
      expect(find.text(warning), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'settings sign-in guards taps, preserves tokens on failure and refreshes after success',
    (tester) async {
      final storage = _SettingsStorage();
      final auth = _SettingsAuth(storage);
      final vehicle = _SettingsVehicle();
      final container = ProviderContainer(
        overrides: [
          authServiceProvider.overrideWithValue(auth),
          vehicleLocationProvider.overrideWith(() => vehicle),
          summonSessionProvider.overrideWithValue(const SummonSessionState()),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        container.dispose();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );
      await tester.tap(find.text('Sign in to Tesla'));
      await tester.tap(find.text('Sign in to Tesla'));
      expect(auth.signIns, 1);
      auth.pending!.completeError(
        AuthException('Tesla sign-in failed. Please retry.'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Tesla sign-in failed. Please retry.'), findsOneWidget);
      expect(storage.accessToken, 'existing-access-token');
      expect(storage.clears, 0);
      expect(vehicle.refreshes, 0);

      await tester.tap(find.text('Sign in to Tesla'));
      expect(auth.signIns, 2);
      auth.pending!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Signed in to Tesla.'), findsOneWidget);
      expect(vehicle.refreshes, 1);
      expect(storage.clears, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'settings sign-in is disabled during every running session phase',
    (tester) async {
      final auth = _SettingsAuth(_SettingsStorage());
      for (final session in const [
        SummonSessionState(isStarting: true),
        SummonSessionState(isActive: true),
        SummonSessionState(isStopping: true),
      ]) {
        final container = ProviderContainer(
          overrides: [
            authServiceProvider.overrideWithValue(auth),
            summonSessionProvider.overrideWithValue(session),
          ],
        );
        try {
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: const MaterialApp(home: SettingsScreen()),
            ),
          );
          final tile = tester.widget<ListTile>(
            find.ancestor(
              of: find.text('Sign in to Tesla'),
              matching: find.byType(ListTile),
            ),
          );
          expect(tile.enabled, isFalse);
          expect(find.text('Stop GPS sync before signing in.'), findsOneWidget);
          await tester.tap(find.text('Sign in to Tesla'));
          expect(auth.signIns, 0);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          container.dispose();
        }
      }
    },
  );

  testWidgets(
    'satellite map retains both marker identities at the same coordinate',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: VehicleMap(
              phoneLatitude: 52,
              phoneLongitude: 5,
              phoneIsMocked: true,
              vehicleLatitude: 52,
              vehicleLongitude: 5,
            ),
          ),
        ),
      );
      final map = tester.widget<GoogleMap>(find.byType(GoogleMap));
      expect(map.mapType, MapType.satellite);
      expect(map.markers.map((m) => m.markerId.value).toSet(), {
        'phone',
        'vehicle',
      });
      final phone = map.markers.singleWhere((m) => m.markerId.value == 'phone');
      final vehicle = map.markers.singleWhere(
        (m) => m.markerId.value == 'vehicle',
      );
      expect(phone.position, vehicle.position);
      expect(phone.anchor, isNot(vehicle.anchor));
      expect(phone.infoWindow.snippet, 'Mocked location');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'location sheet updates effective fix while preserving last real fix',
    (tester) async {
      final phone = ValueNotifier<PhoneFixes>(
        PhoneFixes(effective: _position(52), lastReal: _position(52)),
      );
      final container = ProviderContainer(
        overrides: [
          vehicleLocationProvider.overrideWithValue(
            const VehicleLocationState(latitude: 53, longitude: 5),
          ),
          summonSessionProvider.overrideWithValue(const SummonSessionState()),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        phone.dispose();
        container.dispose();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(body: LocationStatusSheet(phoneFixes: phone)),
          ),
        ),
      );
      expect(find.textContaining('Non-mocked ·'), findsOneWidget);
      phone.value = PhoneFixes(
        effective: _position(53, mocked: true),
        lastReal: phone.value.lastReal,
      );
      await tester.pump();
      expect(find.textContaining('Mocked ·'), findsOneWidget);
      expect(find.textContaining('52.000000, 5.000000'), findsOneWidget);
      expect(find.textContaining('53.000000, 5.000000'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );
}
