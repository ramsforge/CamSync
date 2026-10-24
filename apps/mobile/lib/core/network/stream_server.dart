import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:camsync_protocol/camsync_protocol.dart';

/// Manages dual TCP socket servers on the phone:
/// 1. Video Stream Server (port 8282): dispatches raw binary H.264 packets.
/// 2. Control Server (port 8283): bidirectional JSON-RPC control and telemetry.
class MobileStreamServer {
  final int videoPort;
  final int controlPort;

  ServerSocket? _videoServer;
  ServerSocket? _controlServer;

  final List<Socket> _videoClients = [];
  final List<Socket> _controlClients = [];

  final StreamController<ControlRpcMessage> _controlMessageController =
      StreamController<ControlRpcMessage>.broadcast();

  final StreamController<int> _clientCountController =
      StreamController<int>.broadcast();

  Stream<ControlRpcMessage> get onControlMessage => _controlMessageController.stream;
  Stream<int> get onClientCountChanged => _clientCountController.stream;

  int get connectedClientsCount => _videoClients.length;

  MobileStreamServer({
    this.videoPort = CamSyncConstants.defaultVideoPort,
    this.controlPort = CamSyncConstants.defaultControlPort,
  });

  /// Starts listening for incoming connections from PC (Wi-Fi or ADB forward).
  Future<void> start() async {
    await stop();

    // Native Kotlin VideoStreamingServer handles port 8282 with zero-copy.
    // Dart manages port 8283 for bidirectional JSON-RPC control and telemetry.
    _controlServer = await ServerSocket.bind(
      InternetAddress.anyIPv4,
      controlPort,
      shared: false,
    );
    _controlServer?.listen(_onControlClientConnected);
  }

  void _onControlClientConnected(Socket socket) {
    socket.setOption(SocketOption.tcpNoDelay, true);
    _controlClients.add(socket);

    final lineSplitter = utf8.decoder.bind(socket);
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
            _controlMessageController.add(msg);
          } catch (e) {
            // Ignore malformed control line
          }
        }
      }
    }, onDone: () {
      _controlClients.remove(socket);
    }, onError: (_) {
      _controlClients.remove(socket);
    });
  }

  /// Sends a binary video packet to all connected PC clients.
  void broadcastVideoPacket(CamSyncPacket packet) {
    if (_videoClients.isEmpty) return;
    final encoded = packet.encode();
    for (final client in List<Socket>.from(_videoClients)) {
      try {
        client.add(encoded);
      } catch (e) {
        _videoClients.remove(client);
        _clientCountController.add(_videoClients.length);
      }
    }
  }

  /// Sends raw pre-encoded video packet bytes to all connected clients.
  void broadcastRawVideoBytes(Uint8List bytes) {
    if (_videoClients.isEmpty) return;
    for (final client in List<Socket>.from(_videoClients)) {
      try {
        client.add(bytes);
      } catch (e) {
        _videoClients.remove(client);
        _clientCountController.add(_videoClients.length);
      }
    }
  }

  /// Broadcasts a JSON-RPC message (e.g. telemetry) on the control channel.
  void broadcastControlMessage(ControlRpcMessage message) {
    if (_controlClients.isEmpty) return;
    final encoded = message.encode();
    for (final client in List<Socket>.from(_controlClients)) {
      try {
        client.write(encoded);
      } catch (e) {
        _controlClients.remove(client);
      }
    }
  }

  Future<void> stop() async {
    for (final c in _videoClients) {
      try {
        c.destroy();
      } catch (_) {}
    }
    _videoClients.clear();

    for (final c in _controlClients) {
      try {
        c.destroy();
      } catch (_) {}
    }
    _controlClients.clear();

    await _videoServer?.close();
    _videoServer = null;

    await _controlServer?.close();
    _controlServer = null;

    if (!_clientCountController.isClosed) {
      _clientCountController.add(0);
    }
  }

  void dispose() {
    _controlMessageController.close();
    _clientCountController.close();
    stop();
  }
}
