import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:camsync_protocol/camsync_protocol.dart';

void main() {
  group('CamSyncPacket', () {
    test('encodes and decodes standard IDR packet correctly', () {
      final payload = Uint8List.fromList([0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84]);
      final original = CamSyncPacket(
        frameType: FrameType.keyframe,
        sequenceNumber: 1042,
        timestampMs: 45000,
        payload: payload,
      );

      final encoded = original.encode();
      expect(encoded.length, equals(CamSyncConstants.headerSize + payload.length));

      final decoded = CamSyncPacket.decode(encoded);
      expect(decoded.version, equals(CamSyncConstants.protocolVersion));
      expect(decoded.frameType, equals(FrameType.keyframe));
      expect(decoded.sequenceNumber, equals(1042));
      expect(decoded.timestampMs, equals(45000));
      expect(decoded.payload, equals(payload));
    });

    test('throws FormatException on corrupted magic header', () {
      final invalidBytes = Uint8List(25);
      final byteData = ByteData.sublistView(invalidBytes);
      byteData.setUint32(0, 0x12345678); // Wrong magic

      expect(() => CamSyncPacket.decode(invalidBytes), throwsFormatException);
    });

    test('throws FormatException on truncated packet buffer', () {
      final payload = Uint8List(100);
      final packet = CamSyncPacket(
        frameType: FrameType.delta,
        sequenceNumber: 1,
        timestampMs: 16,
        payload: payload,
      );
      final encoded = packet.encode();
      // Cut off last 10 bytes
      final truncated = Uint8List.sublistView(encoded, 0, encoded.length - 10);

      expect(() => CamSyncPacket.decode(truncated), throwsFormatException);
    });
  });

  group('PacketStreamDecoder', () {
    test('reassembles packets across split stream chunks', () {
      final decoder = PacketStreamDecoder();
      final payload = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
      final packet = CamSyncPacket(
        frameType: FrameType.delta,
        sequenceNumber: 42,
        timestampMs: 120,
        payload: payload,
      );
      final encoded = packet.encode();

      // Split into 3 arbitrary chunks: 5 bytes, 10 bytes, remainder
      final chunk1 = Uint8List.sublistView(encoded, 0, 5);
      final chunk2 = Uint8List.sublistView(encoded, 5, 15);
      final chunk3 = Uint8List.sublistView(encoded, 15);

      expect(decoder.addChunk(chunk1), isEmpty);
      expect(decoder.addChunk(chunk2), isEmpty);

      final result = decoder.addChunk(chunk3);
      expect(result.length, equals(1));
      expect(result.first.sequenceNumber, equals(42));
      expect(result.first.payload, equals(payload));
    });

    test('extracts multiple packets from a single large chunk', () {
      final decoder = PacketStreamDecoder();
      final p1 = CamSyncPacket(
        frameType: FrameType.config,
        sequenceNumber: 1,
        timestampMs: 0,
        payload: Uint8List.fromList([0x67, 0x42]),
      );
      final p2 = CamSyncPacket(
        frameType: FrameType.keyframe,
        sequenceNumber: 2,
        timestampMs: 16,
        payload: Uint8List.fromList([0x65, 0x01, 0x02]),
      );

      final combined = BytesBuilder();
      combined.add(p1.encode());
      combined.add(p2.encode());

      final results = decoder.addChunk(combined.toBytes());
      expect(results.length, equals(2));
      expect(results[0].frameType, equals(FrameType.config));
      expect(results[1].frameType, equals(FrameType.keyframe));
    });

    test('recovers from leading garbage bytes via resync', () {
      final decoder = PacketStreamDecoder();
      final packet = CamSyncPacket(
        frameType: FrameType.delta,
        sequenceNumber: 99,
        timestampMs: 333,
        payload: Uint8List.fromList([0xAA, 0xBB]),
      );
      final valid = packet.encode();

      final garbage = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11]);
      final streamBytes = BytesBuilder();
      streamBytes.add(garbage);
      streamBytes.add(valid);

      final results = decoder.addChunk(streamBytes.toBytes());
      expect(results.length, equals(1));
      expect(results.first.sequenceNumber, equals(99));
      expect(results.first.payload, equals(Uint8List.fromList([0xAA, 0xBB])));
    });
  });
}
