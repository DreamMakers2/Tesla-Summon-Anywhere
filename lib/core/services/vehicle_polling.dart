import 'dart:io';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

/// A single, uncached cooldown shared by the UI and foreground-task isolates.
class VehiclePolling {
  VehiclePolling({SharedPreferencesAsync? preferences})
    : _preferences = preferences ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _preferences;
  static const _nextKey = 'vehicle_location_next_request_ms';
  static const _failuresKey = 'vehicle_location_failures';
  static const interval = Duration(seconds: 5);

  Future<DateTime?> nextRequest() async {
    final value = await _preferences.getInt(_nextKey);
    return value == null ? null : DateTime.fromMillisecondsSinceEpoch(value);
  }

  Future<void> succeeded(DateTime now) async {
    await _preferences.setInt(_failuresKey, 0);
    await _preferences.setInt(
      _nextKey,
      now.add(interval).millisecondsSinceEpoch,
    );
  }

  Future<DateTime> failed(
    DateTime now, {
    bool rateLimited = false,
    bool unavailable = false,
    Duration? serverDelay,
  }) async {
    final failures = (await _preferences.getInt(_failuresKey) ?? 0) + 1;
    final delay = delayFor(
      failures,
      rateLimited: rateLimited,
      unavailable: unavailable,
      serverDelay: serverDelay,
    );
    final next = now.add(delay);
    await _preferences.setInt(_failuresKey, failures);
    await _preferences.setInt(_nextKey, next.millisecondsSinceEpoch);
    return next;
  }

  static Duration delayFor(
    int failures, {
    bool rateLimited = false,
    bool unavailable = false,
    Duration? serverDelay,
  }) {
    final base = rateLimited || unavailable ? 30 : 10;
    final exponent = math.min(math.max(failures - 1, 0), 4);
    final local = Duration(seconds: math.min(base * (1 << exponent), 120));
    return serverDelay != null && serverDelay > local ? serverDelay : local;
  }

  /// Retry-After accepts seconds or an HTTP date. Tesla also reports reset
  /// headers; numeric values are treated as seconds or Unix epoch seconds.
  static Duration? serverDelay(
    Map<String, List<String>> headers,
    DateTime now,
  ) {
    Duration? longest;
    for (final entry in headers.entries) {
      final name = entry.key.toLowerCase();
      if (name != 'retry-after' &&
          !(name.startsWith('ratelimit-') && name.endsWith('-reset')) &&
          name != 'ratelimit-reset') {
        continue;
      }
      for (final value in entry.value) {
        Duration? delay;
        final seconds = int.tryParse(value.trim());
        if (seconds != null && seconds >= 0) {
          try {
            delay = seconds >= 1000000000000
                ? DateTime.fromMillisecondsSinceEpoch(seconds).difference(now)
                : seconds >= 1000000000
                ? DateTime.fromMillisecondsSinceEpoch(
                    seconds * 1000,
                  ).difference(now)
                : Duration(seconds: seconds);
          } on ArgumentError {
            // Invalid reset values fall back to the local backoff.
          }
        } else if (name == 'retry-after') {
          try {
            delay = HttpDate.parse(value).difference(now.toUtc());
          } on HttpException {
            // A malformed header falls back to our normal backoff.
          } on FormatException {
            // Some Dart versions report malformed HTTP dates this way.
          }
        }
        if (delay != null &&
            !delay.isNegative &&
            (longest == null || delay > longest)) {
          longest = delay;
        }
      }
    }
    return longest;
  }
}
