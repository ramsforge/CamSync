import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'dart:typed_data';

// C Signatures
typedef _c_init = Int32 Function();
typedef _c_write_frame = Int32 Function(
  Pointer<Uint8> pData,
  Uint32 width,
  Uint32 height,
  Uint32 pixelFormat,
  Uint64 timestampNs,
);
typedef _c_feed_nal = Int32 Function(
  Pointer<Uint8> pNalData,
  Uint32 nalSize,
  Uint32 frameType,
  Uint64 timestampMs,
);
typedef _c_is_active = Int32 Function();
typedef _c_set_format = Int32 Function(Uint32 width, Uint32 height);
typedef _c_set_mirror = Void Function(Int32 mirrored);
typedef _c_get_latest_frame = Int32 Function(
  Pointer<Uint8> pOutBuffer,
  Uint32 bufferSize,
  Pointer<Uint32> pWidth,
  Pointer<Uint32> pHeight,
  Pointer<Uint64> pFrameNumber,
);
typedef _c_close = Void Function();

// Dart Signatures
typedef _d_init = int Function();
typedef _d_write_frame = int Function(
  Pointer<Uint8> pData,
  int width,
  int height,
  int pixelFormat,
  int timestampNs,
);
typedef _d_feed_nal = int Function(
  Pointer<Uint8> pNalData,
  int nalSize,
  int frameType,
  int timestampMs,
);
typedef _d_is_active = int Function();
typedef _d_set_format = int Function(int width, int height);
typedef _d_set_mirror = void Function(int mirrored);
typedef _d_get_latest_frame = int Function(
  Pointer<Uint8> pOutBuffer,
  int bufferSize,
  Pointer<Uint32> pWidth,
  Pointer<Uint32> pHeight,
  Pointer<Uint64> pFrameNumber,
);
typedef _d_close = void Function();

class DecodedFrame {
  final Uint8List bgraBytes;
  final int width;
  final int height;
  final int frameNumber;

  DecodedFrame({
    required this.bgraBytes,
    required this.width,
    required this.height,
    required this.frameNumber,
  });
}

class CamSyncNative {
  static CamSyncNative? _instance;
  late final DynamicLibrary _dylib;

  late final _d_init _init;
  late final _d_write_frame _writeFrame;
  late final _d_feed_nal _feedNal;
  late final _d_is_active _isActive;
  late final _d_set_format _setFormat;
  late final _d_set_mirror _setMirror;
  late final _d_get_latest_frame _getLatestFrame;
  late final _d_close _close;

  Pointer<Uint8>? _frameBuffer;
  int _frameBufferSize = 0;
  final Pointer<Uint32> _pWidth = calloc<Uint32>();
  final Pointer<Uint32> _pHeight = calloc<Uint32>();
  final Pointer<Uint64> _pFrameNumber = calloc<Uint64>();

  bool _initialized = false;
  bool get isInitialized => _initialized;

  factory CamSyncNative() {
    _instance ??= CamSyncNative._internal();
    return _instance!;
  }

  CamSyncNative._internal() {
    _loadLibrary();
  }

  void _loadLibrary() {
    final possiblePaths = [
      'camsync_native.dll',
      r'build64\Release\camsync_native.dll',
      r'C:\Ramzy\CamSync\build64\Release\camsync_native.dll',
      r'..\..\build\native\Release\camsync_native.dll',
      r'build\native\Release\camsync_native.dll',
      r'C:\Ramzy\CamSync\build\native\Release\camsync_native.dll',
    ];

    DynamicLibrary? lib;
    for (final path in possiblePaths) {
      if (File(path).existsSync()) {
        try {
          lib = DynamicLibrary.open(path);
          break;
        } catch (_) {}
      }
    }

    lib ??= DynamicLibrary.open(r'C:\Ramzy\CamSync\build64\Release\camsync_native.dll');
    _dylib = lib;

    try {
      _init = _dylib.lookupFunction<_c_init, _d_init>('CamSync_Init');
    } catch (_) {
      _init = () => 0;
    }
    try {
      _writeFrame = _dylib.lookupFunction<_c_write_frame, _d_write_frame>('CamSync_WriteFrame');
    } catch (_) {
      _writeFrame = (p, w, h, f, t) => 0;
    }
    try {
      _feedNal = _dylib.lookupFunction<_c_feed_nal, _d_feed_nal>('CamSync_FeedH264Nal');
    } catch (_) {
      _feedNal = (p, l, f, t) => 0;
    }
    try {
      _isActive = _dylib.lookupFunction<_c_is_active, _d_is_active>('CamSync_IsVirtualCamActive');
    } catch (_) {
      _isActive = () => 0;
    }
    try {
      _setFormat = _dylib.lookupFunction<_c_set_format, _d_set_format>('CamSync_SetVideoFormat');
    } catch (_) {
      _setFormat = (w, h) => 0;
    }
    try {
      _setMirror = _dylib.lookupFunction<_c_set_mirror, _d_set_mirror>('CamSync_SetMirror');
    } catch (_) {
      _setMirror = (m) {};
    }
    try {
      _getLatestFrame = _dylib.lookupFunction<_c_get_latest_frame, _d_get_latest_frame>('CamSync_GetLatestFrame');
    } catch (_) {
      _getLatestFrame = (b, s, w, h, fn) => 0;
    }
    try {
      _close = _dylib.lookupFunction<_c_close, _d_close>('CamSync_Close');
    } catch (_) {
      _close = () {};
    }
  }

  bool init() {
    if (_initialized) return true;
    final res = _init();
    _initialized = (res == 1);
    return _initialized;
  }

  bool writeFrame({
    required Uint8List frameBytes,
    required int width,
    required int height,
    required int pixelFormat,
    required int timestampNs,
  }) {
    if (!_initialized) return false;

    final ptr = calloc<Uint8>(frameBytes.length);
    ptr.asTypedList(frameBytes.length).setAll(0, frameBytes);

    final res = _writeFrame(ptr, width, height, pixelFormat, timestampNs);
    calloc.free(ptr);
    return res == 1;
  }

  bool feedNal({
    required Uint8List nalBytes,
    required int frameType,
    required int timestampMs,
  }) {
    if (!_initialized) return false;

    final ptr = calloc<Uint8>(nalBytes.length);
    ptr.asTypedList(nalBytes.length).setAll(0, nalBytes);

    final res = _feedNal(ptr, nalBytes.length, frameType, timestampMs);
    calloc.free(ptr);
    return res == 1;
  }

  bool setVideoFormat(int width, int height) {
    if (!_initialized) return false;
    return _setFormat(width, height) == 1;
  }

  void setMirror(bool mirrored) {
    if (!_initialized) return;
    _setMirror(mirrored ? 1 : 0);
  }

  bool isVirtualCamActive() {
    if (!_initialized) return false;
    return _isActive() == 1;
  }

  DecodedFrame? getLatestFrame() {
    if (!_initialized) return null;
    const maxNeeded = 1920 * 1080 * 4;
    if (_frameBuffer == null || _frameBufferSize < maxNeeded) {
      if (_frameBuffer != null) calloc.free(_frameBuffer!);
      _frameBuffer = calloc<Uint8>(maxNeeded);
      _frameBufferSize = maxNeeded;
    }

    final res = _getLatestFrame(_frameBuffer!, _frameBufferSize, _pWidth, _pHeight, _pFrameNumber);
    if (res != 1) return null;

    final w = _pWidth.value;
    final h = _pHeight.value;
    final num = _pFrameNumber.value;
    final size = w * h * 4;

    return DecodedFrame(
      bgraBytes: Uint8List.fromList(_frameBuffer!.asTypedList(size)),
      width: w,
      height: h,
      frameNumber: num,
    );
  }

  void close() {
    if (_initialized) {
      _close();
      _initialized = false;
    }
  }
}
