import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class VehicleMap extends StatefulWidget {
  const VehicleMap({
    super.key,
    this.phoneLatitude,
    this.phoneLongitude,
    this.phoneIsMocked = false,
    this.vehicleLatitude,
    this.vehicleLongitude,
    this.fitRequest = 0,
  });

  final double? phoneLatitude;
  final double? phoneLongitude;
  final bool phoneIsMocked;
  final double? vehicleLatitude;
  final double? vehicleLongitude;
  final int fitRequest;

  @override
  State<VehicleMap> createState() => _VehicleMapState();
}

class _VehicleMapState extends State<VehicleMap> {
  GoogleMapController? _controller;
  BitmapDescriptor? _phoneIcon;
  bool _fittedBoth = false;
  bool _fittedFirst = false;
  bool _userMovedCamera = false;

  @override
  void initState() {
    super.initState();
    _makePhoneIcon();
  }

  Future<void> _makePhoneIcon() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(2);
    const center = Offset(18, 18);
    canvas.drawCircle(
      center,
      16,
      Paint()..color = Colors.lightBlue.withValues(alpha: 0.3),
    );
    canvas.drawCircle(center, 8, Paint()..color = Colors.white);
    canvas.drawCircle(center, 6, Paint()..color = Colors.blue);
    final picture = recorder.endRecording();
    final image = await picture.toImage(72, 72);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    if (!mounted || bytes == null) return;
    setState(
      () => _phoneIcon = BitmapDescriptor.bytes(
        bytes.buffer.asUint8List(),
        imagePixelRatio: 2,
        width: 36,
        height: 36,
      ),
    );
  }

  LatLng? get _phone =>
      widget.phoneLatitude != null && widget.phoneLongitude != null
      ? LatLng(widget.phoneLatitude!, widget.phoneLongitude!)
      : null;

  LatLng? get _vehicle =>
      widget.vehicleLatitude != null && widget.vehicleLongitude != null
      ? LatLng(widget.vehicleLatitude!, widget.vehicleLongitude!)
      : null;

  @override
  void didUpdateWidget(covariant VehicleMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.fitRequest != oldWidget.fitRequest) {
      _fitLocations();
    } else {
      _fitInitially();
    }
  }

  void _fitInitially() {
    if (_controller == null || _userMovedCamera) return;
    if (_phone != null && _vehicle != null && !_fittedBoth) {
      _fittedBoth = true;
      _fittedFirst = true;
      _fitLocations();
    } else if (!_fittedFirst && (_phone != null || _vehicle != null)) {
      _fittedFirst = true;
      _fitLocations();
    }
  }

  Future<void> _fitLocations() async {
    final controller = _controller;
    final phone = _phone;
    final vehicle = _vehicle;
    if (controller == null || (phone == null && vehicle == null)) return;
    if (phone == null ||
        vehicle == null ||
        ((phone.latitude - vehicle.latitude).abs() < 0.0005 &&
            (phone.longitude - vehicle.longitude).abs() < 0.0005)) {
      await controller.animateCamera(
        CameraUpdate.newLatLngZoom(vehicle ?? phone!, 18),
      );
    } else {
      await controller.animateCamera(
        CameraUpdate.newLatLngBounds(
          LatLngBounds(
            southwest: LatLng(
              phone.latitude < vehicle.latitude
                  ? phone.latitude
                  : vehicle.latitude,
              phone.longitude < vehicle.longitude
                  ? phone.longitude
                  : vehicle.longitude,
            ),
            northeast: LatLng(
              phone.latitude > vehicle.latitude
                  ? phone.latitude
                  : vehicle.latitude,
              phone.longitude > vehicle.longitude
                  ? phone.longitude
                  : vehicle.longitude,
            ),
          ),
          72,
        ),
      );
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vehicle = _vehicle;
    final phone = _phone;
    return Listener(
      onPointerDown: (_) => _userMovedCamera = true,
      child: GoogleMap(
        mapType: MapType.satellite,
        initialCameraPosition: CameraPosition(
          target: vehicle ?? phone ?? const LatLng(20, 0),
          zoom: vehicle != null || phone != null ? 18 : 2,
        ),
        myLocationEnabled: false,
        myLocationButtonEnabled: false,
        zoomControlsEnabled: false,
        padding: const EdgeInsets.only(top: 110, bottom: 220),
        markers: {
          if (vehicle != null)
            Marker(
              markerId: const MarkerId('vehicle'),
              position: vehicle,
              icon: BitmapDescriptor.defaultMarkerWithHue(
                BitmapDescriptor.hueRed,
              ),
              infoWindow: const InfoWindow(title: 'Tesla vehicle'),
              zIndexInt: 2,
            ),
          if (phone != null)
            Marker(
              markerId: const MarkerId('phone'),
              position: phone,
              icon:
                  _phoneIcon ??
                  BitmapDescriptor.defaultMarkerWithHue(
                    BitmapDescriptor.hueAzure,
                  ),
              // The blue halo remains visible around the red pin at the same fix.
              anchor: const Offset(0.5, 0.5),
              infoWindow: InfoWindow(
                title: 'Phone GPS',
                snippet: widget.phoneIsMocked
                    ? 'Mocked location'
                    : 'Non-mocked location',
              ),
              zIndexInt: 1,
            ),
        },
        onMapCreated: (controller) {
          _controller = controller;
          _fitInitially();
        },
      ),
    );
  }
}
