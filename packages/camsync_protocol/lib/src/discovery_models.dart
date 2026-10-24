import 'dart:convert';
import 'constants.dart';

/// Represents an auto-discovered CamSync mobile device on the local network.
class DiscoveredDevice {
  final String name;
  final String ip;
  final int videoPort;
  final int controlPort;
  final String version;
  final DateTime lastSeen;

  const DiscoveredDevice({
    required this.name,
    required this.ip,
    this.videoPort = CamSyncConstants.defaultVideoPort,
    this.controlPort = CamSyncConstants.defaultControlPort,
    this.version = '1.0.1',
    required this.lastSeen,
  });

  Map<String, dynamic> toJson() => {
        'camsync': 'beacon',
        'device': name,
        'ip': ip,
        'videoPort': videoPort,
        'controlPort': controlPort,
        'version': version,
      };

  factory DiscoveredDevice.fromJson(Map<String, dynamic> json, {String? senderIp}) {
    final rawIp = json['ip'] as String?;
    final resolvedIp = (rawIp != null && rawIp.isNotEmpty && rawIp != '0.0.0.0' && rawIp != 'Discovering...')
        ? rawIp
        : (senderIp ?? '127.0.0.1');

    return DiscoveredDevice(
      name: json['device'] as String? ?? 'CamSync Device',
      ip: resolvedIp,
      videoPort: (json['videoPort'] as num?)?.toInt() ?? CamSyncConstants.defaultVideoPort,
      controlPort: (json['controlPort'] as num?)?.toInt() ?? CamSyncConstants.defaultControlPort,
      version: json['version'] as String? ?? '1.0.1',
      lastSeen: DateTime.now(),
    );
  }

  String encode() => jsonEncode(toJson());

  static DiscoveredDevice? parsePayload(String raw, {String? senderIp}) {
    try {
      final decoded = jsonDecode(raw.trim()) as Map<String, dynamic>;
      if (decoded['camsync'] == 'beacon') {
        return DiscoveredDevice.fromJson(decoded, senderIp: senderIp);
      }
    } catch (_) {}
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DiscoveredDevice &&
          runtimeType == other.runtimeType &&
          ip == other.ip;

  @override
  int get hashCode => ip.hashCode;
}
