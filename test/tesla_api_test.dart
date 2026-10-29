import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:summon_anywhere_tesla/core/services/auth_service.dart';
import 'package:summon_anywhere_tesla/core/services/tesla_api_service.dart';
import 'package:summon_anywhere_tesla/core/services/vehicle_polling.dart';
import 'package:summon_anywhere_tesla/core/storage/secure_storage.dart';

class _Preferences extends Fake implements SharedPreferencesAsync {
  _Preferences(this.values);
  final Map<String, int> values;

  @override
  Future<int?> getInt(String key) async => values[key];

  @override
  Future<void> setInt(String key, int value) async => values[key] = value;
}

class _Auth extends AuthService {
  _Auth() : super(const SecureStorage(FlutterSecureStorage()));
  int refreshes = 0;
  String? refreshedToken = 'REFRESHED_TOKEN_FIXTURE';

  @override
  Future<String?> getValidAccessToken() async => 'TOKEN_FIXTURE';

  @override
  Future<String?> refreshAccessToken() async {
    refreshes++;
    return refreshedToken;
  }
}

class _Reply {
  const _Reply(this.status, this.body, [this.headers = const {}]);
  final int status;
  final Map<String, dynamic> body;
  final Map<String, List<String>> headers;
}

class _Http implements HttpClientAdapter {
  final replies = <_Reply>[];
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final reply = replies.removeAt(0);
    return ResponseBody.fromString(
      jsonEncode(reply.body),
      reply.status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        ...reply.headers,
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _location({DateTime? timestamp}) => {
  'response': {
    'display_name': 'Fixture Tesla',
    'state': 'online',
    'drive_state': {
      'latitude': 52.1,
      'longitude': 4.3,
      'timestamp': (timestamp ?? DateTime.now()).millisecondsSinceEpoch,
    },
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Map<String, int> values;
  late _Http http;
  late _Auth auth;
  final clients = <Dio>[];

  TeslaApiService client({_Http? transport}) {
    final dio = Dio(BaseOptions(baseUrl: 'https://fleet.invalid'))
      ..httpClientAdapter = transport ?? http;
    clients.add(dio);
    return TeslaApiService(
      auth,
      dio: dio,
      polling: VehiclePolling(preferences: _Preferences(values)),
    );
  }

  setUp(() {
    values = {};
    http = _Http();
    auth = _Auth();
  });
  tearDown(() {
    for (final dio in clients) {
      dio.close();
    }
    clients.clear();
  });

  test('Fleet GET requests location data and parses fresh telemetry', () async {
    http.replies.add(_Reply(200, _location()));
    final result = await client().getVehicleLocation('VEHICLE_FIXTURE');
    expect(result.isLocationUnavailable, isFalse);
    expect(result.latitude, 52.1);
    expect(result.longitude, 4.3);
    expect(result.vehicleName, 'Fixture Tesla');
    expect(result.sourceTimestamp, isNotNull);
    final request = http.requests.single;
    expect(request.method, 'GET');
    expect(request.path, '/api/1/vehicles/VEHICLE_FIXTURE/vehicle_data');
    expect(request.queryParameters['endpoints'], contains('location_data'));
    expect(request.headers['Authorization'], 'Bearer TOKEN_FIXTURE');
  });

  test('manual refresh and a new worker client share a 429 cooldown', () async {
    http.replies.add(
      const _Reply(
        429,
        {'error': 'rate_limited'},
        {
          'retry-after': ['90'],
        },
      ),
    );
    final foreground = client();
    late DateTime retryAt;
    await expectLater(
      foreground.getVehicleLocation('VEHICLE_FIXTURE'),
      throwsA(
        isA<TeslaApiException>()
            .having((error) => error.statusCode, 'statusCode', 429)
            .having(
              (error) {
                retryAt = error.retryAt!;
                return error.retryAt!.difference(DateTime.now()).inSeconds;
              },
              'server cooldown seconds',
              greaterThanOrEqualTo(88),
            ),
      ),
    );
    final worker = client();
    for (final source in [foreground, worker, client()]) {
      await expectLater(
        source.getVehicleLocation('VEHICLE_FIXTURE'),
        throwsA(
          isA<TeslaApiException>()
              .having((error) => error.coolingDown, 'coolingDown', true)
              .having(
                (error) => error.retryAt?.millisecondsSinceEpoch,
                'retryAt',
                retryAt.millisecondsSinceEpoch,
              ),
        ),
      );
    }
    expect(http.requests, hasLength(1));
  });

  test(
    'vehicle discovery cannot bypass or reset a location cooldown',
    () async {
      http.replies.add(const _Reply(503, {'error': 'unavailable'}));
      final api = client();
      await expectLater(
        api.getVehicleLocation('VEHICLE_FIXTURE'),
        throwsA(isA<TeslaApiException>()),
      );
      await expectLater(
        api.getVehicles(),
        throwsA(
          isA<TeslaApiException>().having(
            (error) => error.coolingDown,
            'coolingDown',
            true,
          ),
        ),
      );
      await expectLater(
        client().getVehicleLocation('VEHICLE_FIXTURE'),
        throwsA(
          isA<TeslaApiException>().having(
            (error) => error.coolingDown,
            'coolingDown',
            true,
          ),
        ),
      );
      expect(http.requests, hasLength(1));
    },
  );

  test('stale data is unavailable and delays the next request', () async {
    http.replies.add(
      _Reply(
        200,
        _location(
          timestamp: DateTime.now().subtract(const Duration(minutes: 3)),
        ),
      ),
    );
    final result = await client().getVehicleLocation('VEHICLE_FIXTURE');
    expect(result.isLocationUnavailable, isTrue);
    expect(result.isStale, isTrue);
    expect(
      result.retryAt!.difference(DateTime.now()).inSeconds,
      greaterThanOrEqualTo(28),
    );
    expect(http.requests, hasLength(1));
  });

  test(
    'HTTP 408 is a sleeping vehicle and does not issue wake commands',
    () async {
      http.replies.add(const _Reply(408, {'error': 'vehicle unavailable'}));
      final result = await client().getVehicleLocation('VEHICLE_FIXTURE');
      expect(result.isAsleep, isTrue);
      expect(result.retryAt, isNotNull);
      expect(http.requests.single.method, 'GET');
    },
  );

  test(
    'HTTP 401 refreshes once then retries the same read-only request',
    () async {
      http.replies.addAll([
        const _Reply(401, {'error': 'unauthorized'}),
        _Reply(200, _location()),
      ]);
      final result = await client().getVehicleLocation('VEHICLE_FIXTURE');
      expect(result.isLocationUnavailable, isFalse);
      expect(auth.refreshes, 1);
      expect(http.requests, hasLength(2));
      expect(
        http.requests.last.headers['Authorization'],
        'Bearer REFRESHED_TOKEN_FIXTURE',
      );
      expect(http.requests.every((request) => request.method == 'GET'), isTrue);
    },
  );

  test(
    'a second 401 stops rather than looping authentication requests',
    () async {
      http.replies.addAll([
        const _Reply(401, {'error': 'unauthorized'}),
        const _Reply(401, {'error': 'unauthorized'}),
      ]);
      await expectLater(
        client().getVehicleLocation('VEHICLE_FIXTURE'),
        throwsA(
          isA<TeslaApiException>()
              .having((error) => error.statusCode, 'statusCode', 401)
              .having((error) => error.retryable, 'retryable', false),
        ),
      );
      expect(auth.refreshes, 1);
      expect(http.requests, hasLength(2));
    },
  );

  test(
    'invalid refresh does not retry vehicle data with an absent token',
    () async {
      auth.refreshedToken = null;
      http.replies.add(const _Reply(401, {'error': 'unauthorized'}));
      await expectLater(
        client().getVehicleLocation('VEHICLE_FIXTURE'),
        throwsA(
          isA<TeslaApiException>().having(
            (error) => error.statusCode,
            'statusCode',
            401,
          ),
        ),
      );
      expect(http.requests, hasLength(1));
    },
  );
}
