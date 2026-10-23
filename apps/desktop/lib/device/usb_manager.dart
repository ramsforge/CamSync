import 'dart:async';
import 'dart:io';

class UsbDevice {
  final String id;
  final String model;
  final String platform; // 'Android' or 'iOS'

  const UsbDevice({
    required this.id,
    required this.model,
    required this.platform,
  });
}

/// Manages USB detection and automated port forwarding (ADB for Android, usbmuxd for iOS).
class UsbManager {
  Timer? _pollTimer;
  final StreamController<List<UsbDevice>> _devicesController =
      StreamController<List<UsbDevice>>.broadcast();

  Stream<List<UsbDevice>> get onDevicesChanged => _devicesController.stream;
  List<UsbDevice> _currentDevices = [];
  List<UsbDevice> get currentDevices => List.unmodifiable(_currentDevices);

  String? _adbPath;

  UsbManager() {
    _locateAdb();
  }

  void _locateAdb() {
    final candidates = [
      'adb',
      'adb.exe',
      r'..\..\native\usb_bridge\adb\adb.exe',
      Platform.environment['LOCALAPPDATA'] != null
          ? '${Platform.environment['LOCALAPPDATA']}\\Android\\Sdk\\platform-tools\\adb.exe'
          : null,
    ];

    for (final c in candidates) {
      if (c == null) continue;
      try {
        final res = Process.runSync(c, ['version']);
        if (res.exitCode == 0) {
          _adbPath = c;
          break;
        }
      } catch (_) {}
    }
  }

  void startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => checkDevices());
    checkDevices();
  }

  void stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> checkDevices() async {
    final devices = <UsbDevice>[];

    // Check Android ADB devices
    if (_adbPath != null) {
      try {
        final result = await Process.run(_adbPath!, ['devices', '-l']);
        if (result.exitCode == 0) {
          final lines = (result.stdout as String).split('\n');
          for (final line in lines) {
            final trimmed = line.trim();
            if (trimmed.isEmpty || trimmed.startsWith('List of devices')) continue;

            final parts = trimmed.split(RegExp(r'\s+'));
            if (parts.length >= 2 && parts[1] == 'device') {
              final serial = parts[0];
              String model = 'Android Device';
              for (final p in parts) {
                if (p.startsWith('model:')) {
                  model = p.substring(6).replaceAll('_', ' ');
                }
              }
              devices.add(UsbDevice(id: serial, model: model, platform: 'Android'));

              // Automatically set up port forwarding
              await setupPortForwarding(serial);
            }
          }
        }
      } catch (_) {}
    }

    _currentDevices = devices;
    _devicesController.add(devices);
  }

  /// Sets up ADB port forward for video and control channels over USB.
  Future<bool> setupPortForwarding(String serial) async {
    if (_adbPath == null) return false;
    try {
      final res1 = await Process.run(_adbPath!, ['-s', serial, 'forward', 'tcp:8282', 'tcp:8282']);
      final res2 = await Process.run(_adbPath!, ['-s', serial, 'forward', 'tcp:8283', 'tcp:8283']);
      return res1.exitCode == 0 && res2.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  void dispose() {
    stopPolling();
    _devicesController.close();
  }
}
