import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:camsync_protocol/camsync_protocol.dart';
import '../../device/usb_manager.dart';
import '../../network/stream_client.dart';
import '../../native/camsync_ffi.dart';

class DesktopMainScreen extends StatefulWidget {
  final bool autoStartUsb;
  const DesktopMainScreen({super.key, this.autoStartUsb = true});

  @override
  State<DesktopMainScreen> createState() => _DesktopMainScreenState();
}

class _DesktopMainScreenState extends State<DesktopMainScreen> {
  final UsbManager _usbManager = UsbManager();
  final StreamClient _streamClient = StreamClient();
  final CamSyncNative _native = CamSyncNative();

  final TextEditingController _ipController = TextEditingController(text: '192.168.1.100');
  int _connectionModeIndex = 0; // 0 = USB, 1 = Wi-Fi

  CamSyncConnectionState _connectionState = CamSyncConnectionState.disconnected;
  List<UsbDevice> _usbDevices = [];

  CameraParameters _params = const CameraParameters(
    resolution: CameraResolution.hd720,
    fps: 30,
    lens: CameraLens.backWide,
    zoom: 1.0,
    torch: false,
    focusMode: FocusMode.continuous,
    focusDistance: 0.0,
    exposureMode: ExposureMode.continuous,
    iso: 200,
    shutterSpeedMs: 16.6,
    whiteBalanceMode: WhiteBalanceMode.continuous,
    kelvin: 5500,
    orientation: OrientationMode.landscapeLeft,
    mirror: false,
    oledPowerSave: false,
  );

  DeviceTelemetry _telemetry = const DeviceTelemetry(
    batteryLevel: 100,
    isCharging: false,
    thermalState: 'nominal',
    temperatureC: 30.0,
    encoderBitrateKbps: 0,
    currentFps: 0.0,
  );

  StreamSubscription? _usbSub;
  StreamSubscription? _stateSub;
  StreamSubscription? _telemetrySub;

  ui.Image? _previewImage;
  Timer? _previewTimer;
  int _lastRenderedFrameNum = 0;
  bool _isDecodingFrame = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoStartUsb) {
      _usbManager.startPolling();
    }

    _usbSub = _usbManager.onDevicesChanged.listen((devices) {
      setState(() => _usbDevices = devices);
    });

    _stateSub = _streamClient.onStateChanged.listen((state) {
      setState(() => _connectionState = state);
      if (state == CamSyncConnectionState.connected) {
        _startPreviewLoop();
      } else {
        _stopPreviewLoop();
      }
    });

    _telemetrySub = _streamClient.onTelemetry.listen((t) {
      setState(() => _telemetry = t);
    });
  }

  void _startPreviewLoop() {
    _previewTimer?.cancel();
    _previewTimer = Timer.periodic(const Duration(milliseconds: 16), (_) => _pollPreviewFrame());
  }

  void _stopPreviewLoop() {
    _previewTimer?.cancel();
    _previewTimer = null;
    if (_previewImage != null) {
      _previewImage?.dispose();
      _previewImage = null;
      _lastRenderedFrameNum = 0;
      if (mounted) setState(() {});
    }
  }

  void _pollPreviewFrame() {
    if (_connectionState != CamSyncConnectionState.connected || _isDecodingFrame) return;

    final frame = _native.getLatestFrame();
    if (frame == null || frame.frameNumber == _lastRenderedFrameNum) return;

    _lastRenderedFrameNum = frame.frameNumber;
    _isDecodingFrame = true;

    ui.decodeImageFromPixels(
      frame.bgraBytes,
      frame.width,
      frame.height,
      ui.PixelFormat.rgba8888,
      (img) {
        if (mounted) {
          setState(() {
            _previewImage?.dispose();
            _previewImage = img;
          });
        } else {
          img.dispose();
        }
        _isDecodingFrame = false;
      },
    );
  }

  Future<void> _connectUsb() async {
    _native.setVideoFormat(_params.resolution.width, _params.resolution.height);
    final success = await _streamClient.connect('127.0.0.1');
    if (success) {
      _streamClient.sendParameters(_params);
      _streamClient.requestStream(true);
    }
  }

  Future<void> _connectWifi() async {
    final input = _ipController.text.trim();
    if (input.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please enter the Wi-Fi IP address shown on your phone.'),
            backgroundColor: Colors.orangeAccent,
          ),
        );
      }
      return;
    }

    _native.setVideoFormat(_params.resolution.width, _params.resolution.height);
    final success = await _streamClient.connect(input);
    if (success) {
      _streamClient.sendParameters(_params);
      _streamClient.requestStream(true);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to connect to $input. Verify the IP and ensure streaming is started on your phone.'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  void _disconnect() {
    _stopPreviewLoop();
    _streamClient.requestStream(false);
    _streamClient.disconnect();
  }

  void _updateParams(CameraParameters newParams) {
    if (newParams.resolution != _params.resolution) {
      _native.setVideoFormat(newParams.resolution.width, newParams.resolution.height);
    }
    setState(() => _params = newParams);
    _streamClient.sendParameters(newParams);
  }

  @override
  void dispose() {
    _stopPreviewLoop();
    _usbSub?.cancel();
    _stateSub?.cancel();
    _telemetrySub?.cancel();
    _usbManager.dispose();
    _streamClient.dispose();
    _ipController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F1117),
      body: Column(
        children: [
          _buildTopBar(),
          Expanded(
            child: Row(
              children: [
                Expanded(flex: 3, child: _buildPreviewArea()),
                Container(width: 1, color: Colors.white10),
                SizedBox(width: 380, child: _buildStudioControls()),
              ],
            ),
          ),
          _buildStatusBar(),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    final isConnected = _connectionState == CamSyncConnectionState.connected;
    final isConnecting = _connectionState == CamSyncConnectionState.connecting;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        color: Color(0xFF161922),
        border: Border(bottom: BorderSide(color: Colors.white10)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.blueAccent.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.videocam_rounded, color: Colors.blueAccent, size: 22),
                ),
                const SizedBox(width: 12),
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'CamSync Studio',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.white),
                    ),
                    Text('Windows Virtual Webcam', style: TextStyle(color: Colors.white54, fontSize: 11)),
                  ],
                ),
              ],
            ),
            const SizedBox(width: 24),

            // Connection Mode Tabs
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, icon: Icon(Icons.usb, size: 16), label: Text('USB Cable')),
                ButtonSegment(value: 1, icon: Icon(Icons.wifi, size: 16), label: Text('Wi-Fi')),
              ],
              selected: {_connectionModeIndex},
              onSelectionChanged: isConnected ? null : (set) => setState(() => _connectionModeIndex = set.first),
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
            ),
            const SizedBox(width: 16),

            // Dynamic Connection Controls
            if (_connectionModeIndex == 0) ...[
              if (_usbDevices.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.green.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.greenAccent.withOpacity(0.4)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle, color: Colors.greenAccent, size: 14),
                      const SizedBox(width: 6),
                      Text(
                        _usbDevices.first.model,
                        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                )
              else
                Text(
                  'Searching for USB device (ADB)...',
                  style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 12),
                ),
              const SizedBox(width: 12),
              ElevatedButton.icon(
                onPressed: isConnecting ? null : (isConnected ? _disconnect : _connectUsb),
                icon: Icon(isConnected ? Icons.link_off : Icons.link),
                label: Text(isConnected ? 'Disconnect' : 'Connect USB'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: isConnected ? Colors.redAccent.withOpacity(0.8) : Colors.blueAccent,
                  foregroundColor: Colors.white,
                ),
              ),
            ] else ...[
              SizedBox(
                width: 150,
                height: 36,
                child: TextField(
                  controller: _ipController,
                  style: const TextStyle(fontSize: 13, color: Colors.white),
                  decoration: InputDecoration(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                    filled: true,
                    fillColor: const Color(0xFF1F232F),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                    hintText: 'Phone IP',
                  ),
                ),
              ),
              const SizedBox(width: 10),
              ElevatedButton.icon(
                onPressed: isConnecting ? null : (isConnected ? _disconnect : _connectWifi),
                icon: Icon(isConnected ? Icons.link_off : Icons.wifi),
                label: Text(isConnected ? 'Disconnect' : 'Connect Wi-Fi'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: isConnected ? Colors.redAccent.withOpacity(0.8) : Colors.blueAccent,
                  foregroundColor: Colors.white,
                ),
              ),
            ],

            const SizedBox(width: 24),

            // Virtual Camera Driver Status
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF1E222D),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white12),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.camera_indoor_outlined,
                    size: 16,
                    color: _native.isInitialized ? Colors.greenAccent : Colors.orangeAccent,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _native.isInitialized ? 'Virtual Camera Driver: Ready' : 'Virtual Camera Driver: Offline',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreviewArea() {
    final isConnected = _connectionState == CamSyncConnectionState.connected;

    return Container(
      color: Colors.black,
      child: Stack(
        children: [
          Center(
            child: isConnected && _previewImage != null
                ? AspectRatio(
                    aspectRatio: _previewImage!.width / _previewImage!.height,
                    child: Container(
                      margin: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.blueAccent.withOpacity(0.15),
                            blurRadius: 20,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: RawImage(
                          image: _previewImage,
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  )
                : AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Container(
                      margin: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: const Color(0xFF141720),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              isConnected ? Icons.videocam : Icons.videocam_off_outlined,
                              size: 64,
                              color: isConnected ? Colors.greenAccent : Colors.white24,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              isConnected
                                  ? 'Awaiting Video Frames...'
                                  : 'Phone not connected',
                              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              isConnected
                                  ? 'Ensure streaming is started on your phone'
                                  : 'Connect phone via USB cable or Wi-Fi to begin',
                              style: const TextStyle(color: Colors.white54, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
          ),

          // Floating Telemetry Overlay (Top Left)
          if (isConnected)
            Positioned(
              top: 36,
              left: 36,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.75),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white24),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.fiber_manual_record,
                      color: _telemetry.currentFps > 0 ? Colors.greenAccent : Colors.redAccent,
                      size: 12,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${_telemetry.currentFps.toStringAsFixed(0)} FPS',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      _telemetry.encoderBitrateKbps >= 1000
                          ? '${(_telemetry.encoderBitrateKbps / 1000).toStringAsFixed(1)} Mbps'
                          : '${_telemetry.encoderBitrateKbps} Kbps',
                      style: const TextStyle(color: Colors.lightBlueAccent, fontSize: 13),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      _previewImage != null
                          ? '${_previewImage!.width}x${_previewImage!.height}'
                          : '${_params.resolution.width}x${_params.resolution.height}',
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStudioControls() {
    return Container(
      color: const Color(0xFF141720),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'STUDIO CAMERA CONTROLS',
            style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.2),
          ),
          const SizedBox(height: 16),

          // Lens Switcher
          const Text('Lens Selection', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          SegmentedButton<CameraLens>(
            segments: const [
              ButtonSegment(value: CameraLens.backUltraWide, label: Text('0.5x')),
              ButtonSegment(value: CameraLens.backWide, label: Text('1x')),
              ButtonSegment(value: CameraLens.backTelephoto, label: Text('3x')),
              ButtonSegment(value: CameraLens.front, label: Text('Selfie')),
            ],
            selected: {_params.lens},
            onSelectionChanged: (set) {
              final newLens = set.first;
              double newZoom = _params.zoom;
              if (newLens == CameraLens.backTelephoto && newZoom < 3.0) {
                newZoom = 3.0;
              } else if (newLens == CameraLens.backWide && newZoom >= 3.0) {
                newZoom = 1.0;
              } else if (newLens == CameraLens.backUltraWide && newZoom > 1.0) {
                newZoom = 1.0;
              }
              _updateParams(_params.copyWith(lens: newLens, zoom: newZoom));
            },
          ),
          const SizedBox(height: 20),

          // Resolution & FPS
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Resolution', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<CameraResolution>(
                      value: _params.resolution,
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: const Color(0xFF1E222D),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      ),
                      dropdownColor: const Color(0xFF1E222D),
                      items: const [
                        DropdownMenuItem(value: CameraResolution.hd720, child: Text('720p HD', style: TextStyle(color: Colors.white, fontSize: 12))),
                        DropdownMenuItem(value: CameraResolution.fhd1080, child: Text('1080p FHD', style: TextStyle(color: Colors.white, fontSize: 12))),
                        DropdownMenuItem(value: CameraResolution.uhd4k, child: Text('4K UHD', style: TextStyle(color: Colors.white, fontSize: 12))),
                      ],
                      onChanged: (res) {
                        if (res != null) _updateParams(_params.copyWith(resolution: res));
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Frame Rate', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<int>(
                      value: _params.fps,
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: const Color(0xFF1E222D),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      ),
                      dropdownColor: const Color(0xFF1E222D),
                      items: const [
                        DropdownMenuItem(value: 30, child: Text('30 FPS', style: TextStyle(color: Colors.white, fontSize: 12))),
                        DropdownMenuItem(value: 60, child: Text('60 FPS', style: TextStyle(color: Colors.white, fontSize: 12))),
                      ],
                      onChanged: (fps) {
                        if (fps != null) _updateParams(_params.copyWith(fps: fps));
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Digital Zoom Slider
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Digital Zoom', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
              Text('${_params.zoom.toStringAsFixed(1)}x', style: const TextStyle(color: Colors.lightBlueAccent, fontWeight: FontWeight.bold)),
            ],
          ),
          Slider(
            value: _params.zoom,
            min: 1.0,
            max: 5.0,
            divisions: 40,
            onChanged: (v) => _updateParams(_params.copyWith(zoom: v)),
          ),
          const SizedBox(height: 12),

          // Torch & OLED Power Saver Toggles
          Material(
            color: const Color(0xFF1B1E28),
            borderRadius: BorderRadius.circular(10),
            child: Column(
              children: [
                SwitchListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  title: const Text('Flashlight / Fill Light', style: TextStyle(color: Colors.white, fontSize: 13)),
                  subtitle: const Text('Use phone flash as face illumination', style: TextStyle(color: Colors.white54, fontSize: 11)),
                  value: _params.torch,
                  activeColor: Colors.amberAccent,
                  onChanged: (val) => _updateParams(_params.copyWith(torch: val)),
                ),
                const Divider(color: Colors.white10, height: 1),
                SwitchListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  title: const Text('Phone OLED Power Saver', style: TextStyle(color: Colors.white, fontSize: 13)),
                  subtitle: const Text('Blacks out phone screen to eliminate heat and battery drain', style: TextStyle(color: Colors.white54, fontSize: 11)),
                  value: _params.oledPowerSave,
                  activeColor: Colors.greenAccent,
                  onChanged: (val) => _updateParams(_params.copyWith(oledPowerSave: val)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Orientation & Mirroring
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    final next = _params.orientation == OrientationMode.landscapeLeft
                        ? OrientationMode.portrait
                        : OrientationMode.landscapeLeft;
                    _updateParams(_params.copyWith(orientation: next));
                  },
                  icon: const Icon(Icons.screen_rotation, size: 16),
                  label: Text(_params.orientation == OrientationMode.landscapeLeft ? 'Landscape' : 'Portrait'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _updateParams(_params.copyWith(mirror: !_params.mirror)),
                  icon: const Icon(Icons.flip, size: 16),
                  label: Text(_params.mirror ? 'Mirrored' : 'Normal'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: const BoxDecoration(
        color: Color(0xFF12141C),
        border: Border(top: BorderSide(color: Colors.white10)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            Row(
              children: [
                Icon(
                  _telemetry.isCharging ? Icons.battery_charging_full : Icons.battery_std,
                  size: 16,
                  color: Colors.white70,
                ),
                const SizedBox(width: 4),
                Text(
                  'Phone Battery: ${_telemetry.batteryLevel}%',
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ],
            ),
            const SizedBox(width: 20),
            Row(
              children: [
                const Icon(Icons.thermostat, size: 16, color: Colors.white70),
                const SizedBox(width: 4),
                Text(
                  'Thermal: ${_telemetry.thermalState} (${_telemetry.temperatureC.toStringAsFixed(1)}°C)',
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ],
            ),
            const SizedBox(width: 24),
            Text(
              'CamSync v1.0.0 • Open Source • 100% Free',
              style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}
