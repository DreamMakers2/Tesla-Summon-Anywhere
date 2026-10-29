import 'package:dio/dio.dart';
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../logging/app_logger.dart';
import '../storage/secure_storage.dart';
import 'vehicle_polling.dart';

part 'auth_service.g.dart';

/// Supplied locally with --dart-define-from-file=secrets.json.
const teslaClientId = String.fromEnvironment(
  'TESLA_CLIENT_ID',
  defaultValue: 'YOUR_TESLA_CLIENT_ID',
);
const teslaClientSecret = String.fromEnvironment(
  'TESLA_CLIENT_SECRET',
  defaultValue: 'YOUR_TESLA_CLIENT_SECRET',
);
const teslaRedirectUri = 'com.summonanywhere.auth://app/callback';
const teslaFleetAudience = String.fromEnvironment(
  'TESLA_FLEET_BASE_URL',
  defaultValue: 'https://fleet-api.prd.eu.vn.cloud.tesla.com',
);
const teslaScopes = [
  'openid',
  'offline_access',
  'user_data',
  'vehicle_device_data',
  'vehicle_location',
];

@Riverpod(keepAlive: true)
AuthService authService(Ref ref) {
  return AuthService(ref.watch(secureStorageProvider));
}

class AuthService {
  AuthService(
    this._storage, {
    Dio? tokenDio,
    String clientId = teslaClientId,
    String clientSecret = teslaClientSecret,
  }) : _tokenDio =
           tokenDio ??
           Dio(
             BaseOptions(
               contentType: Headers.formUrlEncodedContentType,
               connectTimeout: const Duration(seconds: 15),
               receiveTimeout: const Duration(seconds: 15),
             ),
           ),
       _clientId = clientId,
       _clientSecret = clientSecret;

  final SecureStorage _storage;
  final Dio _tokenDio;
  final String _clientId;
  final String _clientSecret;
  final _appAuth = const FlutterAppAuth();

  static const _tokenEndpoint =
      'https://fleet-auth.prd.vn.cloud.tesla.com/oauth2/v3/token';
  static const _serviceConfig = AuthorizationServiceConfiguration(
    authorizationEndpoint: 'https://auth.tesla.com/oauth2/v3/authorize',
    tokenEndpoint: _tokenEndpoint,
  );

  static bool isPlaceholder(String value) => AppLogger.isPlaceholder(value);
  static String maskClientId(String clientId) =>
      AppLogger.maskClientId(clientId);

  static void logOAuthConfigSummary() {
    if (isPlaceholder(teslaClientId) || isPlaceholder(teslaClientSecret)) {
      AppLogger.warn(
        'AUTH',
        'Build with --dart-define-from-file=secrets.json before signing in.',
      );
    }
  }

  Future<bool> isAuthenticated() => _storage.hasTokens();

  Future<void> signIn() async {
    if (isPlaceholder(_clientId) || isPlaceholder(_clientSecret)) {
      throw AuthException(
        'Build the app with --dart-define-from-file=secrets.json to sign in.',
      );
    }
    try {
      final result = await _appAuth.authorize(
        AuthorizationRequest(
          _clientId,
          teslaRedirectUri,
          serviceConfiguration: _serviceConfig,
          scopes: teslaScopes,
          additionalParameters: const {'audience': teslaFleetAudience},
        ),
      );
      final code = result.authorizationCode;
      if (code == null) {
        throw AuthException('Tesla did not complete sign-in. Please retry.');
      }
      final tokens = await _requestTokens({
        'grant_type': 'authorization_code',
        'client_id': _clientId,
        'client_secret': _clientSecret,
        'code': code,
        'audience': teslaFleetAudience,
        'redirect_uri': teslaRedirectUri,
        if (result.codeVerifier != null) 'code_verifier': result.codeVerifier!,
      });
      if (tokens.accessToken == null || tokens.refreshToken == null) {
        throw AuthException('Tesla returned incomplete sign-in data. Retry.');
      }
      await _storage.saveTokens(
        accessToken: tokens.accessToken!,
        refreshToken: tokens.refreshToken!,
        expiry: tokens.expiry,
      );
    } on AuthException {
      rethrow;
    } catch (_) {
      throw AuthException('Tesla sign-in failed. Please retry.');
    }
  }

  Future<String?> getValidAccessToken() async {
    try {
      final accessToken = await _storage.getAccessToken();
      final expiry = await _storage.getTokenExpiry();
      if (accessToken != null &&
          accessToken.isNotEmpty &&
          expiry != null &&
          expiry.isAfter(DateTime.now().add(const Duration(minutes: 2)))) {
        return accessToken;
      }
      return await refreshAccessToken();
    } on AuthException {
      rethrow;
    } catch (_) {
      throw AuthException(
        'Cannot read saved Tesla sign-in. Unlock your phone and retry.',
        retryable: true,
      );
    }
  }

  /// A single forced refresh, also used after an API authentication rejection.
  /// Temporary failures preserve saved tokens and can use the polling backoff.
  Future<String?> refreshAccessToken() async {
    try {
      final refreshToken = await _storage.getRefreshToken();
      if (refreshToken == null || refreshToken.isEmpty) return null;
      final tokens = await _requestTokens({
        'grant_type': 'refresh_token',
        'client_id': _clientId,
        'refresh_token': refreshToken,
      });
      if (tokens.accessToken == null) {
        throw AuthException(
          'Tesla returned incomplete authentication data. Retry shortly.',
          retryable: true,
        );
      }
      await _storage.saveTokens(
        accessToken: tokens.accessToken!,
        refreshToken: tokens.refreshToken ?? refreshToken,
        expiry: tokens.expiry,
      );
      return tokens.accessToken;
    } on AuthException catch (error) {
      if (error.retryable) rethrow;
      return null;
    } catch (_) {
      throw AuthException(
        'Cannot refresh saved Tesla sign-in. Retry shortly.',
        retryable: true,
      );
    }
  }

  Future<void> signOut() => _storage.clearTokens();

  Future<_TeslaTokens> _requestTokens(Map<String, String> body) async {
    try {
      final response = await _tokenDio.post<Map<String, dynamic>>(
        _tokenEndpoint,
        data: body,
      );
      return _TeslaTokens.fromJson(response.data);
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      final retryable =
          status == null || status == 408 || status == 429 || status >= 500;
      throw AuthException(
        retryable
            ? 'Tesla authentication is temporarily unavailable. Retry shortly.'
            : 'Tesla rejected sign-in. Check your credentials and sign in again.',
        retryable: retryable,
        statusCode: status,
        retryAfter: VehiclePolling.serverDelay(
          error.response?.headers.map ?? const {},
          DateTime.now(),
        ),
      );
    }
  }
}

class _TeslaTokens {
  const _TeslaTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.expiry,
  });

  final String? accessToken;
  final String? refreshToken;
  final DateTime expiry;

  factory _TeslaTokens.fromJson(Map<String, dynamic>? json) {
    final expiresIn = json?['expires_in'];
    String? token(Object? value) =>
        value is String && value.trim().isNotEmpty ? value : null;
    return _TeslaTokens(
      accessToken: token(json?['access_token']),
      refreshToken: token(json?['refresh_token']),
      expiry: DateTime.now().add(
        expiresIn is num
            ? Duration(seconds: expiresIn.round())
            : const Duration(hours: 8),
      ),
    );
  }
}

class AuthException implements Exception {
  AuthException(
    this.message, {
    this.retryable = false,
    this.statusCode,
    this.retryAfter,
  });

  final String message;
  final bool retryable;
  final int? statusCode;
  final Duration? retryAfter;

  @override
  String toString() => message;
}
