import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:camsync_protocol/camsync_protocol.dart';

/// Background service on Windows companion for auto-discovering mobile phones over Wi-Fi.
class DeviceDiscoveryService {
  final int discoveryPort;

  RawDatagramSocket? _socket;
  Timer? _probeTimer;
  Timer? _pruneTimer;

  final Map<String, DiscoveredDevice> _devices = {};
  final StreamController<List<DiscoveredDevice>> _controller =
      StreamController<List<DiscoveredDevice>>.broadcast();

  Stream<List<DiscoveredDevice>> get onDevicesChanged => _controller.stream;
  List<DiscoveredDevice> get currentDevices => _devices.values.toList();

  DeviceDiscoveryService({
    this.discoveryPort = CamSyncConstants.defaultDiscoveryPort,
  });

  Future<void> start() async {
    await stop();

    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
        reusePort: true,
      );
      _socket?.broadcastEnabled = true;

      _socket?.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = _socket?.receive();
          if (dg != null) {
            final text = utf8.decode(dg.data, allowMalformed: true).trim();
            final device = DiscoveredDevice.parsePayload(text, senderIp: dg.address.address);
            if (device != null) {
              _devices[device.ip] = device;
              _controller.add(_devices.values.toList());
            }
          }
        }
      });

      // Send probe query every 2 seconds
      _probeTimer = Timer.periodic(const Duration(seconds: 2), (_) => sendProbe());
      sendProbe();

      // Prune stale devices older than 5 seconds
      _pruneTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        final now = DateTime.now();
        final before = _devices.length;
        _devices.removeWhere((_, d) => now.difference(d.lastSeen).inSeconds > 5);
        if (_devices.length != before) {
          _controller.add(_devices.values.toList());
        }
      });
    } catch (_) {}
  }

  void sendProbe() {
    if (_socket == null) return;
    final payload = utf8.encode(jsonEncode({'camsync': 'probe'}));
    try {
      _socket?.send(payload, InternetAddress('255.255.255.255'), discoveryPort);
    } catch (_) {}
  }

  Future<void> stop() async {
    _probeTimer?.cancel();
    _probeTimer = null;
    _pruneTimer?.cancel();
    _pruneTimer = null;
    _socket?.close();
    _socket = null;
    _devices.clear();
    if (!_controller.isClosed) {
      _controller.add([]);
    }
  }

  void dispose() {
    stop();
    _controller.close();
  }
}
