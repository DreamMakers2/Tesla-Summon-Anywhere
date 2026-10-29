import 'package:flutter_test/flutter_test.dart';
import 'package:summon_anywhere_tesla/core/services/location_safety.dart';

void main() {
  group('Coordinate validation', () {
    test('accepts valid bounds', () {
      expect(LocationSafety.validCoordinates(0, 0), isTrue);
      expect(LocationSafety.validCoordinates(90, -180), isTrue);
    });
    test('rejects invalid or non-finite locations', () {
      expect(LocationSafety.validCoordinates(91, 0), isFalse);
      expect(LocationSafety.validCoordinates(0, -181), isFalse);
      expect(LocationSafety.validCoordinates(double.nan, 0), isFalse);
      expect(LocationSafety.validCoordinates(double.infinity, 0), isFalse);
    });
  });
  group('Timestamp validation', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1760000000000);
    test('accepts fresh observations', () {
      expect(
        LocationSafety.isFreshTimestamp(now.millisecondsSinceEpoch, now),
        isTrue,
      );
    });
    test('rejects stale, missing and future timestamps', () {
      expect(
        LocationSafety.isFreshTimestamp(
          now.subtract(const Duration(minutes: 3)).millisecondsSinceEpoch,
          now,
        ),
        isFalse,
      );
      expect(LocationSafety.isFreshTimestamp(null, now), isFalse);
      expect(LocationSafety.isFreshTimestamp('1760000000000', now), isFalse);
      expect(
        LocationSafety.isFreshTimestamp(
          now.add(const Duration(minutes: 1)).millisecondsSinceEpoch, now,
        ),
        isFalse,
      );
    });
  });
  test('Session deadline bounded to five minutes', () {
    final now = DateTime(2026, 10, 28);
    expect(LocationSafety.validDeadline(now.add(const Duration(minutes: 4)), now), isTrue);
    expect(LocationSafety.validDeadline(now, now), isFalse);
    expect(LocationSafety.validDeadline(now.add(const Duration(minutes: 6)), now), isFalse);
  });
}
