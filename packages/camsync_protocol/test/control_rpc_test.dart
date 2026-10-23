import 'package:test/test.dart';
import 'package:camsync_protocol/camsync_protocol.dart';

void main() {
  group('ControlRpcMessage', () {
    test('serializes and parses handshake request/response', () {
      final req = ControlRpcMessage.handshakeRequest(
        id: 1,
        clientName: 'CamSyncDesktop',
        clientVersion: '1.0.0',
      );

      final encoded = req.encode();
      expect(encoded.endsWith('\n'), isTrue);

      final parsed = ControlRpcMessage.parseLine(encoded);
      expect(parsed.id, equals(1));
      expect(parsed.method, equals('handshake.hello'));
      expect(parsed.params?['clientName'], equals('CamSyncDesktop'));
      expect(parsed.isRequest, isTrue);

      final resp = ControlRpcMessage.handshakeResponse(
        id: 1,
        serverName: 'CamSyncMobile',
        serverVersion: '1.0.0',
        supportedCodecs: ['h264', 'hevc'],
      );
      final respParsed = ControlRpcMessage.parseLine(resp.encode());
      expect(respParsed.id, equals(1));
      expect(respParsed.isResponse, isTrue);
      expect(respParsed.result['serverName'], equals('CamSyncMobile'));
    });

    test('serializes and parses camera.setParameters with all fields', () {
      final params = const CameraParameters(
        resolution: CameraResolution.uhd4k,
        fps: 60,
        lens: CameraLens.backUltraWide,
        zoom: 2.0,
        torch: true,
        focusMode: FocusMode.manual,
        focusDistance: 0.42,
        exposureMode: ExposureMode.manual,
        iso: 400,
        shutterSpeedMs: 8.33,
        whiteBalanceMode: WhiteBalanceMode.manual,
        kelvin: 5600,
        orientation: OrientationMode.landscapeRight,
        mirror: true,
        oledPowerSave: true,
      );

      final req = ControlRpcMessage.setParametersRequest(id: 10, parameters: params);
      final parsed = ControlRpcMessage.parseLine(req.encode());

      expect(parsed.method, equals('camera.setParameters'));
      final parsedParams = CameraParameters.fromJson(parsed.params!);

      expect(parsedParams.resolution, equals(CameraResolution.uhd4k));
      expect(parsedParams.fps, equals(60));
      expect(parsedParams.lens, equals(CameraLens.backUltraWide));
      expect(parsedParams.zoom, equals(2.0));
      expect(parsedParams.torch, isTrue);
      expect(parsedParams.focusMode, equals(FocusMode.manual));
      expect(parsedParams.focusDistance, equals(0.42));
      expect(parsedParams.iso, equals(400));
      expect(parsedParams.kelvin, equals(5600));
      expect(parsedParams.orientation, equals(OrientationMode.landscapeRight));
      expect(parsedParams.mirror, isTrue);
      expect(parsedParams.oledPowerSave, isTrue);
    });

    test('serializes and parses telemetry notification', () {
      const telemetry = DeviceTelemetry(
        batteryLevel: 94,
        isCharging: true,
        thermalState: 'nominal',
        temperatureC: 32.5,
        encoderBitrateKbps: 18000,
        currentFps: 59.9,
      );

      final notif = ControlRpcMessage.telemetryNotification(telemetry: telemetry);
      expect(notif.isNotification, isTrue);

      final parsed = ControlRpcMessage.parseLine(notif.encode());
      expect(parsed.method, equals('device.telemetry'));
      final parsedTelemetry = DeviceTelemetry.fromJson(parsed.params!);

      expect(parsedTelemetry.batteryLevel, equals(94));
      expect(parsedTelemetry.isCharging, isTrue);
      expect(parsedTelemetry.thermalState, equals('nominal'));
      expect(parsedTelemetry.temperatureC, closeTo(32.5, 0.01));
      expect(parsedTelemetry.encoderBitrateKbps, equals(18000));
      expect(parsedTelemetry.currentFps, closeTo(59.9, 0.01));
    });

    test('serializes and parses error response', () {
      final err = ControlRpcMessage.errorResponse(
        id: 5,
        code: -32601,
        message: 'Method not found',
      );
      final parsed = ControlRpcMessage.parseLine(err.encode());
      expect(parsed.isError, isTrue);
      expect(parsed.error?['code'], equals(-32601));
      expect(parsed.error?['message'], equals('Method not found'));
    });
  });
}
