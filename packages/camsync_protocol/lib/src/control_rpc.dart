import 'dart:convert';
import 'models.dart';

/// Standard JSON-RPC 2.0 message envelope.
class ControlRpcMessage {
  final String jsonrpc;
  final dynamic id; // null for notifications
  final String? method;
  final Map<String, dynamic>? params;
  final dynamic result;
  final Map<String, dynamic>? error;

  const ControlRpcMessage({
    this.jsonrpc = '2.0',
    this.id,
    this.method,
    this.params,
    this.result,
    this.error,
  });

  bool get isRequest => id != null && method != null;
  bool get isNotification => id == null && method != null;
  bool get isResponse => id != null && method == null;
  bool get isError => error != null;

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{'jsonrpc': jsonrpc};
    if (id != null) map['id'] = id;
    if (method != null) map['method'] = method;
    if (params != null) map['params'] = params;
    if (result != null) map['result'] = result;
    if (error != null) map['error'] = error;
    return map;
  }

  /// Encodes this message as a single-line UTF-8 JSON string with trailing newline.
  String encode() => '${jsonEncode(toJson())}\n';

  factory ControlRpcMessage.fromJson(Map<String, dynamic> json) {
    return ControlRpcMessage(
      jsonrpc: json['jsonrpc'] as String? ?? '2.0',
      id: json['id'],
      method: json['method'] as String?,
      params: json['params'] as Map<String, dynamic>?,
      result: json['result'],
      error: json['error'] as Map<String, dynamic>?,
    );
  }

  factory ControlRpcMessage.parseLine(String line) {
    final decoded = jsonDecode(line.trim()) as Map<String, dynamic>;
    return ControlRpcMessage.fromJson(decoded);
  }

  // --- Factory constructors for standard RPC actions ---

  /// Handshake message sent upon initial connection.
  static ControlRpcMessage handshakeRequest({
    required int id,
    required String clientName,
    required String clientVersion,
  }) {
    return ControlRpcMessage(
      id: id,
      method: 'handshake.hello',
      params: {
        'clientName': clientName,
        'clientVersion': clientVersion,
      },
    );
  }

  /// Handshake response.
  static ControlRpcMessage handshakeResponse({
    required dynamic id,
    required String serverName,
    required String serverVersion,
    required List<String> supportedCodecs,
  }) {
    return ControlRpcMessage(
      id: id,
      result: {
        'serverName': serverName,
        'serverVersion': serverVersion,
        'supportedCodecs': supportedCodecs,
      },
    );
  }

  /// Command to set camera parameters remotely.
  static ControlRpcMessage setParametersRequest({
    required int id,
    required CameraParameters parameters,
  }) {
    return ControlRpcMessage(
      id: id,
      method: 'camera.setParameters',
      params: parameters.toJson(),
    );
  }

  /// Telemetry notification broadcast from phone to desktop companion.
  static ControlRpcMessage telemetryNotification({
    required DeviceTelemetry telemetry,
  }) {
    return ControlRpcMessage(
      method: 'device.telemetry',
      params: telemetry.toJson(),
    );
  }

  /// Command to start/stop the video stream.
  static ControlRpcMessage streamControlRequest({
    required int id,
    required bool start,
    int? requestedFps,
    CameraResolution? requestedResolution,
  }) {
    return ControlRpcMessage(
      id: id,
      method: start ? 'stream.start' : 'stream.stop',
      params: {
        if (requestedFps != null) 'fps': requestedFps,
        if (requestedResolution != null) 'resolution': requestedResolution.toJson(),
      },
    );
  }

  /// Standard success response.
  static ControlRpcMessage successResponse({
    required dynamic id,
    dynamic result = true,
  }) {
    return ControlRpcMessage(
      id: id,
      result: result,
    );
  }

  /// Standard error response.
  static ControlRpcMessage errorResponse({
    required dynamic id,
    required int code,
    required String message,
  }) {
    return ControlRpcMessage(
      id: id,
      error: {
        'code': code,
        'message': message,
      },
    );
  }
}
