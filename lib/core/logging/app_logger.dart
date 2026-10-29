import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// Centralized logging for `flutter run` terminal output.
abstract final class AppLogger {
  static void debug(
    String category,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) => _log('DEBUG', category, message, error: error, stackTrace: stackTrace);

  static void info(
    String category,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) => _log('INFO', category, message, error: error, stackTrace: stackTrace);

  static void warn(
    String category,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) => _log('WARN', category, message, error: error, stackTrace: stackTrace);

  static void error(
    String category,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) => _log('ERROR', category, message, error: error, stackTrace: stackTrace);

  /// Reports presence without exposing any part of a secret.
  static String maskToken(String? token) {
    if (token == null || token.isEmpty) return '(none)';
    return '(present)';
  }

  /// Partially masks a client ID for debugging without exposing the full value.
  static String maskClientId(String clientId) {
    if (clientId.isEmpty) return '(empty)';
    if (clientId.startsWith('YOUR_')) return '(placeholder)';
    return '(configured)';
  }

  /// Returns true when the value is still a placeholder constant.
  static bool isPlaceholder(String value) =>
      value.isEmpty || value.startsWith('YOUR_');

  static void _log(
    String level,
    String category,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    final errorType = error == null
        ? ''
        : ' (error type: ${error.runtimeType})';
    final line = '[$level][$category] $message$errorType';
    developer.log(line, name: 'SummonAnywhere');
    if (kDebugMode) {
      // Some IDE/terminal setups filter developer.log; print ensures visibility.
      // ignore: avoid_print
      print(line);
    }
  }
}
