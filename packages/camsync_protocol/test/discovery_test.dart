import 'package:test/test.dart';
import 'package:camsync_protocol/camsync_protocol.dart';

void main() {
  group('DiscoveredDevice', () {
    test('serializes and parses discovery beacon payload', () {
      final device = DiscoveredDevice(
        name: 'iPhone 12',
        ip: '192.168.1.100',
        videoPort: 8282,
        controlPort: 8283,
        version: '1.0.1',
        lastSeen: DateTime.now(),
      );

      final encoded = device.encode();
      final parsed = DiscoveredDevice.parsePayload(encoded, senderIp: '192.168.1.100');

      expect(parsed, isNotNull);
      expect(parsed!.name, 'iPhone 12');
      expect(parsed.ip, '192.168.1.100');
      expect(parsed.videoPort, 8282);
      expect(parsed.controlPort, 8283);
      expect(parsed.version, '1.0.1');
    });

    test('ignores non-beacon JSON messages', () {
      final parsed = DiscoveredDevice.parsePayload('{"camsync":"probe"}');
      expect(parsed, isNull);
    });
  });
}
