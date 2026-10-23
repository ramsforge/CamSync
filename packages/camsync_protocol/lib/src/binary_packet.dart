import 'dart:async';
import 'dart:typed_data';
import 'constants.dart';

/// Represents a discrete video packet in the CamSync stream.
class CamSyncPacket {
  final int version;
  final FrameType frameType;
  final int sequenceNumber;
  final int timestampMs;
  final Uint8List payload;

  const CamSyncPacket({
    this.version = CamSyncConstants.protocolVersion,
    required this.frameType,
    required this.sequenceNumber,
    required this.timestampMs,
    required this.payload,
  });

  /// Encodes this packet into a contiguous binary byte buffer with the 20-byte header.
  Uint8List encode() {
    final totalSize = CamSyncConstants.headerSize + payload.length;
    final buffer = Uint8List(totalSize);
    final byteData = ByteData.sublistView(buffer);

    // 0..3: Magic
    byteData.setUint32(0, CamSyncConstants.magic, Endian.big);
    // 4: Version
    byteData.setUint8(4, version);
    // 5: FrameType
    byteData.setUint8(5, frameType.value);
    // 6..7: Reserved
    byteData.setUint16(6, 0, Endian.big);
    // 8..11: Sequence Number
    byteData.setUint32(8, sequenceNumber, Endian.big);
    // 12..15: Timestamp (ms)
    byteData.setUint32(12, timestampMs, Endian.big);
    // 16..19: Payload length
    byteData.setUint32(16, payload.length, Endian.big);

    // Payload
    buffer.setRange(CamSyncConstants.headerSize, totalSize, payload);
    return buffer;
  }

  /// Deserializes a single packet from a complete binary buffer.
  /// Throws [FormatException] if the header is malformed.
  static CamSyncPacket decode(Uint8List data) {
    if (data.length < CamSyncConstants.headerSize) {
      throw const FormatException('Buffer smaller than header size');
    }

    final byteData = ByteData.sublistView(data);
    final magic = byteData.getUint32(0, Endian.big);
    if (magic != CamSyncConstants.magic) {
      throw FormatException('Invalid magic header: 0x${magic.toRadixString(16)}');
    }

    final version = byteData.getUint8(4);
    final frameTypeValue = byteData.getUint8(5);
    final frameType = FrameType.fromValue(frameTypeValue);
    final sequenceNumber = byteData.getUint32(8, Endian.big);
    final timestampMs = byteData.getUint32(12, Endian.big);
    final payloadLength = byteData.getUint32(16, Endian.big);

    if (data.length < CamSyncConstants.headerSize + payloadLength) {
      throw FormatException(
        'Truncated packet: expected ${CamSyncConstants.headerSize + payloadLength} bytes, got ${data.length}',
      );
    }

    final payload = Uint8List.sublistView(
      data,
      CamSyncConstants.headerSize,
      CamSyncConstants.headerSize + payloadLength,
    );

    return CamSyncPacket(
      version: version,
      frameType: frameType,
      sequenceNumber: sequenceNumber,
      timestampMs: timestampMs,
      payload: payload,
    );
  }
}

/// Accumulates streaming socket chunks and parses them into full [CamSyncPacket]s.
class PacketStreamDecoder {
  final BytesBuilder _buffer = BytesBuilder(copy: false);

  /// Feeds a chunk of raw bytes received from a TCP socket or stream.
  /// Returns a list of all fully-reassembled [CamSyncPacket]s parsed from this chunk.
  List<CamSyncPacket> addChunk(Uint8List chunk) {
    _buffer.add(chunk);
    final packets = <CamSyncPacket>[];

    while (true) {
      final currentBytes = _buffer.toBytes();
      if (currentBytes.length < CamSyncConstants.headerSize) {
        break;
      }

      final byteData = ByteData.sublistView(currentBytes);
      final magic = byteData.getUint32(0, Endian.big);

      // Resync logic if stream is out of alignment: scan forward for magic bytes
      if (magic != CamSyncConstants.magic) {
        int resyncIndex = -1;
        for (int i = 1; i <= currentBytes.length - 4; i++) {
          if (byteData.getUint32(i, Endian.big) == CamSyncConstants.magic) {
            resyncIndex = i;
            break;
          }
        }
        if (resyncIndex != -1) {
          final remainder = Uint8List.sublistView(currentBytes, resyncIndex);
          _buffer.clear();
          _buffer.add(remainder);
          continue;
        } else {
          // Keep only the last 3 bytes in case magic is split across chunks
          final keepCount = currentBytes.length > 3 ? 3 : currentBytes.length;
          final tail = Uint8List.sublistView(currentBytes, currentBytes.length - keepCount);
          _buffer.clear();
          _buffer.add(tail);
          break;
        }
      }

      final payloadLength = byteData.getUint32(16, Endian.big);
      final totalPacketLength = CamSyncConstants.headerSize + payloadLength;

      if (currentBytes.length < totalPacketLength) {
        // Incomplete packet; wait for more socket data
        break;
      }

      final packetData = Uint8List.sublistView(currentBytes, 0, totalPacketLength);
      packets.add(CamSyncPacket.decode(packetData));

      // Advance buffer past this packet
      final remaining = Uint8List.sublistView(currentBytes, totalPacketLength);
      _buffer.clear();
      _buffer.add(remaining);
    }

    return packets;
  }

  /// Clears internal buffer.
  void reset() {
    _buffer.clear();
  }
}
