import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:camsync_protocol/camsync_protocol.dart';
import '../native/camsync_ffi.dart';

enum CamSyncConnectionState { disconnected, connecting, connected, error }

class StreamClient {
  final CamSyncNative _native = CamSyncNative();
  final PacketStreamDecoder _decoder = PacketStreamDecoder();

  Socket? _videoSocket;
  Socket? _controlSocket;

  CamSyncConnectionState _state = CamSyncConnectionState.disconnected;
  CamSyncConnectionState get state => _state;

  final StreamController<CamSyncConnectionState> _stateController =
      StreamController<CamSyncConnectionState>.broadcast();
  final StreamController<DeviceTelemetry> _telemetryController =
      StreamController<DeviceTelemetry>.broadcast();

  Stream<CamSyncConnectionState> get onStateChanged => _stateController.stream;
  Stream<DeviceTelemetry> get onTelemetry => _telemetryController.stream;

  int _rpcId = 1;

  int _bytesSinceLastTick = 0;
  int _framesSinceLastTick = 0;
  double _measuredFps = 0.0;
  int _measuredBitrateKbps = 0;
  Timer? _metricsTimer;

  DeviceTelemetry _lastDeviceTelemetry = const DeviceTelemetry(
    batteryLevel: 100,
    isCharging: false,
    thermalState: 'nominal',
    temperatureC: 25.0,
    encoderBitrateKbps: 0,
    currentFps: 0,
  );

  StreamClient() {
    _native.init();
  }

  Future<bool> connect(String host) async {
    await disconnect();
    _setState(CamSyncConnectionState.connecting);

    try {
      // Connect Video Socket (TCP 8282)
      _videoSocket = await Socket.connect(host, CamSyncConstants.defaultVideoPort, timeout: const Duration(seconds: 4));
      _videoSocket?.setOption(SocketOption.tcpNoDelay, true);

      // Connect Control Socket (TCP 8283)
      _controlSocket = await Socket.connect(host, CamSyncConstants.defaultControlPort, timeout: const Duration(seconds: 4));
      _controlSocket?.setOption(SocketOption.tcpNoDelay, true);

      _setupVideoListener();
      _setupControlListener();
      _startMetricsTimer();

      _setState(CamSyncConnectionState.connected);
      return true;
    } catch (e) {
      _setState(CamSyncConnectionState.error);
      await disconnect();
      return false;
    }
  }

  void _startMetricsTimer() {
    _metricsTimer?.cancel();
    _bytesSinceLastTick = 0;
    _framesSinceLastTick = 0;
    _measuredFps = 0.0;
    _measuredBitrateKbps = 0;

    _metricsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _measuredFps = _framesSinceLastTick.toDouble();
      _measuredBitrateKbps = (_bytesSinceLastTick * 8) ~/ 1000;
      _bytesSinceLastTick = 0;
      _framesSinceLastTick = 0;

      final effectiveFps = _measuredFps > 0 ? _measuredFps : _lastDeviceTelemetry.currentFps;
      final effectiveBitrate = _measuredBitrateKbps > 0 ? _measuredBitrateKbps : _lastDeviceTelemetry.encoderBitrateKbps;

      final telemetry = DeviceTelemetry(
        batteryLevel: _lastDeviceTelemetry.batteryLevel,
        isCharging: _lastDeviceTelemetry.isCharging,
        thermalState: _lastDeviceTelemetry.thermalState,
        temperatureC: _lastDeviceTelemetry.temperatureC,
        encoderBitrateKbps: effectiveBitrate,
        currentFps: effectiveFps,
      );

      _telemetryController.add(telemetry);
    });
  }

  void _setupVideoListener() {
    _videoSocket?.listen((chunk) {
      _bytesSinceLastTick += chunk.length;
      final packets = _decoder.addChunk(chunk);
      _framesSinceLastTick += packets.length;
      for (final p in packets) {
        _native.feedNal(
          nalBytes: p.payload,
          frameType: p.frameType.value,
          timestampMs: p.timestampMs,
        );
      }
    }, onDone: () {
      disconnect();
    }, onError: (_) {
      disconnect();
    });
  }

  void _setupControlListener() {
    if (_controlSocket == null) return;
    final lineSplitter = utf8.decoder.bind(_controlSocket!);
    String lineBuffer = '';

    lineSplitter.listen((text) {
      lineBuffer += text;
      while (lineBuffer.contains('\n')) {
        final newlineIndex = lineBuffer.indexOf('\n');
        final line = lineBuffer.substring(0, newlineIndex).trim();
        lineBuffer = lineBuffer.substring(newlineIndex + 1);

        if (line.isNotEmpty) {
          try {
            final msg = ControlRpcMessage.parseLine(line);
            if (msg.method == 'device.telemetry' && msg.params != null) {
              _lastDeviceTelemetry = DeviceTelemetry.fromJson(msg.params!);
              if (_measuredFps == 0.0) {
                _telemetryController.add(_lastDeviceTelemetry);
              }
            }
          } catch (_) {}
        }
      }
    }, onDone: () {
      disconnect();
    }, onError: (_) {
      disconnect();
    });
  }

  /// Sends a camera parameter update to the phone.
  void sendParameters(CameraParameters parameters) {
    if (_controlSocket == null || _state != CamSyncConnectionState.connected) return;
    final msg = ControlRpcMessage.setParametersRequest(
      id: _rpcId++,
      parameters: parameters,
    );
    _controlSocket?.write(msg.encode());
  }

  /// Requests the phone to start or stop streaming.
  void requestStream(bool start) {
    if (_controlSocket == null || _state != CamSyncConnectionState.connected) return;
    final msg = ControlRpcMessage.streamControlRequest(
      id: _rpcId++,
      start: start,
    );
    _controlSocket?.write(msg.encode());
  }

  void _setState(CamSyncConnectionState state) {
    _state = state;
    _stateController.add(state);
  }

  Future<void> disconnect() async {
    _metricsTimer?.cancel();
    _metricsTimer = null;
    _bytesSinceLastTick = 0;
    _framesSinceLastTick = 0;
    _measuredFps = 0.0;
    _measuredBitrateKbps = 0;

    _videoSocket?.destroy();
    _videoSocket = null;

    _controlSocket?.destroy();
    _controlSocket = null;

    _decoder.reset();
    _setState(CamSyncConnectionState.disconnected);

    _lastDeviceTelemetry = const DeviceTelemetry(
      batteryLevel: 100,
      isCharging: false,
      thermalState: 'nominal',
      temperatureC: 25.0,
      encoderBitrateKbps: 0,
      currentFps: 0,
    );
    _telemetryController.add(_lastDeviceTelemetry);
  }

  void dispose() {
    disconnect();
    _stateController.close();
    _telemetryController.close();
  }
}
