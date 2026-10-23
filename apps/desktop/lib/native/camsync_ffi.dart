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
typedef _d_close = void Function();

class CamSyncNative {
  static CamSyncNative? _instance;
  late final DynamicLibrary _dylib;

  late final _d_init _init;
  late final _d_write_frame _writeFrame;
  late final _d_feed_nal _feedNal;
  late final _d_is_active _isActive;
  late final _d_close _close;

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

    lib ??= DynamicLibrary.open(r'C:\Ramzy\CamSync\build\native\Release\camsync_native.dll');
    _dylib = lib;

    _init = _dylib.lookupFunction<_c_init, _d_init>('CamSync_Init');
    _writeFrame = _dylib.lookupFunction<_c_write_frame, _d_write_frame>('CamSync_WriteFrame');
    _feedNal = _dylib.lookupFunction<_c_feed_nal, _d_feed_nal>('CamSync_FeedH264Nal');
    _isActive = _dylib.lookupFunction<_c_is_active, _d_is_active>('CamSync_IsVirtualCamActive');
    _close = _dylib.lookupFunction<_c_close, _d_close>('CamSync_Close');
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

  bool isVirtualCamActive() {
    if (!_initialized) return false;
    return _isActive() == 1;
  }

  void close() {
    if (_initialized) {
      _close();
      _initialized = false;
    }
  }
}
