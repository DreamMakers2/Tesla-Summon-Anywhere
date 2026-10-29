import 'package:flutter/services.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'mock_location_service.g.dart';

@Riverpod(keepAlive: true)
MockLocationService mockLocationService(Ref ref) => MockLocationService();

class MockLocationService {
  static const _channel = MethodChannel('com.summonanywhere/mock_location');

  Future<void> blockMocking() async {
    try {
      await _channel.invokeMethod<void>('blockMocking');
    } on PlatformException {
      throw const MockLocationException('Failed to block mock GPS');
    }
  }

  Future<void> allowSession(int sessionId) async {
    try {
      await _channel.invokeMethod<void>('allowSession', {
        'sessionId': sessionId,
      });
    } on PlatformException {
      throw const MockLocationException('Failed to prepare mock GPS session');
    }
  }

  Future<void> retireSession(int sessionId) async {
    try {
      await _channel.invokeMethod<void>('retireSession', {
        'sessionId': sessionId,
      });
    } on PlatformException {
      throw const MockLocationException('Failed to cancel mock GPS session');
    }
  }

  Future<void> disableMockProvider() async {
    try {
      await _channel.invokeMethod<void>('disableMockProvider');
    } on PlatformException {
      throw const MockLocationException('Failed to disable mock provider');
    }
  }

  Future<bool> isEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('isEnabled') ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> openDeveloperSettings() async {
    try {
      await _channel.invokeMethod<void>('openDeveloperSettings');
    } on PlatformException {
      throw const MockLocationException('Failed to open developer settings');
    }
  }

  Future<void> openBatterySettings() async {
    try {
      await _channel.invokeMethod<void>('openBatterySettings');
    } on PlatformException {
      throw const MockLocationException('Failed to open battery settings');
    }
  }
}

class MockLocationException implements Exception {
  const MockLocationException(this.message);
  final String message;

  @override
  String toString() => message;
}
