import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/services/auth_service.dart';
import '../../core/services/mock_location_service.dart';
import '../../core/services/notification_service.dart';
import '../home/providers/summon_session_provider.dart';
import '../home/providers/vehicle_location_provider.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _signingIn = false;
  String? _signInMessage;

  bool get _sessionBusy {
    final session = ref.read(summonSessionProvider);
    return session.isActive || session.isStarting || session.isStopping;
  }

  Future<void> _signIn() async {
    if (_signingIn || _sessionBusy) return;
    setState(() {
      _signingIn = true;
      _signInMessage = null;
    });
    var signedIn = false;
    try {
      await ref.read(authServiceProvider).signIn();
      signedIn = true;
      if (mounted) setState(() => _signInMessage = 'Signed in to Tesla.');
    } on AuthException catch (error) {
      if (mounted) setState(() => _signInMessage = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _signInMessage = 'Tesla sign-in failed. Please retry.');
      }
    } finally {
      if (mounted) setState(() => _signingIn = false);
    }
    if (signedIn && mounted && !_sessionBusy) {
      await ref.read(vehicleLocationProvider.notifier).refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(summonSessionProvider);
    final sessionBusy =
        session.isActive || session.isStarting || session.isStopping;
    Future<void> open(Future<void> Function() action) async {
      try {
        await action();
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not open Android settings.')),
          );
        }
      }
    }

    final mock = ref.read(mockLocationServiceProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.login_rounded),
            title: const Text('Sign in to Tesla'),
            subtitle: Text(
              sessionBusy
                  ? 'Stop GPS sync before signing in.'
                  : _signingIn
                  ? 'Opening Tesla sign-in…'
                  : _signInMessage ??
                        'Reconnect your Tesla account if sign-in has expired.',
            ),
            trailing: _signingIn
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            enabled: !_signingIn && !sessionBusy,
            onTap: _signIn,
          ),
          ListTile(
            leading: const Icon(Icons.developer_mode_rounded),
            title: const Text('Mock location app'),
            subtitle: const Text(
              'Select Summon Anywhere in Developer options.',
            ),
            onTap: () => open(mock.openDeveloperSettings),
          ),
          ListTile(
            leading: const Icon(Icons.battery_saver_outlined),
            title: const Text('Battery settings'),
            subtitle: const Text(
              'Allow the GPS sync session to run in the background.',
            ),
            onTap: () => open(mock.openBatterySettings),
          ),
          ListTile(
            leading: const Icon(Icons.location_on_outlined),
            title: const Text('Location permission'),
            onTap: () => open(() async {
              await Geolocator.openAppSettings();
            }),
          ),
          ListTile(
            leading: const Icon(Icons.notifications_outlined),
            title: const Text('Notifications'),
            onTap: () =>
                open(ref.read(notificationServiceProvider).openSettings),
          ),
        ],
      ),
    );
  }
}
