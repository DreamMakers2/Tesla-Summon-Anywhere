import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:summon_anywhere_tesla/core/services/auth_service.dart';
import 'package:summon_anywhere_tesla/core/storage/secure_storage.dart';

class _Storage extends SecureStorage {
  _Storage() : super(const FlutterSecureStorage());

  String? access;
  String? refresh;
  DateTime? expiry;
  bool failRead = false;

  @override
  Future<String?> getAccessToken() async {
    if (failRead) throw StateError('PRIVATE_STORAGE_FIXTURE');
    return access;
  }

  @override
  Future<String?> getRefreshToken() async => refresh;

  @override
  Future<DateTime?> getTokenExpiry() async => expiry;

  @override
  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
    required DateTime expiry,
  }) async {
    access = accessToken;
    refresh = refreshToken;
    this.expiry = expiry;
  }
}

class _TokenAdapter implements HttpClientAdapter {
  Map<String, dynamic>? body;
  int status = 200;
  int requests = 0;
  String retryAfter = '45';
  Map<String, dynamic> response = {
    'access_token': 'NEW_ACCESS_FIXTURE',
    'refresh_token': 'NEW_REFRESH_FIXTURE',
    'expires_in': 3600,
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    body = Map<String, dynamic>.from(options.data as Map);
    return ResponseBody.fromString(
      jsonEncode(status == 200 ? response : {'error': 'PRIVATE_ERROR_FIXTURE'}),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        if (status == 429) 'retry-after': [retryAfter],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const appAuth = MethodChannel('crossingthestreams.io/flutter_appauth');
  late _Storage storage;
  late _TokenAdapter adapter;
  late Dio dio;
  late AuthService auth;
  late int authorizations;

  setUp(() {
    storage = _Storage();
    adapter = _TokenAdapter();
    dio = Dio(BaseOptions(contentType: Headers.formUrlEncodedContentType))
      ..httpClientAdapter = adapter;
    auth = AuthService(
      storage,
      tokenDio: dio,
      clientId: 'CLIENT_ID_FIXTURE',
      clientSecret: 'CLIENT_SECRET_FIXTURE',
    );
    authorizations = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(appAuth, (call) async {
          authorizations++;
          return {
            'authorizationCode': 'CODE_FIXTURE',
            'codeVerifier': 'VERIFIER_FIXTURE',
          };
        });
  });

  tearDown(() {
    dio.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(appAuth, null);
  });

  void savedTokens() {
    storage.access = 'SAVED_ACCESS_FIXTURE';
    storage.refresh = 'SAVED_REFRESH_FIXTURE';
    storage.expiry = DateTime.now().subtract(const Duration(hours: 1));
  }

  test('initial exchange uses configured credentials and PKCE', () async {
    await auth.signIn();
    expect(authorizations, 1);
    expect(adapter.body?['grant_type'], 'authorization_code');
    expect(adapter.body?['client_id'], 'CLIENT_ID_FIXTURE');
    expect(adapter.body?['client_secret'], 'CLIENT_SECRET_FIXTURE');
    expect(adapter.body?['code_verifier'], 'VERIFIER_FIXTURE');
    expect(storage.access, 'NEW_ACCESS_FIXTURE');
    expect(storage.refresh, 'NEW_REFRESH_FIXTURE');
    expect(teslaScopes, isNot(contains('vehicle_cmds')));
  });

  test('missing build credentials fail before opening OAuth', () async {
    final missing = AuthService(
      storage,
      clientSecret: 'YOUR_TESLA_CLIENT_SECRET',
    );
    await expectLater(
      missing.signIn(),
      throwsA(
        isA<AuthException>().having(
          (error) => error.message,
          'message',
          contains('--dart-define-from-file=secrets.json'),
        ),
      ),
    );
    expect(authorizations, 0);
    expect(adapter.requests, 0);
  });

  test('valid saved tokens are reused without a token request', () async {
    savedTokens();
    storage.expiry = DateTime.now().add(const Duration(hours: 1));
    expect(await auth.getValidAccessToken(), 'SAVED_ACCESS_FIXTURE');
    expect(adapter.requests, 0);
  });

  test(
    'refresh omits client secret and retains an unrotated refresh token',
    () async {
      savedTokens();
      adapter.response.remove('refresh_token');
      expect(await auth.getValidAccessToken(), 'NEW_ACCESS_FIXTURE');
      expect(authorizations, 0);
      expect(adapter.body?['grant_type'], 'refresh_token');
      expect(adapter.body?.containsKey('client_secret'), false);
      expect(storage.refresh, 'SAVED_REFRESH_FIXTURE');
    },
  );

  test('forced refresh does not reuse an unexpired rejected token', () async {
    savedTokens();
    storage.expiry = DateTime.now().add(const Duration(hours: 1));
    expect(await auth.refreshAccessToken(), 'NEW_ACCESS_FIXTURE');
    expect(adapter.requests, 1);
  });

  test('incomplete refresh response preserves saved tokens', () async {
    savedTokens();
    adapter.response['access_token'] = '';
    await expectLater(
      auth.getValidAccessToken(),
      throwsA(
        isA<AuthException>().having(
          (error) => error.retryable,
          'retryable',
          true,
        ),
      ),
    );
    expect(storage.access, 'SAVED_ACCESS_FIXTURE');
    expect(storage.refresh, 'SAVED_REFRESH_FIXTURE');
  });

  for (final status in [429, 503]) {
    test(
      'HTTP $status refresh failure preserves saved tokens for retry',
      () async {
        savedTokens();
        adapter.status = status;
        await expectLater(
          auth.getValidAccessToken(),
          throwsA(
            isA<AuthException>()
                .having((error) => error.retryable, 'retryable', true)
                .having((error) => error.statusCode, 'statusCode', status)
                .having(
                  (error) => error.retryAfter,
                  'retryAfter',
                  status == 429 ? const Duration(seconds: 45) : null,
                ),
          ),
        );
        expect(storage.access, 'SAVED_ACCESS_FIXTURE');
        expect(storage.refresh, 'SAVED_REFRESH_FIXTURE');
      },
    );
  }

  test(
    'HTTP-date retry-after is respected for a throttled token refresh',
    () async {
      savedTokens();
      adapter.status = 429;
      adapter.retryAfter = HttpDate.format(
        DateTime.now().toUtc().add(const Duration(minutes: 2)),
      );
      await expectLater(
        auth.getValidAccessToken(),
        throwsA(
          isA<AuthException>().having(
            (error) => error.retryAfter?.inSeconds,
            'retryAfter seconds',
            greaterThanOrEqualTo(115),
          ),
        ),
      );
      expect(storage.access, 'SAVED_ACCESS_FIXTURE');
      expect(storage.refresh, 'SAVED_REFRESH_FIXTURE');
    },
  );

  test(
    'rejected refresh requires sign-in without deleting existing tokens',
    () async {
      savedTokens();
      adapter.status = 400;
      expect(await auth.getValidAccessToken(), isNull);
      expect(storage.access, 'SAVED_ACCESS_FIXTURE');
      expect(storage.refresh, 'SAVED_REFRESH_FIXTURE');
    },
  );

  test(
    'token errors expose neither credentials nor private server details',
    () async {
      adapter.status = 401;
      final logs = <String>[];
      await runZoned(
        () => expectLater(
          auth.signIn(),
          throwsA(
            isA<AuthException>().having(
              (error) => error.toString(),
              'safe error',
              allOf(isNot(contains('FIXTURE')), contains('sign in again')),
            ),
          ),
        ),
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => logs.add(line),
        ),
      );
      expect(logs.join('\n'), isNot(contains('FIXTURE')));
    },
  );

  test('storage errors are sanitized and retryable', () async {
    storage.failRead = true;
    await expectLater(
      auth.getValidAccessToken(),
      throwsA(
        isA<AuthException>()
            .having((error) => error.retryable, 'retryable', true)
            .having(
              (error) => error.message,
              'message',
              isNot(contains('PRIVATE_')),
            ),
      ),
    );
  });
}
