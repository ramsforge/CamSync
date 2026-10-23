import 'dart:async';
import 'package:flutter/services.dart';
import 'package:camsync_protocol/camsync_protocol.dart';

/// MethodChannel bridge for controlling native camera hardware and hardware encoder.
class CameraChannel {
  static const MethodChannel _methodChannel = MethodChannel('com.camsync/camera');
  static const EventChannel _streamEventChannel = EventChannel('com.camsync/video_stream');

  Stream<Uint8List>? _videoPacketStream;

  /// Stream of raw H.264 binary packets (with 20-byte CamSync header) emitted by native encoder.
  Stream<Uint8List> get onVideoPacket {
    _videoPacketStream ??= _streamEventChannel
        .receiveBroadcastStream()
        .map((event) => event as Uint8List);
    return _videoPacketStream!;
  }

  /// Starts native camera capture session and hardware encoder.
  Future<bool> startCapture({
    required CameraResolution resolution,
    required int fps,
    required CameraLens lens,
  }) async {
    try {
      final result = await _methodChannel.invokeMethod<bool>('startCapture', {
        'width': resolution.width,
        'height': resolution.height,
        'fps': fps,
        'lens': lens.id,
      });
      return result ?? false;
    } on PlatformException catch (_) {
      return false;
    }
  }

  /// Stops native camera capture and hardware encoder.
  Future<bool> stopCapture() async {
    try {
      final result = await _methodChannel.invokeMethod<bool>('stopCapture');
      return result ?? false;
    } on PlatformException catch (_) {
      return false;
    }
  }

  /// Switches active camera lens (0.5x, 1x, 3x, front).
  Future<void> setLens(CameraLens lens) async {
    await _methodChannel.invokeMethod('setLens', {'lens': lens.id});
  }

  /// Sets digital/optical zoom factor (1.0 to max).
  Future<void> setZoom(double zoomRatio) async {
    await _methodChannel.invokeMethod('setZoom', {'zoom': zoomRatio});
  }

  /// Toggles flashlight / torch fill-light.
  Future<void> setTorch(bool enable) async {
    await _methodChannel.invokeMethod('setTorch', {'enabled': enable});
  }

  /// Configures autofocus or manual focus distance.
  Future<void> setFocus(FocusMode mode, double distance) async {
    await _methodChannel.invokeMethod('setFocus', {
      'mode': mode.id,
      'distance': distance,
    });
  }

  /// Configures exposure mode, ISO, and shutter speed.
  Future<void> setExposure(ExposureMode mode, int? iso, double? shutterSpeedMs) async {
    await _methodChannel.invokeMethod('setExposure', {
      'mode': mode.id,
      'iso': iso,
      'shutterSpeedMs': shutterSpeedMs,
    });
  }

  /// Configures white balance mode and Kelvin temperature.
  Future<void> setWhiteBalance(WhiteBalanceMode mode, int? kelvin) async {
    await _methodChannel.invokeMethod('setWhiteBalance', {
      'mode': mode.id,
      'kelvin': kelvin,
    });
  }

  /// Sets video orientation lock.
  Future<void> setOrientation(OrientationMode orientation) async {
    await _methodChannel.invokeMethod('setOrientation', {'orientation': orientation.id});
  }

  /// Applies a full [CameraParameters] configuration bundle.
  Future<void> applyParameters(CameraParameters params) async {
    await _methodChannel.invokeMethod('applyParameters', params.toJson());
  }
}
