import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:camsync_protocol/camsync_protocol.dart';

/// Background service on Windows companion for auto-discovering mobile phones over Wi-Fi.
/// Uses a hybrid approach:
/// 1. UDP Broadcast Listener & Probes (instant for Android)
/// 2. Active Parallel Subnet Probing (instant for iOS & networks where router blocks UDP broadcast)
class DeviceDiscoveryService {
  final int discoveryPort;

  RawDatagramSocket? _socket;
  Timer? _probeTimer;
  Timer? _pruneTimer;
  Timer? _scanTimer;
  bool _isScanning = false;

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
        reusePort: !Platform.isWindows,
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

      // 1. Send UDP probe query every 2 seconds
      _probeTimer = Timer.periodic(const Duration(seconds: 2), (_) => sendProbe());
      sendProbe();

      // 2. Active TCP subnet scanning (for iOS devices where Apple sandbox restricts raw UDP broadcast)
      _scanTimer = Timer.periodic(const Duration(seconds: 3), (_) => scanSubnets());
      scanSubnets();

      // 3. Prune stale devices older than 7 seconds
      _pruneTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        final now = DateTime.now();
        final before = _devices.length;
        _devices.removeWhere((_, d) => now.difference(d.lastSeen).inSeconds > 7);
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

  /// Rapidly checks all hosts on local subnets for open CamSync video port (8282).
  /// Runs fully asynchronously in parallel (taking ~250-300ms total).
  Future<void> scanSubnets() async {
    if (_isScanning) return;
    _isScanning = true;

    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.isLoopback || addr.address.startsWith('169.254')) continue;
          final parts = addr.address.split('.');
          if (parts.length != 4) continue;
          final subnet = '${parts[0]}.${parts[1]}.${parts[2]}';

          final futures = <Future>[];
          for (int i = 1; i <= 254; i++) {
            final targetIp = '$subnet.$i';
            if (targetIp == addr.address) continue;

            futures.add(() async {
              try {
                final s = await Socket.connect(
                  targetIp,
                  CamSyncConstants.defaultVideoPort,
                  timeout: const Duration(milliseconds: 250),
                );
                s.destroy();

                final existing = _devices[targetIp];
                if (existing != null) {
                  _devices[targetIp] = DiscoveredDevice(
                    name: existing.name,
                    ip: existing.ip,
                    videoPort: existing.videoPort,
                    controlPort: existing.controlPort,
                    lastSeen: DateTime.now(),
                  );
                } else {
                  _devices[targetIp] = DiscoveredDevice(
                    name: 'Apple / iOS Device',
                    ip: targetIp,
                    videoPort: CamSyncConstants.defaultVideoPort,
                    controlPort: CamSyncConstants.defaultControlPort,
                    lastSeen: DateTime.now(),
                  );
                  _controller.add(_devices.values.toList());
                }
              } catch (_) {}
            }());
          }
          await Future.wait(futures);
        }
      }
    } catch (_) {} finally {
      _isScanning = false;
    }
  }

  Future<void> stop() async {
    _probeTimer?.cancel();
    _probeTimer = null;
    _scanTimer?.cancel();
    _scanTimer = null;
    _pruneTimer?.cancel();
    _pruneTimer = null;
    _socket?.close();
    _socket = null;
    _isScanning = false;
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
