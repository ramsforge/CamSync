/// Camera resolution descriptor.
class CameraResolution {
  final int width;
  final int height;

  const CameraResolution(this.width, this.height);

  static const CameraResolution hd720 = CameraResolution(1280, 720);
  static const CameraResolution fhd1080 = CameraResolution(1920, 1080);
  static const CameraResolution qhd1440 = CameraResolution(2560, 1440);
  static const CameraResolution uhd4k = CameraResolution(3840, 2160);

  Map<String, dynamic> toJson() => {'width': width, 'height': height};

  factory CameraResolution.fromJson(Map<String, dynamic> json) =>
      CameraResolution(json['width'] as int, json['height'] as int);

  @override
  String toString() => '${width}x$height';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CameraResolution &&
          runtimeType == other.runtimeType &&
          width == other.width &&
          height == other.height;

  @override
  int get hashCode => width.hashCode ^ height.hashCode;
}

/// Physical phone camera lens.
enum CameraLens {
  backWide('back_wide', 'Back Main (1x)'),
  backUltraWide('back_ultra_wide', 'Back Ultra-Wide (0.5x)'),
  backTelephoto('back_telephoto', 'Back Telephoto (3x/5x)'),
  front('front', 'Front (Selfie)');

  final String id;
  final String label;
  const CameraLens(this.id, this.label);

  static CameraLens fromId(String id) {
    for (final lens in values) {
      if (lens.id == id) return lens;
    }
    return CameraLens.backWide;
  }
}

/// Autofocus mode.
enum FocusMode {
  auto('auto'),
  continuous('continuous'),
  manual('manual');

  final String id;
  const FocusMode(this.id);

  static FocusMode fromId(String id) {
    return values.firstWhere((e) => e.id == id, orElse: () => FocusMode.auto);
  }
}

/// Exposure mode.
enum ExposureMode {
  auto('auto'),
  continuous('continuous'),
  manual('manual');

  final String id;
  const ExposureMode(this.id);

  static ExposureMode fromId(String id) {
    return values.firstWhere((e) => e.id == id, orElse: () => ExposureMode.auto);
  }
}

/// White balance mode.
enum WhiteBalanceMode {
  auto('auto'),
  continuous('continuous'),
  manual('manual');

  final String id;
  const WhiteBalanceMode(this.id);

  static WhiteBalanceMode fromId(String id) {
    return values.firstWhere((e) => e.id == id, orElse: () => WhiteBalanceMode.auto);
  }
}

/// Video orientation lock.
enum OrientationMode {
  portrait('portrait'),
  landscapeLeft('landscape_left'),
  landscapeRight('landscape_right'),
  portraitUpsideDown('portrait_upside_down');

  final String id;
  const OrientationMode(this.id);

  static OrientationMode fromId(String id) {
    return values.firstWhere((e) => e.id == id, orElse: () => OrientationMode.landscapeLeft);
  }
}

/// Full camera control settings snapshot.
class CameraParameters {
  final CameraResolution resolution;
  final int fps;
  final CameraLens lens;
  final double zoom;
  final bool torch;
  final FocusMode focusMode;
  final double focusDistance; // 0.0 (infinity) to 1.0 (macro)
  final ExposureMode exposureMode;
  final int? iso;
  final double? shutterSpeedMs;
  final WhiteBalanceMode whiteBalanceMode;
  final int? kelvin;
  final OrientationMode orientation;
  final bool mirror;
  final bool oledPowerSave;

  const CameraParameters({
    this.resolution = CameraResolution.fhd1080,
    this.fps = 60,
    this.lens = CameraLens.backWide,
    this.zoom = 1.0,
    this.torch = false,
    this.focusMode = FocusMode.continuous,
    this.focusDistance = 0.0,
    this.exposureMode = ExposureMode.continuous,
    this.iso,
    this.shutterSpeedMs,
    this.whiteBalanceMode = WhiteBalanceMode.continuous,
    this.kelvin,
    this.orientation = OrientationMode.landscapeLeft,
    this.mirror = false,
    this.oledPowerSave = false,
  });

  Map<String, dynamic> toJson() => {
        'resolution': resolution.toJson(),
        'fps': fps,
        'lens': lens.id,
        'zoom': zoom,
        'torch': torch,
        'focusMode': focusMode.id,
        'focusDistance': focusDistance,
        'exposureMode': exposureMode.id,
        'iso': iso,
        'shutterSpeedMs': shutterSpeedMs,
        'whiteBalanceMode': whiteBalanceMode.id,
        'kelvin': kelvin,
        'orientation': orientation.id,
        'mirror': mirror,
        'oledPowerSave': oledPowerSave,
      };

  factory CameraParameters.fromJson(Map<String, dynamic> json) {
    return CameraParameters(
      resolution: json['resolution'] != null
          ? CameraResolution.fromJson(json['resolution'] as Map<String, dynamic>)
          : CameraResolution.fhd1080,
      fps: json['fps'] as int? ?? 60,
      lens: CameraLens.fromId(json['lens'] as String? ?? 'back_wide'),
      zoom: (json['zoom'] as num?)?.toDouble() ?? 1.0,
      torch: json['torch'] as bool? ?? false,
      focusMode: FocusMode.fromId(json['focusMode'] as String? ?? 'continuous'),
      focusDistance: (json['focusDistance'] as num?)?.toDouble() ?? 0.0,
      exposureMode: ExposureMode.fromId(json['exposureMode'] as String? ?? 'continuous'),
      iso: json['iso'] as int?,
      shutterSpeedMs: (json['shutterSpeedMs'] as num?)?.toDouble(),
      whiteBalanceMode:
          WhiteBalanceMode.fromId(json['whiteBalanceMode'] as String? ?? 'continuous'),
      kelvin: json['kelvin'] as int?,
      orientation: OrientationMode.fromId(json['orientation'] as String? ?? 'landscape_left'),
      mirror: json['mirror'] as bool? ?? false,
      oledPowerSave: json['oledPowerSave'] as bool? ?? false,
    );
  }

  CameraParameters copyWith({
    CameraResolution? resolution,
    int? fps,
    CameraLens? lens,
    double? zoom,
    bool? torch,
    FocusMode? focusMode,
    double? focusDistance,
    ExposureMode? exposureMode,
    int? iso,
    double? shutterSpeedMs,
    WhiteBalanceMode? whiteBalanceMode,
    int? kelvin,
    OrientationMode? orientation,
    bool? mirror,
    bool? oledPowerSave,
  }) {
    return CameraParameters(
      resolution: resolution ?? this.resolution,
      fps: fps ?? this.fps,
      lens: lens ?? this.lens,
      zoom: zoom ?? this.zoom,
      torch: torch ?? this.torch,
      focusMode: focusMode ?? this.focusMode,
      focusDistance: focusDistance ?? this.focusDistance,
      exposureMode: exposureMode ?? this.exposureMode,
      iso: iso ?? this.iso,
      shutterSpeedMs: shutterSpeedMs ?? this.shutterSpeedMs,
      whiteBalanceMode: whiteBalanceMode ?? this.whiteBalanceMode,
      kelvin: kelvin ?? this.kelvin,
      orientation: orientation ?? this.orientation,
      mirror: mirror ?? this.mirror,
      oledPowerSave: oledPowerSave ?? this.oledPowerSave,
    );
  }
}

/// Telemetry reporting device battery, thermal status, and real-time streaming stats.
class DeviceTelemetry {
  final int batteryLevel; // 0 - 100
  final bool isCharging;
  final String thermalState; // 'nominal', 'fair', 'serious', 'critical'
  final double temperatureC;
  final int encoderBitrateKbps;
  final double currentFps;

  const DeviceTelemetry({
    required this.batteryLevel,
    required this.isCharging,
    required this.thermalState,
    required this.temperatureC,
    required this.encoderBitrateKbps,
    required this.currentFps,
  });

  Map<String, dynamic> toJson() => {
        'batteryLevel': batteryLevel,
        'isCharging': isCharging,
        'thermalState': thermalState,
        'temperatureC': temperatureC,
        'encoderBitrateKbps': encoderBitrateKbps,
        'currentFps': currentFps,
      };

  factory DeviceTelemetry.fromJson(Map<String, dynamic> json) {
    return DeviceTelemetry(
      batteryLevel: json['batteryLevel'] as int? ?? 100,
      isCharging: json['isCharging'] as bool? ?? false,
      thermalState: json['thermalState'] as String? ?? 'nominal',
      temperatureC: (json['temperatureC'] as num?)?.toDouble() ?? 25.0,
      encoderBitrateKbps: json['encoderBitrateKbps'] as int? ?? 0,
      currentFps: (json['currentFps'] as num?)?.toDouble() ?? 0.0,
    );
  }
}
