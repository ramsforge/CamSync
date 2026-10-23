/// Constants for CamSync streaming protocol and IPC.
class CamSyncConstants {
  CamSyncConstants._();

  /// Magic bytes for the binary packet header: 'CSNC' (0x43534E43).
  static const int magic = 0x43534E43;

  /// Current protocol version.
  static const int protocolVersion = 1;

  /// Header length in bytes.
  static const int headerSize = 20;

  /// Default TCP/UDP port for raw video stream data.
  static const int defaultVideoPort = 8282;

  /// Default TCP port for bidirectional JSON-RPC control and telemetry.
  static const int defaultControlPort = 8283;

  /// mDNS service discovery type.
  static const String mdnsServiceType = '_camsync._tcp';

  /// Shared memory identifier for Windows IPC.
  static const String sharedMemoryName = r'Global\CamSyncSharedBuffer';

  /// Windows Event signaled when a new video frame is ready in shared memory.
  static const String frameEventName = r'Global\CamSyncNewFrameEvent';

  /// Windows Mutex for synchronizing shared memory read/write.
  static const String frameMutexName = r'Global\CamSyncFrameMutex';
}

/// Video frame classification.
enum FrameType {
  /// Codec configuration metadata (H.264 SPS/PPS or HEVC VPS/SPS/PPS).
  config(0x01),

  /// Keyframe / Instantaneous Decoder Refresh (IDR).
  keyframe(0x02),

  /// Inter-frame / Predicted frame (P-Frame).
  delta(0x03);

  final int value;
  const FrameType(this.value);

  static FrameType fromValue(int val) {
    switch (val) {
      case 0x01:
        return FrameType.config;
      case 0x02:
        return FrameType.keyframe;
      case 0x03:
        return FrameType.delta;
      default:
        throw ArgumentError('Unknown frame type value: $val');
    }
  }
}

/// Supported hardware video codecs.
enum VideoCodec {
  h264(0x01, 'H.264 / AVC'),
  hevc(0x02, 'H.265 / HEVC');

  final int value;
  final String displayName;
  const VideoCodec(this.value, this.displayName);

  static VideoCodec fromValue(int val) {
    switch (val) {
      case 0x01:
        return VideoCodec.h264;
      case 0x02:
        return VideoCodec.hevc;
      default:
        throw ArgumentError('Unknown video codec value: $val');
    }
  }
}
