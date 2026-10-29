// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'vehicle_location_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(VehicleLocation)
final vehicleLocationProvider = VehicleLocationProvider._();

final class VehicleLocationProvider
    extends $NotifierProvider<VehicleLocation, VehicleLocationState> {
  VehicleLocationProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'vehicleLocationProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$vehicleLocationHash();

  @$internal
  @override
  VehicleLocation create() => VehicleLocation();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(VehicleLocationState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<VehicleLocationState>(value),
    );
  }
}

String _$vehicleLocationHash() => r'3768d77755b0adc891c802eb0ef682983d3dfa3d';

abstract class _$VehicleLocation extends $Notifier<VehicleLocationState> {
  VehicleLocationState build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<VehicleLocationState, VehicleLocationState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<VehicleLocationState, VehicleLocationState>,
              VehicleLocationState,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
