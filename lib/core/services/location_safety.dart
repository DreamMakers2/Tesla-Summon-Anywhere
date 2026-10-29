/// Pure validation shared by the task worker and its tests.
abstract final class LocationSafety {
  static const maxLocationAge = Duration(minutes: 2);

  static bool validCoordinates(double latitude, double longitude) =>
      latitude.isFinite && longitude.isFinite &&
      latitude >= -90 && latitude <= 90 &&
      longitude >= -180 && longitude <= 180;

  /// Tesla vehicle_data timestamps are Unix milliseconds. An absent or
  /// untrusted timestamp is treated as stale rather than reused indefinitely.
  static bool isFreshTimestamp(Object? value, DateTime now) {
    if (value is! num || !value.isFinite) return false;
    final milliseconds = value.toInt();
    final age = now.millisecondsSinceEpoch - milliseconds;
    return age >= -10000 && age <= maxLocationAge.inMilliseconds;
  }

  static bool validDeadline(DateTime deadline, DateTime now) {
    final remaining = deadline.difference(now);
    return remaining > Duration.zero &&
        remaining <= const Duration(minutes: 5);
  }
}
