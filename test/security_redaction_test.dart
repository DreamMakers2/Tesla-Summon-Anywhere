import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:summon_anywhere_tesla/core/logging/app_logger.dart';
import 'package:summon_anywhere_tesla/core/services/tesla_api_service.dart';

void main() {
  const sensitiveMarker = 'PRIVATE_ERROR_DETAIL_FIXTURE';

  test('Tesla response bodies never become user-facing error text', () {
    for (final status in [401, 403, 412, 421, 429, 500]) {
      final request = RequestOptions(path: '/fixture');
      final error = DioException(
        requestOptions: request,
        message: sensitiveMarker,
        response: Response(
          requestOptions: request,
          statusCode: status,
          data: {'error_description': sensitiveMarker},
        ),
      );
      final result = TeslaApiService.sanitizeApiError(error);
      expect(result.message, isNot(contains(sensitiveMarker)));
      expect(result.statusCode, status);
    }
  });

  test('logger omits exception and stack contents', () {
    final output = <String>[];
    runZoned(
      () => AppLogger.error(
        'TEST',
        'Operation failed',
        error: Exception(sensitiveMarker),
        stackTrace: StackTrace.fromString(sensitiveMarker),
      ),
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => output.add(line),
      ),
    );
    expect(output.join('\n'), isNot(contains(sensitiveMarker)));
    expect(output.join('\n'), contains('Operation failed'));
  });
}
