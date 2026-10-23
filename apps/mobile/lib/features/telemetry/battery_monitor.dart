import 'dart:async';
import 'package:battery_plus/battery_plus.dart';
import 'package:camsync_protocol/camsync_protocol.dart';

/// Monitors device battery, thermal status, and streaming metrics.
class BatteryMonitor {
  final Battery _battery = Battery();
  int _batteryLevel = 100;
  bool _isCharging = false;

  int _bytesSentSinceLastTick = 0;
  int _framesSentSinceLastTick = 0;
  int _currentBitrateKbps = 0;
  double _currentFps = 0.0;

  Timer? _timer;
  final StreamController<DeviceTelemetry> _telemetryController =
      StreamController<DeviceTelemetry>.broadcast();

  Stream<DeviceTelemetry> get onTelemetry => _telemetryController.stream;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    _tick();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Records sent frame size to compute live bitrate and FPS.
  void recordFrameSent(int byteSize) {
    _bytesSentSinceLastTick += byteSize;
    _framesSentSinceLastTick++;
  }

  Future<void> _tick() async {
    try {
      _batteryLevel = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      _isCharging = (state == BatteryState.charging || state == BatteryState.full);
    } catch (_) {}

    _currentBitrateKbps = (_bytesSentSinceLastTick * 8) ~/ 1000;
    _currentFps = _framesSentSinceLastTick.toDouble();

    _bytesSentSinceLastTick = 0;
    _framesSentSinceLastTick = 0;

    final telemetry = DeviceTelemetry(
      batteryLevel: _batteryLevel,
      isCharging: _isCharging,
      thermalState: 'nominal',
      temperatureC: 33.5, // Native channel can refine this
      encoderBitrateKbps: _currentBitrateKbps,
      currentFps: _currentFps,
    );

    _telemetryController.add(telemetry);
  }

  void dispose() {
    stop();
    _telemetryController.close();
  }
}
