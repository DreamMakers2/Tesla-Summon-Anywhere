import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../features/home/screens/home_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/onboarding/providers/onboarding_provider.dart';
import '../../features/onboarding/screens/onboarding_shell.dart';

part 'app_router.g.dart';

@Riverpod(keepAlive: true)
GoRouter appRouter(Ref ref) {
  return GoRouter(
    initialLocation: '/onboarding',
    routes: [
      GoRoute(
        path: '/onboarding',
        builder: (context, state) => const OnboardingShell(),
      ),
      GoRoute(path: '/home', builder: (context, state) => const HomeScreen()),
      GoRoute(
        path: '/settings',
        builder: (context, state) => const SettingsScreen(),
      ),
    ],
    redirect: (context, state) {
      final complete = ref.read(onboardingCompleteProvider);
      final onOnboarding = state.matchedLocation == '/onboarding';

      if (!complete && !onOnboarding) {
        return '/onboarding';
      }
      if (complete && onOnboarding) {
        return '/home';
      }
      return null;
    },
    refreshListenable: _RouterRefresh(ref),
  );
}

class _RouterRefresh extends ChangeNotifier {
  _RouterRefresh(this._ref) {
    _ref.listen(onboardingCompleteProvider, (previous, next) {
      notifyListeners();
    });
  }

  final Ref _ref;
}
