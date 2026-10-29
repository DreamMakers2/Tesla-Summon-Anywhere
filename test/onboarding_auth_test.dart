import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:summon_anywhere_tesla/core/services/auth_service.dart';
import 'package:summon_anywhere_tesla/core/storage/secure_storage.dart';
import 'package:summon_anywhere_tesla/features/onboarding/providers/onboarding_provider.dart';
import 'package:summon_anywhere_tesla/features/onboarding/screens/step1_auth.dart';

class _Auth extends AuthService {
  _Auth() : super(const SecureStorage(FlutterSecureStorage()));

  int attempts = 0;
  bool fail = false;

  @override
  Future<void> signIn() async {
    attempts++;
    if (fail) throw AuthException('Tesla sign-in failed. Please retry.');
  }
}

void main() {
  for (final fail in [false, true]) {
    testWidgets('sign-in uses OAuth directly (failure=$fail)', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 780);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final auth = _Auth()..fail = fail;
      final container = ProviderContainer(
        overrides: [authServiceProvider.overrideWithValue(auth)],
      );
      container.listen(onboardingStepProvider, (_, _) {});
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Step1Auth()),
        ),
      );
      await tester.tap(find.text('Sign in with Tesla'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(auth.attempts, 1);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Set Tesla sign-in secret'), findsNothing);
      expect(container.read(onboardingStepProvider), fail ? 0 : 1);
      if (fail) {
        expect(
          find.text('Tesla sign-in failed. Please retry.'),
          findsOneWidget,
        );
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
}
