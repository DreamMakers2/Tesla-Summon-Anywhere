import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../logging/app_logger.dart';
import 'auth_service.dart';
import 'location_safety.dart';
import 'vehicle_polling.dart';

part 'tesla_api_service.g.dart';

@Riverpod(keepAlive: true)
TeslaApiService teslaApiService(Ref ref) =>
    TeslaApiService(ref.watch(authServiceProvider));

/// The same Fleet client is used by the map and the foreground worker.
class TeslaApiService {
  TeslaApiService(this._authService, {Dio? dio, VehiclePolling? polling})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: teslaFleetAudience,
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 15),
            ),
          ),
      _polling = polling ?? VehiclePolling();

  final AuthService _authService;
  final Dio _dio;
  final VehiclePolling _polling;
  final _reportedVehicleStatuses = <int>{};
  final _reportedListStatuses = <int>{};

  void _reportVehicleResponse(String path, int? status) {
    if (status == null) return;
    if (path == '/api/1/vehicles') {
      if (_reportedListStatuses.add(status)) {
        AppLogger.info('TESLA_API', 'Vehicle list response: HTTP $status.');
      }
    } else if (path.endsWith('/vehicle_data') &&
        _reportedVehicleStatuses.add(status)) {
      AppLogger.info('TESLA_API', 'Vehicle data response: HTTP $status.');
    }
  }

  Future<Response<Map<String, dynamic>>> _get(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    String? token;
    try {
      token = await _authService.getValidAccessToken();
    } on AuthException catch (error) {
      throw TeslaApiException(
        error.message,
        statusCode: error.statusCode,
        retryable: error.retryable,
        serverDelay: error.retryAfter,
      );
    }
    if (token == null) {
      throw const TeslaApiException(
        'Tesla sign-in is required.',
        statusCode: 401,
      );
    }
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        path,
        queryParameters: queryParameters,
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      _reportVehicleResponse(path, response.statusCode);
      return response;
    } on DioException catch (error) {
      _reportVehicleResponse(path, error.response?.statusCode);
      if (error.response?.statusCode != 401) throw sanitizeApiError(error);
      try {
        token = await _authService.refreshAccessToken();
      } on AuthException catch (authError) {
        throw TeslaApiException(
          authError.message,
          statusCode: authError.statusCode,
          retryable: authError.retryable,
          serverDelay: authError.retryAfter,
        );
      }
      if (token == null) {
        throw const TeslaApiException(
          'Tesla sign-in expired. Sign in again.',
          statusCode: 401,
        );
      }
      try {
        final response = await _dio.get<Map<String, dynamic>>(
          path,
          queryParameters: queryParameters,
          options: Options(headers: {'Authorization': 'Bearer $token'}),
        );
        _reportVehicleResponse(path, response.statusCode);
        return response;
      } on DioException catch (retryError) {
        _reportVehicleResponse(path, retryError.response?.statusCode);
        throw sanitizeApiError(retryError);
      }
    }
  }

  Future<List<TeslaVehicle>> getVehicles() async {
    await _checkCooldown();
    try {
      final response = await _get('/api/1/vehicles');
      final list = response.data?['response'] as List<dynamic>? ?? [];
      return list
          .whereType<Map<String, dynamic>>()
          .map(TeslaVehicle.fromJson)
          .toList();
    } on TeslaApiException catch (error) {
      if (!error.retryable) rethrow;
      final retry = await _polling.failed(
        DateTime.now(),
        rateLimited: error.isRateLimited,
        unavailable: error.statusCode == 408,
        serverDelay: error.serverDelay,
      );
      throw error.withRetryAt(retry);
    }
  }

  Future<void> _checkCooldown() async {
    final now = DateTime.now();
    final next = await _polling.nextRequest();
    if (next != null && next.isAfter(now)) {
      throw TeslaApiException(
        'Waiting before the next vehicle update.',
        retryAt: next,
        retryable: true,
        coolingDown: true,
      );
    }
  }

  Future<VehicleLocationResult> getVehicleLocation(String vehicleId) async {
    await _checkCooldown();
    final requestStarted = DateTime.now();
    try {
      final response = await _get(
        '/api/1/vehicles/$vehicleId/vehicle_data',
        queryParameters: {'endpoints': 'location_data;drive_state'},
      );
      final data = response.data?['response'];
      if (data is! Map<String, dynamic>) {
        throw const TeslaApiException(
          'Tesla returned no vehicle data.',
          retryable: true,
        );
      }
      if (data['state'] == 'asleep' || data['state'] == 'offline') {
        final retry = await _polling.failed(DateTime.now(), unavailable: true);
        return VehicleLocationResult.asleep(retryAt: retry);
      }
      final result = parseLocation(data, DateTime.now());
      if (result.isLocationUnavailable) {
        final retry = await _polling.failed(DateTime.now(), unavailable: true);
        return VehicleLocationResult.locationUnavailable(
          retryAt: retry,
          isStale: result.isStale,
        );
      }
      await _polling.succeeded(requestStarted);
      return result;
    } on TeslaApiException catch (error) {
      if (error.statusCode == 408) {
        final retry = await _polling.failed(DateTime.now(), unavailable: true);
        return VehicleLocationResult.asleep(retryAt: retry);
      }
      if (!error.retryable) rethrow;
      final retry = await _polling.failed(
        DateTime.now(),
        rateLimited: error.isRateLimited,
        serverDelay: error.serverDelay,
      );
      throw error.withRetryAt(retry);
    }
  }

  @visibleForTesting
  static VehicleLocationResult parseLocation(
    Map<String, dynamic> data,
    DateTime now,
  ) {
    var stale = false;
    for (final source in [data['drive_state'], data['location_data']]) {
      if (source is! Map<String, dynamic>) continue;
      final latitude = source['latitude'];
      final longitude = source['longitude'];
      if (latitude is! num ||
          longitude is! num ||
          !LocationSafety.validCoordinates(
            latitude.toDouble(),
            longitude.toDouble(),
          )) {
        continue;
      }
      final timestamp = source['timestamp'];
      if (!LocationSafety.isFreshTimestamp(timestamp, now)) {
        stale = true;
        continue;
      }
      return VehicleLocationResult(
        latitude: latitude.toDouble(),
        longitude: longitude.toDouble(),
        isAsleep: false,
        vehicleName: data['display_name'] as String?,
        sourceTimestamp: DateTime.fromMillisecondsSinceEpoch(
          (timestamp as num).toInt(),
        ),
      );
    }
    return VehicleLocationResult.locationUnavailable(isStale: stale);
  }

  @visibleForTesting
  static TeslaApiException sanitizeApiError(DioException error) {
    final status = error.response?.statusCode;
    final message = switch (status) {
      401 => 'Tesla authentication failed. Sign in again.',
      403 => 'Tesla denied access. Check the granted scopes.',
      408 => 'Vehicle is asleep or offline.',
      412 => 'Fleet API is not registered for this region.',
      421 => 'Tesla account region differs from the configured API region.',
      429 => 'Tesla rate limit reached. Waiting before retrying.',
      int code when code >= 500 => 'Tesla is unavailable. Retrying shortly.',
      null => 'Tesla request failed. Check your connection.',
      _ => 'Tesla request failed (HTTP $status).',
    };
    return TeslaApiException(
      message,
      statusCode: status,
      retryable:
          status == null || status == 408 || status == 429 || status >= 500,
      serverDelay: VehiclePolling.serverDelay(
        error.response?.headers.map ?? const {},
        DateTime.now(),
      ),
    );
  }
}

class TeslaVehicle {
  const TeslaVehicle({
    required this.id,
    required this.vin,
    required this.displayName,
    required this.state,
  });

  factory TeslaVehicle.fromJson(Map<String, dynamic> json) => TeslaVehicle(
    id: json['id']?.toString() ?? json['id_s'] as String? ?? '',
    vin: json['vin'] as String? ?? '',
    displayName: json['display_name'] as String? ?? 'Tesla',
    state: json['state'] as String? ?? 'unknown',
  );

  final String id;
  final String vin;
  final String displayName;
  final String state;
  bool get isAsleep => state == 'asleep';
}

class VehicleLocationResult {
  const VehicleLocationResult({
    required this.latitude,
    required this.longitude,
    required this.isAsleep,
    this.isLocationUnavailable = false,
    this.isStale = false,
    this.vehicleName,
    this.sourceTimestamp,
    this.retryAt,
  });

  factory VehicleLocationResult.asleep({DateTime? retryAt}) =>
      VehicleLocationResult(
        latitude: 0,
        longitude: 0,
        isAsleep: true,
        retryAt: retryAt,
      );

  factory VehicleLocationResult.locationUnavailable({
    DateTime? retryAt,
    bool isStale = false,
  }) => VehicleLocationResult(
    latitude: 0,
    longitude: 0,
    isAsleep: false,
    isLocationUnavailable: true,
    isStale: isStale,
    retryAt: retryAt,
  );

  final double latitude;
  final double longitude;
  final bool isAsleep;
  final bool isLocationUnavailable;
  final bool isStale;
  final String? vehicleName;
  final DateTime? sourceTimestamp;
  final DateTime? retryAt;
}

class TeslaApiException implements Exception {
  const TeslaApiException(
    this.message, {
    this.statusCode,
    this.retryable = false,
    this.serverDelay,
    this.retryAt,
    this.coolingDown = false,
  });

  final String message;
  final int? statusCode;
  final bool retryable;
  final Duration? serverDelay;
  final DateTime? retryAt;
  final bool coolingDown;
  bool get isRateLimited => statusCode == 429;

  TeslaApiException withRetryAt(DateTime value) => TeslaApiException(
    message,
    statusCode: statusCode,
    retryable: retryable,
    serverDelay: serverDelay,
    retryAt: value,
    coolingDown: coolingDown,
  );

  @override
  String toString() => message;
}
