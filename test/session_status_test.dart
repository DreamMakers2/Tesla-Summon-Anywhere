import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:summon_anywhere_tesla/features/home/providers/summon_session_provider.dart';
import 'package:summon_anywhere_tesla/features/home/widgets/session_error_banner.dart';

void main() {
  test('missing, unknown and repeated started events do not claim GPS sync', () {
    const starting = SummonSessionState(isStarting: true);
    var state = applySessionTaskEvent(starting, <String, Object>{});
    state = applySessionTaskEvent(state, {'event': 'started'});
    state = applySessionTaskEvent(state, {'event': 'started'});
    expect(state.isStarting, isTrue);
    expect(state.isActive, isFalse);
  });

  test('stopped event cannot finish an ongoing local stop', () {
    const stopping = SummonSessionState(isActive: true, isStopping: true);
    final state = applySessionTaskEvent(stopping, {
      'event': 'stopped',
      'sessionId': 2,
    }, sessionId: 2);
    expect(state.isStopping, isTrue);
  });

  test('cleanup failure remains actionable, including during stop', () {
    const stopping = SummonSessionState(isActive: true, isStopping: true);
    var state = applySessionTaskEvent(stopping, {'event': 'cleanup_failed'});
    expect(state.isActive, isTrue);
    expect(state.isStopping, isTrue);
    expect(state.error, contains('Retry Stop'));
    state = applySessionTaskEvent(state, {
      'event': 'stopped',
      'sessionId': 2,
    }, sessionId: 2);
    expect(state.isStopping, isTrue);
    expect(state.error, contains('cleanup failed'));
  });

  test('delayed or untagged stopped events cannot stop a newer session', () {
    const active = SummonSessionState(isActive: true);
    for (final event in [
      {'event': 'stopped', 'sessionId': 1},
      {'event': 'stopped'},
    ]) {
      final state = applySessionTaskEvent(active, event, sessionId: 2);
      expect(state.isActive, isTrue);
      expect(state.isStopping, isFalse);
    }
    final stopping = applySessionTaskEvent(active, {
      'event': 'stopped',
      'sessionId': 2,
    }, sessionId: 2);
    expect(stopping.isStopping, isTrue);
    expect(stopping.isActive, isTrue);
  });

  test('an old cleanup failure is treated as a shared GPS safety failure', () {
    const active = SummonSessionState(isActive: true);
    final state = applySessionTaskEvent(active, {
      'event': 'cleanup_failed',
      'sessionId': 1,
    }, sessionId: 2);
    expect(state.isActive, isTrue);
    expect(state.error, contains('cleanup failed'));
  });

  testWidgets('session error remains visible and wraps at narrow widths', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const message = 'Mock GPS cleanup failed. Retry Stop and check your phone.';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SessionErrorBanner(message: message)),
      ),
    );
    expect(find.text(message), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    expect(find.text(message), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
