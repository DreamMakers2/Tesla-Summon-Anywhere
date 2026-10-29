import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/services/tesla_api_service.dart';
import '../../../core/storage/prefs_storage.dart';

part 'vehicle_location_provider.g.dart';

class VehicleLocationState {
  const VehicleLocationState({
    this.latitude,
    this.longitude,
    this.vehicleName,
    this.updatedAt,
    this.sourceTimestamp,
    this.notice,
    this.isLoading = false,
    this.isAsleep = false,
    this.error,
    this.isRateLimited = false,
  });

  final double? latitude;
  final double? longitude;
  final String? vehicleName;
  final DateTime? updatedAt;
  final DateTime? sourceTimestamp;
  final String? notice;
  final bool isLoading;
  final bool isAsleep;
  final String? error;
  final bool isRateLimited;

  VehicleLocationState copyWith({
    double? latitude,
    double? longitude,
    String? vehicleName,
    DateTime? updatedAt,
    DateTime? sourceTimestamp,
    String? notice,
    bool? isLoading,
    bool? isAsleep,
    String? error,
    bool? isRateLimited,
    bool clearError = false,
    bool clearNotice = false,
  }) => VehicleLocationState(
    latitude: latitude ?? this.latitude,
    longitude: longitude ?? this.longitude,
    vehicleName: vehicleName ?? this.vehicleName,
    updatedAt: updatedAt ?? this.updatedAt,
    sourceTimestamp: sourceTimestamp ?? this.sourceTimestamp,
    notice: clearNotice ? null : notice ?? this.notice,
    isLoading: isLoading ?? this.isLoading,
    isAsleep: isAsleep ?? this.isAsleep,
    error: clearError ? null : error ?? this.error,
    isRateLimited: isRateLimited ?? this.isRateLimited,
  );
}

@Riverpod(keepAlive: true)
class VehicleLocation extends _$VehicleLocation {
  String? _vehicleId;
  Future<void>? _inFlight;
  bool _loadedVehicleList = false;

  @override
  VehicleLocationState build() {
    final preferences = ref.read(prefsStorageProvider);
    _vehicleId = preferences.selectedVehicleId;
    scheduleMicrotask(_startInitialRefresh);
    return VehicleLocationState(
      isLoading: true,
      vehicleName: preferences.selectedVehicleName,
    );
  }

  void _startInitialRefresh() {
    if (_inFlight != null) return;
    final future = _refreshOnOpen();
    _track(future);
  }

  Future<void> _refreshOnOpen() async {
    // A restored foreground worker may still own polling. Session startup
    // stops it first and asks for a refresh after cleanup.
    try {
      if (await FlutterForegroundTask.isRunningService) {
        state = state.copyWith(isLoading: false);
        return;
      }
    } catch (_) {
      // Continue with the normal map request if service status is unavailable.
    }
    await _refresh();
  }

  void _track(Future<void> future) {
    _inFlight = future;
    future.whenComplete(() {
      if (identical(_inFlight, future)) _inFlight = null;
    });
  }

  Future<void> waitForIdle() => _inFlight ?? Future<void>.value();

  Future<void> refresh() {
    final pending = _inFlight;
    if (pending != null) return pending;
    final future = _refresh();
    _track(future);
    return future;
  }

  Future<void> _refresh() async {
    state = state.copyWith(
      isLoading: true,
      clearError: true,
      clearNotice: true,
    );
    try {
      final api = ref.read(teslaApiServiceProvider);
      var vehicleId = _vehicleId;
      if (!_loadedVehicleList &&
          (vehicleId == null ||
              vehicleId.isEmpty ||
              state.vehicleName == null)) {
        final vehicles = await api.getVehicles();
        _loadedVehicleList = true;
        if (vehicles.isEmpty) {
          state = state.copyWith(
            isLoading: false,
            error: 'No Tesla vehicle found.',
          );
          return;
        }
        if (vehicleId == null || vehicleId.isEmpty) {
          vehicleId = vehicles.first.id;
        }
        if (vehicleId.isEmpty) {
          state = state.copyWith(
            isLoading: false,
            error: 'Tesla returned no vehicle ID.',
          );
          return;
        }
        _vehicleId = vehicleId;
        final selected = vehicles.where((vehicle) => vehicle.id == vehicleId);
        if (selected.isNotEmpty) {
          state = state.copyWith(vehicleName: selected.first.displayName);
          await ref
              .read(prefsStorageProvider)
              .setSelectedVehicleName(selected.first.displayName);
        }
        await ref.read(prefsStorageProvider).setSelectedVehicleId(vehicleId);
      } else if (vehicleId != null && vehicleId.isNotEmpty) {
        _loadedVehicleList = true;
      }

      if (vehicleId == null || vehicleId.isEmpty) {
        state = state.copyWith(
          isLoading: false,
          error: 'No Tesla vehicle selected.',
        );
        return;
      }
      final location = await api.getVehicleLocation(vehicleId);
      if (location.isAsleep) {
        state = state.copyWith(
          isLoading: false,
          isAsleep: true,
          isRateLimited: false,
          clearError: true,
        );
      } else if (location.isLocationUnavailable) {
        state = state.copyWith(
          isLoading: false,
          isAsleep: false,
          error: location.isStale
              ? 'Vehicle location is stale. Waiting for a fresh update.'
              : 'Vehicle location unavailable. Check Tesla location access.',
        );
      } else {
        acceptLocation(location);
      }
    } on TeslaApiException catch (error) {
      if (error.coolingDown) {
        state = state.copyWith(
          isLoading: false,
          notice: error.message,
          clearError: true,
        );
        return;
      }
      state = state.copyWith(
        isLoading: false,
        isRateLimited: error.isRateLimited,
        error: error.message,
      );
    } catch (_) {
      state = state.copyWith(
        isLoading: false,
        error: 'Could not load the vehicle location. Check your connection.',
      );
    }
  }

  /// Receives the foreground worker's successful response without another GET.
  void acceptLocation(VehicleLocationResult result) {
    state = state.copyWith(
      latitude: result.latitude,
      longitude: result.longitude,
      vehicleName: result.vehicleName,
      sourceTimestamp: result.sourceTimestamp,
      updatedAt: DateTime.now(),
      isLoading: false,
      isAsleep: false,
      isRateLimited: false,
      clearError: true,
      clearNotice: true,
    );
  }

  void reportUnavailable({bool asleep = false, String? error}) {
    state = state.copyWith(
      isLoading: false,
      isAsleep: asleep,
      error: error,
      clearError: error == null,
      clearNotice: true,
    );
  }
}
