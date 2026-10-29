import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../../core/theme/app_colors.dart';
import '../providers/summon_session_provider.dart';
import '../providers/vehicle_location_provider.dart';

class PhoneFixes {
  const PhoneFixes({
    this.effective,
    this.lastReal,
    this.lastRealIsGps = false,
    this.effectiveRecoveryPending = false,
  });

  final Position? effective;
  final Position? lastReal;
  final bool lastRealIsGps;
  final bool effectiveRecoveryPending;
}

String locationAge(DateTime? timestamp) {
  if (timestamp == null) return 'not observed';
  final age = DateTime.now().difference(timestamp);
  if (age.isNegative || age.inSeconds < 5) return 'just now';
  if (age.inSeconds < 60) return '${age.inSeconds}s ago';
  if (age.inMinutes < 60) return '${age.inMinutes}m ago';
  return '${age.inHours}h ago';
}

class LocationStatusSheet extends ConsumerStatefulWidget {
  const LocationStatusSheet({super.key, required this.phoneFixes});
  final ValueListenable<PhoneFixes> phoneFixes;

  @override
  ConsumerState<LocationStatusSheet> createState() =>
      _LocationStatusSheetState();
}

class _LocationStatusSheetState extends ConsumerState<LocationStatusSheet> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _coordinates(double? latitude, double? longitude) =>
      latitude == null || longitude == null
      ? 'Not observed yet'
      : '${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}';

  Widget _fix(String title, String coordinates, String detail, Color color) =>
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.location_on_rounded, color: color),
        title: Text(title),
        subtitle: Text('$coordinates\n$detail'),
        isThreeLine: true,
      );

  @override
  Widget build(BuildContext context) {
    final vehicle = ref.watch(vehicleLocationProvider);
    final session = ref.watch(summonSessionProvider);
    return ValueListenableBuilder<PhoneFixes>(
      valueListenable: widget.phoneFixes,
      builder: (context, fixes, _) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Location status',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _fix(
                'Effective phone GPS',
                _coordinates(
                  fixes.effective?.latitude,
                  fixes.effective?.longitude,
                ),
                fixes.effective == null
                    ? 'Waiting for Android location'
                    : fixes.effectiveRecoveryPending
                    ? 'Mocked/stale effective fix · ${locationAge(fixes.effective!.timestamp)} · fresh effective fix pending'
                    : '${fixes.effective!.isMocked ? 'Mocked' : 'Non-mocked'} · ${locationAge(fixes.effective!.timestamp)} · ±${fixes.effective!.accuracy.round()} m',
                Colors.lightBlueAccent,
              ),
              _fix(
                'Last real phone fix',
                _coordinates(
                  fixes.lastReal?.latitude,
                  fixes.lastReal?.longitude,
                ),
                fixes.lastReal == null
                    ? 'No non-mocked fix observed yet'
                    : '${fixes.lastRealIsGps ? 'GPS provider (non-mocked)' : 'Non-mocked effective fix'} · ${locationAge(fixes.lastReal!.timestamp)}',
                AppColors.summonMint,
              ),
              _fix(
                'Tesla vehicle',
                _coordinates(vehicle.latitude, vehicle.longitude),
                'Vehicle fix · ${locationAge(vehicle.sourceTimestamp ?? vehicle.updatedAt)}',
                AppColors.teslaRed,
              ),
              const Divider(),
              _fix(
                'Last submitted mock fix',
                _coordinates(
                  session.lastSubmittedLatitude,
                  session.lastSubmittedLongitude,
                ),
                session.lastSubmittedAt == null
                    ? 'No Tesla location submitted in this session'
                    : 'Submitted ${locationAge(session.lastSubmittedAt)}',
                AppColors.countdownAmber,
              ),
              const SizedBox(height: 12),
              Text(
                fixes.effectiveRecoveryPending
                    ? 'The blue marker remains the last reported fused location, which may still be cached. The real GPS fix is separate; a fresh effective fix is still pending.'
                    : 'The blue marker shows Android’s effective fused location. A mocked fix can overlap the red vehicle marker.',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
