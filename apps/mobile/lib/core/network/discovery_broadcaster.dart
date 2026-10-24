import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:camsync_protocol/camsync_protocol.dart';

/// Manages UDP discovery beacon broadcasting from mobile to local Wi-Fi.
class DiscoveryBroadcaster {
  final int videoPort;
  final int controlPort;
  final int discoveryPort;

  String deviceName;
  String localIp;

  RawDatagramSocket? _broadcastSocket;
  RawDatagramSocket? _listenSocket;
  Timer? _beaconTimer;
  bool _isRunning = false;

  DiscoveryBroadcaster({
    this.videoPort = CamSyncConstants.defaultVideoPort,
    this.controlPort = CamSyncConstants.defaultControlPort,
    this.discoveryPort = CamSyncConstants.defaultDiscoveryPort,
    this.deviceName = 'CamSync Device',
    this.localIp = '127.0.0.1',
  });

  void updateInfo({String? name, String? ip}) {
    if (name != null && name.isNotEmpty) deviceName = name;
    if (ip != null && ip.isNotEmpty) localIp = ip;
  }

  Future<void> start() async {
    if (_isRunning) return;
    _isRunning = true;

    try {
      // 1. Socket for broadcasting beacons
      _broadcastSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _broadcastSocket?.broadcastEnabled = true;

      // 2. Socket for listening to desktop probe queries on discoveryPort
      try {
        _listenSocket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          discoveryPort,
          reuseAddress: true,
          reusePort: true,
        );
        _listenSocket?.broadcastEnabled = true;
        _listenSocket?.listen((event) {
          if (event == RawSocketEvent.read) {
            final dg = _listenSocket?.receive();
            if (dg != null) {
              final text = utf8.decode(dg.data, allowMalformed: true).trim();
              if (text.contains('probe')) {
                _sendBeaconTo(dg.address, dg.port);
              }
            }
          }
        });
      } catch (_) {}

      // 3. Periodic broadcast timer (every 1.5 seconds)
      _beaconTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
        _broadcastBeacon();
      });

      // Send initial beacon immediately
      _broadcastBeacon();
    } catch (_) {}
  }

  void _broadcastBeacon() {
    if (_broadcastSocket == null || localIp == 'Discovering...' || localIp.isEmpty) return;

    final device = DiscoveredDevice(
      name: deviceName,
      ip: localIp,
      videoPort: videoPort,
      controlPort: controlPort,
      lastSeen: DateTime.now(),
    );

    final payload = utf8.encode(device.encode());

    // Broadcast to generic local broadcast
    try {
      _broadcastSocket?.send(payload, InternetAddress('255.255.255.255'), discoveryPort);
    } catch (_) {}

    // Broadcast to subnet broadcast (e.g. 192.168.100.255)
    final parts = localIp.split('.');
    if (parts.length == 4) {
      final subnetBroadcast = '${parts[0]}.${parts[1]}.${parts[2]}.255';
      try {
        _broadcastSocket?.send(payload, InternetAddress(subnetBroadcast), discoveryPort);
      } catch (_) {}
    }
  }

  void _sendBeaconTo(InternetAddress address, int port) {
    if (_broadcastSocket == null) return;
    final device = DiscoveredDevice(
      name: deviceName,
      ip: localIp,
      videoPort: videoPort,
      controlPort: controlPort,
      lastSeen: DateTime.now(),
    );
    final payload = utf8.encode(device.encode());
    try {
      _broadcastSocket?.send(payload, address, port);
    } catch (_) {}
  }

  void stop() {
    _isRunning = false;
    _beaconTimer?.cancel();
    _beaconTimer = null;
    _broadcastSocket?.close();
    _broadcastSocket = null;
    _listenSocket?.close();
    _listenSocket = null;
  }
}
