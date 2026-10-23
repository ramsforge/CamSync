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
  String _targetHost = '127.0.0.1';

  StreamClient() {
    _native.init();
  }

  Future<bool> connect(String host) async {
    await disconnect();
    _targetHost = host;
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

      _setState(CamSyncConnectionState.connected);
      return true;
    } catch (e) {
      _setState(CamSyncConnectionState.error);
      await disconnect();
      return false;
    }
  }

  void _setupVideoListener() {
    _videoSocket?.listen((chunk) {
      final packets = _decoder.addChunk(chunk);
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
              final telemetry = DeviceTelemetry.fromJson(msg.params!);
              _telemetryController.add(telemetry);
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
    _videoSocket?.destroy();
    _videoSocket = null;

    _controlSocket?.destroy();
    _controlSocket = null;

    _decoder.reset();
    _setState(CamSyncConnectionState.disconnected);
  }

  void dispose() {
    disconnect();
    _stateController.close();
    _telemetryController.close();
  }
}
