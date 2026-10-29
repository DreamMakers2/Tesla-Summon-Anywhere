import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../providers/summon_session_provider.dart';
import '../providers/vehicle_location_provider.dart';
import '../widgets/location_status_sheet.dart';
import '../widgets/session_error_banner.dart';
import '../widgets/summon_button.dart';
import '../widgets/vehicle_map.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  StreamSubscription<List<ConnectivityResult>>? _connectivity;
  StreamSubscription<Position>? _positions;
  ProviderSubscription<SummonSessionState>? _sessionChanges;
  Timer? _locationWatchdog;
  int _silentLocationRetries = 0;
  final _phone = ValueNotifier<PhoneFixes>(const PhoneFixes());
  DateTime? _effectiveRecoveryAfter;
  bool _realGpsInFlight = false;
  bool _realGpsAttempted = false;
  int _realGpsGeneration = 0;
  bool _offline = false;
  bool _checkingLocation = false;
  bool _locationNeedsSettings = false;
  bool _locationServiceDisabled = false;
  String? _locationError;
  int _fitRequest = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sessionChanges = ref.listenManual(summonSessionProvider, _sessionChanged);
    _connectivity = Connectivity().onConnectivityChanged.listen(
      _setConnectivity,
    );
    unawaited(Connectivity().checkConnectivity().then(_setConnectivity));
    unawaited(_startLocation());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_startLocation());
      unawaited(ref.read(summonSessionProvider.notifier).checkService());
    }
  }

  void _setConnectivity(List<ConnectivityResult> results) {
    if (!mounted) return;
    setState(
      () => _offline = results.every((r) => r == ConnectivityResult.none),
    );
  }

  bool _allowsMock(SummonSessionState session) =>
      session.isActive &&
      !session.isStopping &&
      session.lastSubmittedAt != null;

  bool _sessionBusy(SummonSessionState session) =>
      session.isStarting || session.isActive || session.isStopping;

  void _sessionChanged(SummonSessionState? previous, SummonSessionState next) {
    if (_sessionBusy(next) && (previous == null || !_sessionBusy(previous))) {
      _realGpsGeneration++;
      _realGpsAttempted = false;
    }
    if (_allowsMock(next)) {
      _effectiveRecoveryAfter = null;
      _setPhoneRecovery(false);
    } else {
      if (_phone.value.effective?.isMocked ?? false) _markPhoneRecovery();
      if (!_sessionBusy(next)) unawaited(_refreshRealGps());
    }
  }

  void _setPhoneRecovery(bool pending) {
    final phone = _phone.value;
    if (phone.effectiveRecoveryPending == pending) return;
    _phone.value = PhoneFixes(
      effective: phone.effective,
      lastReal: phone.lastReal,
      lastRealIsGps: phone.lastRealIsGps,
      effectiveRecoveryPending: pending,
    );
    if (mounted) setState(() {});
  }

  void _markPhoneRecovery() {
    _effectiveRecoveryAfter ??= DateTime.now();
    _setPhoneRecovery(true);
  }

  bool _freshSince(Position position, DateTime after) {
    final age = DateTime.now().difference(position.timestamp);
    return !position.isMocked &&
        !position.timestamp.isBefore(after) &&
        age >= const Duration(seconds: -10) &&
        age <= const Duration(seconds: 30);
  }

  Future<void> _refreshRealGps() async {
    if (!mounted ||
        _realGpsInFlight ||
        _realGpsAttempted ||
        _locationNeedsSettings ||
        _locationServiceDisabled ||
        !_phone.value.effectiveRecoveryPending ||
        _sessionBusy(ref.read(summonSessionProvider))) {
      return;
    }
    _realGpsInFlight = true;
    _realGpsAttempted = true;
    final generation = _realGpsGeneration;
    final requestedAt = DateTime.now();
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: AndroidSettings(
          forceLocationManager: true,
          accuracy: LocationAccuracy.high,
          timeLimit: const Duration(seconds: 15),
        ),
      );
      if (!mounted ||
          generation != _realGpsGeneration ||
          _sessionBusy(ref.read(summonSessionProvider)) ||
          !_freshSince(position, requestedAt)) {
        return;
      }
      final phone = _phone.value;
      _phone.value = PhoneFixes(
        effective: phone.effective,
        lastReal: position,
        lastRealIsGps: true,
        effectiveRecoveryPending: phone.effectiveRecoveryPending,
      );
    } catch (_) {
      // The pending-effective warning remains; Retry can request another fix.
    } finally {
      _realGpsInFlight = false;
      if (mounted && generation != _realGpsGeneration) {
        unawaited(_refreshRealGps());
      }
    }
  }

  void _observe(Position position, {bool cached = false}) {
    if (!mounted) return;
    final session = ref.read(summonSessionProvider);
    final phone = _phone.value;
    var pending = phone.effectiveRecoveryPending;
    if (!_allowsMock(session) && position.isMocked) {
      _effectiveRecoveryAfter ??= DateTime.now();
      pending = true;
    } else if (!cached &&
        _effectiveRecoveryAfter != null &&
        _freshSince(position, _effectiveRecoveryAfter!)) {
      pending = false;
      _effectiveRecoveryAfter = null;
    }
    final keepReal = position.isMocked || phone.lastRealIsGps;
    _phone.value = PhoneFixes(
      effective: position,
      lastReal: keepReal ? phone.lastReal : position,
      lastRealIsGps: phone.lastRealIsGps,
      effectiveRecoveryPending: pending,
    );
    setState(() => _locationError = null);
    if (pending) unawaited(_refreshRealGps());
  }

  Future<void> _startLocation() async {
    if (!mounted || _checkingLocation) return;
    _checkingLocation = true;
    try {
      _locationServiceDisabled = !await Geolocator.isLocationServiceEnabled();
      if (_locationServiceDisabled) {
        if (mounted) {
          setState(() => _locationError = 'Turn on phone location.');
        }
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      _locationNeedsSettings = permission == LocationPermission.deniedForever;
      if (permission == LocationPermission.denied || _locationNeedsSettings) {
        if (mounted) {
          setState(
            () =>
                _locationError = 'Allow location access for the phone marker.',
          );
        }
        return;
      }
      unawaited(_refreshRealGps());
      if (_positions != null) return;
      try {
        final cached = await Geolocator.getLastKnownPosition();
        if (cached != null) _observe(cached, cached: true);
      } catch (_) {
        // A cached fix is optional; continue with live observations.
      }
      // Geolocator's Android stream silently does nothing if subscribed before
      // its location service has finished binding during cold startup.
      await Future<void>.delayed(const Duration(seconds: 1));
      if (!mounted) return;
      _positions =
          Geolocator.getPositionStream(
            locationSettings: AndroidSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 0,
              intervalDuration: const Duration(seconds: 2),
            ),
          ).listen(
            (position) {
              _locationWatchdog?.cancel();
              _observe(position);
            },
            onError: (_) {
              _locationWatchdog?.cancel();
              _positions = null;
              if (mounted) {
                setState(
                  () => _locationError =
                      'Phone location unavailable. Retry location.',
                );
              }
            },
            cancelOnError: true,
          );
      _locationWatchdog = Timer(const Duration(seconds: 10), () {
        final subscription = _positions;
        if (!mounted || subscription == null) return;
        if (_silentLocationRetries == 0) {
          _silentLocationRetries++;
          _positions = null;
          unawaited(subscription.cancel().then((_) => _startLocation()));
        } else {
          setState(
            () =>
                _locationError = 'Phone location unavailable. Retry location.',
          );
        }
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _locationError = 'Phone location unavailable. Retry location.',
        );
      }
    } finally {
      _checkingLocation = false;
    }
  }

  Future<void> _retryLocation() async {
    _locationWatchdog?.cancel();
    _silentLocationRetries = 0;
    _realGpsGeneration++;
    _realGpsAttempted = false;
    if (_locationNeedsSettings) {
      await Geolocator.openAppSettings();
      return;
    }
    if (_locationServiceDisabled) {
      await Geolocator.openLocationSettings();
      return;
    }
    unawaited(_refreshRealGps());
    await _positions?.cancel();
    _positions = null;
    await _startLocation();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _locationWatchdog?.cancel();
    _sessionChanges?.close();
    unawaited(_connectivity?.cancel());
    unawaited(_positions?.cancel());
    _phone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vehicle = ref.watch(vehicleLocationProvider);
    final session = ref.watch(summonSessionProvider);
    final busy = session.isActive || session.isStarting || session.isStopping;
    final status =
        session.statusMessage ??
        vehicle.notice ??
        (vehicle.isAsleep
            ? 'Vehicle asleep or offline. Refresh when it is available.'
            : null);
    final effective = _phone.value.effective;
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: VehicleMap(
              phoneLatitude: effective?.latitude,
              phoneLongitude: effective?.longitude,
              phoneIsMocked: effective?.isMocked ?? false,
              vehicleLatitude: vehicle.latitude,
              vehicleLongitude: vehicle.longitude,
              fitRequest: _fitRequest,
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _MapPanel(
                    child: Row(
                      children: [
                        const Icon(
                          Icons.directions_car_rounded,
                          color: AppColors.teslaRed,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                vehicle.vehicleName ?? 'Summon Anywhere',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 3),
                              Text(
                                vehicle.isLoading
                                    ? 'Getting vehicle location…'
                                    : vehicle.updatedAt != null
                                    ? 'Vehicle location · ${locationAge(vehicle.sourceTimestamp ?? vehicle.updatedAt)}'
                                    : 'Vehicle location not available yet',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: AppColors.darkSubtext),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Refresh vehicle',
                          onPressed: busy || vehicle.isLoading
                              ? null
                              : () => ref
                                    .read(vehicleLocationProvider.notifier)
                                    .refresh(),
                          icon: const Icon(Icons.refresh_rounded),
                        ),
                        IconButton(
                          tooltip: 'Settings',
                          onPressed: () => context.push('/settings'),
                          icon: const Icon(Icons.settings_outlined),
                        ),
                      ],
                    ),
                  ),
                  if (_offline) ...[
                    const SizedBox(height: 8),
                    const _MapPanel(
                      child: Text(
                        'No internet connection. Reconnect to update the vehicle.',
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (_phone.value.effectiveRecoveryPending &&
                      !_allowsMock(session)) ...[
                    const _MapPanel(
                      child: Text(
                        'Last phone fix is mocked or stale. Waiting for fresh effective location.',
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (session.error != null || vehicle.error != null) ...[
                    SessionErrorBanner(
                      message: session.error ?? vehicle.error!,
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (_locationError != null) ...[
                    _MapPanel(
                      child: Row(
                        children: [
                          Expanded(child: Text(_locationError!)),
                          TextButton(
                            onPressed: _retryLocation,
                            child: Text(
                              _locationNeedsSettings || _locationServiceDisabled
                                  ? 'Settings'
                                  : 'Retry',
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  _MapPanel(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (status != null) ...[
                          Text(status, textAlign: TextAlign.center),
                          const SizedBox(height: 10),
                        ],
                        const SummonButton(),
                        const SizedBox(height: 8),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 8,
                          children: [
                            TextButton.icon(
                              onPressed: () => showModalBottomSheet<void>(
                                context: context,
                                isScrollControlled: true,
                                builder: (_) =>
                                    LocationStatusSheet(phoneFixes: _phone),
                              ),
                              icon: const Icon(
                                Icons.gps_fixed_rounded,
                                size: 18,
                              ),
                              label: const Text('Location status'),
                            ),
                            TextButton.icon(
                              onPressed: () => setState(() => _fitRequest++),
                              icon: const Icon(
                                Icons.center_focus_strong_rounded,
                                size: 18,
                              ),
                              label: const Text('Show both'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MapPanel extends StatelessWidget {
  const _MapPanel({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: AppColors.darkBg.withValues(alpha: 0.9),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: AppColors.darkBorder),
    ),
    child: child,
  );
}
